// SPDX-License-Identifier: GPL-2.0-or-later
//! Byte-scanning helpers shared by the utilities. std.mem's scalar searches
//! are plain byte loops in Zig 0.17.1 (`findScalarLast`), so these use 32-byte
//! vectors. A vector comparison becomes a bit mask whose lane i is bit i
//! (little-endian lane order, which `@bitCast` of a bool vector gives on every
//! target Zig supports).

const std = @import("std");

const V = @Vector(32, u8);

/// Number of bytes in `s` equal to `needle`.
pub fn count(s: []const u8, needle: u8) u64 {
    const nv: V = @splat(needle);
    var n: u64 = 0;
    var i: usize = 0;
    while (i + 32 <= s.len) : (i += 32) {
        const v: V = s[i..][0..32].*;
        n += @popCount(@as(u32, @bitCast(v == nv)));
    }
    while (i < s.len) : (i += 1) n += @intFromBool(s[i] == needle);
    return n;
}

/// Index of the last byte of `s` equal to `needle`, or null.
pub fn lastIndexOf(s: []const u8, needle: u8) ?usize {
    const nv: V = @splat(needle);
    var end = s.len;
    while (end >= 32) {
        const v: V = s[end - 32 ..][0..32].*;
        const mask: u32 = @bitCast(v == nv);
        if (mask != 0) return end - 32 + (31 - @clz(mask));
        end -= 32;
    }
    while (end > 0) {
        end -= 1;
        if (s[end] == needle) return end;
    }
    return null;
}

test "count and lastIndexOf agree with a byte loop" {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var buf: [300]u8 = undefined;
    for (0..200) |_| {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = if (rnd.uintLessThan(u8, 10) == 0) '\n' else 'x';
        const s = buf[0..len];
        var want_count: u64 = 0;
        var want_last: ?usize = null;
        for (s, 0..) |b, i| if (b == '\n') {
            want_count += 1;
            want_last = i;
        };
        try std.testing.expectEqual(want_count, count(s, '\n'));
        try std.testing.expectEqual(want_last, lastIndexOf(s, '\n'));
    }
}
