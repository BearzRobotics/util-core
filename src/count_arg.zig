// SPDX-License-Identifier: GPL-2.0-or-later
//! Parsing of the numeric argument of head/tail -n and -c: `[+|-]NUM[SUFFIX]`.
//! Reference: GNU coreutils manual, "head invocation" and "Block size" (suffix
//! table). POSIX.1-2024 only requires a plain decimal integer (tail: optional
//! sign); the suffixes are GNU extensions.

const std = @import("std");

pub const Sign = enum { none, plus, minus };

pub const Count = struct {
    /// Value after applying the suffix multiplier; saturates at maxInt(u64)
    /// (GNU treats overflowing counts as "unbounded").
    value: u64,
    sign: Sign,
};

/// Parse `text`; null when it is not a valid count. A suffix with no digits
/// means 1 times the suffix (GNU: `-n K`).
pub fn parse(text: []const u8) ?Count {
    var s = text;
    var sign: Sign = .none;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        sign = if (s[0] == '+') .plus else .minus;
        s = s[1..];
    }
    var i: usize = 0;
    var v: u128 = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        v = v * 10 + (s[i] - '0');
        if (v > std.math.maxInt(u64)) v = std.math.maxInt(u64) + 1; // clamp; stays "overflowed"
    }
    const suffix = s[i..];
    if (i == 0 and suffix.len == 0) return null;
    if (i == 0) v = 1;
    const mult = suffixMultiplier(suffix) orelse return null;
    const total = v *| mult;
    return .{
        .value = if (total > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(total),
        .sign = sign,
    };
}

fn suffixMultiplier(suffix: []const u8) ?u128 {
    if (suffix.len == 0) return 1;
    if (std.mem.eql(u8, suffix, "b")) return 512;
    const letters = "kKMmGTPEZYRQ";
    const idx = std.mem.indexOfScalar(u8, letters, suffix[0]) orelse return null;
    // k/K and m/M are the same power; G.. follow in order.
    const power: u7 = switch (suffix[0]) {
        'k', 'K' => 1,
        'M', 'm' => 2,
        'G' => 3,
        'T' => 4,
        'P' => 5,
        'E' => 6,
        'Z' => 7,
        'Y' => 8,
        'R' => 9,
        'Q' => 10,
        else => unreachable,
    };
    _ = idx;
    const rest = suffix[1..];
    const base: u128 = if (rest.len == 0 or std.mem.eql(u8, rest, "iB")) 1024 else if (std.mem.eql(u8, rest, "B")) 1000 else return null;
    var m: u128 = 1;
    var k: u7 = 0;
    while (k < power) : (k += 1) m = m *| base;
    return m;
}

test "parse" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 10), parse("10").?.value);
    try t.expectEqual(Sign.plus, parse("+3").?.sign);
    try t.expectEqual(Sign.minus, parse("-3").?.sign);
    try t.expectEqual(@as(u64, 512), parse("b").?.value);
    try t.expectEqual(@as(u64, 2048), parse("2K").?.value);
    try t.expectEqual(@as(u64, 2000), parse("2KB").?.value);
    try t.expectEqual(@as(u64, 2048), parse("2KiB").?.value);
    try t.expectEqual(@as(u64, 1 << 20), parse("1M").?.value);
    try t.expectEqual(std.math.maxInt(u64), parse("99999999999999999999999").?.value);
    try t.expectEqual(std.math.maxInt(u64), parse("1Q").?.value);
    try t.expect(parse("") == null);
    try t.expect(parse("abc") == null);
    try t.expect(parse("1x") == null);
    try t.expect(parse("+") == null);
}
