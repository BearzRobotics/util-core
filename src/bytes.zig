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

/// Index of the first byte of `s` at or after `from` equal to `needle`, or null.
pub fn indexOf(s: []const u8, needle: u8, from: usize) ?usize {
    const nv: V = @splat(needle);
    var i = from;
    while (i + 32 <= s.len) : (i += 32) {
        const v: V = s[i..][0..32].*;
        const mask: u32 = @bitCast(v == nv);
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < s.len) : (i += 1) if (s[i] == needle) return i;
    return null;
}

/// How common a byte is in text (higher = more common); used to pick the
/// two least common bytes of a needle as the vector filter.
fn commonness(b: u8) u8 {
    const order = " etaoinsrhldcumfpgwybvkxjqz";
    const lower = std.ascii.toLower(b);
    for (order, 0..) |c, i| if (c == lower) return @intCast(order.len - i + 10);
    if (b >= '0' and b <= '9') return 8;
    if (b >= 0x80) return 3;
    return 5;
}

/// A substring searcher: a 32-byte vector scan on two chosen needle bytes,
/// then a comparison of the rest. With `fold`, ASCII letters match in either
/// case (the needle is lower-cased on construction).
pub const Needle = struct {
    bytes: []const u8,
    fold: bool,
    p1: usize,
    p2: usize,

    /// `store` (at least `needle.len` bytes, owned by the caller and kept
    /// alive with the Needle) receives the lower-cased needle when `fold`;
    /// it is unused otherwise, where `needle` itself must stay alive.
    pub fn init(needle: []const u8, fold: bool, store: []u8) Needle {
        var n: Needle = .{ .bytes = needle, .fold = fold, .p1 = 0, .p2 = 0 };
        if (fold) {
            const dst = store[0..needle.len];
            for (needle, dst) |c, *d| d.* = std.ascii.toLower(c);
            n.bytes = dst;
        }
        const b = n.bytes;
        if (b.len > 1) {
            var best: usize = 0;
            for (b, 0..) |c, i| if (commonness(c) < commonness(b[best])) {
                best = i;
            };
            var second: usize = if (best == 0) 1 else 0;
            for (b, 0..) |c, i| if (i != best and commonness(c) < commonness(b[second])) {
                second = i;
            };
            n.p1 = best;
            n.p2 = second;
        }
        return n;
    }

    inline fn eqv(self: *const Needle, v: V, c: u8) @Vector(32, bool) {
        if (self.fold and std.ascii.isAlphabetic(c)) {
            const lv: V = @splat(0x20);
            const cv: V = @splat(c);
            return (v | lv) == cv;
        }
        const cv: V = @splat(c);
        return v == cv;
    }

    inline fn same(self: *const Needle, h: []const u8, n: []const u8) bool {
        if (!self.fold) return std.mem.eql(u8, h, n);
        for (h, n) |a, b| if (std.ascii.toLower(a) != b) return false;
        return true;
    }

    /// Index of the first occurrence at or after `from`, or null.
    pub fn find(self: *const Needle, hay: []const u8, from: usize) ?usize {
        const nb = self.bytes;
        const len = nb.len;
        if (len == 0) return if (from <= hay.len) from else null;
        if (hay.len < len or from > hay.len - len) return null;
        if (len == 1 and !self.fold) return indexOf(hay, nb[0], from);
        const last_start = hay.len - len;
        var i = from;
        const c1 = nb[self.p1];
        const c2 = nb[self.p2];
        if (len == 1) {
            while (i + 32 <= hay.len) : (i += 32) {
                const v: V = hay[i..][0..32].*;
                const mask: u32 = @bitCast(self.eqv(v, c1));
                if (mask != 0) return i + @ctz(mask);
            }
        } else {
            const span = @max(self.p1, self.p2);
            while (i + span + 32 <= hay.len and i <= last_start) : (i += 32) {
                const a: V = hay[i + self.p1 ..][0..32].*;
                const b: V = hay[i + self.p2 ..][0..32].*;
                var mask: u32 = @bitCast(self.eqv(a, c1) & self.eqv(b, c2));
                while (mask != 0) : (mask &= mask - 1) {
                    const at = i + @ctz(mask);
                    if (at > last_start) break;
                    if (self.same(hay[at .. at + len], nb)) return at;
                }
            }
        }
        while (i <= last_start) : (i += 1) {
            if (self.same(hay[i .. i + len], nb)) return i;
        }
        return null;
    }
};

test "indexOf and Needle agree with naive search" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var buf: [400]u8 = undefined;
    var nbuf: [5]u8 = undefined;
    var store: [5]u8 = undefined;
    for (0..4000) |_| {
        const len = rnd.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| b.* = "abAB\n x"[rnd.uintLessThan(usize, 8)];
        const nl = 1 + rnd.uintLessThan(usize, nbuf.len);
        for (nbuf[0..nl]) |*b| b.* = "abAB\n x"[rnd.uintLessThan(usize, 8)];
        const s = buf[0..len];
        const from = if (len == 0) 0 else rnd.uintLessThan(usize, len + 1);
        for ([2]bool{ false, true }) |fold| {
            const nd = Needle.init(nbuf[0..nl], fold, &store);
            var want: ?usize = null;
            var i = from;
            while (i + nl <= len) : (i += 1) {
                var ok = true;
                for (nbuf[0..nl], 0..) |c, k| {
                    const h = s[i + k];
                    if (if (fold) std.ascii.toLower(h) != std.ascii.toLower(c) else h != c) ok = false;
                }
                if (ok) {
                    want = i;
                    break;
                }
            }
            try std.testing.expectEqual(want, nd.find(s, from));
        }
        var wi: ?usize = null;
        var j = from;
        while (j < len) : (j += 1) if (s[j] == nbuf[0]) {
            wi = j;
            break;
        };
        try std.testing.expectEqual(wi, indexOf(s, nbuf[0], from));
    }
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
