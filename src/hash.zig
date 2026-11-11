// SPDX-License-Identifier: GPL-2.0-or-later
//! Message digests and legacy checksums for md5sum, sha*sum, b2sum, cksum
//! and sum. MD5, SHA-1 and SHA-2 come from std.crypto; BLAKE2b (with a
//! variable digest length, which std does not offer at run time), SM3 and the
//! legacy sums are written here.
//!
//! References: RFC 1321 (MD5), RFC 3174 (SHA-1), FIPS 180-4 (SHA-2), RFC 7693
//! (BLAKE2b), GB/T 32905-2016 (SM3), POSIX.1-2024 cksum (CRC), GNU coreutils
//! 9.7 manual "sum invocation" and "cksum invocation" (sysv, bsd).

const std = @import("std");

pub const Algo = enum {
    sysv,
    bsd,
    crc,
    crc32b,
    md5,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    blake2b,
    sm3,

    /// The `-a` name.
    pub fn name(a: Algo) []const u8 {
        return @tagName(a);
    }

    /// Algorithms that produce a digest string (as opposed to a number).
    pub fn isDigest(a: Algo) bool {
        return switch (a) {
            .sysv, .bsd, .crc, .crc32b => false,
            else => true,
        };
    }

    /// Tag used in BSD-style output ("MD5 (file) = ...").
    pub fn tag(a: Algo) []const u8 {
        return switch (a) {
            .md5 => "MD5",
            .sha1 => "SHA1",
            .sha224 => "SHA224",
            .sha256 => "SHA256",
            .sha384 => "SHA384",
            .sha512 => "SHA512",
            .blake2b => "BLAKE2b",
            .sm3 => "SM3",
            else => "",
        };
    }

    /// Full digest length in bytes.
    pub fn digestLen(a: Algo) usize {
        return switch (a) {
            .md5 => 16,
            .sha1 => 20,
            .sha224 => 28,
            .sha256, .sm3 => 32,
            .sha384 => 48,
            .sha512, .blake2b => 64,
            else => 0,
        };
    }
};

pub const max_digest = 64;

/// Streaming digest state. Only the field for the chosen algorithm is live.
pub const Hasher = union(enum) {
    md5: std.crypto.hash.Md5,
    sha1: std.crypto.hash.Sha1,
    sha224: std.crypto.hash.sha2.Sha224,
    sha256: std.crypto.hash.sha2.Sha256,
    sha384: std.crypto.hash.sha2.Sha384,
    sha512: std.crypto.hash.sha2.Sha512,
    blake2b: Blake2b,
    sm3: Sm3,

    /// `out_len` (bytes) only matters for BLAKE2b.
    pub fn init(a: Algo, out_len: usize) Hasher {
        return switch (a) {
            .md5 => .{ .md5 = std.crypto.hash.Md5.init(.{}) },
            .sha1 => .{ .sha1 = std.crypto.hash.Sha1.init(.{}) },
            .sha224 => .{ .sha224 = std.crypto.hash.sha2.Sha224.init(.{}) },
            .sha256 => .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) },
            .sha384 => .{ .sha384 = std.crypto.hash.sha2.Sha384.init(.{}) },
            .sha512 => .{ .sha512 = std.crypto.hash.sha2.Sha512.init(.{}) },
            .blake2b => .{ .blake2b = Blake2b.init(out_len) },
            .sm3 => .{ .sm3 = Sm3.init() },
            else => unreachable,
        };
    }

    pub fn update(h: *Hasher, data: []const u8) void {
        switch (h.*) {
            inline else => |*s| s.update(data),
        }
    }

    /// Writes the digest to the start of `out` and returns its length.
    pub fn final(h: *Hasher, out: *[max_digest]u8) usize {
        switch (h.*) {
            .blake2b => |*s| return s.final(out),
            .sm3 => |*s| {
                s.final(out[0..32]);
                return 32;
            },
            inline else => |*s| {
                const n = @TypeOf(s.*).digest_length;
                s.final(out[0..n]);
                return n;
            },
        }
    }
};

// ------------------------------------------------------------------ BLAKE2b

pub const Blake2b = struct {
    h: [8]u64,
    t: u128 = 0,
    buf: [128]u8 = undefined,
    buf_len: usize = 0,
    out_len: usize,

    const iv = [8]u64{
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    };
    const sigma = [12][16]u8{
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
        .{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
        .{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
        .{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
        .{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
        .{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
        .{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
        .{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
        .{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
        .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
        .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    };

    /// `out_len` in bytes, 1 to 64 (no key).
    pub fn init(out_len: usize) Blake2b {
        std.debug.assert(out_len >= 1 and out_len <= 64);
        var b: Blake2b = .{ .h = iv, .out_len = out_len };
        // Parameter block word 0: digest length, key length 0, fanout 1, depth 1.
        b.h[0] ^= 0x01010000 | @as(u64, out_len);
        return b;
    }

    pub fn update(b: *Blake2b, data: []const u8) void {
        var d = data;
        while (d.len > 0) {
            // The last block must be compressed with the final flag, so a full
            // buffer is only flushed once more input arrives.
            if (b.buf_len == 128) {
                b.t += 128;
                b.compress(&b.buf, false);
                b.buf_len = 0;
            }
            const n = @min(128 - b.buf_len, d.len);
            @memcpy(b.buf[b.buf_len..][0..n], d[0..n]);
            b.buf_len += n;
            d = d[n..];
        }
    }

    pub fn final(b: *Blake2b, out: *[max_digest]u8) usize {
        b.t += b.buf_len;
        @memset(b.buf[b.buf_len..], 0);
        b.compress(&b.buf, true);
        var full: [64]u8 = undefined;
        for (b.h, 0..) |w, i| std.mem.writeInt(u64, full[i * 8 ..][0..8], w, .little);
        @memcpy(out[0..b.out_len], full[0..b.out_len]);
        return b.out_len;
    }

    fn compress(b: *Blake2b, block: *const [128]u8, last: bool) void {
        var m: [16]u64 = undefined;
        for (&m, 0..) |*w, i| w.* = std.mem.readInt(u64, block[i * 8 ..][0..8], .little);
        var v: [16]u64 = undefined;
        v[0..8].* = b.h;
        v[8..16].* = iv;
        v[12] ^= @truncate(b.t);
        v[13] ^= @truncate(b.t >> 64);
        if (last) v[14] = ~v[14];
        for (0..12) |r| {
            const s = &sigma[r];
            mix(&v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
            mix(&v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
            mix(&v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
            mix(&v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
            mix(&v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
            mix(&v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
            mix(&v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
            mix(&v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
        }
        for (0..8) |i| b.h[i] ^= v[i] ^ v[i + 8];
    }

    fn mix(v: *[16]u64, a: usize, b: usize, c: usize, d: usize, x: u64, y: u64) void {
        v[a] = v[a] +% v[b] +% x;
        v[d] = std.math.rotr(u64, v[d] ^ v[a], 32);
        v[c] = v[c] +% v[d];
        v[b] = std.math.rotr(u64, v[b] ^ v[c], 24);
        v[a] = v[a] +% v[b] +% y;
        v[d] = std.math.rotr(u64, v[d] ^ v[a], 16);
        v[c] = v[c] +% v[d];
        v[b] = std.math.rotr(u64, v[b] ^ v[c], 63);
    }
};

// --------------------------------------------------------------------- SM3

pub const Sm3 = struct {
    h: [8]u32 = .{ 0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e },
    buf: [64]u8 = undefined,
    buf_len: usize = 0,
    total: u64 = 0,

    pub const digest_length = 32;

    pub fn init() Sm3 {
        return .{};
    }

    pub fn update(s: *Sm3, data: []const u8) void {
        s.total += data.len;
        var d = data;
        if (s.buf_len > 0) {
            const n = @min(64 - s.buf_len, d.len);
            @memcpy(s.buf[s.buf_len..][0..n], d[0..n]);
            s.buf_len += n;
            d = d[n..];
            if (s.buf_len == 64) {
                s.block(&s.buf);
                s.buf_len = 0;
            }
        }
        while (d.len >= 64) : (d = d[64..]) s.block(d[0..64]);
        if (d.len > 0) {
            @memcpy(s.buf[0..d.len], d);
            s.buf_len = d.len;
        }
    }

    pub fn final(s: *Sm3, out: *[32]u8) void {
        const bits = s.total * 8;
        var pad: [72]u8 = @splat(0);
        pad[0] = 0x80;
        const pad_len = (if (s.buf_len < 56) 56 - s.buf_len else 120 - s.buf_len);
        std.mem.writeInt(u64, pad[pad_len..][0..8], bits, .big);
        const total = s.total;
        s.update(pad[0 .. pad_len + 8]);
        s.total = total;
        for (s.h, 0..) |w, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], w, .big);
    }

    fn p0(x: u32) u32 {
        return x ^ std.math.rotl(u32, x, 9) ^ std.math.rotl(u32, x, 17);
    }
    fn p1(x: u32) u32 {
        return x ^ std.math.rotl(u32, x, 15) ^ std.math.rotl(u32, x, 23);
    }

    fn block(s: *Sm3, data: *const [64]u8) void {
        var w: [68]u32 = undefined;
        for (0..16) |i| w[i] = std.mem.readInt(u32, data[i * 4 ..][0..4], .big);
        for (16..68) |j| {
            w[j] = p1(w[j - 16] ^ w[j - 9] ^ std.math.rotl(u32, w[j - 3], 15)) ^ std.math.rotl(u32, w[j - 13], 7) ^ w[j - 6];
        }
        var a = s.h[0];
        var b = s.h[1];
        var c = s.h[2];
        var d = s.h[3];
        var e = s.h[4];
        var f = s.h[5];
        var g = s.h[6];
        var hh = s.h[7];
        for (0..64) |j| {
            const t: u32 = if (j < 16) 0x79cc4519 else 0x7a879d8a;
            const ss1 = std.math.rotl(u32, std.math.rotl(u32, a, 12) +% e +% std.math.rotl(u32, t, @as(u5, @intCast(j % 32))), 7);
            const ss2 = ss1 ^ std.math.rotl(u32, a, 12);
            const ff = if (j < 16) a ^ b ^ c else (a & b) | (a & c) | (b & c);
            const gg = if (j < 16) e ^ f ^ g else (e & f) | (~e & g);
            const tt1 = ff +% d +% ss2 +% (w[j] ^ w[j + 4]);
            const tt2 = gg +% hh +% ss1 +% w[j];
            d = c;
            c = std.math.rotl(u32, b, 9);
            b = a;
            a = tt1;
            hh = g;
            g = std.math.rotl(u32, f, 19);
            f = e;
            e = p0(tt2);
        }
        s.h[0] ^= a;
        s.h[1] ^= b;
        s.h[2] ^= c;
        s.h[3] ^= d;
        s.h[4] ^= e;
        s.h[5] ^= f;
        s.h[6] ^= g;
        s.h[7] ^= hh;
    }
};

// --------------------------------------------------------- legacy checksums

/// POSIX cksum CRC (polynomial 0x04C11DB7, MSB first, length appended, then
/// complemented).
pub const PosixCrc = struct {
    crc: u32 = 0,
    len: u64 = 0,

    const table = blk: {
        @setEvalBranchQuota(10000);
        var t: [256]u32 = undefined;
        for (0..256) |i| {
            var c: u32 = @as(u32, @intCast(i)) << 24;
            for (0..8) |_| c = if (c & 0x80000000 != 0) (c << 1) ^ 0x04c11db7 else c << 1;
            t[i] = c;
        }
        break :blk t;
    };

    pub fn update(s: *PosixCrc, data: []const u8) void {
        var c = s.crc;
        for (data) |b| c = (c << 8) ^ table[(c >> 24) ^ b];
        s.crc = c;
        s.len += data.len;
    }

    pub fn final(s: *PosixCrc) u32 {
        var c = s.crc;
        var n = s.len;
        while (n != 0) : (n >>= 8) c = (c << 8) ^ table[(c >> 24) ^ @as(u8, @truncate(n))];
        return ~c;
    }
};

/// BSD `sum -r`: 16-bit rotating checksum.
pub const BsdSum = struct {
    sum: u16 = 0,
    len: u64 = 0,

    pub fn update(s: *BsdSum, data: []const u8) void {
        var v = s.sum;
        for (data) |b| {
            v = (v >> 1) | (v << 15);
            v +%= b;
        }
        s.sum = v;
        s.len += data.len;
    }
};

/// System V `sum -s`: byte sum folded to 16 bits.
pub const SysvSum = struct {
    sum: u32 = 0,
    len: u64 = 0,

    pub fn update(s: *SysvSum, data: []const u8) void {
        var v = s.sum;
        for (data) |b| v +%= b;
        s.sum = v;
        s.len += data.len;
    }

    pub fn final(s: SysvSum) u16 {
        var r = (s.sum & 0xffff) +% (s.sum >> 16);
        r = (r & 0xffff) +% (r >> 16);
        return @truncate(r);
    }
};

test "known digests" {
    const t = std.testing;
    var out: [max_digest]u8 = undefined;
    var h = Hasher.init(.sm3, 0);
    h.update("abc");
    var n = h.final(&out);
    try t.expectEqualSlices(u8, &.{ 0x66, 0xc7, 0xf0, 0xf4, 0x62, 0xee, 0xed, 0xd9 }, out[0..8]);
    try t.expectEqual(@as(usize, 32), n);
    h = Hasher.init(.blake2b, 64);
    h.update("abc");
    n = h.final(&out);
    try t.expectEqualSlices(u8, &.{ 0xba, 0x80, 0xa5, 0x3f, 0x98, 0x1c, 0x4d, 0x0d }, out[0..8]);
    // Chunked input must equal one-shot input at every split.
    var data: [300]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 7);
    var one: [max_digest]u8 = undefined;
    var h1 = Hasher.init(.blake2b, 37);
    h1.update(&data);
    const n1 = h1.final(&one);
    for ([_]usize{ 1, 127, 128, 129, 256 }) |split| {
        var two: [max_digest]u8 = undefined;
        var h2 = Hasher.init(.blake2b, 37);
        h2.update(data[0..split]);
        h2.update(data[split..]);
        const n2 = h2.final(&two);
        try t.expectEqualSlices(u8, one[0..n1], two[0..n2]);
    }
}
