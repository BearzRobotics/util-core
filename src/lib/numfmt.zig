// SPDX-License-Identifier: GPL-2.0-or-later
//! numfmt library: convert numbers from/to human-readable strings.
//! Reference: GNU coreutils manual "numfmt invocation" (9.7). POSIX does not
//! specify numfmt.
//!
//! Arithmetic uses x87 extended precision (f80) like GNU's `long double`, and
//! the scaling, rounding, padding and field-splitting rules follow the
//! algorithm in GNU numfmt.c (coreutils 9.6 sources, consulted 2026-11-07).
//! The C locale is assumed: no digit grouping and a '.' decimal point.
//!
//! The library does not exit: when `--invalid=abort` (the default) meets a
//! bad number it stops and reports `Result.aborted`; the caller picks the
//! exit status (GNU uses 2).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Sink = @import("sink.zig").Sink;
const fmt_float = @import("../fmt_float.zig");

pub const Env = common.Env;

pub const Scale = enum { none, auto, si, iec, iec_i };
pub const Round = enum { up, down, from_zero, towards_zero, nearest };
pub const Inval = enum { abort, fail, warn, ignore };

/// Outcome of parsing one number with an optional unit suffix.
pub const Sse = enum { ok, precision_loss, overflow, invalid_number, forbidden_suffix, invalid_suffix, missing_i };

const max_unscaled_digits = 18; // LDBL_DIG
const max_acceptable_digits = 33;

/// An inclusive range of field numbers (1-based).
pub const Range = struct { lo: u64, hi: u64 };

pub const Options = struct {
    /// Scale of the input (--from) and of the output (--to).
    scale_from: Scale = .none,
    scale_to: Scale = .none,
    round: Round = .from_zero,
    /// What to do with an input that is not a number (--invalid).
    invalid: Inval = .abort,
    /// Suffix to strip from the input and add to the output (--suffix).
    suffix: ?[]const u8 = null,
    /// --from-unit and --to-unit multipliers.
    from_unit: u64 = 1,
    to_unit: u64 = 1,
    /// Set by --grouping or a ' flag in the format; has no effect in the C locale.
    grouping: bool = false,
    /// --padding; negative pads on the right. Zero: none (or automatic).
    padding_width: i64 = 0,
    /// Width of a `%0N` format.
    zero_padding_width: usize = 0,
    /// Digits after the point (from the format); -1: derived from the input.
    user_precision: i64 = -1,
    /// Literal text before and after the number from --format. `applyFormat`
    /// sets these as slices of the format string, which must outlive the run.
    format_prefix: ?[]const u8 = null,
    format_suffix: ?[]const u8 = null,
    /// Field delimiter (-d); null: runs of blanks.
    delimiter: ?u8 = null,
    /// Line terminator (-z gives 0).
    line_delim: u8 = '\n',
    /// Leading lines passed through unchanged (--header).
    header: u64 = 0,
    /// Emit the --debug diagnostics.
    debug: bool = false,
    /// Fields to convert (--field), sorted and merged; null: field 1 only.
    fields: ?[]const Range = null,
};

/// Diagnostics. Each is a problem with one input; `aborted` runs stop after
/// the first one that is not suppressed.
pub const Event = union(enum) {
    /// The number could not be parsed; `kind` is never `.ok` or `.precision_loss`.
    bad_number: struct { kind: Sse, input: []const u8 },
    /// Parsed, but followed by `rest`.
    invalid_suffix_in_input: struct { input: []const u8, rest: []const u8 },
    /// --debug: more digits than long double holds.
    precision_loss: []const u8,
    /// The value and the precision are too large to print without --to.
    too_large_with_precision: struct { value: []const u8, precision: usize },
    too_large: []const u8,
    /// Beyond 999Q.
    too_large_for_scale: []const u8,
    /// --debug, with --header and command-line operands.
    header_ignored,
    /// --debug: the format's padding replaced --padding.
    padding_overridden,
    /// --debug: at the end, some input numbers were invalid.
    some_failed,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// `--invalid=abort` met a bad number and the run stopped there.
    aborted: bool = false,
    /// Every number converted.
    valid: bool = true,
};

pub const Input = union(enum) {
    /// One line per operand.
    operands: []const []const u8,
    /// Everything readable from the reader, split into lines.
    reader: *Io.Reader,
};

pub const Error = error{ OutOfMemory, WriteFailed, ReadFailed };

const State = struct {
    env: Env,
    observer: Observer,
    out: Sink,
    scale_from: Scale,
    scale_to: Scale,
    round_style: Round,
    inval: Inval,
    suffix: ?[]const u8,
    from_unit: u64,
    to_unit: u64,
    padding_width: i64,
    zero_padding_width: usize,
    user_precision: i64,
    format_prefix: ?[]const u8,
    format_suffix: ?[]const u8,
    conv_exit_code: u8,
    auto_padding: bool,
    delimiter: ?u8,
    line_delim: u8,
    header: u64,
    debug: bool,
    ranges: []const Range,
    have_ranges: bool,
    gpa: std.mem.Allocator,
    /// An abort-mode error ended the run.
    aborted: bool = false,
};

/// Convert the numbers of `input` and write the result to `w`.
pub fn run(env: Env, o: Options, input: Input, w: *Io.Writer, observer: Observer) Error!Result {
    var st: State = .{
        .env = env,
        .observer = observer,
        .out = Sink.init(w),
        .scale_from = o.scale_from,
        .scale_to = o.scale_to,
        .round_style = o.round,
        .inval = o.invalid,
        .suffix = o.suffix,
        .from_unit = o.from_unit,
        .to_unit = o.to_unit,
        .padding_width = o.padding_width,
        .zero_padding_width = o.zero_padding_width,
        .user_precision = o.user_precision,
        .format_prefix = o.format_prefix,
        .format_suffix = o.format_suffix,
        .conv_exit_code = if (o.invalid != .abort) 0 else 2,
        .auto_padding = o.padding_width == 0 and o.delimiter == null,
        .delimiter = o.delimiter,
        .line_delim = o.line_delim,
        .header = o.header,
        .debug = o.debug,
        .ranges = o.fields orelse &.{},
        .have_ranges = o.fields != null,
        .gpa = env.gpa,
    };
    var valid_numbers = true;
    switch (input) {
        .operands => |operands| {
            if (st.debug and st.header != 0) observer.emit(.header_ignored);
            for (operands) |op| {
                if (!processLine(&st, op, true)) valid_numbers = false;
                if (st.aborted) break;
            }
        },
        .reader => |r| {
            var batches: common.Batcher = .{};
            defer batches.deinit(env.gpa);
            var header = st.header;
            var at_end = false;
            while (!at_end and !st.aborted and !st.out.failed) {
                // What is converted goes out before a read that may wait.
                st.out.flush();
                const got: []const u8 = r.peekGreedy(1) catch |e| switch (e) {
                    error.EndOfStream => "",
                    error.ReadFailed => return error.ReadFailed,
                };
                at_end = got.len == 0;
                const data = if (at_end) batches.rest() else try batches.add(env.gpa, got, &.{st.line_delim}) orelse "";
                r.toss(got.len);
                var pos: usize = 0;
                while (pos < data.len and !st.out.failed) {
                    const e = std.mem.indexOfScalarPos(u8, data, pos, st.line_delim);
                    const stop = e orelse data.len;
                    const next = if (e) |x| x + 1 else data.len;
                    if (header > 0) {
                        header -= 1;
                        st.out.write(data[pos..next]);
                    } else if (!processLine(&st, data[pos..stop], e != null)) valid_numbers = false;
                    if (st.aborted) break;
                    pos = next;
                }
            }
        },
    }
    st.out.flush();
    if (st.aborted) return .{ .aborted = true, .valid = false };
    if (st.debug and !valid_numbers) observer.emit(.some_failed);
    if (st.out.failed) return error.WriteFailed;
    return .{ .valid = valid_numbers };
}

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

/// Report a failure and decide whether the run stops (abort mode).
fn failed(st: *State, ev: Event) void {
    if (st.inval == .ignore) return;
    st.observer.emit(ev);
    if (st.conv_exit_code != 0) st.aborted = true;
}

/// Returns false when the field is not a valid number.
fn processField(st: *State, text: []const u8, field: u64) bool {
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
        failed(st, .{ .bad_number = .{ .kind = parsed.e, .input = body } });
        if (st.aborted) return false;
        valid = false;
    } else if (parsed.end < body.len) {
        failed(st, .{ .invalid_suffix_in_input = .{ .input = body, .rest = body[parsed.end..] } });
        if (st.aborted) return false;
        valid = false;
    } else if (parsed.e == .precision_loss and st.debug) {
        st.observer.emit(.{ .precision_loss = body });
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
                failed(st, .{ .too_large_with_precision = .{ .value = g, .precision = precision_used } })
            else
                failed(st, .{ .too_large = g });
            if (st.aborted) return false;
        }
        st.out.write(text);
        return false;
    }
    if (x > max_acceptable_digits - 1) {
        if (st.inval != .ignore) {
            const g = fmt_float.formatAllocLong(st.gpa, .{ .conv = 'g' }, val) catch "?";
            defer if (!std.mem.eql(u8, g, "?")) st.gpa.free(g);
            failed(st, .{ .too_large_for_scale = g });
            if (st.aborted) return false;
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

fn processLine(st: *State, line: []const u8, newline: bool) bool {
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
            if (st.aborted) return false;
            st.out.writeByte(st.delimiter orelse ' ');
            pos += 1;
        } else {
            if (!processField(st, line[start..pos], field)) valid = false;
            if (st.aborted) return false;
            break;
        }
    }
    if (newline) st.out.writeByte(st.line_delim);
    return valid;
}

/// A --from-unit / --to-unit size: digits with an optional suffix (K=1000,
/// Ki=1024, ...). Null when invalid or zero.
pub fn parseUnit(text: []const u8) ?u64 {
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
    if (!ok or total == 0 or total > std.math.maxInt(u64)) return null;
    return @intCast(total);
}

/// What was wrong with a --field list.
pub const FieldsProblem = struct {
    kind: Kind = .out_of_memory,
    /// The offending text for `too_large` (the number) and `invalid_value`.
    text: []const u8 = "",

    pub const Kind = enum { invalid_range, from_one, decreasing, too_large, invalid_value, missing_list, out_of_memory };
};

/// cut-style field list (set_fields with SETFLD_ALLOW_DASH). Returns the
/// sorted, merged ranges (caller frees), or null with `problem` filled in.
pub fn parseFields(gpa: std.mem.Allocator, spec: []const u8, problem: *FieldsProblem) ?[]Range {
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
    problem.* = .{};
    const fail = struct {
        fn f(pr: *FieldsProblem, kind: FieldsProblem.Kind, text: []const u8) ?[]Range {
            pr.* = .{ .kind = kind, .text = text };
            return null;
        }
    }.f;
    while (true) {
        const c: u8 = if (i < s.len) s[i] else 0;
        if (c == '-') {
            if (dash) return fail(problem, .invalid_range, "");
            dash = true;
            i += 1;
            if (lhs and value == 0) return fail(problem, .from_one, "");
            initial = if (lhs) value else 1;
            value = 0;
        } else if (c == ',' or isBlank(c) or c == 0) {
            if (dash) {
                dash = false;
                if (!lhs and !rhs) initial = 1;
                if (!rhs) {
                    list.append(gpa, .{ .lo = initial, .hi = max }) catch return null;
                } else {
                    if (value < initial) return fail(problem, .decreasing, "");
                    list.append(gpa, .{ .lo = initial, .hi = value }) catch return null;
                }
                value = 0;
            } else {
                if (value == 0) return fail(problem, .from_one, "");
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
                return fail(problem, .too_large, s[e..f]);
            }
            value = add[0];
            i += 1;
        } else {
            return fail(problem, .invalid_value, s[i..]);
        }
    }
    if (list.items.len == 0) return fail(problem, .missing_list, "");
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

/// Why a --format string was rejected.
pub const FormatError = error{ NoDirective, EndsInPercent, InvalidPrecision, InvalidDirective, TooManyDirectives };

/// Parse a --format string (`%[0]['][-][N][.][N]f` with literal text around
/// it) and apply it to `o`: the literal prefix and suffix (slices of `fmt`,
/// which must outlive the run), padding, zero padding, precision and grouping.
pub fn applyFormat(o: *Options, fmt: []const u8, observer: Observer) FormatError!void {
    var i: usize = 0;
    var prefix_len: usize = 0;
    while (true) {
        if (i >= fmt.len) return error.NoDirective;
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
            o.grouping = true;
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
        if (o.debug and o.padding_width != 0 and !(zero_padding and pad > 0))
            observer.emit(.padding_overridden);
        if (pad < 0) {
            o.padding_width = pad;
        } else if (zero_padding) {
            o.zero_padding_width = @intCast(@min(pad, std.math.maxInt(i32)));
        } else o.padding_width = pad;
    }
    i = j;
    if (i >= fmt.len) return error.EndsInPercent;
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
        if (pv < 0 or (i < fmt.len and (isBlank(fmt[i]) or fmt[i] == '+')) or pv == std.math.maxInt(i64)) return error.InvalidPrecision;
        o.user_precision = pv;
        i = if (k == ds) i else k;
        if (k == ds) i = k;
    }
    if (i >= fmt.len or fmt[i] != 'f') return error.InvalidDirective;
    i += 1;
    const suffix_pos = i;
    while (i < fmt.len) {
        if (fmt[i] == '%' and !(i + 1 < fmt.len and fmt[i + 1] == '%')) return error.TooManyDirectives;
        i += if (fmt[i] == '%') 2 else 1;
    }
    if (prefix_len > 0) o.format_prefix = fmt[0..prefix_len];
    if (suffix_pos < fmt.len) o.format_suffix = fmt[suffix_pos..];
}
