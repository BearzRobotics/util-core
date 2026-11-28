// SPDX-License-Identifier: GPL-2.0-or-later
//! strftime in the C locale with the GNU extensions of gnulib's nstrftime:
//! the flags `_ - 0 ^ # :`, field widths, %N (nanoseconds), %s, the %:z family,
//! and %F/%G/%V/%U/%W week arithmetic. Used by date, ls, stat, pr, who, du,
//! touch and find.
//!
//! Reference: GNU coreutils manual "date invocation" (Date conversion
//! specifiers), POSIX.1-2024 strftime/date, and gnulib nstrftime behaviour
//! checked against /usr/bin/date 9.7.

const std = @import("std");
const tz = @import("tz.zig");

const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// The padding flag in force: the last of _ - 0 + counts. `plus` pads like
/// `zero`; on a year it may also add a sign.
const Pad = enum { default, none, space, zero, plus };

/// ISO 8601 week number and year of `tm`.
pub fn isoWeek(tm: *const tz.Tm) struct { year: i64, week: i64 } {
    const wd: i64 = @mod(@as(i64, tm.wday) + 6, 7); // Monday = 0
    const yday: i64 = tm.yday;
    var week = @divFloor(yday - wd + 10, 7);
    var year = tm.year;
    if (week < 1) {
        year -= 1;
        const ylen: i64 = if (tz.isLeap(year)) 366 else 365;
        week = @divFloor(yday + ylen - wd + 10, 7);
    } else if (week == 53) {
        const ylen: i64 = if (tz.isLeap(year)) 366 else 365;
        if (yday - wd + 3 >= ylen) {
            week = 1;
            year += 1;
        }
    }
    return .{ .year = year, .week = week };
}

/// What a conversion was written with.
const Spec = struct {
    pad: Pad = .default,
    width: ?usize = null,
    /// ^
    upper: bool = false,
    /// #
    swap: bool = false,
};

/// Text in its field: - drops the padding, 0 and + pad with zeros, anything
/// else with blanks.
fn writeText(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, spec: Spec) !void {
    const want = if (spec.pad == .none) 0 else spec.width orelse 0;
    if (text.len < want) try out.appendNTimes(gpa, if (spec.pad == .zero or spec.pad == .plus) '0' else ' ', want - text.len);
    try out.appendSlice(gpa, text);
}

const Case = enum { keep, upper, lower };

fn writeCased(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, case: Case, spec: Spec) !void {
    const from = out.items.len;
    try writeText(out, gpa, text, spec);
    for (out.items[from..]) |*c| c.* = switch (case) {
        .keep => c.*,
        .upper => std.ascii.toUpper(c.*),
        .lower => std.ascii.toLower(c.*),
    };
}

/// A number of at least `digits` places, sign included, padded with
/// `default_pad`. A width given replaces `digits`. `sign` is printed before
/// the magnitude.
fn paddedNumber(out: *std.ArrayList(u8), gpa: std.mem.Allocator, sign: []const u8, magnitude: u64, digits: usize, default_pad: Pad, spec: Spec) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{magnitude}) catch unreachable;
    const pad = if (spec.pad == .default) default_pad else spec.pad;
    const len = sign.len + s.len;
    const want = if (pad == .none) len else @max(len, spec.width orelse digits);
    if (pad == .space) try out.appendNTimes(gpa, ' ', want - len);
    try out.appendSlice(gpa, sign);
    if (pad != .space) try out.appendNTimes(gpa, '0', want - len);
    try out.appendSlice(gpa, s);
}

fn number(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: i64, digits: usize, default_pad: Pad, spec: Spec) !void {
    try paddedNumber(out, gpa, if (value < 0) "-" else "", @abs(value), digits, default_pad, spec);
}

/// The conversions of a year or a part of one: `base` places, and with the +
/// flag a sign when the year takes more than that, or the field is wider.
fn yearish(out: *std.ArrayList(u8), gpa: std.mem.Allocator, negative: bool, magnitude: u64, base: usize, spec: Spec) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{magnitude}) catch unreachable;
    var sign: []const u8 = if (negative) "-" else "";
    if (!negative and spec.pad == .plus and ((spec.width orelse base) > base or s.len > base)) sign = "+";
    try paddedNumber(out, gpa, sign, magnitude, base, .zero, spec);
}

/// The last two digits of a year, as gnulib counts them before year 0 too.
fn twoDigits(year: i64) u64 {
    return @abs(@rem(year, 100));
}

/// %N: the width is the number of digits. - drops trailing zeros and _ puts
/// blanks in their place; one digit always stays.
fn nanoseconds(out: *std.ArrayList(u8), gpa: std.mem.Allocator, nsec: u32, spec: Spec) !void {
    var buf: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{nsec}) catch unreachable;
    const width = spec.width orelse 9;
    var digits: []const u8 = buf[0..@min(width, 9)];
    if (spec.pad == .none or spec.pad == .space) {
        while (digits.len > 1 and digits[digits.len - 1] == '0') digits = digits[0 .. digits.len - 1];
    }
    try out.appendSlice(gpa, digits);
    if (spec.pad == .none or width <= digits.len) return;
    try out.appendNTimes(gpa, if (spec.pad == .space) ' ' else '0', width - digits.len);
}

/// What the C library prints for `%conv`, put in the field `spec` asks for.
/// Its years differ from gnulib's: a year and a century are not padded, and
/// before year 0 the century and the year of it round down.
fn writeSystemNumber(out: *std.ArrayList(u8), gpa: std.mem.Allocator, conv: u8, tm: *const tz.Tm, epoch: i64, nsec: u32, spec: Spec) std.mem.Allocator.Error!void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);
    switch (conv) {
        'C' => {
            // (Zig would put a + on a padded signed number.)
            const century = @divFloor(tm.year, 100);
            try tmp.print(gpa, "{s}{d}", .{ if (century < 0) "-" else "", @abs(century) });
        },
        'y' => try tmp.print(gpa, "{d:0>2}", .{@as(u64, @intCast(@mod(tm.year, 100)))}),
        'g' => try tmp.print(gpa, "{d:0>2}", .{@as(u64, @intCast(@mod(isoWeek(tm).year, 100)))}),
        'G' => try tmp.print(gpa, "{d}", .{isoWeek(tm).year}),
        'Y' => try tmp.print(gpa, "{d}", .{tm.year}),
        else => try format(&tmp, gpa, &.{ '%', conv }, tm, epoch, nsec),
    }
    try writeCased(out, gpa, tmp.items, .keep, spec);
}

/// Whether the E or O modifier goes with `conv`; otherwise the directive is
/// not one and is printed as it stands.
fn modifierFits(modifier: u8, conv: u8) bool {
    return std.mem.indexOfScalar(u8, switch (modifier) {
        'E' => "cnpqrstuxyzCPRTXYZ%",
        else => "bdeghjklmnprstuwyzBCGHIMNPRSTUVWZ%",
    }, conv) != null;
}

/// %z with up to three colons. As GNU: the offset is one number (hhmm, h:mm,
/// h:mm:ss) in a field whose width, sign included, defaults to that of the
/// full form. - drops the
/// padding, _ puts blanks before the sign, otherwise zeros follow it.
fn zoneOffset(out: *std.ArrayList(u8), gpa: std.mem.Allocator, tm: *const tz.Tm, colons: usize, width: ?usize, pad: Pad) !void {
    const off = tm.gmtoff;
    // The zone "-00" stands for an unknown offset.
    const negative = off < 0 or (off == 0 and std.mem.startsWith(u8, tm.zoneName(), "-"));
    const a: u32 = @abs(off);
    const hh = a / 3600;
    const mm = (a % 3600) / 60;
    const ss = a % 60;
    // %:::z shows no more than it has to.
    const form: usize = if (colons < 3) colons else if (ss != 0) 2 else if (mm != 0) 1 else 3;
    var buf: [32]u8 = undefined;
    const text = switch (form) {
        0 => std.fmt.bufPrint(&buf, "{d}", .{hh * 100 + mm}),
        1 => std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{ hh, mm }),
        2 => std.fmt.bufPrint(&buf, "{d}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }),
        else => std.fmt.bufPrint(&buf, "{d}", .{hh}),
    } catch unreachable;
    const least: usize = switch (form) {
        0 => 5,
        1 => 6,
        2 => 9,
        else => 3,
    };
    const len = 1 + text.len;
    const field = if (pad == .none) len else @max(len, width orelse least);
    if (pad == .space) try out.appendNTimes(gpa, ' ', field - len);
    try out.append(gpa, if (negative) '-' else '+');
    if (pad != .space) try out.appendNTimes(gpa, '0', field - len);
    try out.appendSlice(gpa, text);
}

/// Append the formatted time. `epoch` and `nsec` feed %s and %N.
pub fn format(out: *std.ArrayList(u8), gpa: std.mem.Allocator, fmt: []const u8, tm: *const tz.Tm, epoch: i64, nsec: u32) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        var spec: Spec = .{};
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '_' => spec.pad = .space,
                '-' => spec.pad = .none,
                '0' => spec.pad = .zero,
                '+' => spec.pad = .plus,
                '^' => spec.upper = true,
                '#' => spec.swap = true,
                else => break,
            }
        }
        // As GNU, no field is wider than INT_MAX.
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) spec.width = @min((spec.width orelse 0) *| 10 +| (fmt[i] - '0'), std.math.maxInt(i32));
        var modifier: u8 = 0;
        if (i < fmt.len and (fmt[i] == 'E' or fmt[i] == 'O')) {
            modifier = fmt[i];
            i += 1;
        }
        var colons: usize = 0;
        while (i < fmt.len and fmt[i] == ':') : (i += 1) colons += 1;
        if (i >= fmt.len) {
            try writeCased(out, gpa, fmt[start..], if (spec.upper) .upper else .keep, spec);
            break;
        }
        var conv = fmt[i];
        i += 1;
        // Colons go with z alone, three at most. When something else follows
        // them, GNU takes the directive to end at the first.
        if (colons > 0 and conv != 'z') {
            i -= colons;
            conv = 0;
        } else if (colons > 3) conv = 0;
        if (modifier != 0 and conv != 0 and !modifierFits(modifier, conv)) conv = 0;
        // In the C locale E and O change nothing in what a number looks like,
        // and GNU leaves these to the system: only the padding is its own.
        const system = if (modifier == 'O') "deHIjklmMSuUVwWCgGyz" else if (modifier == 'E') "CyY" else "";
        // With O a negative value stays GNU's own, written as without O.
        const negative = modifier == 'O' and switch (conv) {
            'z' => tm.gmtoff < 0 or (tm.gmtoff == 0 and std.mem.startsWith(u8, tm.zoneName(), "-")),
            's' => epoch < 0,
            'C' => tm.year < 0,
            'G' => isoWeek(tm).year < 0,
            else => false,
        };
        if (conv != 0 and colons == 0 and !negative and std.mem.indexOfScalar(u8, system, conv) != null) {
            try writeSystemNumber(out, gpa, conv, tm, epoch, nsec, spec);
            continue;
        }
        const name_case: Case = if (spec.upper or spec.swap) .upper else .keep;
        const year = tm.year;
        const hour12: i64 = if (tm.hour % 12 == 0) 12 else tm.hour % 12;
        switch (conv) {
            // % takes no flags, width or modifier. With any, the whole thing is
            // text, which GNU pads as if the closing % were not part of it.
            '%' => if (i - start == 2) try out.append(gpa, '%') else {
                var short = spec;
                if (short.width) |w| short.width = w +| 1;
                try writeText(out, gpa, fmt[start..i], short);
            },
            'n' => try writeText(out, gpa, "\n", spec),
            't' => try writeText(out, gpa, "\t", spec),
            'a' => try writeCased(out, gpa, weekdays[tm.wday][0..3], name_case, spec),
            'A' => try writeCased(out, gpa, weekdays[tm.wday], name_case, spec),
            'b', 'h' => try writeCased(out, gpa, months[tm.mon - 1][0..3], name_case, spec),
            'B' => try writeCased(out, gpa, months[tm.mon - 1], name_case, spec),
            // # gives the other case of what these print by themselves.
            'p' => try writeCased(out, gpa, if (tm.hour >= 12) "PM" else "AM", if (spec.swap) .lower else .keep, spec),
            'P' => try writeCased(out, gpa, if (tm.hour >= 12) "pm" else "am", .keep, spec),
            'Z' => try writeCased(out, gpa, tm.zoneName(), if (spec.swap) .lower else if (spec.upper) .upper else .keep, spec),
            'c', 'D', 'F', 'r', 'R', 'T', 'x', 'X' => {
                var tmp: std.ArrayList(u8) = .empty;
                defer tmp.deinit(gpa);
                var outer = spec;
                switch (conv) {
                    'F' => {
                        // "%+4Y-%m-%d" when nothing is asked for; else the flag
                        // and what the width leaves go to the year.
                        var year_spec: Spec = .{ .pad = spec.pad, .width = if (spec.width) |w| w -| 6 else 0 };
                        if (spec.pad == .default and spec.width == null) year_spec = .{ .pad = .plus, .width = 4 };
                        try yearish(&tmp, gpa, year < 0, @abs(year), 4, year_spec);
                        try tmp.print(gpa, "-{d:0>2}-{d:0>2}", .{ tm.mon, tm.mday });
                        outer.upper = false;
                    },
                    // In the C locale %c and %x are the system's, whose years
                    // are a plain number and a remainder that is never negative.
                    'c' => {
                        try format(&tmp, gpa, "%a %b %e %H:%M:%S ", tm, epoch, nsec);
                        try tmp.print(gpa, "{d}", .{year});
                    },
                    'x' => {
                        try format(&tmp, gpa, "%m/%d/", tm, epoch, nsec);
                        try tmp.print(gpa, "{d:0>2}", .{@as(u64, @intCast(@mod(year, 100)))});
                    },
                    // gnulib's own: a - or _ also reaches the year.
                    'D' => {
                        try format(&tmp, gpa, "%m/%d/", tm, epoch, nsec);
                        try yearish(&tmp, gpa, false, twoDigits(year), 2, .{ .pad = spec.pad });
                    },
                    else => try format(&tmp, gpa, switch (conv) {
                        'r' => "%I:%M:%S %p",
                        'R' => "%H:%M",
                        else => "%H:%M:%S",
                    }, tm, epoch, nsec),
                }
                try writeCased(out, gpa, tmp.items, if (outer.upper) .upper else .keep, outer);
            },
            'C' => try yearish(out, gpa, year < 0, @abs(@divTrunc(year, 100)), 2, spec),
            'y' => try yearish(out, gpa, false, twoDigits(year), 2, spec),
            'Y' => try yearish(out, gpa, year < 0, @abs(year), 4, spec),
            'G' => {
                const iso = isoWeek(tm).year;
                try yearish(out, gpa, iso < 0, @abs(iso), 4, spec);
            },
            'g' => try yearish(out, gpa, false, twoDigits(isoWeek(tm).year), 2, spec),
            'd' => try number(out, gpa, tm.mday, 2, .zero, spec),
            'e' => try number(out, gpa, tm.mday, 2, .space, spec),
            'H' => try number(out, gpa, tm.hour, 2, .zero, spec),
            'k' => try number(out, gpa, tm.hour, 2, .space, spec),
            'I' => try number(out, gpa, hour12, 2, .zero, spec),
            'l' => try number(out, gpa, hour12, 2, .space, spec),
            'j' => try number(out, gpa, @as(i64, tm.yday) + 1, 3, .zero, spec),
            'm' => try number(out, gpa, tm.mon, 2, .zero, spec),
            'M' => try number(out, gpa, tm.min, 2, .zero, spec),
            'S' => try number(out, gpa, tm.sec, 2, .zero, spec),
            's' => try number(out, gpa, epoch, 1, .zero, spec),
            'u' => try number(out, gpa, if (tm.wday == 0) 7 else tm.wday, 1, .zero, spec),
            'w' => try number(out, gpa, tm.wday, 1, .zero, spec),
            'U' => try number(out, gpa, @divFloor(@as(i64, tm.yday) + 7 - tm.wday, 7), 2, .zero, spec),
            'W' => try number(out, gpa, @divFloor(@as(i64, tm.yday) + 7 - @mod(@as(i64, tm.wday) + 6, 7), 7), 2, .zero, spec),
            'V' => try number(out, gpa, isoWeek(tm).week, 2, .zero, spec),
            'q' => try number(out, gpa, @divFloor(@as(i64, tm.mon) - 1, 3) + 1, 1, .zero, spec),
            'N' => try nanoseconds(out, gpa, nsec, spec),
            // Here + is no different from no flag.
            'z' => try zoneOffset(out, gpa, tm, colons, spec.width, if (spec.pad == .plus) .default else spec.pad),
            // Not a directive: its text, upper-cased where # would have done
            // that to the name asked for.
            else => {
                const names = spec.swap and i - start > 1 and (fmt[i - 1] == 'b' or fmt[i - 1] == 'h');
                try writeCased(out, gpa, fmt[start..i], if (spec.upper or names) .upper else .keep, spec);
            },
        }
    }
}

test "a width too large to read is cut, not an overflow" {
    var tm = tz.breakdown(0, 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    // Only with - is such a field short enough to look at.
    try format(&out, std.testing.allocator, "%-99999999999999999999d|", &tm, 0, 0);
    try std.testing.expectEqualStrings("1|", out.items);
}

test "flags, widths and years as gnulib has them" {
    const t = std.testing;
    var tm = tz.breakdown(1709611506, 0);
    tm.zone_len = 3;
    @memcpy(tm.zone[0..3], "UTC");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try format(&out, t.allocator, "%P%^P%#P|%-5N|%+12F|%4:q|%:q|%+e|%+5a|%12D|%-D|%+3y|%5%", &tm, 1709611506, 7006008);
    try t.expectEqualStrings("amamam|007|+02024-03-05| %4:q|%:q|05|00Tue|    03/05/24|03/05/24|+24|   %5%", out.items);
}

test "format basics" {
    const t = std.testing;
    var tm = tz.breakdown(1700000000, 0);
    tm.zone_len = 3;
    @memcpy(tm.zone[0..3], "UTC");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try format(&out, t.allocator, "%Y-%m-%d %H:%M:%S %a %b %e %j %U %V %Z %z %:z %s", &tm, 1700000000, 0);
    try t.expectEqualStrings("2023-11-14 22:13:20 Tue Nov 14 318 46 46 UTC +0000 +00:00 1700000000", out.items);
}
