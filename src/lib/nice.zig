// SPDX-License-Identifier: GPL-2.0-or-later
//! nice library: the decision logic of running a program with a modified
//! scheduling priority.
//! Reference: GNU coreutils manual "nice invocation" (9.7); POSIX.1-2024 nice.
//!
//! Changing the niceness and replacing the process are process-wide actions
//! (decision 0004), so they stay in the wrapper (`src/commands/nice.zig`);
//! this module parses the adjustment, picks the new niceness and decides
//! which failures of the change are only warnings.

const std = @import("std");

/// Adjustment used when none is given.
pub const default_adjustment: i64 = 10;

pub const Obsolete = struct {
    /// The adjustment text ("N" for -N, "-N" for --N).
    adjustment: []const u8,
    /// The remaining arguments.
    rest: []const [:0]const u8,
};

/// Obsolete "-N" / "--N" forms (adjustment N / -N) are recognised only as the
/// first argument, before option parsing sees it.
pub fn obsoleteAdjustment(args: []const [:0]const u8) ?Obsolete {
    if (args.len == 0) return null;
    const a: []const u8 = args[0];
    if (a.len >= 2 and a[0] == '-' and std.ascii.isDigit(a[1])) return .{ .adjustment = a[1..], .rest = args[1..] };
    if (a.len >= 3 and a[0] == '-' and a[1] == '-' and std.ascii.isDigit(a[2])) return .{ .adjustment = a[1..], .rest = args[1..] };
    return null;
}

/// Parse an adjustment: an optionally signed decimal integer, saturating at
/// the 32-bit range like GNU.
pub fn parseAdjustment(text: []const u8) error{Invalid}!i64 {
    return std.fmt.parseInt(i64, if (text.len > 0 and text[0] == '+') text[1..] else text, 10) catch |e| switch (e) {
        error.Overflow => if (text.len > 0 and text[0] == '-') std.math.minInt(i32) else std.math.maxInt(i32),
        else => error.Invalid,
    };
}

/// The niceness to request: `current + delta`, clamped to -20..19.
pub fn targetNice(current: i32, delta: i64) i32 {
    return @intCast(std.math.clamp(@as(i64, current) +| delta, -20, 19));
}

/// Failure to set the niceness is only a warning for these errors (the
/// command still runs), as in GNU.
pub fn isOnlyWarning(e: std.os.linux.E) bool {
    return e == .PERM or e == .ACCES;
}

test "adjustments" {
    try std.testing.expectEqual(@as(i64, 5), try parseAdjustment("+5"));
    try std.testing.expectEqual(@as(i64, -3), try parseAdjustment("-3"));
    try std.testing.expectError(error.Invalid, parseAdjustment("x"));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)), try parseAdjustment("99999999999999999999"));
    try std.testing.expectEqual(@as(i32, 19), targetNice(5, 100));
    try std.testing.expectEqual(@as(i32, -20), targetNice(5, -100));
    try std.testing.expectEqual(@as(i32, 19), targetNice(5, std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(i32, -20), targetNice(-5, std.math.minInt(i64)));
}
