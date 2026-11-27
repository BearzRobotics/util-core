// SPDX-License-Identifier: GPL-2.0-or-later
//! sleep: delay for a specified time (library form, decision 0004).
//!
//! GNU extension followed here: operands NUMBER[smhd], summed; NUMBER may be
//! fractional, have an exponent, be hexadecimal or "inf". Not implemented:
//! parsing in the current locale's decimal point.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// Total time to wait, in seconds; infinity waits forever.
    seconds: f64 = 0,
};

/// Seconds denoted by one operand, or null when it is invalid. Negative and
/// NaN values are invalid (GNU rejects anything not >= 0).
pub fn parseInterval(text: []const u8) ?f64 {
    if (text.len == 0) return null;
    var body = text;
    var mult: f64 = 1;
    switch (text[text.len - 1]) {
        's' => body = text[0 .. text.len - 1],
        'm' => {
            body = text[0 .. text.len - 1];
            mult = 60;
        },
        'h' => {
            body = text[0 .. text.len - 1];
            mult = 3600;
        },
        'd' => {
            body = text[0 .. text.len - 1];
            mult = 86400;
        },
        else => {},
    }
    if (body.len == 0 or body[0] == '+' and body.len == 1) return null;
    const v = std.fmt.parseFloat(f64, body) catch return null;
    if (std.math.isNan(v) or v < 0) return null;
    return v * mult;
}

/// The longest single wait. Systems limit a wait in different ways (a
/// timespec's i64 seconds, a count of 100 ns units); this is within them all.
const slice_s = std.math.maxInt(i32);

/// Waits `opts.seconds`, in slices when that is long; infinity (or a time too
/// large to count in nanoseconds) waits forever. Fails only when the wait
/// itself fails (for example cancellation).
pub fn run(env: Env, opts: Options) Io.Cancelable!void {
    const max_ns: f64 = @floatFromInt(std.math.maxInt(i96));
    const ns = opts.seconds * std.time.ns_per_s;
    const forever = !(ns < max_ns);
    var left: i96 = if (forever) 0 else @intFromFloat(ns);
    const slice_ns = @as(i96, slice_s) * std.time.ns_per_s;
    while (true) {
        const d: i96 = if (forever) slice_ns else @min(left, slice_ns);
        try Io.sleep(env.io, .fromNanoseconds(d), .awake);
        if (forever) continue;
        left -= d;
        if (left <= 0) return;
    }
}

test "parseInterval" {
    const t = std.testing;
    try t.expectEqual(@as(?f64, 5), parseInterval("5"));
    try t.expectEqual(@as(?f64, 0.5), parseInterval("0.5"));
    try t.expectEqual(@as(?f64, 120), parseInterval("2m"));
    try t.expectEqual(@as(?f64, 7200), parseInterval("2h"));
    try t.expectEqual(@as(?f64, 86400), parseInterval("1d"));
    try t.expectEqual(@as(?f64, 1.5), parseInterval("1.5s"));
    try t.expectEqual(@as(?f64, 1), parseInterval("1e0"));
    try t.expect(std.math.isInf(parseInterval("inf").?));
    try t.expect(parseInterval("") == null);
    try t.expect(parseInterval("-1") == null);
    try t.expect(parseInterval("abc") == null);
    try t.expect(parseInterval("s") == null);
    try t.expect(parseInterval("nan") == null);
}
