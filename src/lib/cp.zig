// SPDX-License-Identifier: GPL-2.0-or-later
//! cp library: copy files and directories.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "cp invocation"
//! (9.7), POSIX.1-2024 cp, GNU coreutils 9.6 src/cp.c (target-directory
//! logic, --parents) and src/copy.c (see src/copy.zig, the shared engine).
//!
//! The caller parses the command line, resolves what the destination is and
//! passes the `Options` (the engine's option set), the operands and a
//! `Destination`. Diagnostics, verbose lines and prompts come back through
//! `copy.Sink`.

const std = @import("std");
const common = @import("common.zig");
const copy = @import("../copy.zig");
const backup = @import("../backup.zig");
const quote = @import("../quote.zig");
const sys = @import("../sys.zig");
const posixacl = @import("../posixacl.zig");
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
    /// Copy every source into this directory.
    directory: []const u8,
    /// `sources` is [source, dest]: copy source onto dest. `new_dst` says the
    /// destination does not exist yet.
    file: struct { new_dst: bool },
};

pub const Params = struct {
    destination: Destination,
    /// --parents: re-create the source's directory path under the target.
    parents: bool = false,
    /// --strip-trailing-slashes.
    strip_trailing_slashes: bool = false,
};

/// Copy `sources` as `params` says. Returns false when any copy failed.
pub fn run(env: Env, x: Options, sources: []const []const u8, params: Params, sink: Sink) error{OutOfMemory}!bool {
    var c = copy.Copier.init(env, sink, x);
    defer c.deinit();
    var ok = true;
    var new_dst = false;

    switch (params.destination) {
        .directory => |target| {
            if (sources.len >= 2) {
                c.x.track_dest = true;
                c.x.track_src = true;
            }
            for (sources) |arg_in| {
                const arg = if (params.strip_trailing_slashes) stripTrailingSlashes(arg_in) else arg_in;
                var dst_name: []u8 = undefined;
                var parent_exists = true;
                // --parents: the directory made or found to copy into.
                var parent_dir: ?sys.FileStat = null;
                var attr_list: std.ArrayList(DirAttr) = .empty;
                defer attr_list.deinit(env.gpa);
                if (params.parents) {
                    const a2 = stripTrailingSlashes(arg);
                    dst_name = try copy.joinName(env.gpa, target, a2);
                    parent_exists = makeDirParents(&c, dst_name, a2, &attr_list, &parent_dir, &new_dst, x);
                } else {
                    var base = lastComponent(arg);
                    base = stripTrailingSlashes(base);
                    if (std.mem.eql(u8, base, "..")) base = base[0..0];
                    dst_name = try copy.joinName(env.gpa, target, base);
                }
                defer env.gpa.free(dst_name);
                if (!parent_exists) {
                    ok = false;
                } else {
                    var into_self = false;
                    var rs: ?bool = null;
                    if (parent_dir) |seen| {
                        if (!copyBelow(&c, arg, dst_name, seen, new_dst, &into_self, &rs)) ok = false;
                    } else if (!c.copy(arg, dst_name, @intFromBool(new_dst), &into_self, &rs)) ok = false;
                    if (params.parents) {
                        if (!reProtect(&c, dst_name, stripTrailingSlashes(arg), attr_list.items, x)) ok = false;
                    }
                }
            }
        },
        .file => |f| {
            const source = sources[0];
            var dest = sources[1];
            if (c.x.unlink_dest_after_failed_open and c.x.backup_type != .none and std.mem.eql(u8, source, dest) and !f.new_dst) {
                var e: E = .SUCCESS;
                const st2 = sys.fileStat(dest, true, &e);
                if (st2 != null and st2.?.isReg()) {
                    if (backup.findBackupName(env, x.backup_suffix, c.arena.allocator(), dest, c.x.backup_type)) |nb| {
                        dest = nb;
                        c.x.backup_type = .none;
                    }
                }
            }
            var into_self = false;
            var rs: ?bool = null;
            ok = c.copy(source, dest, -@as(i32, @intFromBool(f.new_dst)), &into_self, &rs);
        },
    }
    return ok;
}

pub fn stripTrailingSlashes(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn lastComponent(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const t = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, t, '/');
    return if (slash) |s| t[s + 1 ..] else t;
}

/// Copy `source` to `dst_name`, whose leading directories lead to `seen`.
/// That directory is held open, so that replacing one of those below the target
/// while the copy runs does not move the copy elsewhere.
fn copyBelow(c: *copy.Copier, source: []const u8, dst_name: []const u8, seen: sys.FileStat, new_dst: bool, into_self: *bool, rename_succeeded: *?bool) bool {
    const dir_name = dst_name[0..dirLen(dst_name)];
    var level: dirat.Level = undefined;
    if (dirat.enter(&level, null, dir_name, .{ .follow = true, .expect = seen, .same_device = true, .path_only = true })) |e| {
        warn(c, "cannot access {f}: {s}", .{ quote.quoteA(dir_name), sys.errnoText(e) });
        return false;
    }
    defer _ = dirat.leave(&level);
    var name = dst_name[dir_name.len..];
    while (name.len > 0 and name[0] == '/') name = name[1..];
    return c.copyAt(source, .{ .dir = &level, .name = name }, dst_name, @intFromBool(new_dst), into_self, rename_succeeded);
}

const DirAttr = struct {
    st: sys.FileStat,
    /// The directory below the target that `st` is for.
    made: sys.FileStat = undefined,
    slash_offset: usize,
    restore_mode: bool,
};

/// A diagnostic without the flush the engine's own messages do first (the
/// --parents code never flushed).
fn warn(c: *copy.Copier, comptime fmt: []const u8, args: anytype) void {
    const t = std.fmt.allocPrint(c.gpa, fmt, args) catch return;
    defer c.gpa.free(t);
    c.sink.observer.emit(.{ .diag = t });
}

/// make_dir_parents_private: create the leading directories of `dst_name`
/// below the target; `src` is the source name appended to the target. Each
/// is made, changed and entered by name in the one above it. `parent_dir` is
/// set to the last of them, when there is any.
fn makeDirParents(c: *copy.Copier, dst_name: []const u8, src: []const u8, attr_list: *std.ArrayList(DirAttr), parent_dir: *?sys.FileStat, new_dst: *bool, x: copy.Opts) bool {
    var e: E = .SUCCESS;
    // Offset of the source name inside dst_name.
    const src_offset = dst_name.len - src.len;
    const dirlen = dirLen(dst_name);
    if (dirlen <= src_offset) return true;
    const dst_dir = dst_name[0..dirlen];
    var rel_start: usize = src_offset;
    while (rel_start < dst_name.len and dst_name[rel_start] == '/') rel_start += 1;
    const have = sys.fileStat(dst_dir, true, &e);
    if (have == null) {
        var slash = rel_start;
        var above = sys.openFd(dst_name[0..src_offset], sys.O.PATH | sys.O.DIRECTORY, 0, &e) orelse {
            warn(c, "failed to get attributes of {f}: {s}", .{ quote.quoteA(dst_name[0..src_offset]), sys.errnoText(e) });
            return false;
        };
        defer _ = sys.closeFd(above);
        while (std.mem.indexOfScalarPos(u8, dst_name, slash, '/')) |sl| {
            const dir_part = dst_name[0..sl];
            const name = dst_name[slash..sl];
            const src_part = dst_name[src_offset..sl];
            const dstat = sys.fileStatAt(above, name, true, &e);
            const missing = dstat == null;
            var wanted_here = false;
            if (missing or x.preserve_ownership or x.preserve_mode or x.preserve_timestamps) {
                var se: E = .SUCCESS;
                const sst = sys.fileStat(src_part, true, &se);
                const src_errno: E = if (sst == null) se else if (sst.?.isDir()) .SUCCESS else .NOTDIR;
                if (src_errno != .SUCCESS) {
                    warn(c, "failed to get attributes of {f}: {s}", .{ quote.quoteA(src_part), sys.errnoText(src_errno) });
                    return false;
                }
                attr_list.insert(c.gpa, 0, .{ .st = sst.?, .slash_offset = sl, .restore_mode = false }) catch {
                    warn(c, "memory exhausted", .{});
                    return false;
                };
                wanted_here = true;
            }
            if (missing) {
                new_dst.* = true;
                const src_mode = attr_list.items[0].st.mode;
                const omitted: u32 = src_mode & (if (x.preserve_ownership) @as(u32, 0o077) else if (x.preserve_mode) @as(u32, 0o022) else 0);
                var mkdir_mode: u32 = if (x.explicit_no_preserve_mode) 0o777 else src_mode;
                mkdir_mode &= 0o7777 & ~omitted;
                if (sys.mkdirAt(above, name, mkdir_mode)) |me| {
                    warn(c, "cannot make directory {f}: {s}", .{ quote.quoteA(dir_part), sys.errnoText(me) });
                    return false;
                }
                if (x.verbose) {
                    var buf: [8192]u8 = undefined;
                    const t = std.fmt.bufPrint(&buf, "{s} -> {s}\n", .{ src_part, dir_part }) catch "";
                    c.sink.observer.emit(.{ .out = t });
                }
                const stats = sys.fileStatAt(above, name, false, &e) orelse {
                    warn(c, "failed to get attributes of {f}: {s}", .{ quote.quoteA(dir_part), sys.errnoText(e) });
                    return false;
                };
                var om = omitted;
                if (!x.preserve_mode) {
                    if (om & ~stats.mode != 0) om &= ~x.umask;
                    if (om & ~stats.mode != 0 or (stats.mode & 0o700) != 0o700) {
                        attr_list.items[0].st.mode = stats.mode | om;
                        attr_list.items[0].restore_mode = true;
                    }
                }
                const accessible = stats.mode | 0o700;
                if (stats.mode != accessible) {
                    const made: dirat.Spot = .{ .dir = above, .name = name };
                    if (made.setMode(0o040000, accessible)) |ce| {
                        warn(c, "setting permissions for {f}: {s}", .{ quote.quoteA(dir_part), sys.errnoText(ce) });
                        return false;
                    }
                }
            } else if (!dstat.?.isDir()) {
                warn(c, "{f} exists but is not a directory", .{quote.quoteA(dir_part)});
                return false;
            } else new_dst.* = false;
            // Into it: through a link only where one was already there.
            var is_link = false;
            if (!missing) {
                const own = sys.fileStatAt(above, name, false, &e);
                is_link = own != null and own.?.isLink();
            }
            const next = sys.openFdAt(above, name, sys.O.PATH | sys.O.DIRECTORY | (if (is_link) 0 else sys.O.NOFOLLOW), 0, &e) orelse {
                warn(c, "cannot access {f}: {s}", .{ quote.quoteA(dir_part), sys.errnoText(e) });
                return false;
            };
            _ = sys.closeFd(above);
            above = next;
            const entered = sys.fstatFd(above, &e) orelse {
                warn(c, "failed to get attributes of {f}: {s}", .{ quote.quoteA(dir_part), sys.errnoText(e) });
                return false;
            };
            if (wanted_here) attr_list.items[0].made = entered;
            parent_dir.* = entered;
            slash = sl + 1;
            while (slash < dst_name.len and dst_name[slash] == '/') slash += 1;
        }
    } else if (!have.?.isDir()) {
        warn(c, "{f} exists but is not a directory", .{quote.quoteA(dst_dir)});
        return false;
    } else {
        new_dst.* = false;
        parent_dir.* = have;
    }
    return true;
}

fn dirLen(path: []const u8) usize {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return 0;
    var d = slash;
    while (d > 1 and path[d - 1] == '/') d -= 1;
    return if (d == 0) 1 else d;
}

/// `src` is the source name that the end of `dst_name` repeats.
fn reProtect(c: *copy.Copier, dst_name: []const u8, src: []const u8, attrs: []const DirAttr, x: copy.Opts) bool {
    for (attrs) |at| {
        const name = dst_name[0..at.slash_offset];
        const src_part = dst_name[dst_name.len - src.len .. at.slash_offset];
        // Changed through a descriptor on the directory that was made or
        // found, whatever its path leads to by now.
        var level: dirat.Level = undefined;
        if (dirat.enter(&level, null, name, .{ .follow = true, .expect = at.made, .same_device = true, .path_only = true })) |e| {
            warn(c, "failed to preserve attributes of {f}: {s}", .{ quote.quoteA(name), sys.errnoText(e) });
            return false;
        }
        defer _ = dirat.leave(&level);
        const here: dirat.Spot = .{ .dir = level.fd, .name = "." };
        // A name that is a link keeps its own owner changed, as in GNU.
        const owned: dirat.Spot = if (level.through_link) .{ .dir = sys.cwdFd(), .name = name } else here;
        if (x.preserve_timestamps) {
            const ts = [2]sys.TimeSpec{ .{ .sec = at.st.atime_s, .nsec = at.st.atime_ns }, .{ .sec = at.st.mtime_s, .nsec = at.st.mtime_ns } };
            if (sys.setTimesAt(here.dir, here.name, ts, false)) |te| {
                warn(c, "failed to preserve times for {f}: {s}", .{ quote.quoteA(name), sys.errnoText(te) });
                return false;
            }
        }
        if (x.preserve_ownership) {
            if (sys.chownAtDir(owned.dir, owned.name, at.st.uid, at.st.gid, true)) |ce| {
                if (!((ce == .PERM or ce == .INVAL or ce == .ACCES) and !x.chown_privileges)) {
                    warn(c, "failed to preserve ownership for {f}: {s}", .{ quote.quoteA(name), sys.errnoText(ce) });
                    return false;
                }
                _ = sys.chownAtDir(owned.dir, owned.name, std.math.maxInt(u32), at.st.gid, true);
            }
        }
        if (x.preserve_mode) {
            if (posixacl.preserve(.{ .path = src_part }, .{ .entry = .{ .spot = here, .type_bits = 0o040000 } }, at.st.mode & 0o7777, true)) |ce| {
                warn(c, "failed to preserve permissions for {f}: {s}", .{ quote.quoteA(name), sys.errnoText(ce) });
                return false;
            }
        } else if (at.restore_mode) {
            if (here.setMode(0o040000, at.st.mode & 0o7777)) |ce| {
                warn(c, "failed to preserve permissions for {f}: {s}", .{ quote.quoteA(name), sys.errnoText(ce) });
                return false;
            }
        }
    }
    return true;
}
