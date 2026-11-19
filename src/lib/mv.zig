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

/// rm -r on the source after an inter-device copy.
fn removeTree(c: *copy.Copier, path: []const u8, verbose: bool) bool {
    const env = c.env;
    var e: E = .SUCCESS;
    const st = sys.fileStat(path, false, &e) orelse {
        c.errPrint("cannot remove {f}: {s}", .{ quote.quoteA(path), sys.errnoText(e) });
        return false;
    };
    var ok = true;
    if (st.isDir()) {
        var dir = Io.Dir.cwd().openDir(env.io, path, .{ .iterate = true }) catch |err| {
            c.errPrint("cannot remove {f}: {s}", .{ quote.quoteA(path), errtext.errText(err) });
            return false;
        };
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| env.gpa.free(n);
            names.deinit(env.gpa);
        }
        var it = dir.iterate();
        while (it.next(env.io) catch null) |entry| {
            const dup = env.gpa.dupe(u8, entry.name) catch break;
            names.append(env.gpa, dup) catch {
                env.gpa.free(dup);
                break;
            };
        }
        dir.close(env.io);
        for (names.items) |n| {
            const child = copy.joinName(env.gpa, path, n) catch continue;
            defer env.gpa.free(child);
            if (!removeTree(c, child, verbose)) ok = false;
        }
        if (ok) {
            if (sys.unlinkPath(path, true)) |ue| {
                c.errPrint("cannot remove {f}: {s}", .{ quote.quoteA(path), sys.errnoText(ue) });
                return false;
            }
            if (verbose) say(c, "removed directory {f}\n", .{quote.quoteA(path)});
        }
        return ok;
    }
    if (sys.unlinkPath(path, false)) |ue| {
        c.errPrint("cannot remove {f}: {s}", .{ quote.quoteA(path), sys.errnoText(ue) });
        return false;
    }
    if (verbose) say(c, "removed {f}\n", .{quote.quoteA(path)});
    return true;
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
            if (!removeTree(c, source, c.x.verbose)) ok = false;
        }
    }
    return ok;
}
