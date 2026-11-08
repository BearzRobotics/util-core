//! printf — format and print data.
//! References: GNU coreutils manual "printf invocation" (9.7); POSIX.1-2024
//! printf (format, escapes, argument reuse).
//!
//! Numbers are held as intmax/uintmax (integers) and f80 (floating point, the
//! x87 long double GNU uses, so 0.1 prints as 0.1L and %a shows 64 bits).
//! The locale is C: \u and \U escapes are printed back as written (upper-case
//! hex), as GNU does outside a UTF-8 locale.

const std = @import("std");
const cli = @import("../cli.zig");
const fmt_float = @import("../fmt_float.zig");
const numparse = @import("../numparse.zig");

const State = struct {
    ctx: cli.Context,
    out: *cli.Out,
    args: []const [:0]const u8,
    next: usize = 0,
    status: u8 = 0,
    stop: bool = false, // \c seen
    used_any: bool = false,

    fn nextArg(s: *State) ?[]const u8 {
        s.used_any = true;
        if (s.next >= s.args.len) return null;
        const a = s.args[s.next];
        s.next += 1;
        return a;
    }
};

pub fn main(ctx: cli.Context) u8 {
    var args: []const [:0]const u8 = ctx.args;
    if (args.len > 0 and std.mem.eql(u8, args[0], "--help")) return help(ctx);
    if (args.len > 0 and std.mem.eql(u8, args[0], "--version")) return if (cli.printVersion(ctx)) 0 else 1;
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args = args[1..];
    if (args.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    const format = args[0];
    var out = cli.Out.init(ctx.io);
    var st: State = .{ .ctx = ctx, .out = &out, .args = args[1..] };

    // The format is reused while arguments remain (and a pass consumed some).
    while (true) {
        const before = st.next;
        st.used_any = false;
        if (!pass(&st, format)) {
            out.flush();
            return 1;
        }
        if (st.stop) break;
        if (st.next == before) {
            if (st.args.len > 0 and !st.used_any) {
                var wb: [4400]u8 = undefined;
                const line = std.fmt.bufPrint(&wb, "{s}: warning: ignoring excess arguments, starting with {f}\n", .{ ctx.name, cli.quoteC(st.args[0]) }) catch "";
                out.flush();
                std.Io.File.stderr().writeStreamingAll(ctx.io, line) catch {};
            }
            break;
        }
        if (st.next >= st.args.len) break;
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return st.status;
}

/// One pass over the format. Returns false after a fatal error.
fn pass(st: *State, format: []const u8) bool {
    var i: usize = 0;
    while (i < format.len) {
        const c = format[i];
        if (c == '\\') {
            i += escape(st, format, i, false) orelse return false;
            if (st.stop) return true;
            continue;
        }
        if (c != '%') {
            st.out.writeByte(c);
            i += 1;
            continue;
        }
        i += conversion(st, format, i) orelse return false;
        if (st.stop) return true;
    }
    return true;
}

fn hexVal(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// Interpret the backslash sequence at `s[i..]` (s[i] == '\\'). Returns its
/// length in `s`, or null after a fatal error. `in_b` selects the %b rules
/// (an octal escape needs a leading 0 there; \c stops all output).
fn escape(st: *State, s: []const u8, i: usize, in_b: bool) ?usize {
    const out = st.out;
    if (i + 1 >= s.len) {
        out.writeByte('\\');
        return 1;
    }
    const c = s[i + 1];
    switch (c) {
        '\\' => out.writeByte('\\'),
        '"' => out.writeByte('"'),
        'a' => out.writeByte(7),
        'b' => out.writeByte(8),
        'e' => out.writeByte(27),
        'f' => out.writeByte(12),
        'n' => out.writeByte('\n'),
        'r' => out.writeByte('\r'),
        't' => out.writeByte('\t'),
        'v' => out.writeByte(11),
        'c' => {
            st.stop = true;
            return 2;
        },
        '0'...'7' => {
            // %b: \0NNN (up to three digits after the 0); format: \NNN.
            var j = i + 1;
            var digits: usize = 0;
            var v: u32 = 0;
            if (in_b and c == '0') j += 1;
            const max: usize = 3;
            while (j < s.len and digits < max and s[j] >= '0' and s[j] <= '7') : (j += 1) {
                v = v * 8 + (s[j] - '0');
                digits += 1;
            }
            out.writeByte(@truncate(v));
            return j - i;
        },
        'x' => {
            var j = i + 2;
            var v: u32 = 0;
            var n: usize = 0;
            while (j < s.len and n < 2) : (j += 1) {
                const d = hexVal(s[j]) orelse break;
                v = v * 16 + d;
                n += 1;
            }
            if (n == 0) {
                cli.warn(st.ctx, "missing hexadecimal number in escape", .{});
                return null;
            }
            out.writeByte(@truncate(v));
            return j - i;
        },
        'u', 'U' => {
            const want: usize = if (c == 'u') 4 else 8;
            var j = i + 2;
            var v: u32 = 0;
            var n: usize = 0;
            while (j < s.len and n < want) : (j += 1) {
                const d = hexVal(s[j]) orelse break;
                v = v *% 16 +% d;
                n += 1;
            }
            if (n < want) {
                cli.warn(st.ctx, "missing hexadecimal number in escape", .{});
                return null;
            }
            // GNU's check applies to \u names; \U names go straight to output.
            const bad = c == 'u' and ((v < 0xA0 and v != 0x24 and v != 0x40 and v != 0x60) or (v >= 0xD800 and v <= 0xDFFF));
            if (bad) {
                cli.warn(st.ctx, "invalid universal character name \\u{s}", .{s[i + 2 .. j]});
                return null;
            }
            if (c == 'U' and v < 0x80) {
                out.writeByte(@intCast(v));
            } else if (c == 'u') {
                out.print("\\u{X:0>4}", .{v}); // C locale: no conversion possible
            } else out.print("\\U{X:0>8}", .{v});
            return j - i;
        },
        else => {
            out.writeByte('\\');
            out.writeByte(c);
        },
    }
    return 2;
}

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    quote: bool = false, // the ' flag
    width: usize = 0,
    precision: ?usize = null,
};

/// Handle the conversion at `f[i..]` (f[i] == '%'); returns its length.
fn conversion(st: *State, f: []const u8, i: usize) ?usize {
    var j = i + 1;
    var sp: Spec = .{};
    // glibc accepts "%N$" (the number is ignored: arguments are consumed in order).
    {
        var k = j;
        while (k < f.len and std.ascii.isDigit(f[k])) k += 1;
        if (k > j and k < f.len and f[k] == '$') j = k + 1;
    }
    while (j < f.len) : (j += 1) switch (f[j]) {
        '-' => sp.left = true,
        '+' => sp.plus = true,
        ' ' => sp.space = true,
        '#' => sp.alt = true,
        '0' => sp.zero = true,
        '\'' => sp.quote = true,
        else => break,
    };
    // Width.
    if (j < f.len and f[j] == '*') {
        j += 1;
        const w = intArg(st, true);
        if (w < 0) {
            sp.left = true;
            sp.width = @intCast(-w);
        } else sp.width = @intCast(w);
    } else {
        while (j < f.len and std.ascii.isDigit(f[j])) : (j += 1) sp.width = sp.width *| 10 +| (f[j] - '0');
    }
    // Precision.
    if (j < f.len and f[j] == '.') {
        j += 1;
        if (j < f.len and f[j] == '*') {
            j += 1;
            const p = intArg(st, true);
            sp.precision = if (p < 0) null else @intCast(p);
        } else {
            var p: usize = 0;
            while (j < f.len and std.ascii.isDigit(f[j])) : (j += 1) p = p *| 10 +| (f[j] - '0');
            sp.precision = p;
        }
    }
    // Length modifiers are ignored.
    while (j < f.len and std.mem.indexOfScalar(u8, "hlLjzt", f[j]) != null) j += 1;
    if (j >= f.len) {
        cli.warn(st.ctx, "{s}: invalid conversion specification", .{f[i..]});
        return null;
    }
    const conv = f[j];
    j += 1;
    if (!flagsAllowed(conv, sp)) return invalidSpec(st, f[i..j]);
    switch (conv) {
        '%' => {
            if (j - i != 2) {
                cli.warn(st.ctx, "{s}: invalid conversion specification", .{f[i..j]});
                return null;
            }
            st.out.writeByte('%');
        },
        's' => {
            const a = st.nextArg() orelse "";
            const text = if (sp.precision) |p| a[0..@min(p, a.len)] else a;
            pad(st, text, sp);
        },
        'c' => {
            const a = st.nextArg() orelse "";
            pad(st, if (a.len == 0) "\x00" else a[0..1], sp);
        },
        'b' => {
            if (hasModifiers(sp)) return invalidSpec(st, f[i..j]);
            const a = st.nextArg() orelse "";
            if (!bArg(st, a)) return null;
        },
        'q' => {
            if (hasModifiers(sp)) return invalidSpec(st, f[i..j]);
            const a = st.nextArg() orelse "";
            var buf: [8192]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            quoteShell(&w, a) catch {};
            pad(st, w.buffered(), sp);
        },
        'd', 'i' => {
            const v = intArg(st, false);
            fmtSigned(st, v, sp);
        },
        'o', 'u', 'x', 'X' => {
            const v = uintArg(st);
            fmtUnsigned(st, v, conv, sp);
        },
        'e', 'E', 'f', 'F', 'g', 'G' => {
            const v = floatArg(st);
            const s = fmt_float.formatAllocLong(st.ctx.gpa, .{ .left = sp.left, .plus = sp.plus, .space = sp.space, .alt = sp.alt, .zero = sp.zero, .width = sp.width, .precision = sp.precision, .conv = conv }, v) catch return null;
            defer st.ctx.gpa.free(s);
            st.out.write(s);
        },
        'a', 'A' => {
            const v = floatArg(st);
            hexFloat(st, v, conv == 'A', sp);
        },
        else => {
            cli.warn(st.ctx, "{s}: invalid conversion specification", .{f[i..j]});
            return null;
        },
    }
    return j - i;
}

fn pad(st: *State, text: []const u8, sp: Spec) void {
    const fill = if (sp.width > text.len) sp.width - text.len else 0;
    if (!sp.left) for (0..fill) |_| st.out.writeByte(' ');
    st.out.write(text);
    if (sp.left) for (0..fill) |_| st.out.writeByte(' ');
}

/// %b: the argument with backslash escapes; \c ends all output.
fn bArg(st: *State, a: []const u8) bool {
    var i: usize = 0;
    while (i < a.len) {
        if (a[i] == '\\') {
            i += escape(st, a, i, true) orelse return false;
            if (st.stop) return true;
        } else {
            st.out.writeByte(a[i]);
            i += 1;
        }
    }
    return true;
}

/// Which flags GNU accepts with which conversion (found by probing 9.7):
/// d i u: - + space 0 '   o x X e E a A: - + space # 0   f F g G: all but none
/// missing   c s: - + space only; c takes no precision.
fn flagsAllowed(conv: u8, sp: Spec) bool {
    switch (conv) {
        'd', 'i', 'u' => return !sp.alt,
        'o', 'x', 'X', 'e', 'E', 'a', 'A' => return !sp.quote,
        'f', 'F', 'g', 'G' => return true,
        'c' => return !sp.alt and !sp.zero and !sp.quote and sp.precision == null,
        's' => return !sp.alt and !sp.zero and !sp.quote,
        else => return true,
    }
}

fn hasModifiers(sp: Spec) bool {
    return sp.left or sp.plus or sp.space or sp.alt or sp.zero or sp.quote or sp.width != 0 or sp.precision != null;
}

fn invalidSpec(st: *State, text: []const u8) ?usize {
    cli.warn(st.ctx, "{s}: invalid conversion specification", .{text});
    return null;
}

/// Shell quoting as printf %q: plain when safe, '...' or $'...' otherwise.
fn quoteShell(w: *std.Io.Writer, a: []const u8) !void {
    try cli.quote(a).format(w);
}

// ------------------------------------------------------------ numeric args

fn reportNumber(st: *State, text: []const u8, what: enum { none, not_numeric, partial, range }) void {
    switch (what) {
        .none => {},
        .not_numeric => cli.warn(st.ctx, "{f}: expected a numeric value", .{cli.quoteC(text)}),
        .partial => cli.warn(st.ctx, "{f}: value not completely converted", .{cli.quoteC(text)}),
        .range => cli.warn(st.ctx, "{f}: Numerical result out of range", .{cli.quoteC(text)}),
    }
    if (what != .none) st.status = 1;
}

/// Next argument as intmax_t (width/precision arguments pass `silent`).
fn intArg(st: *State, silent: bool) i64 {
    _ = silent;
    const a = st.nextArg() orelse return 0;
    if (a.len >= 2 and (a[0] == '\'' or a[0] == '"')) {
        charConstWarning(st, a);
        return a[1];
    }
    return parseInteger(st, a, true);
}

fn uintArg(st: *State) u64 {
    const a = st.nextArg() orelse return 0;
    if (a.len >= 2 and (a[0] == '\'' or a[0] == '"')) {
        charConstWarning(st, a);
        return a[1];
    }
    return @bitCast(parseInteger(st, a, false));
}

/// "'AB": the value is that of 'A'; the rest is ignored with a warning.
fn charConstWarning(st: *State, a: []const u8) void {
    if (a.len > 2) {
        var buf: [4400]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}: warning: {s}: character(s) following character constant have been ignored\n", .{ st.ctx.name, a[2..] }) catch return;
        std.Io.File.stderr().writeStreamingAll(st.ctx.io, line) catch {};
    }
}

/// strtoimax / strtoumax with base detection, as GNU printf does.
fn parseInteger(st: *State, a: []const u8, signed: bool) i64 {
    var i: usize = 0;
    while (i < a.len and (a[i] == ' ' or (a[i] >= '\t' and a[i] <= '\r'))) i += 1;
    var neg = false;
    if (i < a.len and (a[i] == '+' or a[i] == '-')) {
        neg = a[i] == '-';
        i += 1;
    }
    var base: u8 = 10;
    if (i + 1 < a.len and a[i] == '0' and (a[i + 1] == 'x' or a[i + 1] == 'X') and i + 2 < a.len and std.ascii.isHex(a[i + 2])) {
        base = 16;
        i += 2;
    } else if (i < a.len and a[i] == '0') base = 8;
    const start = i;
    var v: u128 = 0;
    var over = false;
    while (i < a.len) : (i += 1) {
        const d = std.fmt.charToDigit(a[i], base) catch break;
        v = v * base + d;
        if (v > std.math.maxInt(u64) * 2) {
            over = true;
            v = std.math.maxInt(u64) * 2;
        }
    }
    if (i == start and base != 8) {
        reportNumber(st, a, .not_numeric);
        return 0;
    }
    if (i == start and base == 8) {
        // lone "0" handled by the loop; an empty digit run here is "0" itself
    }
    var result: i64 = undefined;
    var range = over;
    if (signed) {
        if (neg) {
            if (v > @as(u128, 1) << 63) {
                result = std.math.minInt(i64);
                range = true;
            } else result = @intCast(-@as(i128, @intCast(v)));
        } else if (v > std.math.maxInt(i64)) {
            result = std.math.maxInt(i64);
            range = true;
        } else result = @intCast(v);
    } else {
        // strtoumax: a minus sign negates modulo 2^64.
        if (v > std.math.maxInt(u64)) {
            result = -1;
            range = true;
        } else {
            const u: u64 = @intCast(v);
            result = @bitCast(if (neg) 0 -% u else u);
        }
    }
    if (range) {
        reportNumber(st, a, .range);
    } else if (i < a.len) reportNumber(st, a, .partial);
    return result;
}

fn floatArg(st: *State) f80 {
    const a = st.nextArg() orelse return 0;
    if (a.len >= 2 and (a[0] == '\'' or a[0] == '"')) {
        charConstWarning(st, a);
        return @as(f80, @floatFromInt(a[1]));
    }
    const p = numparse.parseFloatPrefix(a) orelse {
        reportNumber(st, a, .not_numeric);
        return 0;
    };
    if (p.len < a.len) reportNumber(st, a, .partial);
    return p.value;
}

// ------------------------------------------------------- integer formatting

fn fmtSigned(st: *State, v: i64, sp: Spec) void {
    var digits: [32]u8 = undefined;
    const neg = v < 0;
    const mag: u64 = if (neg) @intCast(-@as(i128, v)) else @intCast(v);
    const text = std.fmt.bufPrint(&digits, "{d}", .{mag}) catch unreachable;
    const sign: []const u8 = if (neg) "-" else if (sp.plus) "+" else if (sp.space) " " else "";
    emitNumber(st, sign, "", text, sp, mag == 0);
}

fn fmtUnsigned(st: *State, v: u64, conv: u8, sp: Spec) void {
    var digits: [80]u8 = undefined;
    const text = switch (conv) {
        'o' => std.fmt.bufPrint(&digits, "{o}", .{v}) catch unreachable,
        'x' => std.fmt.bufPrint(&digits, "{x}", .{v}) catch unreachable,
        'X' => std.fmt.bufPrint(&digits, "{X}", .{v}) catch unreachable,
        else => std.fmt.bufPrint(&digits, "{d}", .{v}) catch unreachable,
    };
    var prefix: []const u8 = "";
    var t = text;
    if (sp.alt and v != 0) {
        if (conv == 'x') prefix = "0x";
        if (conv == 'X') prefix = "0X";
    }
    var oct_pad = false;
    if (sp.alt and conv == 'o') oct_pad = true;
    // "#o" forces a leading zero unless the digits already start with one.
    if (oct_pad and !(t.len > 0 and t[0] == '0' and v == 0) and !(sp.precision != null and sp.precision.? > t.len)) {
        prefix = "0";
    }
    if (conv == 'u' or conv == 'x' or conv == 'X' or conv == 'o') t = text;
    emitNumber(st, "", prefix, t, sp, v == 0);
}

/// Sign, prefix and digits with precision (minimum digits) and width.
fn emitNumber(st: *State, sign: []const u8, prefix: []const u8, digits: []const u8, sp: Spec, is_zero: bool) void {
    var body_digits = digits;
    var zero_digits: usize = 0;
    if (sp.precision) |p| {
        if (p == 0 and is_zero) body_digits = "";
        if (p > body_digits.len) zero_digits = p - body_digits.len;
    }
    const len = sign.len + prefix.len + zero_digits + body_digits.len;
    var fill: usize = if (sp.width > len) sp.width - len else 0;
    const zero_pad = sp.zero and !sp.left and sp.precision == null;
    if (!sp.left and !zero_pad) for (0..fill) |_| st.out.writeByte(' ');
    st.out.write(sign);
    st.out.write(prefix);
    if (zero_pad) {
        for (0..fill) |_| st.out.writeByte('0');
        fill = 0;
    }
    for (0..zero_digits) |_| st.out.writeByte('0');
    st.out.write(body_digits);
    if (sp.left) for (0..fill) |_| st.out.writeByte(' ');
}

/// %a for an x87 long double as glibc prints it: the first hex digit is 8 to f
/// (0x8p-3 for 1.0) and up to 15 fraction digits follow.
fn hexFloat(st: *State, v: f80, upper: bool, sp: Spec) void {
    var buf: [160]u8 = undefined;
    const neg = std.math.signbit(v);
    const sign: []const u8 = if (neg) "-" else if (sp.plus) "+" else if (sp.space) " " else "";
    const x = if (upper) "0X" else "0x";
    const pch: u8 = if (upper) 'P' else 'p';
    var body: []const u8 = undefined;
    if (std.math.isNan(v)) {
        body = if (upper) "NAN" else "nan";
    } else if (std.math.isInf(v)) {
        body = if (upper) "INF" else "inf";
    } else if (v == 0) {
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll(x) catch {};
        w.writeByte('0') catch {};
        const p = sp.precision orelse 0;
        if (p > 0 or sp.alt) w.writeByte('.') catch {};
        for (0..@min(p, 100)) |_| w.writeByte('0') catch {};
        w.print("{c}+0", .{pch}) catch {};
        body = w.buffered();
    } else {
        const bits: u80 = @bitCast(@abs(v));
        var sig: u64 = @truncate(bits);
        var e2: i32 = @as(i32, @intCast((bits >> 64) & 0x7fff)) - 16383;
        if (e2 == -16383) {
            // Pseudo-denormal range: normalise so the top bit is set.
            const sh: u6 = @intCast(@clz(sig));
            sig <<= sh;
            e2 = -16382 - @as(i32, sh);
        }
        var first: u64 = sig >> 60;
        var frac: u64 = sig & ((@as(u64, 1) << 60) - 1);
        var exp: i32 = e2 - 3;
        var ndig: usize = 15;
        if (sp.precision) |p| {
            if (p < 15) {
                const drop: u6 = @intCast((15 - p) * 4);
                const half: u64 = @as(u64, 1) << (drop - 1);
                const rem = frac & ((@as(u64, 1) << drop) - 1);
                frac >>= drop;
                const odd = if (p == 0) (first & 1) == 1 else (frac & 1) == 1;
                if (rem > half or (rem == half and odd)) frac += 1;
                if (p == 0) {
                    if (frac != 0) {
                        first += 1;
                        frac = 0;
                    }
                } else if (frac >> @as(u6, @intCast(p * 4)) != 0) {
                    frac = 0;
                    first += 1;
                }
                if (first == 16) { // carried out of the top digit: 0x10 renormalises to 0x1
                    first = 1;
                    exp += 4;
                }
                ndig = p;
            }
        }
        var digs: [32]u8 = undefined;
        const alpha = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
        for (0..ndig) |k| {
            const sh: u6 = @intCast((ndig - 1 - k) * 4);
            digs[k] = alpha[@intCast((frac >> sh) & 0xf)];
        }
        var dl: usize = ndig;
        if (sp.precision == null) {
            while (dl > 0 and digs[dl - 1] == '0') dl -= 1;
        }
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll(x) catch {};
        w.print("{c}", .{alpha[@intCast(first)]}) catch {};
        const extra = if (sp.precision) |p| (if (p > 15) p - 15 else 0) else 0;
        if (dl > 0 or extra > 0 or sp.alt) w.writeByte('.') catch {};
        w.writeAll(digs[0..dl]) catch {};
        for (0..@min(extra, 60)) |_| w.writeByte('0') catch {};
        w.print("{c}{s}{d}", .{ pch, if (exp < 0) "-" else "+", @abs(exp) }) catch {};
        body = w.buffered();
    }
    padHex(st, sign, body, sp);
}

fn padHex(st: *State, sign: []const u8, body: []const u8, sp: Spec) void {
    const len = sign.len + body.len;
    const fill = if (sp.width > len) sp.width - len else 0;
    const finite = body.len > 1 and body[0] == '0';
    if (!sp.left and !(sp.zero and finite)) for (0..fill) |_| st.out.writeByte(' ');
    st.out.write(sign);
    if (sp.zero and finite and !sp.left) {
        // zeros go after the 0x prefix
        st.out.write(body[0..2]);
        for (0..fill) |_| st.out.writeByte('0');
        st.out.write(body[2..]);
    } else st.out.write(body);
    if (sp.left) for (0..fill) |_| st.out.writeByte(' ');
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: printf FORMAT [ARGUMENT]...\n  or:  printf OPTION\nPrint ARGUMENT(s) according to FORMAT, or execute according to OPTION:\n\n      --help        display this help and exit\n      --version     output version information and exit\n\nFORMAT controls the output as in C printf.  Interpreted sequences are:\n\n  \\\"      double quote\n  \\\\      backslash\n  \\a      alert (BEL)\n  \\b      backspace\n  \\c      produce no further output\n  \\e      escape\n  \\f      form feed\n  \\n      new line\n  \\r      carriage return\n  \\t      horizontal tab\n  \\v      vertical tab\n  \\NNN    byte with octal value NNN (1 to 3 digits)\n  \\xHH    byte with hexadecimal value HH (1 to 2 digits)\n  \\uHHHH  Unicode (ISO/IEC 10646) character with hex value HHHH (4 digits)\n  \\UHHHHHHHH  Unicode character with hex value HHHHHHHH (8 digits)\n  %%      a single %\n  %b      ARGUMENT as a string with '\\' escapes interpreted,\n          except that octal escapes are of the form \\0 or \\0NNN\n  %q      ARGUMENT is printed in a format that can be reused as shell input,\n          escaping non-printable characters with the proposed POSIX $'' syntax.\n\nand all C format specifications ending with one of diouxXfeEgGcs, with\nARGUMENTs converted to proper type first.  Variable widths are handled.\n")) 0 else 1;
}
