// SPDX-License-Identifier: GPL-2.0-or-later
//! Command-line side of backups (gnulib backupfile.c, xget_version and
//! set_simple_backup_suffix): resolving --backup=CONTROL / VERSION_CONTROL and
//! the suffix. Used by the cp, mv and install wrappers; the naming and
//! renaming is in backup.zig.

const std = @import("std");
const cli = @import("cli.zig");
const argmatch = @import("argmatch.zig");
const backup = @import("backup.zig");

pub const version_table = [_]argmatch.Entry{
    .{ .name = "none", .value = 0 },     .{ .name = "off", .value = 0 },
    .{ .name = "simple", .value = 1 },   .{ .name = "never", .value = 1 },
    .{ .name = "existing", .value = 2 }, .{ .name = "nil", .value = 2 },
    .{ .name = "numbered", .value = 3 }, .{ .name = "t", .value = 3 },
};

/// The simple backup suffix: S, else $SIMPLE_BACKUP_SUFFIX, else "~". A
/// suffix that is empty or contains a '/' is replaced by "~".
pub fn simpleSuffix(ctx: cli.Context, s_in: ?[]const u8) []const u8 {
    const s = s_in orelse cli.getenv(ctx, "SIMPLE_BACKUP_SUFFIX");
    return if (s) |v| (if (v.len > 0 and std.mem.indexOfScalar(u8, v, '/') == null) v else "~") else "~";
}

/// xget_version: null (after printing the diagnostic) for a bad name.
pub fn parseVersion(ctx: cli.Context, context: []const u8, arg: ?[]const u8) ?backup.Type {
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
