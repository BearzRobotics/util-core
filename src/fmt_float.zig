// SPDX-License-Identifier: GPL-2.0-or-later
//! C-compatible printf formatting of one double: %e %E %f %F %g %G with the
//! flags `-+ #0`, a width and a precision (as in POSIX.1-2024 printf(1) /
//! fprintf and the GNU seq format rules).
//!
//! The standard library's float formatter prints the shortest round-trip
//! digits and then pads, which differs from C for any precision beyond the
//! shortest representation (printf("%.20f", 0.1) prints the exact binary
//! value). Here the value is converted exactly with big integers and rounded
//! half-to-even on the exact binary value, as glibc does.
//!
//! Not implemented: %a / %A (hexadecimal floating point) and locale
//! decimal points or thousands grouping (the C locale is assumed).

const std = @import("std");
const big = std.math.big;
const Allocator = std.mem.Allocator;

pub const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    precision: ?usize = null,
    /// One of e E f F g G.
    conv: u8 = 'f',
};

/// A finite non-negative value as mant * 2^exp (mant == 0 for zero).
const Dec = struct {
    mant: u64,
    exp: i64,

    fn of64(v: f64) Dec {
        const bits: u64 = @bitCast(@abs(v));
        const frac = bits & ((1 << 52) - 1);
        const be: i64 = @intCast((bits >> 52) & 0x7ff);
        return .{ .mant = if (be == 0) frac else frac | (1 << 52), .exp = (if (be == 0) 1 else be) - 1075 };
    }

    fn of80(v: f80) Dec {
        const bits: u80 = @bitCast(v);
        const mant: u64 = @truncate(bits);
        const be: i64 = @intCast((bits >> 64) & 0x7fff);
        return .{ .mant = mant, .exp = (if (be == 0) 1 else be) - 16383 - 63 };
    }

    /// floor(log10(value)) up to one unit; callers correct it by retrying.
    fn log10Estimate(d: Dec) i64 {
        const e2 = d.exp + 63 - @as(i64, @clz(d.mant));
        return @intFromFloat(@floor(@as(f64, @floatFromInt(e2)) * 0.30102999566398120));
    }
};

/// Format `value` according to `spec`; the caller owns the returned slice.
pub fn formatAlloc(gpa: Allocator, spec: Spec, value: f64) ![]u8 {
    return formatAllocT(f64, gpa, spec, value);
}

/// Same for an x87 long double (what GNU printf and seq format with).
pub fn formatAllocLong(gpa: Allocator, spec: Spec, value: f80) ![]u8 {
    return formatAllocT(f80, gpa, spec, value);
}

fn formatAllocT(comptime T: type, gpa: Allocator, spec: Spec, value: T) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    const neg = std.math.signbit(value);
    const upper = std.ascii.isUpper(spec.conv);
    var finite = true;
    if (std.math.isNan(value)) {
        finite = false;
        try body.appendSlice(gpa, if (upper) "NAN" else "nan");
    } else if (std.math.isInf(value)) {
        finite = false;
        try body.appendSlice(gpa, if (upper) "INF" else "inf");
    } else {
        try formatFinite(gpa, &body, spec, if (T == f80) Dec.of80(value) else Dec.of64(value));
    }

    const sign: []const u8 = if (neg) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
    const len = sign.len + body.items.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const pad = if (spec.width > len) spec.width - len else 0;
    if (spec.left) {
        try out.appendSlice(gpa, sign);
        try out.appendSlice(gpa, body.items);
        try out.appendNTimes(gpa, ' ', pad);
    } else if (spec.zero and finite) {
        try out.appendSlice(gpa, sign);
        try out.appendNTimes(gpa, '0', pad);
        try out.appendSlice(gpa, body.items);
    } else {
        try out.appendNTimes(gpa, ' ', pad);
        try out.appendSlice(gpa, sign);
        try out.appendSlice(gpa, body.items);
    }
    return out.toOwnedSlice(gpa);
}

fn formatFinite(gpa: Allocator, body: *std.ArrayList(u8), spec: Spec, v: Dec) !void {
    const prec = spec.precision orelse 6;
    switch (spec.conv) {
        'f', 'F' => try fixed(gpa, body, v, prec, spec.alt),
        'e', 'E' => _ = try expo(gpa, body, v, prec, spec.alt, spec.conv == 'E'),
        'g', 'G' => {
            const p = if (prec == 0) 1 else prec;
            // The exponent X that %e would print after rounding to p digits.
            var probe: std.ArrayList(u8) = .empty;
            defer probe.deinit(gpa);
            const x = try expo(gpa, &probe, v, p - 1, false, false);
            if (x >= -4 and x < @as(i64, @intCast(p))) {
                try fixed(gpa, body, v, @intCast(@as(i64, @intCast(p)) - 1 - x), spec.alt);
            } else {
                _ = try expo(gpa, body, v, p - 1, spec.alt, spec.conv == 'G');
            }
            if (!spec.alt) stripZeros(body);
        },
        else => unreachable,
    }
}

/// Remove trailing zeros of the fraction (and a bare point) of a %g result,
/// leaving any exponent part in place.
fn stripZeros(body: *std.ArrayList(u8)) void {
    const items = body.items;
    const e_pos = std.mem.indexOfAny(u8, items, "eE");
    const mant_end = e_pos orelse items.len;
    if (std.mem.indexOfScalar(u8, items[0..mant_end], '.') == null) return;
    var end = mant_end;
    while (end > 0 and items[end - 1] == '0') end -= 1;
    if (end > 0 and items[end - 1] == '.') end -= 1;
    if (e_pos) |ep| {
        const tail_len = items.len - ep;
        std.mem.copyForwards(u8, items[end..][0..tail_len], items[ep..]);
        body.shrinkRetainingCapacity(end + tail_len);
    } else body.shrinkRetainingCapacity(end);
}

/// round_half_even(v * 10^pow10) as a big integer.
fn scaledRound(gpa: Allocator, v: Dec, pow10: i64) !big.int.Managed {
    // v = mant * 2^exp exactly.
    const mant = v.mant;
    const exp = v.exp;

    var num = try big.int.Managed.initSet(gpa, mant);
    defer num.deinit();
    var den = try big.int.Managed.initSet(gpa, 1);
    defer den.deinit();
    var ten = try big.int.Managed.initSet(gpa, 10);
    defer ten.deinit();
    var tmp = try big.int.Managed.init(gpa);
    defer tmp.deinit();

    if (exp > 0) try num.shiftLeft(&num, @intCast(exp)) else if (exp < 0) try den.shiftLeft(&den, @intCast(-exp));
    if (pow10 != 0) {
        var p = try big.int.Managed.initSet(gpa, 1);
        defer p.deinit();
        try p.pow(&ten, @intCast(@abs(pow10)));
        if (pow10 > 0) {
            try tmp.mul(&num, &p);
            try num.copy(tmp.toConst());
        } else {
            try tmp.mul(&den, &p);
            try den.copy(tmp.toConst());
        }
    }
    var q = try big.int.Managed.init(gpa);
    errdefer q.deinit();
    var r = try big.int.Managed.init(gpa);
    defer r.deinit();
    try q.divTrunc(&r, &num, &den);
    // Compare 2r with den.
    try r.shiftLeft(&r, 1);
    const ord = r.toConst().order(den.toConst());
    var one = try big.int.Managed.initSet(gpa, 1);
    defer one.deinit();
    const odd = q.isOdd();
    if (ord == .gt or (ord == .eq and odd)) {
        try tmp.add(&q, &one);
        try q.copy(tmp.toConst());
    }
    return q;
}

fn digitsOf(gpa: Allocator, n: *const big.int.Managed) ![]u8 {
    return n.toString(gpa, 10, .lower);
}

fn fixed(gpa: Allocator, body: *std.ArrayList(u8), v: Dec, prec: usize, alt: bool) !void {
    var q = try scaledRound(gpa, v, @intCast(prec));
    defer q.deinit();
    const digits = try digitsOf(gpa, &q);
    defer gpa.free(digits);
    var int_len: usize = 0;
    if (digits.len > prec) {
        int_len = digits.len - prec;
        try body.appendSlice(gpa, digits[0..int_len]);
    } else try body.append(gpa, '0');
    if (prec > 0 or alt) try body.append(gpa, '.');
    if (prec > 0) {
        if (digits.len < prec) try body.appendNTimes(gpa, '0', prec - digits.len);
        try body.appendSlice(gpa, digits[int_len..]);
    }
}

/// Appends d.ddde±XX and returns the decimal exponent printed.
fn expo(gpa: Allocator, body: *std.ArrayList(u8), v: Dec, prec: usize, alt: bool, upper: bool) !i64 {
    var x: i64 = 0;
    var digits: []u8 = &.{};
    defer if (digits.len > 0) gpa.free(digits);
    if (v.mant != 0) {
        x = v.log10Estimate();
        while (true) {
            var q = try scaledRound(gpa, v, @as(i64, @intCast(prec)) - x);
            defer q.deinit();
            const d = try digitsOf(gpa, &q);
            if (d.len == prec + 1) {
                digits = d;
                break;
            }
            gpa.free(d);
            if (d.len > prec + 1) x += 1 else x -= 1;
        }
    } else {
        digits = try gpa.alloc(u8, prec + 1);
        @memset(digits, '0');
    }
    try body.append(gpa, digits[0]);
    if (prec > 0 or alt) try body.append(gpa, '.');
    try body.appendSlice(gpa, digits[1..]);
    try body.append(gpa, if (upper) 'E' else 'e');
    try body.append(gpa, if (x < 0) '-' else '+');
    var buf: [24]u8 = undefined;
    const ex = std.fmt.bufPrint(&buf, "{d:0>2}", .{@abs(x)}) catch unreachable;
    try body.appendSlice(gpa, ex);
    return x;
}

fn expect(spec: Spec, v: f64, want: []const u8) !void {
    const got = try formatAlloc(std.testing.allocator, spec, v);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "fixed" {
    try expect(.{ .conv = 'f' }, 1.0, "1.000000");
    try expect(.{ .conv = 'f', .precision = 2 }, 0.125, "0.12");
    try expect(.{ .conv = 'f', .precision = 2 }, 0.375, "0.38");
    try expect(.{ .conv = 'f', .precision = 0 }, 2.5, "2");
    try expect(.{ .conv = 'f', .precision = 0 }, 3.5, "4");
    try expect(.{ .conv = 'f', .precision = 20 }, 0.1, "0.10000000000000000555");
    try expect(.{ .conv = 'f', .precision = 0, .alt = true }, 3.0, "3.");
    try expect(.{ .conv = 'f', .precision = 1 }, -0.04, "-0.0");
    try expect(.{ .conv = 'f', .precision = 0 }, 1e22, "10000000000000000000000");
    try expect(.{ .conv = 'f', .precision = 0 }, 1e30, "1000000000000000019884624838656");
}

test "exponent" {
    try expect(.{ .conv = 'e' }, 1.0, "1.000000e+00");
    try expect(.{ .conv = 'E', .precision = 3 }, 12345.678, "1.235E+04");
    try expect(.{ .conv = 'e', .precision = 2 }, 9.999e-5, "1.00e-04");
    try expect(.{ .conv = 'e', .precision = 0 }, 0, "0e+00");
    try expect(.{ .conv = 'e', .precision = 3 }, 1e100, "1.000e+100");
}

test "general" {
    try expect(.{ .conv = 'g' }, 100000.0, "100000");
    try expect(.{ .conv = 'g' }, 1000000.0, "1e+06");
    try expect(.{ .conv = 'g' }, 0.0001, "0.0001");
    try expect(.{ .conv = 'g' }, 0.00001, "1e-05");
    try expect(.{ .conv = 'g' }, 0.5, "0.5");
    try expect(.{ .conv = 'G' }, 1e-5, "1E-05");
    try expect(.{ .conv = 'g', .precision = 3, .alt = true }, 1.0, "1.00");
    try expect(.{ .conv = 'g', .precision = 0 }, 123.0, "1e+02");
    try expect(.{ .conv = 'g' }, 0, "0");
    try expect(.{ .conv = 'g' }, 123456789.0, "1.23457e+08");
}

test "flags and width" {
    try expect(.{ .conv = 'f', .precision = 2, .width = 8 }, 3.14159, "    3.14");
    try expect(.{ .conv = 'f', .precision = 2, .width = 8, .left = true }, 3.14159, "3.14    ");
    try expect(.{ .conv = 'f', .precision = 2, .width = 8, .zero = true }, -3.14159, "-0003.14");
    try expect(.{ .conv = 'f', .precision = 1, .plus = true }, 2.0, "+2.0");
    try expect(.{ .conv = 'f', .precision = 1, .space = true }, 2.0, " 2.0");
    try expect(.{ .conv = 'f', .width = 6 }, std.math.inf(f64), "   inf");
    try expect(.{ .conv = 'F', .zero = true, .width = 6 }, -std.math.inf(f64), "  -INF");
    try expect(.{ .conv = 'g' }, std.math.nan(f64), "nan");
}
