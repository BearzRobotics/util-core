// SPDX-License-Identifier: GPL-2.0-or-later
//! numfmt — convert numbers from/to human-readable strings.
//! Reference: GNU coreutils manual "numfmt invocation" (9.7). POSIX does not
//! specify numfmt.
//!
//! Arithmetic uses x87 extended precision (f80) like GNU's `long double`, and
//! the scaling, rounding, padding and field-splitting rules follow the
//! algorithm in GNU numfmt.c (coreutils 9.6 sources, consulted 2026-11-07).
//! The C locale is assumed: no digit grouping and a '.' decimal point.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const fmt_float = @import("../fmt_float.zig");
const Io = std.Io;

const help_text = @embedFile("../help/numfmt.txt");

const Scale = enum { none, auto, si, iec, iec_i };
const Round = enum { up, down, from_zero, towards_zero, nearest };
const Inval = enum { abort, fail, warn, ignore };

const Sse = enum { ok, precision_loss, overflow, invalid_number, forbidden_suffix, invalid_suffix, missing_i };

const max_unscaled_digits = 18; // LDBL_DIG
const max_acceptable_digits = 33;

const Range = struct { lo: u64, hi: u64 };

const State = struct {
    ctx: cli.Context,
    out: cli.Out,
    scale_from: Scale = .none,
    scale_to: Scale = .none,
    round_style: Round = .from_zero,
    inval: Inval = .abort,
    suffix: ?[]const u8 = null,
    from_unit: u64 = 1,
    to_unit: u64 = 1,
    grouping: bool = false,
    padding_width: i64 = 0,
    zero_padding_width: usize = 0,
    user_precision: i64 = -1,
    format_prefix: ?[]const u8 = null,
    format_suffix: ?[]const u8 = null,
    conv_exit_code: u8 = 2,
    auto_padding: bool = false,
    delimiter: ?u8 = null, // null = blanks
    line_delim: u8 = '\n',
    header: u64 = 0,
    debug: bool = false,
    ranges: []const Range = &.{},
    have_ranges: bool = false,
    gpa: std.mem.Allocator,
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn baseOf(s: Scale) f80 {
    return switch (s) {
        .iec, .iec_i => 1024,
        else => 1000,
    };
}

fn suffixPower(c: u8) u32 {
    return switch (c) {
        'k', 'K' => 1,
        'M' => 2,
        'G' => 3,
        'T' => 4,
        'P' => 5,
        'E' => 6,
        'Z' => 7,
        'Y' => 8,
        'R' => 9,
        'Q' => 10,
        else => 0,
    };
}

fn suffixChar(p: u32) []const u8 {
    return switch (p) {
        0 => "",
        1 => "K",
        2 => "M",
        3 => "G",
        4 => "T",
        5 => "P",
        6 => "E",
        7 => "Z",
        8 => "Y",
        9 => "R",
        10 => "Q",
        else => "(error)",
    };
}

fn validSuffix(c: u8) bool {
    return std.mem.indexOfScalar(u8, "KkMGTPEZYRQ", c) != null;
}

fn powerld(base: f80, x: u32) f80 {
    if (x == 0) return 1;
    var r = base;
    var i: u32 = 1;
    while (i < x) : (i += 1) r *= base;
    return r;
}

fn absld(v: f80) f80 {
    return if (v < 0) -v else v;
}

/// Divide `val` by `base` until |val| < base; returns the count.
fn expld(val: f80, base: f80, power: *u32) f80 {
    var v = val;
    var p: u32 = 0;
    if (val >= -std.math.floatMax(f80) and val <= std.math.floatMax(f80)) {
        while (absld(v) >= base) {
            p += 1;
            v /= base;
        }
    }
    power.* = p;
    return v;
}

const intmax: f80 = 9223372036854775807.0;

fn toI64(v: f80) i64 {
    return @intFromFloat(v);
}

fn roundCeiling(v: f80) i64 {
    var i = toI64(v);
    if (@as(f80, @floatFromInt(i)) < v) i += 1;
    return i;
}
fn roundFloor(v: f80) i64 {
    return -roundCeiling(-v);
}
fn roundFromZero(v: f80) i64 {
    return if (v < 0) roundFloor(v) else roundCeiling(v);
}
fn roundNearest(v: f80) i64 {
    return toI64(if (v < 0) v - 0.5 else v + 0.5);
}

fn simpleRound(val0: f80, t: Round) f80 {
    var val = val0;
    const mul: i64 = toI64(val / intmax);
    val -= intmax * @as(f80, @floatFromInt(mul));
    const r: i64 = switch (t) {
        .up => roundCeiling(val),
        .down => roundFloor(val),
        .from_zero => roundFromZero(val),
        .towards_zero => toI64(val),
        .nearest => roundNearest(val),
    };
    return intmax * @as(f80, @floatFromInt(mul)) + @as(f80, @floatFromInt(r));
}

const Parsed = struct { e: Sse, end: usize, value: f80, precision: usize };

/// simple_strtod_int: digits with an optional leading '-'.
fn strtodInt(s: []const u8, start: usize, value: *f80, negative: *bool) struct { e: Sse, end: usize } {
    var e: Sse = .ok;
    var val: f80 = 0;
    var digits: usize = 0;
    var found = false;
    var i = start;
    if (i < s.len and s[i] == '-') {
        i += 1;
        negative.* = true;
    } else negative.* = false;
    while (i < s.len and std.ascii.isDigit(s[i])) {
        const d = s[i] - '0';
        found = true;
        if (val != 0 or d != 0) digits += 1;
        if (digits > max_unscaled_digits) e = .precision_loss;
        if (digits > max_acceptable_digits) return .{ .e = .overflow, .end = i };
        val *= 10;
        val += @as(f80, @floatFromInt(d));
        i += 1;
    }
    if (!found and !(i < s.len and s[i] == '.')) return .{ .e = .invalid_number, .end = i };
    if (negative.*) val = -val;
    value.* = val;
    return .{ .e = e, .end = i };
}

fn strtodFloat(s: []const u8, value: *f80, precision: *usize) struct { e: Sse, end: usize } {
    precision.* = 0;
    var negative = false;
    const r = strtodInt(s, 0, value, &negative);
    var e = r.e;
    var end = r.end;
    if (e != .ok and e != .precision_loss) return .{ .e = e, .end = end };
    if (end < s.len and s[end] == '.') {
        end += 1;
        var frac: f80 = 0;
        var neg_frac = false;
        const r2 = strtodInt(s, end, &frac, &neg_frac);
        if (r2.e != .ok and r2.e != .precision_loss) return .{ .e = r2.e, .end = r2.end };
        if (r2.e == .precision_loss) e = .precision_loss;
        if (neg_frac) return .{ .e = .invalid_number, .end = r2.end };
        const exponent = r2.end - end;
        frac = frac / powerld(10, @intCast(exponent));
        if (negative) value.* -= frac else value.* += frac;
        precision.* = exponent;
        end = r2.end;
    }
    return .{ .e = e, .end = end };
}

fn strtodHuman(s: []const u8, allowed: Scale) Parsed {
    var power: u32 = 0;
    var scale_base = baseOf(allowed);
    var value: f80 = 0;
    var precision: usize = 0;
    const r = strtodFloat(s, &value, &precision);
    var e = r.e;
    var end = r.end;
    if (e != .ok and e != .precision_loss) return .{ .e = e, .end = end, .value = value, .precision = precision };
    if (end < s.len) {
        while (end < s.len and isBlank(s[end])) end += 1;
        // GNU's strchr also "finds" the terminating NUL, so trailing blanks
        // count as an (empty) valid suffix.
        const at_end = end >= s.len;
        if (!at_end and !validSuffix(s[end])) return .{ .e = .invalid_suffix, .end = end, .value = value, .precision = precision };
        if (allowed == .none) return .{ .e = .forbidden_suffix, .end = end, .value = value, .precision = precision };
        if (!at_end) {
            power = suffixPower(s[end]);
            end += 1;
        }
        if (allowed == .auto and end < s.len and s[end] == 'i') {
            scale_base = 1024;
            end += 1;
        } else if (allowed == .iec_i) {
            if (end < s.len and s[end] == 'i') end += 1 else return .{ .e = .missing_i, .end = end, .value = value, .precision = precision };
        }
        precision = 0;
    }
    value *= powerld(scale_base, power);
    if (e != .precision_loss) e = r.e;
    return .{ .e = e, .end = end, .value = value, .precision = precision };
}

fn formatF(st: *State, val: f80, prec: usize, zero_w: usize) ![]u8 {
    return fmt_float.formatAllocLong(st.gpa, .{ .conv = 'f', .precision = prec, .zero = zero_w > 0, .width = zero_w }, val);
}

/// double_to_human: returns the formatted number text (caller frees).
fn doubleToHuman(st: *State, val0: f80, precision: usize) ![]u8 {
    var val = val0;
    if (st.scale_to == .none) {
        val *= powerld(10, @intCast(precision));
        val = simpleRound(val, st.round_style);
        val /= powerld(10, @intCast(precision));
        const num = try formatF(st, val, precision, st.zero_padding_width);
        defer st.gpa.free(num);
        return std.fmt.allocPrint(st.gpa, "{s}{s}", .{ num, st.suffix orelse "" });
    }
    const base = baseOf(st.scale_to);
    var power: u32 = 0;
    val = expld(val, base, &power);
    var adjust: u32 = 0;
    if (st.user_precision != -1) {
        adjust = @intCast(@min(@as(i64, power) * 3, st.user_precision));
    } else if (absld(val) < 10) adjust = 1;
    val *= powerld(10, adjust);
    val = simpleRound(val, st.round_style);
    val /= powerld(10, adjust);
    if (absld(val) >= base) {
        val /= base;
        power += 1;
    }
    const show_dp = val != 0 and absld(val) < 10 and power > 0;
    const prec: usize = if (st.user_precision == -1) @intFromBool(show_dp) else @intCast(st.user_precision);
    const num = try formatF(st, val, prec, st.zero_padding_width);
    defer st.gpa.free(num);
    const sc: []const u8 = if (power == 1 and st.scale_to == .si) "k" else suffixChar(power);
    const i_suffix: []const u8 = if (st.scale_to == .iec_i and power > 0) "i" else "";
    return std.fmt.allocPrint(st.gpa, "{s}{s}{s}{s}", .{ num, sc, i_suffix, st.suffix orelse "" });
}

fn simpleStrtodFatal(st: *State, e: Sse, input: []const u8) void {
    if (st.inval == .ignore) return;
    const q = cli.quoteC(input);
    switch (e) {
        .overflow => cli.warn(st.ctx, "value too large to be converted: {f}", .{q}),
        .invalid_number => cli.warn(st.ctx, "invalid number: {f}", .{q}),
        .forbidden_suffix => cli.warn(st.ctx, "rejecting suffix in input: {f} (consider using --from)", .{q}),
        .invalid_suffix => cli.warn(st.ctx, "invalid suffix in input: {f}", .{q}),
        .missing_i => cli.warn(st.ctx, "missing 'i' suffix in input: {f} (e.g Ki/Mi/Gi)", .{q}),
        else => {},
    }
    if (st.conv_exit_code != 0) {
        st.out.flush();
        std.process.exit(st.conv_exit_code);
    }
}

/// Returns false when the field is not a valid number.
fn processField(st: *State, text: []u8, field: u64) bool {
    if (!includeField(st, field)) {
        st.out.write(text);
        return true;
    }
    var t: []const u8 = text;
    // Trim --suffix only at the very end.
    if (st.suffix) |sfx| {
        if (t.len > sfx.len and std.mem.endsWith(u8, t, sfx)) t = t[0 .. t.len - sfx.len];
    }
    var p: usize = 0;
    while (p < t.len and isBlank(t[p])) p += 1;
    if (st.auto_padding) st.padding_width = if (p > 0 or field > 1) @intCast(t.len) else 0;

    const body = t[p..];
    const parsed = strtodHuman(body, st.scale_from);
    var valid = true;
    var val: f80 = parsed.value;
    var precision: usize = parsed.precision;
    if (parsed.e != .ok and parsed.e != .precision_loss) {
        simpleStrtodFatal(st, parsed.e, body);
        valid = false;
    } else if (parsed.end < body.len) {
        if (st.inval != .ignore) {
            cli.warn(st.ctx, "invalid suffix in input {f}: {f}", .{ cli.quoteC(body), cli.quoteC(body[parsed.end..]) });
            if (st.conv_exit_code != 0) {
                st.out.flush();
                std.process.exit(st.conv_exit_code);
            }
        }
        valid = false;
    } else if (parsed.e == .precision_loss and st.debug) {
        cli.warn(st.ctx, "large input value {f}: possible precision loss", .{cli.quoteC(body)});
    }
    if (valid) {
        if (st.from_unit != 1 or st.to_unit != 1) {
            val = (val * @as(f80, @floatFromInt(st.from_unit))) / @as(f80, @floatFromInt(st.to_unit));
        }
    } else precision = 0;
    if (!valid) {
        st.out.write(text);
        return false;
    }

    // prepare_padded_number
    const precision_used: usize = if (st.user_precision == -1) precision else @intCast(st.user_precision);
    var x: u32 = 0;
    _ = expld(val, 10, &x);
    if (st.scale_to == .none and x + precision_used > max_unscaled_digits) {
        if (st.inval != .ignore) {
            const g = fmt_float.formatAllocLong(st.gpa, .{ .conv = 'g' }, val) catch "?";
            defer if (!std.mem.eql(u8, g, "?")) st.gpa.free(g);
            if (precision_used > 0)
                cli.warn(st.ctx, "value/precision too large to be printed: '{s}/{d}' (consider using --to)", .{ g, precision_used })
            else
                cli.warn(st.ctx, "value too large to be printed: '{s}' (consider using --to)", .{g});
            if (st.conv_exit_code != 0) {
                st.out.flush();
                std.process.exit(st.conv_exit_code);
            }
        }
        st.out.write(text);
        return false;
    }
    if (x > max_acceptable_digits - 1) {
        if (st.inval != .ignore) {
            const g = fmt_float.formatAllocLong(st.gpa, .{ .conv = 'g' }, val) catch "?";
            defer if (!std.mem.eql(u8, g, "?")) st.gpa.free(g);
            cli.warn(st.ctx, "value too large to be printed: '{s}' (cannot handle values > 999Q)", .{g});
            if (st.conv_exit_code != 0) {
                st.out.flush();
                std.process.exit(st.conv_exit_code);
            }
        }
        st.out.write(text);
        return false;
    }
    const num = doubleToHuman(st, val, precision_used) catch {
        st.out.write(text);
        return false;
    };
    defer st.gpa.free(num);
    var pad: i64 = 0;
    if (st.padding_width != 0) {
        var printable = true;
        for (num) |c| if (c < 0x20 or c >= 0x7f) {
            printable = false;
        };
        if (printable) {
            const w: i64 = @intCast(num.len);
            if (st.padding_width < 0) {
                if (st.padding_width < -w) pad = st.padding_width + w;
            } else if (w < st.padding_width) pad = st.padding_width - w;
        }
    }
    if (st.format_prefix) |pf| st.out.write(pf);
    var k = pad;
    while (k > 0) : (k -= 1) st.out.writeByte(' ');
    st.out.write(num);
    k = pad;
    while (k < 0) : (k += 1) st.out.writeByte(' ');
    if (st.format_suffix) |sf| st.out.write(sf);
    return true;
}

fn includeField(st: *const State, field: u64) bool {
    if (!st.have_ranges) return field == 1;
    for (st.ranges) |r| if (r.lo <= field and field <= r.hi) return true;
    return false;
}

fn processLine(st: *State, line: []u8, newline: bool) bool {
    var valid = true;
    var field: u64 = 0;
    var pos: usize = 0;
    while (true) {
        field += 1;
        const start = pos;
        var end = pos;
        if (st.delimiter) |d| {
            if (end >= line.len or line[end] != d) {
                while (end < line.len and line[end] != d) end += 1;
            }
        } else {
            while (end < line.len and (line[end] == '\n' or isBlank(line[end]))) end += 1;
            while (end < line.len and !(line[end] == '\n' or isBlank(line[end]))) end += 1;
        }
        pos = end;
        if (pos < line.len) {
            if (!processField(st, line[start..pos], field)) valid = false;
            st.out.writeByte(st.delimiter orelse ' ');
            pos += 1;
        } else {
            if (!processField(st, line[start..pos], field)) valid = false;
            break;
        }
    }
    if (newline) st.out.writeByte(st.line_delim);
    return valid;
}

fn argMatch(ctx: cli.Context, opt: []const u8, value: []const u8, names: []const []const u8) ?usize {
    var found: ?usize = null;
    var ambiguous = false;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, value)) return i;
        if (std.mem.startsWith(u8, n, value)) {
            if (found != null) ambiguous = true;
            found = i;
        }
    }
    if (found != null and !ambiguous) return found;
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    for (names) |nm| {
        const piece = std.fmt.bufPrint(buf[n..], "\n  - {f}", .{cli.quoteC(nm)}) catch break;
        n += piece.len;
    }
    cli.warn(ctx, "{s} argument {f} for {f}\nValid arguments are:{s}\nTry '{s} --help' for more information.", .{
        if (ambiguous) "ambiguous" else "invalid",
        cli.quoteC(value),
        cli.quoteC(opt),
        buf[0..n],
        ctx.name,
    });
    return null;
}

fn unitToU64(ctx: cli.Context, text: []const u8) ?u64 {
    // Suffixes as with --from=auto: K=1000, Ki=1024, KiB invalid.
    var t = text;
    var mult: u128 = 1;
    var ok = text.len > 0;
    if (text.len > 0 and !std.ascii.isDigit(text[text.len - 1])) {
        var base: u128 = 1000;
        var letter_end = text.len;
        if (text[text.len - 1] == 'i' and text.len >= 2 and !std.ascii.isDigit(text[text.len - 2])) {
            base = 1024;
            letter_end = text.len - 1;
        }
        const letter = text[letter_end - 1];
        if (!validSuffix(letter)) ok = false;
        var pw = suffixPower(letter);
        while (pw > 0) : (pw -= 1) mult *= base;
        t = text[0 .. letter_end - 1];
        if (t.len == 0) t = "1";
    }
    var v: u128 = 0;
    if (ok) {
        if (t.len == 0) ok = false;
        for (t) |c| {
            if (!std.ascii.isDigit(c)) {
                ok = false;
                break;
            }
            v = v * 10 + (c - '0');
            if (v > std.math.maxInt(u64)) {
                ok = false;
                break;
            }
        }
    }
    const total = v * mult;
    if (!ok or total == 0 or total > std.math.maxInt(u64)) {
        cli.warn(ctx, "invalid unit size: {f}", .{cli.quoteC(text)});
        return null;
    }
    return @intCast(total);
}

/// cut-style field list (set_fields with SETFLD_ALLOW_DASH).
fn parseFields(ctx: cli.Context, gpa: std.mem.Allocator, spec: []const u8) ?[]Range {
    var list: std.ArrayList(Range) = .empty;
    defer list.deinit(gpa);
    var initial: u64 = 1;
    var value: u64 = 0;
    var lhs = false;
    var rhs = false;
    var dash = false;
    var i: usize = 0;
    var s = spec;
    if (std.mem.eql(u8, s, "-")) {
        value = 1;
        lhs = true;
        dash = true;
        i = 1;
    }
    const max = std.math.maxInt(u64);
    const fail = struct {
        fn f(c: cli.Context, comptime fmt: []const u8, args: anytype) ?[]Range {
            cli.warn(c, fmt ++ "\nTry '{s} --help' for more information.", args ++ .{c.name});
            return null;
        }
    }.f;
    while (true) {
        const c: u8 = if (i < s.len) s[i] else 0;
        if (c == '-') {
            if (dash) return fail(ctx, "invalid field range", .{});
            dash = true;
            i += 1;
            if (lhs and value == 0) return fail(ctx, "fields are numbered from 1", .{});
            initial = if (lhs) value else 1;
            value = 0;
        } else if (c == ',' or isBlank(c) or c == 0) {
            if (dash) {
                dash = false;
                if (!lhs and !rhs) initial = 1;
                if (!rhs) {
                    list.append(gpa, .{ .lo = initial, .hi = max }) catch return null;
                } else {
                    if (value < initial) return fail(ctx, "invalid decreasing range", .{});
                    list.append(gpa, .{ .lo = initial, .hi = value }) catch return null;
                }
                value = 0;
            } else {
                if (value == 0) return fail(ctx, "fields are numbered from 1", .{});
                list.append(gpa, .{ .lo = value, .hi = value }) catch return null;
                value = 0;
            }
            if (c == 0) break;
            i += 1;
            lhs = false;
            rhs = false;
        } else if (std.ascii.isDigit(c)) {
            if (dash) rhs = true else lhs = true;
            const d: u64 = c - '0';
            const mul = @mulWithOverflow(value, 10);
            const add = if (mul[1] == 0) @addWithOverflow(mul[0], d) else mul;
            if (mul[1] != 0 or add[1] != 0 or add[0] == max) {
                var e = i;
                while (e > 0 and std.ascii.isDigit(s[e - 1])) e -= 1;
                var f = i;
                while (f < s.len and std.ascii.isDigit(s[f])) f += 1;
                return fail(ctx, "field number {f} is too large", .{cli.quoteC(s[e..f])});
            }
            value = add[0];
            i += 1;
        } else {
            return fail(ctx, "invalid field value {f}", .{cli.quoteC(s[i..])});
        }
    }
    if (list.items.len == 0) return fail(ctx, "missing list of fields", .{});
    std.mem.sort(Range, list.items, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.lo < b.lo;
        }
    }.lt);
    // Merge overlapping ranges.
    var out: std.ArrayList(Range) = .empty;
    for (list.items) |r| {
        if (out.items.len > 0 and r.lo <= out.items[out.items.len - 1].hi) {
            const last = &out.items[out.items.len - 1];
            last.hi = @max(last.hi, r.hi);
        } else out.append(gpa, r) catch return null;
    }
    s = "";
    return out.toOwnedSlice(gpa) catch null;
}

fn parseFormat(st: *State, fmt: []const u8) bool {
    const ctx = st.ctx;
    var i: usize = 0;
    var prefix_len: usize = 0;
    while (true) {
        if (i >= fmt.len) {
            cli.warn(ctx, "format {f} has no % directive", .{cli.quoteC(fmt)});
            return false;
        }
        if (fmt[i] == '%' and !(i + 1 < fmt.len and fmt[i + 1] == '%')) break;
        const step: usize = if (fmt[i] == '%') 2 else 1;
        prefix_len += 1;
        i += step;
    }
    i += 1;
    var zero_padding = false;
    while (true) {
        var skip: usize = 0;
        while (i + skip < fmt.len and fmt[i + skip] == ' ') skip += 1;
        i += skip;
        if (i < fmt.len and fmt[i] == '\'') {
            st.grouping = true;
            i += 1;
        } else if (i < fmt.len and fmt[i] == '0') {
            zero_padding = true;
            i += 1;
        } else if (skip == 0) break;
    }
    // strtoimax
    var j = i;
    var neg = false;
    if (j < fmt.len and (fmt[j] == '-' or fmt[j] == '+')) {
        neg = fmt[j] == '-';
        j += 1;
    }
    var pad: i64 = 0;
    const digits_start = j;
    while (j < fmt.len and std.ascii.isDigit(fmt[j])) : (j += 1) pad = pad *| 10 +| (fmt[j] - '0');
    if (j == digits_start) j = i; // no number
    if (neg) pad = -pad;
    if (pad != 0) {
        if (st.debug and st.padding_width != 0 and !(zero_padding and pad > 0))
            cli.warn(ctx, "--format padding overriding --padding", .{});
        if (pad < 0) {
            st.padding_width = pad;
        } else if (zero_padding) {
            st.zero_padding_width = @intCast(@min(pad, std.math.maxInt(i32)));
        } else st.padding_width = pad;
    }
    i = j;
    if (i >= fmt.len) {
        cli.warn(ctx, "format {f} ends in %", .{cli.quoteC(fmt)});
        return false;
    }
    if (fmt[i] == '.') {
        i += 1;
        var k = i;
        var pv: i64 = 0;
        var neg2 = false;
        if (k < fmt.len and (fmt[k] == '-' or fmt[k] == '+')) {
            neg2 = fmt[k] == '-';
            k += 1;
        }
        const ds = k;
        while (k < fmt.len and std.ascii.isDigit(fmt[k])) : (k += 1) pv = pv *| 10 +| (fmt[k] - '0');
        if (neg2) pv = -pv;
        if (pv < 0 or (i < fmt.len and (isBlank(fmt[i]) or fmt[i] == '+')) or pv == std.math.maxInt(i64)) {
            cli.warn(ctx, "invalid precision in format {f}", .{cli.quoteC(fmt)});
            return false;
        }
        st.user_precision = pv;
        i = if (k == ds) i else k;
        if (k == ds) i = k;
    }
    if (i >= fmt.len or fmt[i] != 'f') {
        cli.warn(ctx, "invalid format {f}, directive must be %[0]['][-][N][.][N]f", .{cli.quoteC(fmt)});
        return false;
    }
    i += 1;
    const suffix_pos = i;
    while (i < fmt.len) {
        if (fmt[i] == '%' and !(i + 1 < fmt.len and fmt[i + 1] == '%')) {
            cli.warn(ctx, "format {f} has too many % directives", .{cli.quoteC(fmt)});
            return false;
        }
        i += if (fmt[i] == '%') 2 else 1;
    }
    if (prefix_len > 0) st.format_prefix = st.gpa.dupe(u8, fmt[0..prefix_len]) catch return false;
    if (suffix_pos < fmt.len) st.format_suffix = st.gpa.dupe(u8, fmt[suffix_pos..]) catch return false;
    return true;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var st: State = .{ .ctx = ctx, .out = cli.Out.init(ctx.io), .gpa = gpa };
    defer {
        if (st.have_ranges) gpa.free(st.ranges);
        if (st.format_prefix) |x| gpa.free(x);
        if (st.format_suffix) |x| gpa.free(x);
    }
    var format_str: ?[]const u8 = null;
    var field_spec: ?[]const u8 = null;

    var p = getopt.Parser.init(ctx, "d:z", &.{
        .{ .name = "from", .arg = .required, .id = 1100 },
        .{ .name = "from-unit", .arg = .required, .id = 1101 },
        .{ .name = "to", .arg = .required, .id = 1102 },
        .{ .name = "to-unit", .arg = .required, .id = 1103 },
        .{ .name = "round", .arg = .required, .id = 1104 },
        .{ .name = "padding", .arg = .required, .id = 1105 },
        .{ .name = "suffix", .arg = .required, .id = 1106 },
        .{ .name = "grouping", .id = 1107 },
        .{ .name = "delimiter", .arg = .required, .id = 'd' },
        .{ .name = "field", .arg = .required, .id = 1108 },
        .{ .name = "debug", .id = 1109 },
        .{ .name = "header", .arg = .optional, .id = 1110 },
        .{ .name = "format", .arg = .required, .id = 1111 },
        .{ .name = "invalid", .arg = .required, .id = 1112 },
        .{ .name = "zero-terminated", .id = 'z' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            1100 => {
                const names = [_][]const u8{ "none", "auto", "si", "iec", "iec-i" };
                const k = argMatch(ctx, "--from", o.arg.?, &names) orelse return 1;
                st.scale_from = @enumFromInt(k);
            },
            1101 => st.from_unit = unitToU64(ctx, o.arg.?) orelse return 1,
            1102 => {
                const names = [_][]const u8{ "none", "si", "iec", "iec-i" };
                const k = argMatch(ctx, "--to", o.arg.?, &names) orelse return 1;
                st.scale_to = switch (k) {
                    0 => .none,
                    1 => .si,
                    2 => .iec,
                    else => .iec_i,
                };
            },
            1103 => st.to_unit = unitToU64(ctx, o.arg.?) orelse return 1,
            1104 => {
                const names = [_][]const u8{ "up", "down", "from-zero", "towards-zero", "nearest" };
                const k = argMatch(ctx, "--round", o.arg.?, &names) orelse return 1;
                st.round_style = @enumFromInt(k);
            },
            1105 => {
                const v = std.fmt.parseInt(i64, o.arg.?, 10) catch |e| blk: {
                    if (e == error.Overflow) break :blk @as(i64, if (o.arg.?[0] == '-') std.math.minInt(i64) else std.math.maxInt(i64));
                    cli.warn(ctx, "invalid padding value {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                };
                if (v == 0) {
                    cli.warn(ctx, "invalid padding value {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                }
                st.padding_width = v;
            },
            1106 => st.suffix = o.arg,
            1107 => st.grouping = true,
            'd' => {
                const a = o.arg.?;
                if (a.len > 1) {
                    cli.warn(ctx, "the delimiter must be a single character", .{});
                    return 1;
                }
                st.delimiter = if (a.len == 0) 0 else a[0];
            },
            1108 => {
                if (field_spec != null) {
                    cli.warn(ctx, "multiple field specifications", .{});
                    return 1;
                }
                field_spec = o.arg;
                st.ranges = parseFields(ctx, gpa, o.arg.?) orelse return 1;
                st.have_ranges = true;
            },
            1109 => st.debug = true,
            1110 => {
                if (o.arg) |a| {
                    const v = std.fmt.parseInt(u64, a, 10) catch 0;
                    if (v == 0) {
                        cli.warn(ctx, "invalid header value {f}", .{cli.quoteC(a)});
                        return 1;
                    }
                    st.header = v;
                } else st.header = 1;
            },
            1111 => format_str = o.arg,
            1112 => {
                const names = [_][]const u8{ "abort", "fail", "warn", "ignore" };
                const k = argMatch(ctx, "--invalid", o.arg.?, &names) orelse return 1;
                st.inval = @enumFromInt(k);
            },
            'z' => st.line_delim = 0,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };

    if (format_str != null and st.grouping) {
        cli.warn(ctx, "--grouping cannot be combined with --format", .{});
        return 1;
    }
    if (st.debug and st.scale_from == .none and st.scale_to == .none and !st.grouping and st.padding_width == 0 and format_str == null)
        cli.warn(ctx, "no conversion option specified", .{});
    if (format_str) |f| if (!parseFormat(&st, f)) return 1;
    if (st.grouping) {
        if (st.scale_to != .none) {
            cli.warn(ctx, "grouping cannot be combined with --to", .{});
            return 1;
        }
        if (st.debug) cli.warn(ctx, "grouping has no effect in this locale", .{});
    }
    st.auto_padding = st.padding_width == 0 and st.delimiter == null;
    if (st.inval != .abort) st.conv_exit_code = 0;

    var valid_numbers = true;
    const operands = p.operands.items;
    if (operands.len > 0) {
        if (st.debug and st.header != 0) cli.warn(ctx, "--header ignored with command-line input", .{});
        for (operands) |op| {
            const buf = gpa.dupe(u8, op) catch return 1;
            defer gpa.free(buf);
            if (!processLine(&st, buf, true)) valid_numbers = false;
        }
    } else {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);
        var chunk: [65536]u8 = undefined;
        const stdin = Io.File.stdin();
        while (true) {
            const n = cli.readChunk(ctx.io, stdin, &chunk) catch {
                cli.warn(ctx, "error reading input", .{});
                return 1;
            };
            if (n == 0) break;
            data.appendSlice(gpa, chunk[0..n]) catch return 1;
        }
        var pos: usize = 0;
        var header = st.header;
        while (header > 0 and pos < data.items.len) : (header -= 1) {
            const e = std.mem.indexOfScalarPos(u8, data.items, pos, st.line_delim);
            const stop = if (e) |x| x + 1 else data.items.len;
            st.out.write(data.items[pos..stop]);
            pos = stop;
        }
        while (pos < data.items.len) {
            const e = std.mem.indexOfScalarPos(u8, data.items, pos, st.line_delim);
            const stop = e orelse data.items.len;
            const line = gpa.dupe(u8, data.items[pos..stop]) catch return 1;
            defer gpa.free(line);
            if (!processLine(&st, line, e != null)) valid_numbers = false;
            pos = if (e) |x| x + 1 else data.items.len;
        }
    }
    st.out.flush();
    if (st.debug and !valid_numbers) cli.warn(ctx, "failed to convert some of the input numbers", .{});
    if (st.out.failed) return 1;
    if (!valid_numbers and st.inval != .warn and st.inval != .ignore) return 2;
    return 0;
}
