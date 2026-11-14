// SPDX-License-Identifier: GPL-2.0-or-later
//! A moment in time as broken-down data, and its `--json` form (decision 0003).
//!
//! Input is what `date` already computes: the epoch seconds and nanoseconds
//! and the `tz.Tm` for them in the chosen zone. Nothing here parses a date or
//! reads the clock.

const std = @import("std");
const Io = std.Io;
const tz = @import("tz.zig");
const json = @import("json.zig");

const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

/// Write one moment as a JSON object and a newline: `epoch`, `nsec`, `iso8601`
/// (to the second, with the numeric offset), `year`, `month`, `day`, `hour`,
/// `minute`, `second`, `weekday` (name) and `weekday_number` (ISO 8601: Monday
/// is 1, Sunday is 7), `day_of_year` (1-based), `utc_offset` (seconds east of
/// UTC), `zone` (abbreviation) and `dst`.
pub fn writeJson(w: *Io.Writer, tm: *const tz.Tm, sec: i64, nsec: u32) Io.Writer.Error!void {
    const off = tm.gmtoff;
    const abs_off: u32 = @abs(off);
    try w.print("{{\"epoch\":{d},\"nsec\":{d},\"iso8601\":\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}\"", .{
        sec, nsec, @as(u32, @intCast(@max(tm.year, 0))), tm.mon, tm.mday, tm.hour, tm.min, tm.sec, @as(u8, if (off < 0) '-' else '+'), abs_off / 3600, (abs_off % 3600) / 60,
    });
    try w.print(",\"year\":{d},\"month\":{d},\"day\":{d},\"hour\":{d},\"minute\":{d},\"second\":{d}", .{ tm.year, tm.mon, tm.mday, tm.hour, tm.min, tm.sec });
    try w.writeAll(",\"weekday\":");
    try json.writeString(w, weekday_names[tm.wday % 7]);
    try w.print(",\"weekday_number\":{d},\"day_of_year\":{d},\"utc_offset\":{d},\"zone\":", .{ if (tm.wday == 0) @as(u8, 7) else tm.wday, @as(u32, tm.yday) + 1, off });
    try json.writeString(w, tm.zoneName());
    try w.print(",\"dst\":{s}}}\n", .{if (tm.isdst) "true" else "false"});
}

test "json: UTC and a negative half-hour offset" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const utc = tz.breakdown(1234567890, 0);
    try writeJson(&w, &utc, 1234567890, 5);
    const out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"epoch\":1234567890,\"nsec\":5,\"iso8601\":\"2009-02-13T23:31:30+00:00\""));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"weekday\":\"Friday\",\"weekday_number\":5,\"day_of_year\":44,\"utc_offset\":0") != null);
    var w2: Io.Writer = .fixed(&buf);
    var shifted = tz.breakdown(1234567890, -(3 * 3600 + 1800));
    shifted.gmtoff = -(3 * 3600 + 1800);
    try writeJson(&w2, &shifted, 1234567890, 0);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "T20:01:30-03:30\"") != null);
}

test "json: Sunday is ISO weekday 7" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const sunday = tz.breakdown(1234656000, 0); // 2009-02-15
    try writeJson(&w, &sunday, 1234656000, 0);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"weekday\":\"Sunday\",\"weekday_number\":7") != null);
}
