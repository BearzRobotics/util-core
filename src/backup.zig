// SPDX-License-Identifier: GPL-2.0-or-later
//! Backup file naming and renaming (gnulib backupfile.c, coreutils 9.6,
//! consulted 2026-11-07) shared by cp, mv, install and ln.

const std = @import("std");
const cli = @import("cli.zig");
const sys = @import("sys.zig");
const argmatch = @import("argmatch.zig");
const Io = std.Io;
const E = std.os.linux.E;

pub const Type = enum { none, simple, numbered_existing, numbered };

pub const version_table = [_]argmatch.Entry{
    .{ .name = "none", .value = 0 },     .{ .name = "off", .value = 0 },
    .{ .name = "simple", .value = 1 },   .{ .name = "never", .value = 1 },
    .{ .name = "existing", .value = 2 }, .{ .name = "nil", .value = 2 },
    .{ .name = "numbered", .value = 3 }, .{ .name = "t", .value = 3 },
};

var suffix_storage: []const u8 = "~";
var suffix_set = false;

/// set_simple_backup_suffix: S, else $SIMPLE_BACKUP_SUFFIX, else "~".
pub fn setSimpleSuffix(ctx: cli.Context, s_in: ?[]const u8) void {
    const s = s_in orelse cli.getenv(ctx, "SIMPLE_BACKUP_SUFFIX");
    suffix_storage = if (s) |v| (if (v.len > 0 and std.mem.indexOfScalar(u8, v, '/') == null) v else "~") else "~";
    suffix_set = true;
}

pub fn simpleSuffix(ctx: cli.Context) []const u8 {
    if (!suffix_set) setSimpleSuffix(ctx, null);
    return suffix_storage;
}

/// xget_version: null (after printing the diagnostic) for a bad name.
pub fn parseVersion(ctx: cli.Context, context: []const u8, arg: ?[]const u8) ?Type {
    var v = arg;
    if (v == null or v.?.len == 0) v = cli.getenv(ctx, "VERSION_CONTROL");
    if (v == null or v.?.len == 0) return .numbered_existing;
    const r = argmatch.match(v.?, &version_table);
    switch (r) {
        .ok => |n| return switch (n) {
            0 => .none,
            1 => .simple,
            2 => .numbered_existing,
            else => .numbered,
        },
        else => {
            argmatch.die(ctx, v.?, context, &version_table, r);
            return null;
        },
    }
}

fn dirOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    var d = slash;
    while (d > 0 and path[d - 1] == '/') d -= 1;
    return if (d == 0) "/" else path[0..d];
}

/// Highest existing numbered backup of `file` (0 when none) and whether the
/// number is all 9s.
fn highestNumbered(ctx: cli.Context, file: []const u8, base: []const u8) ?struct { n: u64 } {
    var dir = Io.Dir.cwd().openDir(ctx.io, dirOf(file), .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var best: u64 = 0;
    var found = false;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
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

fn nameFor(ctx: cli.Context, arena: std.mem.Allocator, file: []const u8, btype: *Type, numbered_ok: *bool) ![]const u8 {
    var end = file.len;
    while (end > 1 and file[end - 1] == '/') end -= 1;
    const f = file[0..end];
    const base_off = if (std.mem.lastIndexOfScalar(u8, f, '/')) |s| s + 1 else 0;
    const base = f[base_off..];
    numbered_ok.* = true;
    if (btype.* == .simple) return std.fmt.allocPrint(arena, "{s}{s}", .{ f, simpleSuffix(ctx) });
    const hi = highestNumbered(ctx, f, base);
    const n: u64 = if (hi) |h| h.n else 0;
    if (n == 0) {
        if (btype.* == .numbered_existing) {
            btype.* = .simple;
            return std.fmt.allocPrint(arena, "{s}{s}", .{ f, simpleSuffix(ctx) });
        }
        return std.fmt.allocPrint(arena, "{s}.~1~", .{f});
    }
    return std.fmt.allocPrint(arena, "{s}.~{d}~", .{ f, n + 1 });
}

/// The name a backup of `file` would get (nothing is renamed).
pub fn findBackupName(ctx: cli.Context, arena: std.mem.Allocator, file: []const u8, btype_in: Type) ?[]const u8 {
    var bt = btype_in;
    var ok: bool = true;
    return nameFor(ctx, arena, file, &bt, &ok) catch null;
}

/// Rename `file` to its backup name; returns the new name, or null with
/// `err` set (ENOENT when the file does not exist).
pub fn backupRename(ctx: cli.Context, arena: std.mem.Allocator, file: []const u8, btype_in: Type, err: *E) ?[]const u8 {
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        var bt = btype_in;
        var ok: bool = true;
        const name = nameFor(ctx, arena, file, &bt, &ok) catch {
            err.* = .NOMEM;
            return null;
        };
        var end = file.len;
        while (end > 1 and file[end - 1] == '/') end -= 1;
        const flags: u32 = if (bt == .simple) 0 else sys.RENAME_NOREPLACE;
        if (sys.renamePath(file[0..end], name, flags)) |e| {
            if (e == .EXIST and bt != .simple) continue;
            err.* = e;
            return null;
        }
        return name;
    }
    err.* = .EXIST;
    return null;
}
