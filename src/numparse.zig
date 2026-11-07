//! strtold-like parsing of a floating-point prefix, shared by printf and
//! numfmt. Accepts leading white space, a sign, decimal numbers with an
//! optional exponent, hexadecimal floating point (0x1.8p3), "inf"/"infinity"
//! and "nan" in any case. Values are x87 extended doubles (f80) (f80 is x87 long double, as GNU uses).

const std = @import("std");

pub const Parsed = struct { value: f80, len: usize };

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn startsWithNoCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// v * 2^e in steps of 2^±1000 (powers of two that f64 holds exactly).
fn scale2(v: f80, e: i32) f80 {
    var r = v;
    var k = e;
    while (k > 0) {
        const step = @min(k, 1000);
        r *= @as(f80, std.math.pow(f64, 2, @floatFromInt(step)));
        k -= step;
    }
    while (k < 0) {
        const step = @min(-k, 1000);
        r /= @as(f80, std.math.pow(f64, 2, @floatFromInt(step)));
        k += step;
    }
    return r;
}

/// Parse a prefix of `s`; null when no number starts there.
pub fn parseFloatPrefix(s: []const u8) ?Parsed {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    const rest = s[i..];
    if (startsWithNoCase(rest, "infinity")) return .{ .value = if (neg) -std.math.inf(f80) else std.math.inf(f80), .len = i + 8 };
    if (startsWithNoCase(rest, "inf")) return .{ .value = if (neg) -std.math.inf(f80) else std.math.inf(f80), .len = i + 3 };
    if (startsWithNoCase(rest, "nan")) {
        var n: usize = 3;
        // nan(chars)
        if (rest.len > 3 and rest[3] == '(') {
            if (std.mem.indexOfScalar(u8, rest[3..], ')')) |close| n = 3 + close + 1;
        }
        return .{ .value = if (neg) -std.math.nan(f80) else std.math.nan(f80), .len = i + n };
    }
    if (rest.len >= 3 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X') and (std.ascii.isHex(rest[2]) or (rest[2] == '.' and rest.len > 3 and std.ascii.isHex(rest[3])))) {
        var v: f80 = 0;
        var k: usize = 2;
        while (k < rest.len and std.ascii.isHex(rest[k])) : (k += 1) v = v * 16 + @as(f80, @floatFromInt(std.fmt.charToDigit(rest[k], 16) catch 0));
        var scale: f80 = 1;
        if (k < rest.len and rest[k] == '.') {
            k += 1;
            while (k < rest.len and std.ascii.isHex(rest[k])) : (k += 1) {
                scale /= 16;
                v += scale * @as(f80, @floatFromInt(std.fmt.charToDigit(rest[k], 16) catch 0));
            }
        }
        if (k < rest.len and (rest[k] == 'p' or rest[k] == 'P')) {
            var m = k + 1;
            var eneg = false;
            if (m < rest.len and (rest[m] == '+' or rest[m] == '-')) {
                eneg = rest[m] == '-';
                m += 1;
            }
            if (m < rest.len and std.ascii.isDigit(rest[m])) {
                var e: i32 = 0;
                while (m < rest.len and std.ascii.isDigit(rest[m])) : (m += 1) e = @min(e *| 10 +| @as(i32, rest[m] - '0'), 100000);
                v = scale2(v, if (eneg) -e else e);
                k = m;
            }
        }
        return .{ .value = if (neg) -v else v, .len = i + k };
    }
    var k: usize = 0;
    var digits: usize = 0;
    while (k < rest.len and std.ascii.isDigit(rest[k])) : (k += 1) digits += 1;
    if (k < rest.len and rest[k] == '.') {
        k += 1;
        while (k < rest.len and std.ascii.isDigit(rest[k])) : (k += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (k < rest.len and (rest[k] == 'e' or rest[k] == 'E')) {
        var m = k + 1;
        if (m < rest.len and (rest[m] == '+' or rest[m] == '-')) m += 1;
        if (m < rest.len and std.ascii.isDigit(rest[m])) {
            while (m < rest.len and std.ascii.isDigit(rest[m])) m += 1;
            k = m;
        }
    }
    const v = std.fmt.parseFloat(f80, rest[0..k]) catch 0;
    return .{ .value = if (neg) -v else v, .len = i + k };
}

test "parseFloatPrefix" {
    const t = std.testing;
    try t.expectEqual(@as(f80, 1.5), parseFloatPrefix("1.5").?.value);
    try t.expectEqual(@as(usize, 3), parseFloatPrefix("1.5abc").?.len);
    try t.expectEqual(@as(f80, 8), parseFloatPrefix("0x1p3").?.value);
    try t.expect(parseFloatPrefix("abc") == null);
    try t.expect(std.math.isInf(parseFloatPrefix("-INF").?.value));
    try t.expectEqual(@as(f80, 1000), parseFloatPrefix(" 1e3").?.value);
}
