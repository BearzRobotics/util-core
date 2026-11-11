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
const cli = @import("cli.zig");

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
    out: *cli.Out,
    col: usize = 0,
    pending: [8]u8 = undefined,
    pending_len: usize = 0,
    any: bool = false,
    z85_bad: bool = false,

    fn put(e: *Encoder, c: u8) void {
        if (e.wrap != 0 and e.col == e.wrap) {
            e.out.writeByte('\n');
            e.col = 0;
        }
        e.out.writeByte(c);
        e.col += 1;
        e.any = true;
    }

    pub fn feed(e: *Encoder, data: []const u8) void {
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
                e.group(e.pending[0..size]);
                e.pending_len = 0;
            }
        }
    }

    pub fn finish(e: *Encoder) void {
        if (e.pending_len > 0) {
            if (e.kind == .z85) {
                e.z85_bad = true; // input length must be a multiple of 4
            } else e.group(e.pending[0..e.pending_len]);
            e.pending_len = 0;
        }
        if (e.any and e.wrap != 0 and e.col > 0) e.out.writeByte('\n');
    }

    fn group(e: *Encoder, g: []const u8) void {
        const sp = specOf(e.kind);
        switch (e.kind) {
            .base64, .base64url => {
                const a = sp.alphabet;
                var v: u32 = 0;
                for (g, 0..) |b, i| v |= @as(u32, b) << @intCast(16 - 8 * i);
                const chars: usize = (g.len * 8 + 5) / 6;
                for (0..4) |i| {
                    if (i < chars) e.put(a[(v >> @intCast(18 - 6 * i)) & 63]) else e.put('=');
                }
            },
            .base32, .base32hex => {
                const a = sp.alphabet;
                var v: u64 = 0;
                for (g, 0..) |b, i| v |= @as(u64, b) << @intCast(32 - 8 * i);
                const chars: usize = (g.len * 8 + 4) / 5;
                for (0..8) |i| {
                    if (i < chars) e.put(a[@intCast((v >> @intCast(35 - 5 * i)) & 31)]) else e.put('=');
                }
            },
            .base16 => {
                e.put(alpha16[g[0] >> 4]);
                e.put(alpha16[g[0] & 15]);
            },
            .base2msbf => for (0..8) |i| e.put('0' + @as(u8, @intCast((g[0] >> @intCast(7 - i)) & 1))),
            .base2lsbf => for (0..8) |i| e.put('0' + @as(u8, @intCast((g[0] >> @intCast(i)) & 1))),
            .z85 => {
                var v: u32 = std.mem.readInt(u32, g[0..4], .big);
                var tmp: [5]u8 = undefined;
                var i: usize = 5;
                while (i > 0) {
                    i -= 1;
                    tmp[i] = alpha85[v % 85];
                    v /= 85;
                }
                for (tmp) |c| e.put(c);
            },
        }
    }
};

// ---------------------------------------------------------------- decoding

pub const Decoder = struct {
    kind: Kind,
    ignore_garbage: bool,
    out: *cli.Out,
    q: [8]u8 = undefined, // significant characters of the current quantum
    qlen: usize = 0,
    failed: bool = false,
    lut: [256]i8 = undefined,

    pub fn init(kind: Kind, ignore_garbage: bool, out: *cli.Out) Decoder {
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
    pub fn feed(d: *Decoder, data: []const u8) bool {
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
                if (!d.quantum(d.q[0..d.qlen])) d.failed = true;
                d.qlen = 0;
            }
        }
        return !d.failed;
    }

    /// End of input: a partial quantum may still be a legal unpadded tail.
    pub fn finish(d: *Decoder) bool {
        if (d.failed) return false;
        if (d.qlen > 0) {
            const ok = d.quantum(d.q[0..d.qlen]);
            d.qlen = 0;
            if (!ok) return false;
        }
        return true;
    }

    fn quantum(d: *Decoder, q: []const u8) bool {
        return switch (d.kind) {
            .base64, .base64url => d.quantum64(q),
            .base32, .base32hex => d.quantum32(q),
            .base16 => d.quantumBits(q, 4),
            .base2msbf, .base2lsbf => d.quantumBits(q, 1),
            .z85 => d.quantum85(q),
        };
    }

    fn val(d: *const Decoder, c: u8) ?u8 {
        const v = d.lut[c];
        return if (v < 0) null else @intCast(v);
    }

    fn quantum64(d: *Decoder, q: []const u8) bool {
        if (q.len < 2) return false;
        const a = d.val(q[0]) orelse return false;
        const b = d.val(q[1]) orelse return false;
        d.out.writeByte((a << 2) | (b >> 4));
        if (q.len == 2) return b & 0xf == 0; // unpadded end of input
        if (q[2] == '=') {
            if (q.len != 4 or q[3] != '=') return false;
            return b & 0xf == 0;
        }
        const c = d.val(q[2]) orelse return false;
        d.out.writeByte(((b & 0xf) << 4) | (c >> 2));
        if (q.len == 4 and q[3] == '=') return c & 3 == 0; // "xyz="
        if (q.len == 3) return c & 3 == 0; // unpadded end of input
        const e = d.val(q[3]) orelse return false;
        d.out.writeByte(((c & 3) << 6) | e);
        return true;
    }

    /// base32 quantum: data characters, then (in a full quantum) '=' padding.
    /// Characters are consumed in order and a byte is written as soon as its
    /// eight bits are known, so the bytes before a bad character are still
    /// output; the shape (2, 4, 5 or 7 data characters) and zero trailing bits
    /// are checked afterwards.
    fn quantum32(d: *Decoder, q: []const u8) bool {
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
                d.out.writeByte(@truncate(acc >> @intCast(nbits - 8)));
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
    fn quantumBits(d: *Decoder, q: []const u8, bits: u3) bool {
        if (d.kind == .base16) {
            if (q.len != 2) return false;
            const hi = d.val(q[0]) orelse return false;
            const lo = d.val(q[1]) orelse return false;
            d.out.writeByte((hi << 4) | lo);
            return true;
        }
        _ = bits;
        if (q.len != 8) return false;
        var b: u8 = 0;
        for (q, 0..) |c, i| {
            const x = d.val(c) orelse return false;
            if (d.kind == .base2msbf) b |= x << @intCast(7 - i) else b |= x << @intCast(i);
        }
        d.out.writeByte(b);
        return true;
    }

    fn quantum85(d: *Decoder, q: []const u8) bool {
        if (q.len != 5) return false;
        var v: u64 = 0;
        for (q) |c| {
            const x = d.val(c) orelse return false;
            v = v * 85 + x;
        }
        if (v > 0xffffffff) return false;
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @intCast(v), .big);
        d.out.write(&b);
        return true;
    }
};

// -------------------------------------------------------------- front end

const long_names = [_][]const u8{ "decode", "ignore-garbage", "wrap", "help", "version", "base64", "base64url", "base32", "base32hex", "base16", "base2msbf", "base2lsbf", "z85" };

/// `fixed` is the encoding of base64/base32; basenc passes null and takes it
/// from an option.
pub fn main(ctx: cli.Context, fixed: ?Kind) u8 {
    var kind: ?Kind = fixed;
    var decode = false;
    var ignore = false;
    var wrap: usize = 76;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    const is_basenc = fixed == null;

    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            if (k >= 5 and !is_basenc) {
                cli.badLong(ctx, a, .none);
                return 1;
            }
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (k == 2 and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--wrap' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                    return 1;
                }
                value = ctx.args[i];
            } else if (k != 2 and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => decode = true,
                1 => ignore = true,
                2 => wrap = parseWrap(ctx, value.?) orelse return 1,
                3 => return help(ctx, is_basenc),
                4 => return if (cli.printVersion(ctx)) 0 else 1,
                5 => kind = .base64,
                6 => kind = .base64url,
                7 => kind = .base32,
                8 => kind = .base32hex,
                9 => kind = .base16,
                10 => kind = .base2msbf,
                11 => kind = .base2lsbf,
                else => kind = .z85,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'd' => decode = true,
            'i' => ignore = true,
            'w' => {
                var value: []const u8 = a[j + 1 ..];
                if (value.len == 0) {
                    i += 1;
                    if (i >= ctx.args.len) {
                        cli.warn(ctx, "option requires an argument -- 'w'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    value = ctx.args[i];
                }
                wrap = parseWrap(ctx, value) orelse return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }
    const k = kind orelse {
        cli.warn(ctx, "missing encoding type\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    };
    if (files.items.len > 1) {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ files.items[1], ctx.name });
        return 1;
    }
    const name: []const u8 = if (files.items.len == 1) files.items[0] else "-";
    const file = cli.openInput(ctx.io, name) catch |e| {
        // GNU opens a directory fine and reports the failed read.
        if (e == error.IsDir) cli.warn(ctx, "read error: Is a directory", .{}) else cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
        return 1;
    };
    defer cli.closeInput(ctx.io, file);

    var out = cli.Out.init(ctx.io);
    var buf: [64 * 1024]u8 = undefined;
    var status: u8 = 0;
    if (decode) {
        var d = Decoder.init(k, ignore, &out);
        var ok = true;
        while (ok) {
            const n = cli.readChunk(ctx.io, file, &buf) catch |e| {
                out.flush();
                cli.warn(ctx, "read error: {s}", .{cli.errText(e)});
                return 1;
            };
            if (n == 0) break;
            ok = d.feed(buf[0..n]);
        }
        if (ok) ok = d.finish();
        if (!ok) {
            out.flush();
            cli.warn(ctx, "invalid input", .{});
            status = 1;
        }
    } else {
        var e: Encoder = .{ .kind = k, .wrap = wrap, .out = &out };
        // Z85 needs a multiple of four bytes; GNU reports the error before
        // writing anything, so check the length first.
        if (k == .z85) {
            var all: std.ArrayList(u8) = .empty;
            defer all.deinit(ctx.gpa);
            while (true) {
                all.ensureUnusedCapacity(ctx.gpa, 64 * 1024) catch return oom(ctx);
                const n = cli.readChunk(ctx.io, file, all.unusedCapacitySlice()) catch |err| {
                    cli.warn(ctx, "read error: {s}", .{cli.errText(err)});
                    return 1;
                };
                if (n == 0) break;
                all.items.len += n;
            }
            // GNU encodes 30720-byte blocks and checks each block's length, so
            // the blocks before a bad (last) one are still written.
            var rest: []const u8 = all.items;
            while (rest.len > 0) {
                const blk = rest[0..@min(rest.len, 30720)];
                if (blk.len % 4 != 0) {
                    out.flush();
                    cli.warn(ctx, "invalid input (length must be multiple of 4 characters)", .{});
                    return 1;
                }
                e.feed(blk);
                rest = rest[blk.len..];
            }
            e.finish();
            out.flush();
            return if (out.failed) 1 else 0;
        }
        while (true) {
            const n = cli.readChunk(ctx.io, file, &buf) catch |err| {
                out.flush();
                cli.warn(ctx, "read error: {s}", .{cli.errText(err)});
                return 1;
            };
            if (n == 0) break;
            e.feed(buf[0..n]);
            if (out.failed) break;
        }
        e.finish();
        if (e.z85_bad) {
            out.flush();
            cli.warn(ctx, "invalid input (length must be multiple of 4 characters)", .{});
            status = 1;
        }
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return status;
}

fn parseWrap(ctx: cli.Context, text: []const u8) ?usize {
    return std.fmt.parseInt(usize, text, 10) catch {
        cli.warn(ctx, "invalid wrap size: '{s}'", .{text});
        return null;
    };
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context, basenc: bool) u8 {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Usage: {s} [OPTION]... [FILE]\n" ++
        "Encode or decode FILE, or standard input, to standard output.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "{s}" ++
        "  -d, --decode          decode data\n" ++
        "  -i, --ignore-garbage  when decoding, ignore non-alphabet characters\n" ++
        "  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).\n" ++
        "                          Use 0 to disable line wrapping\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n", .{
        ctx.name,
        if (basenc) "      --base64 --base64url --base32 --base32hex --base16\n      --base2msbf --base2lsbf --z85   select the encoding\n" else "",
    }) catch return 1;
    return if (cli.writeStdout(ctx.io, text)) 0 else 1;
}
