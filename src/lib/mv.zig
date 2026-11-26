// SPDX-License-Identifier: GPL-2.0-or-later
//! mv library: move (rename) files.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "mv invocation"
//! (9.7), POSIX.1-2024 mv, and GNU coreutils 9.6 src/mv.c; the rename and
//! cross-device copy logic is in src/copy.zig. `--exchange` is not
//! implemented.
//!
//! The caller parses the command line and resolves the destination; this
//! module moves each source (rename, or copy and remove across devices).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const copy = @import("../copy.zig");
const quote = @import("../quote.zig");
const errtext = @import("../errtext.zig");
const sys = @import("../sys.zig");
const dirat = @import("../dirat.zig");
const E = std.os.linux.E;

pub const Env = common.Env;
pub const Options = copy.Opts;
pub const Event = copy.Event;
pub const Observer = copy.Observer;
pub const Prompt = copy.Prompt;
pub const Confirm = copy.Confirm;
pub const Sink = copy.Sink;

pub const Destination = union(enum) {
    /// Move every source into this directory.
    directory: []const u8,
    /// `sources` is [source, dest].
    file,
};

pub const Params = struct {
    destination: Destination,
    /// --strip-trailing-slashes.
    strip_trailing_slashes: bool = false,
};

/// The rename(2) errno GNU mv tries before analysing the operands
/// (RENAME_NOREPLACE; 0 on success). Pass the result as `rename_errno` in
/// `Options` (-1 means not tried).
pub fn probeRename(source: []const u8, dest: []const u8) i32 {
    return if (sys.renamePath(source, dest, sys.RENAME_NOREPLACE)) |re| @intFromEnum(re) else 0;
}

/// Move `sources` as `params` says. Returns false when any move failed.
pub fn run(env: Env, x: Options, sources: []const []const u8, params: Params, sink: Sink) error{OutOfMemory}!bool {
    var c = copy.Copier.init(env, sink, x);
    defer c.deinit();
    var ok = true;
    switch (params.destination) {
        .directory => |td| {
            if (sources.len >= 2) c.x.track_dest = true;
            for (sources, 0..) |src_in, i| {
                c.x.last_file = i + 1 == sources.len;
                const source = if (params.strip_trailing_slashes) stripSlashes(src_in) else src_in;
                const base = lastComponent(source);
                const joined = try copy.joinName(env.gpa, td, base);
                defer env.gpa.free(joined);
                const dest = stripSlashes(joined);
                if (!doMove(&c, source, dest)) ok = false;
            }
        },
        .file => {
            c.x.last_file = true;
            const s0 = if (params.strip_trailing_slashes) stripSlashes(sources[0]) else sources[0];
            const s1 = if (params.strip_trailing_slashes) stripSlashes(sources[1]) else sources[1];
            ok = doMove(&c, s0, s1);
        },
    }
    return ok;
}

fn stripSlashes(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn lastComponent(path: []const u8) []const u8 {
    // GNU last_component keeps trailing slashes (they are stripped later).
    var i = path.len;
    while (i > 0 and path[i - 1] == '/') i -= 1;
    const start = if (std.mem.lastIndexOfScalar(u8, path[0..i], '/')) |s| s + 1 else 0;
    return path[start..path.len];
}

fn say(c: *copy.Copier, comptime fmt: []const u8, args: anytype) void {
    var b: [8200]u8 = undefined;
    c.emit(.{ .out = std.fmt.bufPrint(&b, fmt, args) catch "" });
}

/// rm -r on the source after an inter-device copy. The walk is
/// descriptor-relative (dirat.zig): a symbolic link put where a directory was
/// is removed or refused, never followed. `name` is the file's name in the
/// open directory `parent` (the operand itself when null); `path` is for
/// messages.
fn removeTree(c: *copy.Copier, parent: ?*dirat.Level, name: []const u8, path: []const u8, verbose: bool) bool {
    var e: E = .SUCCESS;
    const st = sys.fileStatAt(dirat.fdOf(parent), name, false, &e) orelse return cannotRemove(c, path, e);
    if (st.isDir()) {
        if (!removeContents(c, parent, name, path, st, verbose)) return false;
        if (sys.unlinkAt(dirat.fdOf(parent), name, true)) |ue| return cannotRemove(c, path, ue);
        if (verbose) say(c, "removed directory {f}\n", .{quote.quoteA(path)});
        return true;
    }
    if (sys.unlinkAt(dirat.fdOf(parent), name, false)) |ue| return cannotRemove(c, path, ue);
    if (verbose) say(c, "removed {f}\n", .{quote.quoteA(path)});
    return true;
}

fn cannotRemove(c: *copy.Copier, path: []const u8, e: E) bool {
    c.errPrint("cannot remove {f}: {s}", .{ quote.quoteA(path), sys.errnoText(e) });
    return false;
}

/// Remove everything in the directory; false when something is left.
fn removeContents(c: *copy.Copier, parent: ?*dirat.Level, name: []const u8, path: []const u8, seen: sys.FileStat, verbose: bool) bool {
    const env = c.env;
    var level: dirat.Level = undefined;
    if (dirat.enter(&level, parent, name, .{ .expect = seen })) |e| return cannotRemove(c, path, e);
    var ok = true;
    var e: E = .SUCCESS;
    if (sys.readDirNamesFd(env.gpa, level.fd, &e)) |names| {
        defer sys.freeDirEntries(env.gpa, names);
        for (names) |n| {
            if (!level.open) break;
            const child = copy.joinName(env.gpa, path, n.name) catch {
                ok = cannotRemove(c, path, .NOMEM);
                break;
            };
            defer env.gpa.free(child);
            if (!removeTree(c, &level, n.name, child, verbose)) ok = false;
        }
    } else ok = cannotRemove(c, path, e);
    if (dirat.leave(&level)) |le| return cannotRemove(c, path, le);
    return ok;
}

fn doMove(c: *copy.Copier, source: []const u8, dest: []const u8) bool {
    var into_self = false;
    var rs: ?bool = false;
    var ok = c.copy(source, dest, 0, &into_self, &rs);
    if (ok) {
        var remove = false;
        if (into_self) {
            ok = false;
        } else if (rs.?) {
            // renamed, or the user declined
        } else remove = true;
        if (remove) {
            if (!removeTree(c, null, source, source, c.x.verbose)) ok = false;
        }
    }
    return ok;
}
