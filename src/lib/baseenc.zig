// SPDX-License-Identifier: GPL-2.0-or-later
//! Shared implementation of base64, base32 and basenc.
//! References: GNU coreutils manual (9.7) "base64 invocation", "base32
//! invocation", "basenc invocation"; RFC 4648 (sections 4 to 8); ZeroMQ
//! spec 32/Z85.
//!
//! Decoding is incremental, like gnulib's: significant characters are grouped
//! into quanta (4 for base64, 8 for base32, ...), every complete quantum is
//! written at once, and when a quantum is invalid the bytes decoded from it
//! before the fault are still written ("abc" then "invalid input"). Missing
//! padding at end of input is accepted when the leftover characters can only
//! be a final partial quantum with zero trailing bits.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Input = common.Input;
pub const Env = common.Env;

pub const Kind = enum { base64, base64url, base32, base32hex, base16, base2msbf, base2lsbf, z85 };

const alpha64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const alpha64url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const alpha32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const alpha32hex = "0123456789ABCDEFGHIJKLMNOPQRSTUV";
const alpha16 = "0123456789ABCDEF";
const alpha85 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#";

const Spec = struct {
    alphabet: []const u8,
    bits: u3, // bits per character (z85 handled separately)
    quantum: u8, // characters per quantum
    pad: bool, // '=' padding
};

fn specOf(k: Kind) Spec {
    return switch (k) {
        .base64 => .{ .alphabet = alpha64, .bits = 6, .quantum = 4, .pad = true },
        .base64url => .{ .alphabet = alpha64url, .bits = 6, .quantum = 4, .pad = true },
        .base32 => .{ .alphabet = alpha32, .bits = 5, .quantum = 8, .pad = true },
        .base32hex => .{ .alphabet = alpha32hex, .bits = 5, .quantum = 8, .pad = true },
        .base16 => .{ .alphabet = alpha16, .bits = 4, .quantum = 2, .pad = false },
        .base2msbf, .base2lsbf => .{ .alphabet = "01", .bits = 1, .quantum = 8, .pad = false },
        .z85 => .{ .alphabet = alpha85, .bits = 0, .quantum = 5, .pad = false },
    };
}

/// `kind` has no default: the caller must choose an encoding.
pub const Options = struct {
    kind: Kind,
    decode: bool = false,
    ignore_garbage: bool = false,
    wrap: usize = 76,
};

// ---------------------------------------------------------------- encoding

pub const Encoder = struct {
    kind: Kind,
    wrap: usize,
    out: *Io.Writer,
    col: usize = 0,
    pending: [8]u8 = undefined,
    pending_len: usize = 0,
    any: bool = false,

    fn put(e: *Encoder, c: u8) Io.Writer.Error!void {
        if (e.wrap != 0 and e.col == e.wrap) {
            try e.out.writeByte('\n');
            e.col = 0;
        }
        try e.out.writeByte(c);
        e.col += 1;
        e.any = true;
    }

    pub fn feed(e: *Encoder, data: []const u8) Io.Writer.Error!void {
        const size: usize = switch (e.kind) {
            .base64, .base64url => 3,
            .base32, .base32hex => 5,
            .base16, .base2msbf, .base2lsbf => 1,
            .z85 => 4,
        };
        var d = data;
        while (d.len > 0) {
            const n = @min(size - e.pending_len, d.len);
            @memcpy(e.pending[e.pending_len..][0..n], d[0..n]);
            e.pending_len += n;
            d = d[n..];
            if (e.pending_len == size) {
                try e.group(e.pending[0..size]);
                e.pending_len = 0;
            }
        }
    }

    pub fn finish(e: *Encoder) Io.Writer.Error!void {
        if (e.pending_len > 0) {
            // z85 input is checked to be a multiple of 4 bytes by `run`.
            if (e.kind != .z85) try e.group(e.pending[0..e.pending_len]);
            e.pending_len = 0;
        }
        if (e.any and e.wrap != 0 and e.col > 0) try e.out.writeByte('\n');
    }

    fn group(e: *Encoder, g: []const u8) Io.Writer.Error!void {
        const sp = specOf(e.kind);
        switch (e.kind) {
            .base64, .base64url => {
                const a = sp.alphabet;
                var v: u32 = 0;
                for (g, 0..) |b, i| v |= @as(u32, b) << @intCast(16 - 8 * i);
                const chars: usize = (g.len * 8 + 5) / 6;
                for (0..4) |i| {
                    if (i < chars) try e.put(a[(v >> @intCast(18 - 6 * i)) & 63]) else try e.put('=');
                }
            },
            .base32, .base32hex => {
                const a = sp.alphabet;
                var v: u64 = 0;
                for (g, 0..) |b, i| v |= @as(u64, b) << @intCast(32 - 8 * i);
                const chars: usize = (g.len * 8 + 4) / 5;
                for (0..8) |i| {
                    if (i < chars) try e.put(a[@intCast((v >> @intCast(35 - 5 * i)) & 31)]) else try e.put('=');
                }
            },
            .base16 => {
                try e.put(alpha16[g[0] >> 4]);
                try e.put(alpha16[g[0] & 15]);
            },
            .base2msbf => for (0..8) |i| try e.put('0' + @as(u8, @intCast((g[0] >> @intCast(7 - i)) & 1))),
            .base2lsbf => for (0..8) |i| try e.put('0' + @as(u8, @intCast((g[0] >> @intCast(i)) & 1))),
            .z85 => {
                var v: u32 = std.mem.readInt(u32, g[0..4], .big);
                var tmp: [5]u8 = undefined;
                var i: usize = 5;
                while (i > 0) {
                    i -= 1;
                    tmp[i] = alpha85[v % 85];
                    v /= 85;
                }
                for (tmp) |c| try e.put(c);
            },
        }
    }
};

// ---------------------------------------------------------------- decoding

pub const Decoder = struct {
    kind: Kind,
    ignore_garbage: bool,
    out: *Io.Writer,
    q: [8]u8 = undefined, // significant characters of the current quantum
    qlen: usize = 0,
    failed: bool = false,
    lut: [256]i8 = undefined,

    pub fn init(kind: Kind, ignore_garbage: bool, out: *Io.Writer) Decoder {
        var d: Decoder = .{ .kind = kind, .ignore_garbage = ignore_garbage, .out = out };
        @memset(&d.lut, -1);
        for (specOf(kind).alphabet, 0..) |c, i| d.lut[c] = @intCast(i);
        // GNU quirks, kept on purpose: base16 also reads lower-case digits, and
        // basenc maps base32hex to base32 character by character, so the
        // letters W to Z (outside the hex alphabet) keep their base32 values.
        if (kind == .base16) for ("abcdef", 10..) |c, i| {
            d.lut[c] = @intCast(i);
        };
        if (kind == .base32hex) for ("WXYZ", 22..) |c, i| {
            d.lut[c] = @intCast(i);
        };
        return d;
    }

    /// Feed raw input; returns false after the first error (output so far is
    /// already written).
    pub fn feed(d: *Decoder, data: []const u8) Io.Writer.Error!bool {
        // basenc turns base64url input into base64 before decoding and
        // rejects '+' and '/' during that pass, i.e. before any output.
        if (d.kind == .base64url and !d.ignore_garbage and std.mem.indexOfAny(u8, data, "+/") != null) {
            d.failed = true;
            return false;
        }
        for (data) |c| {
            if (d.failed) return false;
            if (c == '\n') continue; // GNU always allows line breaks
            // '=' is never garbage, even in encodings without padding (GNU).
            var in_alpha = d.lut[c] >= 0 or c == '=';
            // The base32hex quirk letters only count when not ignoring garbage.
            if (d.kind == .base32hex and std.mem.indexOfScalar(u8, "WXYZ", c) != null) in_alpha = false;
            // GNU's z85 test is strchr() on the alphabet, which finds the NUL terminator.
            if (d.kind == .z85 and c == 0) in_alpha = true;
            if (!in_alpha and d.ignore_garbage) continue;
            d.q[d.qlen] = c;
            d.qlen += 1;
            if (d.qlen == specOf(d.kind).quantum) {
                if (!try d.quantum(d.q[0..d.qlen])) d.failed = true;
                d.qlen = 0;
            }
        }
        return !d.failed;
    }

    /// End of input: a partial quantum may still be a legal unpadded tail.
    pub fn finish(d: *Decoder) Io.Writer.Error!bool {
        if (d.failed) return false;
        if (d.qlen > 0) {
            const ok = try d.quantum(d.q[0..d.qlen]);
            d.qlen = 0;
            if (!ok) return false;
        }
        return true;
    }

    fn quantum(d: *Decoder, q: []const u8) Io.Writer.Error!bool {
        return switch (d.kind) {
            .base64, .base64url => try d.quantum64(q),
            .base32, .base32hex => try d.quantum32(q),
            .base16 => try d.quantumBits(q, 4),
            .base2msbf, .base2lsbf => try d.quantumBits(q, 1),
            .z85 => try d.quantum85(q),
        };
    }

    fn val(d: *const Decoder, c: u8) ?u8 {
        const v = d.lut[c];
        return if (v < 0) null else @intCast(v);
    }

    fn quantum64(d: *Decoder, q: []const u8) Io.Writer.Error!bool {
        if (q.len < 2) return false;
        const a = d.val(q[0]) orelse return false;
        const b = d.val(q[1]) orelse return false;
        try d.out.writeByte((a << 2) | (b >> 4));
        if (q.len == 2) return b & 0xf == 0; // unpadded end of input
        if (q[2] == '=') {
            if (q.len != 4 or q[3] != '=') return false;
            return b & 0xf == 0;
        }
        const c = d.val(q[2]) orelse return false;
        try d.out.writeByte(((b & 0xf) << 4) | (c >> 2));
        if (q.len == 4 and q[3] == '=') return c & 3 == 0; // "xyz="
        if (q.len == 3) return c & 3 == 0; // unpadded end of input
        const e = d.val(q[3]) orelse return false;
        try d.out.writeByte(((c & 3) << 6) | e);
        return true;
    }

    /// base32 quantum: data characters, then (in a full quantum) '=' padding.
    /// Characters are consumed in order and a byte is written as soon as its
    /// eight bits are known, so the bytes before a bad character are still
    /// output; the shape (2, 4, 5 or 7 data characters) and zero trailing bits
    /// are checked afterwards.
    fn quantum32(d: *Decoder, q: []const u8) Io.Writer.Error!bool {
        // A short final quantum that ends in padding is rejected unseen (GNU
        // writes nothing for it); any other is decoded as far as it goes.
        if (q.len < 8 and q[q.len - 1] == '=') return false;
        var acc: u32 = 0;
        var nbits: u32 = 0;
        var k: usize = 0;
        while (k < q.len and q[k] != '=') : (k += 1) {
            const x = d.val(q[k]) orelse return false;
            acc = (acc << 5) | x;
            nbits += 5;
            if (nbits >= 8) {
                try d.out.writeByte(@truncate(acc >> @intCast(nbits - 8)));
                nbits -= 8;
                acc &= (@as(u32, 1) << @intCast(nbits)) - 1;
            }
        }
        if (k < q.len) {
            if (q.len != 8) return false;
            for (q[k..]) |c| if (c != '=') return false;
        }
        switch (k) {
            2, 4, 5, 7, 8 => {},
            else => return false,
        }
        return acc == 0; // leftover bits must be zero
    }

    /// base16 (2 digits per byte) and base2 (8 digits per byte).
    fn quantumBits(d: *Decoder, q: []const u8, bits: u3) Io.Writer.Error!bool {
        if (d.kind == .base16) {
            if (q.len != 2) return false;
            const hi = d.val(q[0]) orelse return false;
            const lo = d.val(q[1]) orelse return false;
            try d.out.writeByte((hi << 4) | lo);
            return true;
        }
        _ = bits;
        if (q.len != 8) return false;
        var b: u8 = 0;
        for (q, 0..) |c, i| {
            const x = d.val(c) orelse return false;
            if (d.kind == .base2msbf) b |= x << @intCast(7 - i) else b |= x << @intCast(i);
        }
        try d.out.writeByte(b);
        return true;
    }

    fn quantum85(d: *Decoder, q: []const u8) Io.Writer.Error!bool {
        if (q.len != 5) return false;
        var v: u64 = 0;
        for (q) |c| {
            const x = d.val(c) orelse return false;
            v = v * 85 + x;
        }
        if (v > 0xffffffff) return false;
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @intCast(v), .big);
        try d.out.writeAll(&b);
        return true;
    }
};


// ------------------------------------------------------------------- run

/// How a run ended. Output written before the fault is already in the writer.
pub const Result = union(enum) {
    ok,
    /// Decoding met an invalid quantum or character.
    invalid_input,
    /// z85 encoding of input whose length is not a multiple of 4 bytes.
    bad_length,
    /// The input could not be opened (nothing was read).
    open_failed: anyerror,
    /// Reading the input failed part way.
    read_failed: anyerror,
};

/// Encode or decode `input` to `out`. The caller flushes `out` (and words any
/// non-ok result). Write failures are returned as `error.WriteFailed`.
pub fn run(env: Env, options: Options, input: Input, out: *Io.Writer) (Io.Writer.Error || std.mem.Allocator.Error)!Result {
    const opened = input.open(env.io) catch |e| return .{ .open_failed = e };
    defer opened.close(env.io);
    const file = opened.file;
    var buf: [64 * 1024]u8 = undefined;
    if (options.decode) {
        var d = Decoder.init(options.kind, options.ignore_garbage, out);
        var ok = true;
        while (ok) {
            const n = common.readChunk(env.io, file, &buf) catch |e| return .{ .read_failed = e };
            if (n == 0) break;
            ok = try d.feed(buf[0..n]);
        }
        if (ok) ok = try d.finish();
        return if (ok) .ok else .invalid_input;
    }
    var e: Encoder = .{ .kind = options.kind, .wrap = options.wrap, .out = out };
    // Z85 needs a multiple of four bytes; GNU reports the error before
    // writing anything for the bad block, so read everything first.
    if (options.kind == .z85) {
        var all: std.ArrayList(u8) = .empty;
        defer all.deinit(env.gpa);
        while (true) {
            try all.ensureUnusedCapacity(env.gpa, 64 * 1024);
            const n = common.readChunk(env.io, file, all.unusedCapacitySlice()) catch |err| return .{ .read_failed = err };
            if (n == 0) break;
            all.items.len += n;
        }
        // GNU encodes 30720-byte blocks and checks each block's length, so
        // the blocks before a bad (last) one are still written.
        var rest: []const u8 = all.items;
        while (rest.len > 0) {
            const blk = rest[0..@min(rest.len, 30720)];
            if (blk.len % 4 != 0) return .bad_length;
            try e.feed(blk);
            rest = rest[blk.len..];
        }
        try e.finish();
        return .ok;
    }
    while (true) {
        const n = common.readChunk(env.io, file, &buf) catch |err| return .{ .read_failed = err };
        if (n == 0) break;
        try e.feed(buf[0..n]);
    }
    try e.finish();
    return .ok;
}

test "encode and decode through the Encoder and Decoder" {
    var storage: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&storage);
    var e: Encoder = .{ .kind = .base64, .wrap = 0, .out = &w };
    try e.feed("hello");
    try e.finish();
    try std.testing.expectEqualStrings("aGVsbG8=", w.buffered());

    var w2: Io.Writer = .fixed(&storage);
    var d = Decoder.init(.base64, false, &w2);
    try std.testing.expect(try d.feed("aGVsbG8="));
    try std.testing.expect(try d.finish());
    try std.testing.expectEqualStrings("hello", w2.buffered());

    var w3: Io.Writer = .fixed(&storage);
    var d3 = Decoder.init(.base32, false, &w3);
    try std.testing.expect(!(try d3.feed("!!!!!!!!")));
}
