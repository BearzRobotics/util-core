// SPDX-License-Identifier: GPL-2.0-or-later
//! seq — print a sequence of numbers.
//! Reference: GNU coreutils manual "seq invocation" (9.7); POSIX does not
//! specify seq.
//!
//! Two evaluation paths:
//!  * Decimal path: when FIRST, INCREMENT and LAST are fixed-point decimal
//!    numbers (an exponent is allowed) and no -f is given, values are exact
//!    scaled integers (i128), so `seq 0 0.1 0.3` includes 0.3 and there is no
//!    accumulated rounding error. Output uses %.PRECf with PRECISION from the
//!    operands (GNU manual).
//!  * Float path: -f FORMAT, hexadecimal or infinite operands. The k-th value
//!    is FIRST + k*INCREMENT in double precision (GNU uses long double, so the
//!    last digits of huge or non-representable values can differ), formatted
//!    with src/fmt_float.zig.
//! Not implemented: %a / %A in -f FORMAT.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Sink = @import("sink.zig").Sink;
const ff = @import("../fmt_float.zig");

pub const Env = common.Env;

/// A decimal operand: value = mant * 10^-scale (scale may be negative).
const Dec = struct {
    mant: i128,
    scale: i32,
    inf: i2 = 0, // +1 / -1 for infinities, mant ignored

    fn precision(d: Dec) usize {
        return @intCast(@max(d.scale, 0));
    }
};

/// Everything `run` needs besides the operands.
pub const Options = struct {
    /// printf-style floating-point FORMAT (-f); null for the default.
    format: ?[]const u8 = null,
    /// Written between numbers (-s).
    separator: []const u8 = "\n",
    /// Zero-pad to a common width (-w). The caller rejects it together with
    /// `format`; the library does not.
    equal_width: bool = false,
};

/// A problem that stops the run before any number is produced.
pub const Event = union(enum) {
    /// An operand is not a floating-point number.
    invalid_argument: []const u8,
    /// An operand is NaN.
    not_a_number: []const u8,
    /// INCREMENT is zero (the operand text).
    zero_increment: []const u8,
    format_ends_in_percent: []const u8,
    format_too_many_directives: []const u8,
    format_no_directive: []const u8,
    format_unknown_directive: struct { format: []const u8, conv: u8 },
    format_unsupported_directive: struct { format: []const u8, conv: u8 },
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// False when an event stopped the run (the GNU exit status is then 1).
    ok: bool,
};

pub const Error = error{ OutOfMemory, WriteFailed };

/// Print the sequence for one to three operands: LAST, FIRST LAST, or FIRST
/// INCREMENT LAST. The caller has checked the operand count (1 to 3).
pub fn run(env: Env, options: Options, operands: []const []const u8, w: *Io.Writer, observer: Observer) Error!Result {
    const nums = operands;
    const first_s: []const u8 = if (nums.len > 1) nums[0] else "1";
    const step_s: []const u8 = if (nums.len > 2) nums[1] else "1";
    const last_s: []const u8 = nums[nums.len - 1];

    // Validate every operand first so errors come out in operand order.
    const ops = [_][]const u8{ first_s, step_s, last_s };
    var vals: [3]f64 = undefined;
    var decs: [3]?Dec = undefined;
    for (ops, 0..) |t, k| {
        if (k == 1 and nums.len < 3) {
            vals[k] = 1;
            decs[k] = .{ .mant = 1, .scale = 0 };
            continue;
        }
        if (k == 0 and nums.len < 2) {
            vals[k] = 1;
            decs[k] = .{ .mant = 1, .scale = 0 };
            continue;
        }
        decs[k] = parseDecimal(t);
        vals[k] = parseFloatArg(t) orelse {
            observer.emit(.{ .invalid_argument = t });
            return .{ .ok = false };
        };
        if (std.math.isNan(vals[k])) {
            observer.emit(.{ .not_a_number = t });
            return .{ .ok = false };
        }
    }
    if (vals[1] == 0) {
        observer.emit(.{ .zero_increment = step_s });
        return .{ .ok = false };
    }

    var out = Sink.init(w);
    const sep = options.separator;
    const ok = if (options.format == null and decs[0] != null and decs[1] != null and decs[2] != null)
        decimalPath(env, observer, &out, decs[0].?, decs[1].?, decs[2].?, sep, options.equal_width)
    else
        floatPath(env, observer, &out, vals, options.format, sep, options.equal_width);
    const done = try ok;
    out.flush();
    if (out.failed) return error.WriteFailed;
    return .{ .ok = done };
}

/// Any floating-point spelling C's strtod accepts (decimal, exponent, hex,
/// inf/infinity/nan with a sign), or null.
fn parseFloatArg(t: []const u8) ?f64 {
    if (t.len == 0) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

/// Parse `[+-]digits[.digits][e[+-]digits]` (at least one mantissa digit) or
/// an infinity into exact form; null for anything else (hex, nan, overflow).
fn parseDecimal(t: []const u8) ?Dec {
    var s = t;
    var neg = false;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (std.ascii.eqlIgnoreCase(s, "inf") or std.ascii.eqlIgnoreCase(s, "infinity"))
        return .{ .mant = 0, .scale = 0, .inf = if (neg) -1 else 1 };
    var mant: i128 = 0;
    var digits: usize = 0;
    var frac: i32 = 0;
    var seen_point = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (std.ascii.isDigit(c)) {
            mant = std.math.mul(i128, mant, 10) catch return null;
            mant = std.math.add(i128, mant, c - '0') catch return null;
            digits += 1;
            if (seen_point) frac += 1;
        } else if (c == '.' and !seen_point) {
            seen_point = true;
        } else break;
    }
    if (digits == 0) return null;
    var exp: i32 = 0;
    if (i < s.len) {
        if (s[i] != 'e' and s[i] != 'E') return null;
        exp = std.fmt.parseInt(i32, s[i + 1 ..], 10) catch return null;
        if (@abs(exp) > 60) return null; // far outside i128 range; use the float path
    }
    return .{ .mant = if (neg) -mant else mant, .scale = frac - exp };
}

fn pow10(n: u32) ?i128 {
    var r: i128 = 1;
    var k: u32 = 0;
    while (k < n) : (k += 1) r = std.math.mul(i128, r, 10) catch return null;
    return r;
}

/// `d` as a mantissa at the common scale `s`.
fn rescale(d: Dec, s: i32) ?i128 {
    const shift: u32 = @intCast(s - d.scale);
    return std.math.mul(i128, d.mant, pow10(shift) orelse return null) catch null;
}

fn decimalPath(env: Env, observer: Observer, out: *Sink, first: Dec, step: Dec, last: Dec, sep: []const u8, equal_width: bool) Error!bool {
    if (first.inf != 0 or step.inf != 0) return floatFallback(env, observer, out, first, step, last, sep, equal_width);
    var scale: i32 = @max(@max(first.scale, step.scale), 0);
    if (last.inf == 0) scale = @max(scale, last.scale);
    const f = rescale(first, scale) orelse return floatFallback(env, observer, out, first, step, last, sep, equal_width);
    const st = rescale(step, scale) orelse return floatFallback(env, observer, out, first, step, last, sep, equal_width);
    const l: i128 = if (last.inf > 0) std.math.maxInt(i128) else if (last.inf < 0) std.math.minInt(i128) else rescale(last, scale) orelse return floatFallback(env, observer, out, first, step, last, sep, equal_width);

    // Digits printed after the point: from FIRST and INCREMENT only (GNU).
    const prec: u32 = @intCast(@max(first.precision(), step.precision()));
    const shown_scale: u32 = @intCast(scale);
    // `value` is stored at `scale` digits; values reachable from FIRST and
    // STEP have at most `prec` meaningful digits, so dropping extra ones is exact.
    const drop = pow10(shown_scale - prec).?;

    var width: usize = 0;
    if (equal_width) {
        var b1: [64]u8 = undefined;
        var b2: [64]u8 = undefined;
        // LAST is formatted as an operand even when it is never reached.
        const lw = if (last.inf != 0) 0 else fmtDec(&b2, @divTrunc(l, drop), prec, 0).len;
        width = @max(fmtDec(&b1, @divTrunc(f, drop), prec, 0).len, lw);
    }

    if (prec == 0 and width == 0 and last.inf == 0 and st != 0 and fitsI64(f) and fitsI64(l) and fitsI64(st)) {
        integerPath(out, @intCast(f), @intCast(l), @intCast(st), sep);
        return true;
    }

    var x = f;
    var buf: [64]u8 = undefined;
    var first_item = true;
    while (if (st > 0) x <= l else x >= l) {
        if (!first_item) out.write(sep);
        first_item = false;
        out.write(fmtDec(&buf, @divTrunc(x, drop), prec, width));
        if (out.failed) return true;
        x = std.math.add(i128, x, st) catch break;
    }
    if (!first_item) out.writeByte('\n');
    return true;
}

fn fitsI64(v: i128) bool {
    return v >= std.math.minInt(i64) and v <= std.math.maxInt(i64);
}

/// Integers without padding: plain 64-bit arithmetic and a two-digits-at-a-
/// time formatter instead of the exact i128 decimal machinery (which divides
/// 128-bit numbers once per digit). Output is identical to the general path.
fn integerPath(out: *Sink, first: i64, last: i64, step: i64, sep: []const u8) void {
    var x = first;
    var any = false;
    var buf: [24]u8 = undefined;
    while (if (step > 0) x <= last else x >= last) {
        if (any) out.write(sep);
        any = true;
        out.write(formatI64(&buf, x));
        if (out.failed) return;
        x = std.math.add(i64, x, step) catch break;
    }
    if (any) out.writeByte('\n');
}

const digit_pairs = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |i| {
        t[2 * i] = '0' + i / 10;
        t[2 * i + 1] = '0' + i % 10;
    }
    break :blk t;
};

/// Decimal text of `v`, written backwards into the end of `buf`.
fn formatI64(buf: *[24]u8, v: i64) []const u8 {
    var m: u64 = @abs(v);
    var i: usize = buf.len;
    while (m >= 100) {
        const r: usize = @intCast(m % 100);
        m /= 100;
        i -= 2;
        buf[i] = digit_pairs[2 * r];
        buf[i + 1] = digit_pairs[2 * r + 1];
    }
    if (m >= 10) {
        i -= 2;
        buf[i] = digit_pairs[2 * @as(usize, @intCast(m))];
        buf[i + 1] = digit_pairs[2 * @as(usize, @intCast(m)) + 1];
    } else {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(m));
    }
    if (v < 0) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

/// Format `v` (scaled by 10^prec) with `prec` decimals, zero padded to `width`.
fn fmtDec(buf: []u8, v: i128, prec: u32, width: usize) []const u8 {
    var tmp: [48]u8 = undefined;
    var n: usize = 0;
    var m: u128 = @abs(v);
    while (m > 0 or n <= prec) {
        tmp[n] = @intCast('0' + m % 10);
        m /= 10;
        n += 1;
    }
    // tmp holds digits least-significant first: insert the point before `prec` digits.
    var len: usize = 0;
    const neg = v < 0;
    var total = n + @intFromBool(prec > 0) + @intFromBool(neg);
    if (total > buf.len) total = buf.len;
    const pad = if (width > total) width - total else 0;
    if (neg) {
        buf[len] = '-';
        len += 1;
    }
    var k: usize = 0;
    while (k < pad) : (k += 1) {
        buf[len] = '0';
        len += 1;
    }
    var d = n;
    while (d > 0) {
        d -= 1;
        buf[len] = tmp[d];
        len += 1;
        if (prec > 0 and d == prec) {
            buf[len] = '.';
            len += 1;
        }
    }
    return buf[0..len];
}

fn decToFloat(d: Dec) f64 {
    if (d.inf != 0) return if (d.inf > 0) std.math.inf(f64) else -std.math.inf(f64);
    return @as(f64, @floatFromInt(d.mant)) * std.math.pow(f64, 10, -@as(f64, @floatFromInt(d.scale)));
}

fn floatFallback(env: Env, observer: Observer, out: *Sink, first: Dec, step: Dec, last: Dec, sep: []const u8, equal_width: bool) Error!bool {
    return floatPath(env, observer, out, .{ decToFloat(first), decToFloat(step), decToFloat(last) }, null, sep, equal_width);
}

const Parsed = struct { prefix: []const u8, spec: ff.Spec, suffix: []const u8 };

/// Split FORMAT around its single float conversion. Messages follow GNU seq.
fn parseFormat(observer: Observer, f: []const u8) ?Parsed {
    var i: usize = 0;
    var found: ?Parsed = null;
    var prefix_end: usize = 0;
    while (i < f.len) {
        if (f[i] != '%') {
            i += 1;
            continue;
        }
        if (i + 1 >= f.len) {
            observer.emit(.{ .format_ends_in_percent = f });
            return null;
        }
        if (f[i + 1] == '%') {
            i += 2;
            continue;
        }
        if (found != null) {
            observer.emit(.{ .format_too_many_directives = f });
            return null;
        }
        const start = i;
        i += 1;
        var spec: ff.Spec = .{};
        while (i < f.len and std.mem.indexOfScalar(u8, "-+ #0'", f[i]) != null) : (i += 1) switch (f[i]) {
            '-' => spec.left = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '#' => spec.alt = true,
            '0' => spec.zero = true,
            else => {},
        };
        var w: usize = 0;
        while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) w = w *| 10 +| (f[i] - '0');
        spec.width = w;
        if (i < f.len and f[i] == '.') {
            i += 1;
            var p: usize = 0;
            while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) p = p *| 10 +| (f[i] - '0');
            spec.precision = p;
        }
        if (i < f.len and f[i] == 'L') i += 1;
        if (i >= f.len) {
            observer.emit(.{ .format_ends_in_percent = f });
            return null;
        }
        const c = f[i];
        if (std.mem.indexOfScalar(u8, "eEfFgG", c) == null) {
            if (c == 'a' or c == 'A') observer.emit(.{ .format_unsupported_directive = .{ .format = f, .conv = c } }) else observer.emit(.{ .format_unknown_directive = .{ .format = f, .conv = c } });
            return null;
        }
        spec.conv = c;
        found = .{ .prefix = f[0..start], .spec = spec, .suffix = "" };
        prefix_end = i + 1;
        i += 1;
    }
    var p = found orelse {
        observer.emit(.{ .format_no_directive = f });
        return null;
    };
    p.suffix = f[prefix_end..];
    return p;
}

/// Write literal text from FORMAT, turning "%%" into "%".
fn writeLiteral(out: *Sink, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        out.writeByte(text[i]);
        if (text[i] == '%' and i + 1 < text.len and text[i + 1] == '%') i += 1;
    }
}

fn floatPath(env: Env, observer: Observer, out: *Sink, v: [3]f64, format: ?[]const u8, sep: []const u8, equal_width: bool) Error!bool {
    const first = v[0];
    const step = v[1];
    const last = v[2];
    var parsed: Parsed = undefined;
    if (format) |f| {
        parsed = parseFormat(observer, f) orelse return false;
    } else {
        parsed = .{ .prefix = "", .spec = .{ .conv = 'g' }, .suffix = "" };
        if (equal_width) {
            // Zero-pad to the widest of FIRST and LAST formatted with %g.
            parsed.spec.zero = true;
            const w1 = ff.formatAlloc(env.gpa, .{ .conv = 'g' }, first) catch return error.OutOfMemory;
            defer env.gpa.free(w1);
            const w2 = ff.formatAlloc(env.gpa, .{ .conv = 'g' }, last) catch return error.OutOfMemory;
            defer env.gpa.free(w2);
            parsed.spec.width = @max(w1.len, w2.len);
        }
    }
    var k: u64 = 0;
    var first_item = true;
    while (true) : (k += 1) {
        const x = first + @as(f64, @floatFromInt(k)) * step;
        if (if (step >= 0) x > last else x < last) break;
        if (!first_item) out.write(sep);
        first_item = false;
        writeLiteral(out, parsed.prefix);
        const s = ff.formatAlloc(env.gpa, parsed.spec, x) catch return error.OutOfMemory;
        defer env.gpa.free(s);
        out.write(s);
        writeLiteral(out, parsed.suffix);
        if (out.failed) return true;
        if (std.math.isInf(x)) break;
    }
    if (!first_item) out.writeByte('\n');
    return true;
}

test "parseDecimal" {
    const t = std.testing;
    const a = parseDecimal("1.50").?;
    try t.expectEqual(@as(i128, 150), a.mant);
    try t.expectEqual(@as(i32, 2), a.scale);
    const b = parseDecimal("1e3").?;
    try t.expectEqual(@as(i32, -3), b.scale);
    try t.expectEqual(@as(usize, 0), b.precision());
    try t.expectEqual(@as(i32, 5), parseDecimal("1e-5").?.scale);
    try t.expectEqual(@as(i128, -5), parseDecimal("-.5").?.mant);
    try t.expect(parseDecimal("0x10") == null);
    try t.expect(parseDecimal("") == null);
    try t.expect(parseDecimal("1.2.3") == null);
    try t.expectEqual(@as(i2, -1), parseDecimal("-inf").?.inf);
}

test "fmtDec" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.5", fmtDec(&b, 5, 1, 0));
    try std.testing.expectEqualStrings("-0.05", fmtDec(&b, -5, 2, 0));
    try std.testing.expectEqualStrings("007", fmtDec(&b, 7, 0, 3));
    try std.testing.expectEqualStrings("-07", fmtDec(&b, -7, 0, 3));
    try std.testing.expectEqualStrings("0", fmtDec(&b, 0, 0, 0));
    try std.testing.expectEqualStrings("12.30", fmtDec(&b, 1230, 2, 0));
}

test "formatI64" {
    var b: [24]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("0", formatI64(&b, 0));
    try t.expectEqualStrings("7", formatI64(&b, 7));
    try t.expectEqualStrings("10", formatI64(&b, 10));
    try t.expectEqualStrings("-99", formatI64(&b, -99));
    try t.expectEqualStrings("100", formatI64(&b, 100));
    try t.expectEqualStrings("123456789", formatI64(&b, 123456789));
    try t.expectEqualStrings("9223372036854775807", formatI64(&b, std.math.maxInt(i64)));
    try t.expectEqualStrings("-9223372036854775808", formatI64(&b, std.math.minInt(i64)));
}
