// SPDX-License-Identifier: GPL-2.0-or-later
//! Backup file naming and renaming (gnulib backupfile.c, coreutils 9.6,
//! consulted 2026-11-07) shared by cp, mv, install and ln. Library code (decision
//! 0004): no argument handling and no process-wide state; the caller resolves
//! the version-control argument and the suffix (see backup_args.zig).

const std = @import("std");
const common = @import("lib/common.zig");
const sys = @import("sys.zig");
const Io = std.Io;
const E = std.os.linux.E;

pub const Type = enum { none, simple, numbered_existing, numbered };

const ListError = error{ OutOfMemory, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, ListFailed };

fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    var d = slash;
    while (d > 0 and path[d - 1] == '/') d -= 1;
    return if (d == 0) "/" else path[0..d];
}

/// The number of the highest existing numbered backup of `file`, as its
/// digits (allocated with `arena`), or "" when there is none. A name is chosen
/// by whoever can create files in that directory, so the number may be larger
/// than any integer type; it is kept and incremented as text.
///
/// A listing that fails is an error, not "none": `--backup=existing` would
/// then make a simple backup, over an older one. The exception is a directory
/// that may not be listed, or is not there: GNU too carries on as if it held
/// no numbered backups.
fn highestNumbered(env: common.Env, arena: std.mem.Allocator, from: sys.Handle, file: []const u8, base: []const u8) ListError![]const u8 {
    const start: Io.Dir = .{ .handle = from };
    var dir = start.openDir(env.io, dirOf(file), .{ .iterate = true }) catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied, error.FileNotFound, error.NotDir => return "",
        error.ProcessFdQuotaExceeded => return error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded => return error.SystemFdQuotaExceeded,
        error.SystemResources => return error.OutOfMemory,
        else => return error.ListFailed,
    };
    defer dir.close(env.io);
    var best: []u8 = &.{};
    var it = dir.iterate();
    while (it.next(env.io) catch return error.ListFailed) |entry| {
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
        if (!ok or !laterNumber(digits, best)) continue;
        best = try arena.dupe(u8, digits);
    }
    return best;
}

/// Whether the number `a` is greater than `b`; neither has leading zeros.
fn laterNumber(a: []const u8, b: []const u8) bool {
    return if (a.len != b.len) a.len > b.len else std.mem.order(u8, a, b) == .gt;
}

/// The decimal number after `digits` ("" counts as zero).
fn increment(arena: std.mem.Allocator, digits: []const u8) error{OutOfMemory}![]const u8 {
    // One spare leading zero takes the carry out of a run of nines.
    const out = try arena.alloc(u8, digits.len + 1);
    out[0] = '0';
    @memcpy(out[1..], digits);
    var i = out.len - 1;
    while (out[i] == '9') : (i -= 1) out[i] = '0';
    out[i] += 1;
    return if (out[0] == '0') out[1..] else out;
}

fn nameFor(env: common.Env, suffix: []const u8, arena: std.mem.Allocator, from: sys.Handle, file: []const u8, btype: *Type, numbered_ok: *bool) ![]const u8 {
    var end = file.len;
    while (end > 1 and file[end - 1] == '/') end -= 1;
    const f = file[0..end];
    const base_off = if (std.mem.lastIndexOfScalar(u8, f, '/')) |s| s + 1 else 0;
    const base = f[base_off..];
    numbered_ok.* = true;
    if (btype.* == .simple) return std.fmt.allocPrint(arena, "{s}{s}", .{ f, suffix });
    const highest = try highestNumbered(env, arena, from, f, base);
    if (highest.len == 0 and btype.* == .numbered_existing) {
        btype.* = .simple;
        return std.fmt.allocPrint(arena, "{s}{s}", .{ f, suffix });
    }
    return std.fmt.allocPrint(arena, "{s}.~{s}~", .{ f, try increment(arena, highest) });
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
        const name = nameFor(env, suffix, arena, dir, file, &bt, &ok) catch |e| {
            err.* = switch (e) {
                error.OutOfMemory => .NOMEM,
                error.ProcessFdQuotaExceeded => .MFILE,
                error.SystemFdQuotaExceeded => .NFILE,
                else => .IO,
            };
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

test "a listing that fails is not taken for one without numbered backups" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const env: common.Env = .{ .io = std.testing.io, .gpa = std.testing.allocator, .environ = null };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(std.testing.io, "loop", "loop", .{});
    const from = tmp.dir.handle;
    try std.testing.expectError(error.ListFailed, highestNumbered(env, arena_state.allocator(), from, "loop/f", "f"));
    // No directory there: the rename that follows will say so.
    try std.testing.expectEqualStrings("", try highestNumbered(env, arena_state.allocator(), from, "nowhere/f", "f"));
}

test "backup numbers are incremented as text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][2][]const u8{
        .{ "", "1" },
        .{ "1", "2" },
        .{ "9", "10" },
        .{ "199", "200" },
        .{ "18446744073709551615", "18446744073709551616" },
        .{ "99999999999999999999999", "100000000000000000000000" },
    }) |case| try std.testing.expectEqualStrings(case[1], try increment(arena, case[0]));
    try std.testing.expect(laterNumber("10", "9"));
    try std.testing.expect(laterNumber("1", ""));
    try std.testing.expect(!laterNumber("5", "5"));
}
