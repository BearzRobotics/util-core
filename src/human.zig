//! Human-readable sizes and block-size specifications: ports of GNU
//! gnulib's human_readable() and human_options() (coreutils 9.6 lib/human.c,
//! consulted 2026-11-07) and of the part of xstrtoumax() they rely on.
//! C locale only (no digit grouping, "." as the decimal point).

const std = @import("std");
const fmt_float = @import("fmt_float.zig");

pub const ceiling: u32 = 0;
pub const round_to_nearest: u32 = 1;
pub const floor: u32 = 2;
pub const group_digits: u32 = 4;
pub const suppress_point_zero: u32 = 8;
pub const autoscale: u32 = 16;
pub const base_1024: u32 = 32;
pub const space_before_unit: u32 = 64;
pub const si: u32 = 128;
pub const b_suffix: u32 = 256;

/// Longest text human_readable can produce.
pub const longest = 48;

const power_letter = [_]u8{ 0, 'K', 'M', 'G', 'T', 'P', 'E', 'Z', 'Y', 'R', 'Q' };

fn adjustValue(style: u32, value: f80) f80 {
    if (style != round_to_nearest and value < 18446744073709551615.0) {
        const u: u64 = @intFromFloat(value);
        const uf: f80 = @floatFromInt(u);
        return @floatFromInt(u + @intFromBool(style == ceiling and uf != value));
    }
    return value;
}

fn fmtLong(buf: []u8, prec: usize, v: f80) []const u8 {
    var fba_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const s = fmt_float.formatAllocLong(fba.allocator(), .{ .precision = prec, .conv = 'f' }, v) catch return "0";
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Format `n` (in units of `from_block`) in units of `to_block` into `buf`
/// (at least `longest` bytes) and return the text.
pub fn readable(n: u64, buf: []u8, opts: u32, from_block: u64, to_block: u64) []const u8 {
    const style = opts & (round_to_nearest | floor | ceiling);
    const base: u64 = if (opts & base_1024 != 0) 1024 else 1000;
    var amt: u64 = 0;
    var tenths: u64 = 0;
    var rounding: u64 = 0;
    var exponent: i32 = -1;
    const exponent_max: i32 = power_letter.len - 1;

    // The number is built right-to-left into `digits` ending at `psuffix`.
    var tmp: [longest + 8]u8 = undefined;
    const suffix_room = 4;
    const psuffix: usize = tmp.len - suffix_room;
    var p: usize = psuffix;

    var integer = false;
    if (to_block <= from_block) {
        if (from_block % to_block == 0) {
            const multiplier = from_block / to_block;
            const m = @mulWithOverflow(n, multiplier);
            if (m[1] == 0) {
                amt = m[0];
                tenths = 0;
                rounding = 0;
                integer = true;
            }
        }
    } else if (from_block != 0 and to_block % from_block == 0) {
        const divisor = to_block / from_block;
        const r10 = (n % divisor) * 10;
        const r2 = (r10 % divisor) * 2;
        amt = n / divisor;
        tenths = r10 / divisor;
        rounding = if (r2 < divisor) @as(u64, @intFromBool(0 < r2)) else 2 + @as(u64, @intFromBool(divisor < r2));
        integer = true;
    }

    if (!integer) {
        const dto: f80 = @floatFromInt(to_block);
        const from: f80 = @floatFromInt(from_block);
        const nf: f80 = @floatFromInt(n);
        var damt: f80 = nf * (from / dto);
        var tb: [256]u8 = undefined;
        var text: []const u8 = undefined;
        if (opts & autoscale == 0) {
            text = fmtLong(&tb, 0, adjustValue(style, damt));
        } else {
            var e: f80 = 1;
            exponent = 0;
            const basef: f80 = @floatFromInt(base);
            while (true) {
                e *= basef;
                exponent += 1;
                if (!(e * basef <= damt and exponent < exponent_max)) break;
            }
            damt /= e;
            text = fmtLong(&tb, 1, adjustValue(style, damt));
            const nonint: usize = 2;
            const need = 1 + nonint + @as(usize, @intFromBool(opts & base_1024 == 0)) < text.len or
                (opts & suppress_point_zero != 0 and text[text.len - 1] == '0');
            if (need) {
                var t2: [256]u8 = undefined;
                text = fmtLong(&t2, 0, adjustValue(style, damt * 10) / 10);
                @memcpy(tb[0..text.len], text);
                text = tb[0..text.len];
            }
        }
        p = psuffix - text.len;
        @memcpy(tmp[p..][0..text.len], text);
    } else {
        if (opts & autoscale != 0) {
            exponent = 0;
            if (base <= amt) {
                while (true) {
                    const r10: u64 = (amt % base) * 10 + tenths;
                    const r2: u64 = (r10 % base) * 2 + (rounding >> 1);
                    amt /= base;
                    tenths = r10 / base;
                    rounding = if (r2 < base) @as(u64, @intFromBool(r2 + rounding != 0)) else 2 + @as(u64, @intFromBool(base < r2 + rounding));
                    exponent += 1;
                    if (!(base <= amt and exponent < exponent_max)) break;
                }
                if (amt < 10) {
                    const bump = if (style == round_to_nearest) 2 < rounding + (tenths & 1) else (style == ceiling and 0 < rounding);
                    if (bump) {
                        tenths += 1;
                        rounding = 0;
                        if (tenths == 10) {
                            amt += 1;
                            tenths = 0;
                        }
                    }
                    if (amt < 10 and (tenths != 0 or opts & suppress_point_zero == 0)) {
                        p -= 1;
                        tmp[p] = '0' + @as(u8, @intCast(tenths));
                        p -= 1;
                        tmp[p] = '.';
                        tenths = 0;
                        rounding = 0;
                    }
                }
            }
        }
        const up = if (style == round_to_nearest) 5 < tenths + @as(u64, @intFromBool(0 < rounding + (amt & 1))) else (style == ceiling and 0 < tenths + rounding);
        if (up) {
            amt += 1;
            if (opts & autoscale != 0 and amt == base and exponent < exponent_max) {
                exponent += 1;
                if (opts & suppress_point_zero == 0) {
                    p -= 1;
                    tmp[p] = '0';
                    p -= 1;
                    tmp[p] = '.';
                }
                amt = 1;
            }
        }
        while (true) {
            p -= 1;
            tmp[p] = '0' + @as(u8, @intCast(amt % 10));
            amt /= 10;
            if (amt == 0) break;
        }
    }

    var ps: usize = psuffix;
    if (opts & si != 0) {
        if (exponent < 0) {
            exponent = 0;
            var power: u64 = 1;
            while (power < to_block) : (power *%= base) {
                exponent += 1;
                if (exponent == exponent_max) break;
            }
        }
        if ((exponent != 0 or opts & b_suffix != 0) and opts & space_before_unit != 0) {
            tmp[ps] = ' ';
            ps += 1;
        }
        if (exponent != 0) {
            tmp[ps] = if (opts & base_1024 == 0 and exponent == 1) 'k' else power_letter[@intCast(exponent)];
            ps += 1;
        }
        if (opts & b_suffix != 0) {
            if (opts & base_1024 != 0 and exponent != 0) {
                tmp[ps] = 'i';
                ps += 1;
            }
            tmp[ps] = 'B';
            ps += 1;
        }
    }
    const text = tmp[p..ps];
    @memcpy(buf[0..text.len], text);
    return buf[0..text.len];
}

pub const StrtolError = enum { ok, overflow, invalid_suffix_char, invalid_suffix_char_with_overflow, invalid };

pub const Parsed = struct {
    err: StrtolError,
    value: u64 = 0,
    /// Offset just past the consumed text.
    end: usize = 0,
};

/// xstrtoumax(s, &p, 0, &val, valid_suffixes) with GNU's suffix handling.
pub fn strtoumax(s: []const u8, valid_suffixes: []const u8) Parsed {
    return strtoumaxBase(s, valid_suffixes, false);
}

/// Like strtoumax; `decimal` forces base 10 (no 0x / leading-zero octal).
pub fn strtoumaxBase(s: []const u8, valid_suffixes: []const u8, decimal: bool) Parsed {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= '\t' and s[i] <= '\r'))) i += 1;
    if (i < s.len and s[i] == '-') return .{ .err = .invalid };
    if (i < s.len and s[i] == '+') i += 1;
    var base: u64 = 10;
    if (!decimal and i < s.len and s[i] == '0') {
        if (i + 2 < s.len and (s[i + 1] == 'x' or s[i + 1] == 'X') and std.ascii.isHex(s[i + 2])) {
            base = 16;
            i += 2;
        } else base = 8;
    }
    const digits_start = i;
    var v: u64 = 0;
    var overflow = false;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        const d: u64 = if (c >= '0' and c <= '9') c - '0' else if (base == 16 and std.ascii.isHex(c)) (std.ascii.toLower(c) - 'a' + 10) else break;
        if (d >= base) break;
        const m = @mulWithOverflow(v, base);
        const a = @addWithOverflow(m[0], d);
        if (m[1] != 0 or a[1] != 0) overflow = true;
        v = a[0];
    }
    if (i == digits_start) {
        // No digits: a bare valid suffix means 1 * suffix.
        if (i < s.len and std.mem.indexOfScalar(u8, valid_suffixes, s[i]) != null) {
            v = 1;
        } else return .{ .err = .invalid };
    }
    if (overflow) v = std.math.maxInt(u64);
    var err: StrtolError = if (overflow) .overflow else .ok;
    if (i < s.len) {
        var sbase: u64 = 1024;
        var width: usize = 1;
        const c = s[i];
        if (std.mem.indexOfScalar(u8, valid_suffixes, c) == null) {
            return .{ .err = if (overflow) .invalid_suffix_char_with_overflow else .invalid_suffix_char, .value = v, .end = i };
        }
        switch (c) {
            'E', 'G', 'g', 'k', 'K', 'M', 'm', 'P', 'Q', 'R', 'T', 't', 'Y', 'Z' => {
                if (std.mem.indexOfScalar(u8, valid_suffixes, '0') != null and i + 1 < s.len) {
                    switch (s[i + 1]) {
                        'i' => if (i + 2 < s.len and s[i + 2] == 'B') {
                            width += 2;
                        },
                        'B', 'D' => {
                            sbase = 1000;
                            width += 1;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        const power: u32 = switch (c) {
            'b', 'B', 'w' => 0,
            'c' => 0,
            'E' => 6,
            'G', 'g' => 3,
            'k', 'K' => 1,
            'M', 'm' => 2,
            'P' => 5,
            'Q' => 10,
            'R' => 9,
            'T', 't' => 4,
            'Y' => 8,
            'Z' => 7,
            else => return .{ .err = if (overflow) .invalid_suffix_char_with_overflow else .invalid_suffix_char, .value = v, .end = i },
        };
        var scales: [10]u64 = undefined;
        var n_scales: usize = 0;
        switch (c) {
            'b' => {
                scales[0] = 512;
                n_scales = 1;
            },
            'B' => {
                scales[0] = 1024;
                n_scales = 1;
            },
            'w' => {
                scales[0] = 2;
                n_scales = 1;
            },
            else => {
                while (n_scales < power) : (n_scales += 1) scales[n_scales] = sbase;
            },
        }
        for (scales[0..n_scales]) |sc| {
            const m = @mulWithOverflow(v, sc);
            if (m[1] != 0) {
                v = std.math.maxInt(u64);
                err = .overflow;
            } else v = m[0];
        }
        i += width;
        if (i < s.len) {
            return .{ .err = if (err == .overflow) .invalid_suffix_char_with_overflow else .invalid_suffix_char, .value = v, .end = i };
        }
    }
    return .{ .err = err, .value = v, .end = i };
}

pub const BlockSize = struct { opts: u32 = 0, size: u64 = 0, err: StrtolError = .ok };

fn default_block_size(posixly_correct: bool) u64 {
    return if (posixly_correct) 512 else 1024;
}

/// GNU human_options. `spec` null means "use BLOCK_SIZE / BLOCKSIZE", which
/// the caller passes in already resolved (`env_block_size`).
pub fn options(spec: ?[]const u8, env_block_size: ?[]const u8, posixly_correct: bool) BlockSize {
    var r: BlockSize = .{};
    var s_opt = spec;
    if (s_opt == null) s_opt = env_block_size;
    if (s_opt == null) {
        r.size = default_block_size(posixly_correct);
    } else {
        var s = s_opt.?;
        if (s.len > 0 and s[0] == '\'') {
            r.opts |= group_digits;
            s = s[1..];
        }
        if (matchBlockSize(s)) |o| {
            r.opts |= o;
            r.size = 1;
        } else {
            const p = strtoumax(s, "eEgGkKmMpPtTyYzZ0");
            if (p.err != .ok) {
                r.opts = 0;
                r.err = p.err;
                r.size = p.value;
            } else {
                r.size = p.value;
                // Walk to the first digit-less prefix: a suffix was present.
                var k: usize = 0;
                while (k <= s.len and (k >= s.len or !(s[k] >= '0' and s[k] <= '9'))) : (k += 1) {
                    if (k == p.end) {
                        r.opts |= si;
                        if (s[p.end - 1] == 'B') r.opts |= b_suffix;
                        if (s[p.end - 1] != 'B' or (p.end >= 2 and s[p.end - 2] == 'i')) r.opts |= base_1024;
                        break;
                    }
                }
            }
        }
    }
    if (r.size == 0) {
        r.size = default_block_size(posixly_correct);
        r.err = .invalid;
    }
    return r;
}

fn matchBlockSize(s: []const u8) ?u32 {
    // argmatch over {"human-readable", "si"}: exact or unique prefix.
    if (s.len == 0) return null;
    const names = [_][]const u8{ "human-readable", "si" };
    const vals = [_]u32{ autoscale + si + base_1024, autoscale + si };
    var found: ?usize = null;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, s)) return vals[i];
        if (std.mem.startsWith(u8, n, s)) {
            if (found == null) found = i else return null;
        }
    }
    return if (found) |f| vals[f] else null;
}

test "readable" {
    var buf: [longest]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("4.0K", readable(4096, &buf, autoscale | si | base_1024, 1, 1));
    try t.expectEqualStrings("12", readable(12, &buf, 0, 1, 1));
    try t.expectEqualStrings("2", readable(2048, &buf, 0, 1, 1024));
    try t.expectEqualStrings("1.5M", readable(1572864, &buf, autoscale | si | base_1024, 1, 1));
}
