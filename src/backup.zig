// SPDX-License-Identifier: GPL-2.0-or-later
//! Backup file naming and renaming (gnulib backupfile.c, coreutils 9.6,
//! consulted 2026-11-07) shared by cp, mv and install. Library code (decision
//! 0004): no argument handling and no process-wide state; the caller resolves
//! the version-control argument and the suffix (see backup_args.zig).

const std = @import("std");
const common = @import("lib/common.zig");
const sys = @import("sys.zig");
const Io = std.Io;
const E = std.os.linux.E;

pub const Type = enum { none, simple, numbered_existing, numbered };

fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    var d = slash;
    while (d > 0 and path[d - 1] == '/') d -= 1;
    return if (d == 0) "/" else path[0..d];
}

/// Highest existing numbered backup of `file` (0 when none) and whether the
/// number is all 9s.
fn highestNumbered(env: common.Env, from: sys.Handle, file: []const u8, base: []const u8) ?struct { n: u64 } {
    const start: Io.Dir = .{ .handle = from };
    var dir = start.openDir(env.io, dirOf(file), .{ .iterate = true }) catch return null;
    defer dir.close(env.io);
    var best: u64 = 0;
    var found = false;
    var it = dir.iterate();
    while (it.next(env.io) catch null) |entry| {
        const nm = entry.name;
        if (nm.len < base.len + 4) continue;
        if (!std.mem.startsWith(u8, nm, base)) continue;
        if (nm[base.len] != '.' or nm[base.len + 1] != '~') continue;
        const rest = nm[base.len + 2 ..];
        if (rest.len < 2 or rest[rest.len - 1] != '~') continue;
        const digits = rest[0 .. rest.len - 1];
        if (digits[0] < '1' or digits[0] > '9') continue;
        var ok = true;
        for (digits) |d| if (d < '0' or d > '9') {
            ok = false;
        };
        if (!ok) continue;
        const v = std.fmt.parseInt(u64, digits, 10) catch continue;
        if (!found or v > best) best = v;
        found = true;
    }
    if (!found) return .{ .n = 0 };
    return .{ .n = best };
}

fn nameFor(env: common.Env, suffix: []const u8, arena: std.mem.Allocator, from: sys.Handle, file: []const u8, btype: *Type, numbered_ok: *bool) ![]const u8 {
    var end = file.len;
    while (end > 1 and file[end - 1] == '/') end -= 1;
    const f = file[0..end];
    const base_off = if (std.mem.lastIndexOfScalar(u8, f, '/')) |s| s + 1 else 0;
    const base = f[base_off..];
    numbered_ok.* = true;
    if (btype.* == .simple) return std.fmt.allocPrint(arena, "{s}{s}", .{ f, suffix });
    const hi = highestNumbered(env, from, f, base);
    const n: u64 = if (hi) |h| h.n else 0;
    if (n == 0) {
        if (btype.* == .numbered_existing) {
            btype.* = .simple;
            return std.fmt.allocPrint(arena, "{s}{s}", .{ f, suffix });
        }
        return std.fmt.allocPrint(arena, "{s}.~1~", .{f});
    }
    return std.fmt.allocPrint(arena, "{s}.~{d}~", .{ f, n + 1 });
}

/// The name a backup of `file` would get (nothing is renamed).
pub fn findBackupName(env: common.Env, suffix: []const u8, arena: std.mem.Allocator, file: []const u8, btype_in: Type) ?[]const u8 {
    var bt = btype_in;
    var ok: bool = true;
    return nameFor(env, suffix, arena, sys.cwdFd(), file, &bt, &ok) catch null;
}

/// Rename `file`, resolved from the open directory `dir`, to its backup name;
/// returns the new name (relative to `dir` like `file`), or null with `err` set
/// (ENOENT when the file does not exist).
pub fn backupRename(env: common.Env, suffix: []const u8, arena: std.mem.Allocator, dir: sys.Handle, file: []const u8, btype_in: Type, err: *E) ?[]const u8 {
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        var bt = btype_in;
        var ok: bool = true;
        const name = nameFor(env, suffix, arena, dir, file, &bt, &ok) catch {
            err.* = .NOMEM;
            return null;
        };
        var end = file.len;
        while (end > 1 and file[end - 1] == '/') end -= 1;
        const flags: u32 = if (bt == .simple) 0 else sys.RENAME_NOREPLACE;
        if (sys.renameAt(dir, file[0..end], dir, name, flags)) |e| {
            if (e == .EXIST and bt != .simple) continue;
            err.* = e;
            return null;
        }
        return name;
    }
    err.* = .EXIST;
    return null;
}
