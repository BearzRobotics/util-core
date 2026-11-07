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

const Pad = enum { default, none, space, zero };

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

fn writePadded(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, width: usize, pad_char: u8) !void {
    if (text.len < width) try out.appendNTimes(gpa, pad_char, width - text.len);
    try out.appendSlice(gpa, text);
}

fn number(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: i64, digits: usize, pad: Pad, default_pad: u8, width: ?usize) !void {
    var buf: [32]u8 = undefined;
    const neg = value < 0;
    const mag: u64 = @abs(value);
    const s = std.fmt.bufPrint(&buf, "{d}", .{mag}) catch unreachable;
    const want: usize = width orelse digits;
    var pc: u8 = default_pad;
    switch (pad) {
        .none => {
            if (neg) try out.append(gpa, '-');
            try out.appendSlice(gpa, s);
            return;
        },
        .space => pc = ' ',
        .zero => pc = '0',
        .default => {},
    }
    const total = s.len + @intFromBool(neg);
    if (pc == '0') {
        if (neg) try out.append(gpa, '-');
        if (total < want) try out.appendNTimes(gpa, '0', want - total);
        try out.appendSlice(gpa, s);
    } else {
        if (total < want) try out.appendNTimes(gpa, ' ', want - total);
        if (neg) try out.append(gpa, '-');
        try out.appendSlice(gpa, s);
    }
}

fn caseText(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, upper: bool, lower: bool, width: ?usize, pad: Pad) !void {
    var tmp: [64]u8 = undefined;
    const n = @min(text.len, tmp.len);
    for (text[0..n], 0..) |c, i| tmp[i] = if (upper) std.ascii.toUpper(c) else if (lower) std.ascii.toLower(c) else c;
    const pc: u8 = if (pad == .zero) '0' else ' ';
    if (pad == .none) return out.appendSlice(gpa, tmp[0..n]);
    try writePadded(out, gpa, tmp[0..n], width orelse 0, pc);
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
        var pad: Pad = .default;
        var upper = false;
        var swap = false;
        var colons: usize = 0;
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '_' => pad = .space,
                '-' => pad = .none,
                '0' => pad = .zero,
                '^' => upper = true,
                '#' => swap = true,
                '+' => {},
                else => break,
            }
        }
        var width: ?usize = null;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) width = (width orelse 0) * 10 + (fmt[i] - '0');
        while (i < fmt.len and fmt[i] == ':') : (i += 1) colons += 1;
        if (i < fmt.len and (fmt[i] == 'E' or fmt[i] == 'O')) i += 1;
        if (i >= fmt.len) {
            try out.appendSlice(gpa, fmt[start..]);
            break;
        }
        const conv = fmt[i];
        i += 1;
        switch (conv) {
            '%' => try out.append(gpa, '%'),
            'n' => try out.append(gpa, '\n'),
            't' => try out.append(gpa, '\t'),
            'a' => try caseText(out, gpa, weekdays[tm.wday][0..3], upper or swap, false, width, pad),
            'A' => try caseText(out, gpa, weekdays[tm.wday], upper or swap, false, width, pad),
            'b', 'h' => try caseText(out, gpa, months[tm.mon - 1][0..3], upper or swap, false, width, pad),
            'B' => try caseText(out, gpa, months[tm.mon - 1], upper or swap, false, width, pad),
            'p' => try caseText(out, gpa, if (tm.hour >= 12) "PM" else "AM", upper, swap, width, pad),
            'P' => try caseText(out, gpa, if (tm.hour >= 12) "pm" else "am", upper, false, width, pad),
            'Z' => try caseText(out, gpa, tm.zoneName(), upper, swap, width, pad),
            'c', 'D', 'F', 'r', 'R', 'T', 'x', 'X' => {
                const sub: []const u8 = switch (conv) {
                    'c' => "%a %b %e %H:%M:%S %Y",
                    'D', 'x' => "%m/%d/%y",
                    'F' => "%Y-%m-%d",
                    'r' => "%I:%M:%S %p",
                    'R' => "%H:%M",
                    'T', 'X' => "%H:%M:%S",
                    else => unreachable,
                };
                var tmp: std.ArrayList(u8) = .empty;
                defer tmp.deinit(gpa);
                if (conv == 'F' and tm.year >= 0 and tm.year < 1000) {
                    try tmp.print(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(tm.year)), tm.mon, tm.mday });
                } else try format(&tmp, gpa, sub, tm, epoch, nsec);
                if (upper) for (tmp.items) |*ch| {
                    ch.* = std.ascii.toUpper(ch.*);
                };
                try writePadded(out, gpa, tmp.items, width orelse 0, if (pad == .zero) '0' else ' ');
            },
            'C' => try number(out, gpa, @divFloor(tm.year, 100), 2, pad, '0', width),
            'd' => try number(out, gpa, tm.mday, 2, pad, '0', width),
            'e' => try number(out, gpa, tm.mday, 2, pad, ' ', width),
            'H' => try number(out, gpa, tm.hour, 2, pad, '0', width),
            'k' => try number(out, gpa, tm.hour, 2, pad, ' ', width),
            'I' => try number(out, gpa, if (tm.hour % 12 == 0) 12 else tm.hour % 12, 2, pad, '0', width),
            'l' => try number(out, gpa, if (tm.hour % 12 == 0) 12 else tm.hour % 12, 2, pad, ' ', width),
            'j' => try number(out, gpa, @as(i64, tm.yday) + 1, 3, pad, '0', width),
            'm' => try number(out, gpa, tm.mon, 2, pad, '0', width),
            'M' => try number(out, gpa, tm.min, 2, pad, '0', width),
            'S' => try number(out, gpa, tm.sec, 2, pad, '0', width),
            's' => try number(out, gpa, epoch, 1, pad, '0', width),
            'u' => try number(out, gpa, if (tm.wday == 0) 7 else tm.wday, 1, pad, '0', width),
            'w' => try number(out, gpa, tm.wday, 1, pad, '0', width),
            'U' => try number(out, gpa, @divFloor(@as(i64, tm.yday) + 7 - tm.wday, 7), 2, pad, '0', width),
            'W' => try number(out, gpa, @divFloor(@as(i64, tm.yday) + 7 - @mod(@as(i64, tm.wday) + 6, 7), 7), 2, pad, '0', width),
            'V' => try number(out, gpa, isoWeek(tm).week, 2, pad, '0', width),
            'G' => try number(out, gpa, isoWeek(tm).year, 1, pad, '0', width),
            'g' => try number(out, gpa, @mod(isoWeek(tm).year, 100), 2, pad, '0', width),
            'y' => try number(out, gpa, @mod(tm.year, 100), 2, pad, '0', width),
            'Y' => try number(out, gpa, tm.year, 1, pad, '0', width),
            'N' => {
                var buf: [9]u8 = undefined;
                _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{nsec}) catch unreachable;
                const w = @min(width orelse 9, 9);
                try out.appendSlice(gpa, buf[0..w]);
                if ((width orelse 0) > 9) try out.appendNTimes(gpa, '0', width.? - 9);
            },
            'z' => {
                const off = tm.gmtoff;
                const sign: u8 = if (off < 0) '-' else '+';
                const a: u32 = @abs(off);
                const hh = a / 3600;
                const mm = (a % 3600) / 60;
                const ss = a % 60;
                var tmp: [32]u8 = undefined;
                const s = switch (colons) {
                    0 => std.fmt.bufPrint(&tmp, "{c}{d:0>2}{d:0>2}", .{ sign, hh, mm }),
                    1 => std.fmt.bufPrint(&tmp, "{c}{d:0>2}:{d:0>2}", .{ sign, hh, mm }),
                    2 => std.fmt.bufPrint(&tmp, "{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, hh, mm, ss }),
                    else => if (ss != 0)
                        std.fmt.bufPrint(&tmp, "{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, hh, mm, ss })
                    else if (mm != 0)
                        std.fmt.bufPrint(&tmp, "{c}{d:0>2}:{d:0>2}", .{ sign, hh, mm })
                    else
                        std.fmt.bufPrint(&tmp, "{c}{d:0>2}", .{ sign, hh }),
                } catch unreachable;
                const w = width orelse 0;
                if (s.len < w) {
                    if (pad == .space) {
                        try out.appendNTimes(gpa, ' ', w - s.len);
                        try out.appendSlice(gpa, s);
                    } else {
                        try out.append(gpa, s[0]);
                        try out.appendNTimes(gpa, '0', w - s.len);
                        try out.appendSlice(gpa, s[1..]);
                    }
                } else try out.appendSlice(gpa, s);
            },
            else => try out.appendSlice(gpa, fmt[start..i]),
        }
    }
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
