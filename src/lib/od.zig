// SPDX-License-Identifier: GPL-2.0-or-later
//! od library — dump files in octal and other formats (decision 0004).
//! Argument parsing (including the traditional OFFSET operands and the -t type
//! strings) and the GNU diagnostics are in src/commands/od.zig.
//! Reference: GNU coreutils manual "od invocation" (9.7); POSIX.1-2024 od
//! (-A -b -c -d -j -N -o -s -t -v -x and the offset operand).
//!
//! Input is cut into blocks of `bytes_per_block` bytes. Every -t format prints
//! one line per block; the columns of all formats are aligned to the widest
//! one (each field is left-padded by (line width - own width) / fields), a
//! repeated full block becomes `*`, and a short final block is zero-padded
//! for display.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const wsink = @import("wsink.zig");
const fmt_float = @import("../fmt_float.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Kind = enum { a, c, d, u, o, x, f };

pub const Options = struct {
    /// -t formats (kind and size, plus `half`/`z`); empty means `-t o2`.
    formats: []const Fmt = &.{},
    /// -A radix: 'o', 'd', 'x' or 'n'.
    radix: u8 = 'o',
    /// -j: bytes to skip first.
    skip: u64 = 0,
    /// -N: at most this many bytes.
    limit: ?u64 = null,
    /// -v: do not collapse repeated lines into `*`.
    verbose: bool = false,
    /// -w: bytes per output line (null: 16 or the lcm of the element sizes).
    width: ?u64 = null,
    /// -S: dump strings of at least this length instead of formatted data.
    strings: ?u64 = null,
    big_endian: bool = false,
    /// --traditional label (the second offset operand).
    label: ?u64 = null,
};

pub const Failure = struct { name: []const u8, err: anyerror };

pub const Event = union(enum) {
    open_failed: Failure,
    read_failed: Failure,
    /// -w was not a multiple of the element size; `using` was used.
    invalid_width: struct { width: u64, using: usize },
    /// -j skipped past the end of the combined input.
    skip_past_end,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// An input could not be read, or the skip went past the end.
    failed: bool = false,
};

pub const Error = error{ OutOfMemory, WriteFailed };

/// Dump `inputs` in order onto `out_w`.
pub fn run(env: Env, opts: Options, inputs: []const Input, out_w: *Io.Writer, obs: Observer) Error!Result {
    const gpa = env.gpa;
    var fmts: std.ArrayList(Fmt) = .empty;
    defer fmts.deinit(gpa);
    try fmts.appendSlice(gpa, opts.formats);
    if (fmts.items.len == 0) try fmts.append(gpa, .{ .kind = .o, .size = 2 });

    // Block size: lcm of element sizes; default 16 (or the lcm if larger).
    var lcm: usize = 1;
    for (fmts.items) |*f| {
        f.width = fieldWidth(f.*);
        lcm = lcmOf(lcm, f.size);
    }
    var bpb: usize = 16;
    if (lcm > 16) bpb = lcm;
    if (opts.width) |w| {
        if (w % lcm != 0 or w == 0) {
            obs.emit(.{ .invalid_width = .{ .width = w, .using = lcm } });
            bpb = lcm;
        } else bpb = std.math.cast(usize, w) orelse return error.OutOfMemory;
    } else if (bpb % lcm != 0) bpb = lcm;

    // Column alignment across formats.
    var line_w: usize = 0;
    for (fmts.items) |f| {
        const chars = std.math.mul(usize, f.width + 1, bpb / f.size) catch return error.OutOfMemory;
        line_w = @max(line_w, chars);
    }
    for (fmts.items) |*f| f.pad = line_w - (f.width + 1) * (bpb / f.size);

    var src = Source.init(env, obs, inputs, opts.limit);
    defer src.deinit();
    const skip = opts.skip;
    if (skip > 0 and !src.skipBytes(skip)) {
        if (!src.had_error) obs.emit(.skip_past_end);
        return .{ .failed = true };
    }

    var out = wsink.Sink.initWriter(out_w);
    const have_label = opts.label != null;
    if (opts.strings) |min| {
        dumpStrings(&src, &out, min, opts.radix, skip);
    } else {
        const buf = try gpa.alloc(u8, std.math.mul(usize, bpb, 2) catch return error.OutOfMemory);
        defer gpa.free(buf);
        const cur = buf[0..bpb];
        const prev = buf[bpb..];
        var have_prev = false;
        var star_printed = false;
        var addr: u64 = skip;
        var lab: u64 = opts.label orelse 0;
        const radix = opts.radix;
        while (!out.failed) {
            const n = src.read(cur);
            if (n == 0) break;
            if (!opts.verbose and n == bpb and have_prev and std.mem.eql(u8, cur, prev)) {
                if (!star_printed) {
                    out.write("*\n");
                    star_printed = true;
                }
            } else {
                star_printed = false;
                // Zero only up to the end of the last element: with a large
                // -w the rest of the block is never looked at.
                if (n < bpb) @memset(cur[n..@min(bpb, std.mem.alignForward(usize, n, lcm))], 0);
                printBlock(&out, fmts.items, cur, n, addr, radix, opts.big_endian, if (have_label) lab else null);
                have_prev = n == bpb;
                if (have_prev) @memcpy(prev, cur);
            }
            addr += n;
            lab += n;
            if (n < bpb) break;
        }
        if (radix != 'n' and (src.opened_any or !src.had_error)) {
            printAddr(&out, addr, radix);
            if (have_label) {
                out.write(" (");
                printAddr(&out, lab, radix);
                out.write(")");
            }
            out.writeByte('\n');
        }
    }
    out.flush();
    if (out.failed) return error.WriteFailed;
    return .{ .failed = src.had_error };
}

pub const Fmt = struct {
    kind: Kind,
    size: u8, // bytes per element
    /// f only: 'B' bfloat16, 'H' half, or 0.
    half: u8 = 0,
    z: bool = false,
    width: usize = 0, // natural field width (set by `run`)
    pad: usize = 0, // extra left padding per field (set by `run`)
};

const a_names = [_][]const u8{
    "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel", "bs", "ht", "nl", "vt", "ff", "cr", "so", "si",
    "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb", "can", "em", "sub", "esc", "fs", "gs", "rs", "us",
    "sp",
};

fn fieldWidth(f: Fmt) usize {
    return switch (f.kind) {
        .a, .c => 3,
        .x => 2 * @as(usize, f.size),
        .o => (8 * @as(usize, f.size) + 2) / 3,
        .u => switch (f.size) {
            1 => 3,
            2 => 5,
            4 => 10,
            else => 20,
        },
        .d => switch (f.size) {
            1 => 4,
            2 => 6,
            4 => 11,
            else => 20,
        },
        .f => switch (f.size) {
            2 => 15,
            4 => 15,
            8 => 24,
            else => 29,
        },
    };
}
fn lcmOf(a: usize, b: usize) usize {
    return a / std.math.gcd(a, b) * b;
}

// ----------------------------------------------------------------- input

const Source = struct {
    env: Env,
    obs: Observer,
    files: []const Input,
    next_file: usize = 0,
    cur: ?Input.Opened = null,
    left: ?u64,
    had_error: bool = false,
    opened_any: bool = false,
    /// Kind of the most recently opened input (a character device such as
    /// /dev/null can be 'skipped' arbitrarily far, like lseek does).
    last_char_dev: bool = false,
    buf: [65536]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,

    fn init(env: Env, obs: Observer, files: []const Input, limit: ?u64) Source {
        return .{ .env = env, .obs = obs, .files = files, .left = limit };
    }

    fn deinit(s: *Source) void {
        if (s.cur) |f| f.close(s.env.io);
    }

    /// Refill the internal buffer; false at the end of all input.
    fn fill(s: *Source) bool {
        while (true) {
            if (s.cur == null) {
                if (s.next_file >= s.files.len) return false;
                const in = s.files[s.next_file];
                const name = in.name orelse "-";
                s.next_file += 1;
                s.cur = in.open(s.env.io) catch |e| {
                    s.had_error = true;
                    if (e == error.IsDir) s.opened_any = true; // GNU opens it and fails on read
                    s.obs.emit(.{ .open_failed = .{ .name = name, .err = e } });
                    continue;
                };
                s.opened_any = true;
                if (s.cur.?.file.stat(s.env.io)) |st| {
                    s.last_char_dev = st.kind == .character_device;
                } else |_| {}
            }
            const n = common.readChunk(s.env.io, s.cur.?.file, &s.buf) catch |e| {
                s.had_error = true;
                const name = s.files[s.next_file - 1].name orelse "-";
                s.obs.emit(.{ .read_failed = .{ .name = name, .err = e } });
                s.cur.?.close(s.env.io);
                s.cur = null;
                continue;
            };
            if (n == 0) {
                s.cur.?.close(s.env.io);
                s.cur = null;
                continue;
            }
            s.pos = 0;
            s.len = n;
            return true;
        }
    }
    fn skipBytes(s: *Source, n: u64) bool {
        var left = n;
        while (left > 0) {
            if (s.pos == s.len and !s.fill()) return s.last_char_dev;
            const take: usize = @intCast(@min(left, s.len - s.pos));
            s.pos += take;
            left -= take;
        }
        return true;
    }

    /// Read up to out.len bytes, honouring -N.
    fn read(s: *Source, out: []u8) usize {
        var want = out.len;
        if (s.left) |l| want = @min(want, @as(usize, @intCast(@min(l, std.math.maxInt(usize)))));
        var got: usize = 0;
        while (got < want) {
            if (s.pos == s.len and !s.fill()) break;
            const take = @min(want - got, s.len - s.pos);
            @memcpy(out[got .. got + take], s.buf[s.pos .. s.pos + take]);
            s.pos += take;
            got += take;
        }
        if (s.left) |*l| l.* -= got;
        return got;
    }
};

// ---------------------------------------------------------------- output

fn printAddr(out: *wsink.Sink, addr: u64, radix: u8) void {
    switch (radix) {
        'o' => out.print("{o:0>7}", .{addr}),
        'd' => out.print("{d:0>7}", .{addr}),
        'x' => out.print("{x:0>6}", .{addr}),
        else => {},
    }
}

fn addrWidth(radix: u8) usize {
    return switch (radix) {
        'o', 'd' => 7,
        'x' => 6,
        else => 0,
    };
}

fn spaces(out: *wsink.Sink, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) out.writeByte(' ');
}

/// The part of a line's `pad` extra spaces that belongs to its last `left`
/// of `fields` fields.
fn padLeft(pad: usize, left: usize, fields: usize) usize {
    return @intCast(@as(u128, pad) * left / fields);
}

fn printBlock(out: *wsink.Sink, fmts: []const Fmt, block: []const u8, n_bytes: usize, addr: u64, radix: u8, big: bool, label: ?u64) void {
    for (fmts, 0..) |f, fi| {
        if (fi == 0) {
            printAddr(out, addr, radix);
            if (label) |l| {
                out.write(" (");
                printAddr(out, l, radix);
                out.write(")");
            }
        } else {
            spaces(out, addrWidth(radix));
            if (label != null) spaces(out, 3 + addrWidth(radix));
        }
        const n_elems = (n_bytes + f.size - 1) / f.size;
        const fields = block.len / f.size;
        var i: usize = 0;
        while (i < n_elems) : (i += 1) {
            var tmp: [16]u8 = undefined;
            const e = block[i * f.size ..][0..f.size];
            @memcpy(tmp[0..f.size], e);
            if (big and f.size > 1) std.mem.reverse(u8, tmp[0..f.size]);
            out.writeByte(' ');
            // As in GNU, the padding is spread over the fields, so that the
            // formats of a block end in the same column.
            spaces(out, padLeft(f.pad, fields - i, fields) - padLeft(f.pad, fields - i - 1, fields));
            printElem(out, f, tmp[0..f.size]);
        }
        if (f.z) {
            // Pad the missing fields, then ">printable<".
            const missing = fields - n_elems;
            spaces(out, missing * (1 + f.width) + padLeft(f.pad, missing, fields));
            out.write("  >");
            for (block[0..n_bytes]) |c| out.writeByte(if (c >= 0x20 and c < 0x7f) c else '.');
            out.writeByte('<');
        }
        out.writeByte('\n');
    }
}

fn printElem(out: *wsink.Sink, f: Fmt, e: []const u8) void {
    var buf: [64]u8 = undefined;
    switch (f.kind) {
        .a => {
            const c = e[0] & 0x7f;
            const s: []const u8 = if (c <= 32) a_names[c] else if (c == 127) "del" else @as(*const [1]u8, &e[0]);
            var one: [1]u8 = .{c};
            const shown = if (c > 32 and c < 127) one[0..] else s;
            printRight(out, shown, f.width);
        },
        .c => {
            const c = e[0];
            const s: []const u8 = switch (c) {
                0 => "\\0",
                7 => "\\a",
                8 => "\\b",
                9 => "\\t",
                10 => "\\n",
                11 => "\\v",
                12 => "\\f",
                13 => "\\r",
                else => if (c >= 0x20 and c < 0x7f) @as(*const [1]u8, &e[0]) else std.fmt.bufPrint(&buf, "{o:0>3}", .{c}) catch "?",
            };
            printRight(out, s, f.width);
        },
        .o, .x, .u, .d => {
            var v: u64 = 0;
            for (e, 0..) |b, k| v |= @as(u64, b) << @intCast(8 * k);
            const s: []const u8 = switch (f.kind) {
                .o => std.fmt.bufPrint(&buf, "{o:0>[1]}", .{ v, f.width }) catch "?",
                .x => std.fmt.bufPrint(&buf, "{x:0>[1]}", .{ v, f.width }) catch "?",
                .u => std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?",
                else => blk: {
                    const bits: u7 = @intCast(8 * f.size);
                    const sv: i64 = if (bits == 64) @bitCast(v) else signExtend(v, bits);
                    break :blk std.fmt.bufPrint(&buf, "{d}", .{sv}) catch "?";
                },
            };
            printRight(out, s, f.width);
        },
        .f => {
            var tb: [64]u8 = undefined;
            const t: []const u8 = switch (f.size) {
                2 => blk: {
                    const bits = std.mem.readInt(u16, e[0..2], .little);
                    const v: f32 = if (f.half == 'B') @bitCast(@as(u32, bits) << 16) else @floatCast(@as(f16, @bitCast(bits)));
                    break :blk shortestG(f32, v, 6, &tb);
                },
                4 => shortestG(f32, @bitCast(std.mem.readInt(u32, e[0..4], .little)), 6, &tb),
                8 => shortestG(f64, @bitCast(std.mem.readInt(u64, e[0..8], .little)), 15, &tb),
                else => blk: {
                    const lo = std.mem.readInt(u64, e[0..8], .little);
                    const hi = std.mem.readInt(u16, e[8..10], .little);
                    const bits: u80 = (@as(u80, hi) << 64) | lo;
                    // x87 encodings with a clear integer bit (and a non-zero,
                    // non-max exponent) are "unnormals"; glibc prints them as nan.
                    const exp15 = hi & 0x7fff;
                    if (exp15 != 0 and exp15 != 0x7fff and (lo >> 63) == 0) break :blk if (hi & 0x8000 != 0) "-nan" else "nan";
                    if (exp15 == 0x7fff and (lo >> 63) == 0) break :blk if (hi & 0x8000 != 0) "-nan" else "nan";
                    if (exp15 == 0 and lo != 0) break :blk denormalG(lo, hi & 0x8000 != 0, &tb);
                    break :blk shortestG(f80, @bitCast(bits), 18, &tb);
                },
            };
            printRight(out, t, f.width);
        },
    }
}

/// A value rounded to so many significant digits, trailing zeros dropped.
const Decimal = struct {
    digits: [32]u8,
    len: usize,
    exp: i32,

    fn round(d: *Decimal, value: f80, places: usize) bool {
        const gpa = std.heap.page_allocator;
        // [-]d[.ddd]e+XX
        const text = fmt_float.formatAllocLong(gpa, .{ .conv = 'e', .precision = places - 1 }, value) catch return false;
        defer gpa.free(text);
        const epos = std.mem.indexOfScalar(u8, text, 'e') orelse return false;
        d.len = 0;
        for (text[0..epos]) |c| if (std.ascii.isDigit(c)) {
            d.digits[d.len] = c;
            d.len += 1;
        };
        while (d.len > 1 and d.digits[d.len - 1] == '0') d.len -= 1;
        d.exp = std.fmt.parseInt(i32, text[epos + 1 ..], 10) catch return false;
        return true;
    }
};

/// C `%g` of the shortest decimal that reads back as `v` (GNU od prints
/// floating point values this way, with at most `prec` significant digits).
fn shortestG(comptime T: type, v: T, dig: usize, buf: *[64]u8) []const u8 {
    if (std.math.isNan(v)) return if (std.math.signbit(v)) "-nan" else "nan";
    if (std.math.isInf(v)) return if (v < 0) "-inf" else "inf";
    var raw: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&raw, "{e}", .{v}) catch return "?";
    var i: usize = 0;
    var neg = false;
    if (sci[0] == '-') {
        neg = true;
        i = 1;
    }
    const epos = std.mem.indexOfScalar(u8, sci, 'e') orelse return "?";
    var digits: [48]u8 = undefined;
    var nd: usize = 0;
    for (sci[i..epos]) |c| {
        if (c != '.') {
            digits[nd] = c;
            nd += 1;
        }
    }
    var exp = std.fmt.parseInt(i32, sci[epos + 1 ..], 10) catch return "?";
    // GNU prints with %g, which rounds correctly. Next to a power of two the
    // shortest text that reads back need not be the correctly rounded one of
    // that length; then that one does not read back, and GNU takes one digit
    // more.
    if (nd > dig) {
        var exact: Decimal = undefined;
        if (!exact.round(@floatCast(v), nd)) return "?";
        if (exact.exp != exp or !std.mem.eql(u8, exact.digits[0..exact.len], digits[0..nd])) {
            if (!exact.round(@floatCast(v), nd + 1)) return "?";
            nd = exact.len;
            @memcpy(digits[0..nd], exact.digits[0..nd]);
            exp = exact.exp;
        }
    }
    var w: std.Io.Writer = .fixed(buf);
    if (neg) w.writeByte('-') catch {};
    if (nd == 1 and digits[0] == '0') {
        w.writeByte('0') catch {};
        return w.buffered();
    }
    // GNU tries precisions dig, dig+1, ... (from 1 for subnormals) until the
    // text reads back; %g then goes scientific when exp >= that precision.
    const sub = v != 0 and @abs(v) < std.math.floatMin(T);
    const prec: usize = if (sub) nd else @max(nd, dig);
    if (exp < -4 or exp >= @as(i32, @intCast(prec))) {
        w.writeByte(digits[0]) catch {};
        if (nd > 1) {
            w.writeByte('.') catch {};
            w.writeAll(digits[1..nd]) catch {};
        }
        w.print("e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) }) catch {};
    } else if (exp < 0) {
        w.writeAll("0.") catch {};
        var z: i32 = -exp - 1;
        while (z > 0) : (z -= 1) w.writeByte('0') catch {};
        w.writeAll(digits[0..nd]) catch {};
    } else {
        const int_digits: usize = @intCast(exp + 1);
        if (nd <= int_digits) {
            w.writeAll(digits[0..nd]) catch {};
            var z = int_digits - nd;
            while (z > 0) : (z -= 1) w.writeByte('0') catch {};
        } else {
            w.writeAll(digits[0..int_digits]) catch {};
            w.writeByte('.') catch {};
            w.writeAll(digits[int_digits..nd]) catch {};
        }
    }
    return w.buffered();
}

/// Shortest `%g` text (precision 1..21) that reads back as the x87 denormal
/// with mantissa `m` (value m * 2^-16445). std.fmt mis-scales these, so the
/// round trip is checked exactly with big integers: a decimal D*10^q
/// represents the value when |D*10^q - m*2^-16445| <= 2^-16446.
fn denormalG(m: u64, neg: bool, buf: *[64]u8) []const u8 {
    const gpa = std.heap.page_allocator;
    const value: f80 = @bitCast((@as(u80, @intFromBool(neg)) << 79) | m);
    var p: usize = 1;
    while (p <= 21) : (p += 1) {
        const e_txt = fmt_float.formatAllocLong(gpa, .{ .conv = 'e', .precision = p - 1 }, value) catch return "?";
        defer gpa.free(e_txt);
        // e_txt: [-]d[.ddd]e-XXXX
        var i: usize = 0;
        if (e_txt[0] == '-') i = 1;
        const epos = std.mem.indexOfScalar(u8, e_txt, 'e') orelse return "?";
        var digits: [32]u8 = undefined;
        var nd: usize = 0;
        for (e_txt[i..epos]) |c| if (c != '.') {
            digits[nd] = c;
            nd += 1;
        };
        const x = std.fmt.parseInt(i32, e_txt[epos + 1 ..], 10) catch return "?";
        const q: i32 = x - @as(i32, @intCast(nd)) + 1; // value ~ D * 10^q, q negative here
        if (q >= 0) continue;
        const k: usize = @intCast(-q);
        var d_big = std.math.big.int.Managed.init(gpa) catch return "?";
        defer d_big.deinit();
        d_big.setString(10, digits[0..nd]) catch return "?";
        d_big.shiftLeft(&d_big, 16446) catch return "?"; // D * 2^16446
        var ten = std.math.big.int.Managed.initSet(gpa, 10) catch return "?";
        defer ten.deinit();
        var pw = std.math.big.int.Managed.init(gpa) catch return "?";
        defer pw.deinit();
        pw.pow(&ten, @intCast(k)) catch return "?"; // 10^k
        var m2 = std.math.big.int.Managed.initSet(gpa, m) catch return "?";
        defer m2.deinit();
        m2.shiftLeft(&m2, 1) catch return "?"; // 2m
        m2.mul(&m2, &pw) catch return "?"; // 2m * 10^k
        var diff = std.math.big.int.Managed.init(gpa) catch return "?";
        defer diff.deinit();
        diff.sub(&d_big, &m2) catch return "?";
        diff.abs();
        if (diff.order(pw) != .gt) {
            const g = fmt_float.formatAllocLong(gpa, .{ .conv = 'g', .precision = p }, value) catch return "?";
            defer gpa.free(g);
            const n = @min(g.len, buf.len);
            @memcpy(buf[0..n], g[0..n]);
            return buf[0..n];
        }
    }
    return "?";
}

fn signExtend(v: u64, bits: u7) i64 {
    const shift: u6 = @intCast(64 - @as(u7, bits));
    return @as(i64, @bitCast(v << shift)) >> shift;
}

fn printRight(out: *wsink.Sink, s: []const u8, width: usize) void {
    if (s.len < width) spaces(out, width - s.len);
    out.write(s);
}

fn dumpStrings(src: *Source, out: *wsink.Sink, min: u64, radix: u8, start: u64) void {
    var addr: u64 = start;
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(src.env.gpa);
    var str_start: u64 = addr;
    var one: [1]u8 = undefined;
    while (true) {
        if (src.read(&one) == 0) break;
        const c = one[0];
        if (c == 0) {
            if (cur.items.len >= min) {
                if (radix != 'n') {
                    printAddr(out, str_start, radix);
                    out.writeByte(' ');
                }
                out.write(cur.items);
                out.writeByte('\n');
            }
            cur.clearRetainingCapacity();
        } else if (c >= 0x20 and c < 0x7f) {
            if (cur.items.len == 0) str_start = addr;
            cur.append(src.env.gpa, c) catch return;
        } else cur.clearRetainingCapacity();
        addr += 1;
    }
}
