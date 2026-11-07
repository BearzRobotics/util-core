//! Time zones: TZif files and POSIX TZ strings, plus the civil-calendar
//! arithmetic that date, touch, ls, stat, pr and who share.
//!
//! References: tzfile(5) (RFC 8536, TZif versions 1-4), POSIX.1-2024
//! "Environment Variables" (TZ), glibc tzset semantics: an unset TZ means
//! /etc/localtime, an empty TZ means UTC, ":name" or "name" is looked up in
//! /usr/share/zoneinfo (or is a path), anything else is a POSIX rule string.

const std = @import("std");
const Io = std.Io;

pub const Type = struct {
    utoff: i32,
    isdst: bool,
    abbr: [12]u8 = @splat(0),
    abbr_len: u8 = 0,

    pub fn name(t: *const Type) []const u8 {
        return t.abbr[0..t.abbr_len];
    }
};

fn mkType(utoff: i32, isdst: bool, abbr: []const u8) Type {
    var t: Type = .{ .utoff = utoff, .isdst = isdst };
    const n = @min(abbr.len, t.abbr.len);
    @memcpy(t.abbr[0..n], abbr[0..n]);
    t.abbr_len = @intCast(n);
    return t;
}

const RuleKind = enum { julian1, julian0, mwd };
const RuleSpec = struct { kind: RuleKind = .mwd, m: u8 = 0, w: u8 = 0, d: u16 = 0, time: i32 = 7200 };

pub const Rule = struct {
    std: Type,
    dst: ?Type = null,
    start: RuleSpec = .{},
    end: RuleSpec = .{},
};

pub const Zone = struct {
    gpa: std.mem.Allocator,
    trans: []i64 = &.{},
    trans_type: []u8 = &.{},
    types: []Type = &.{},
    rule: ?Rule = null,

    pub fn deinit(z: *Zone) void {
        z.gpa.free(z.trans);
        z.gpa.free(z.trans_type);
        z.gpa.free(z.types);
        z.* = undefined;
    }

    pub fn utc(gpa: std.mem.Allocator) Zone {
        return .{ .gpa = gpa, .rule = .{ .std = mkType(0, false, "UTC") } };
    }

    /// The zone type in effect at UTC time `t`.
    pub fn at(z: *const Zone, t: i64) Type {
        if (z.trans.len == 0 or t < z.trans[0]) {
            if (z.trans.len == 0 and z.types.len == 0) {
                if (z.rule) |r| return ruleAt(r, t);
                return mkType(0, false, "UTC");
            }
            // Before the first transition: first standard-time type.
            for (z.types) |ty| if (!ty.isdst) return ty;
            return z.types[0];
        }
        if (t >= z.trans[z.trans.len - 1] and z.rule != null) return ruleAt(z.rule.?, t);
        // Binary search for the last transition <= t.
        var lo: usize = 0;
        var hi: usize = z.trans.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (z.trans[mid] <= t) lo = mid else hi = mid;
        }
        return z.types[z.trans_type[lo]];
    }
};

// ------------------------------------------------------------- calendar

pub fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn daysInMonth(y: i64, m: u8) u8 {
    const dm = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (m == 2 and isLeap(y)) 29 else dm[m - 1];
}

/// Days since 1970-01-01 of the civil date (proleptic Gregorian).
pub fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: u8, day: u8 };

pub fn civilFromDays(z0: i64) Civil {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = if (m <= 2) y + 1 else y, .month = @intCast(m), .day = @intCast(d) };
}

/// Broken-down time, like struct tm (year is the full year, month 1-12).
pub const Tm = struct {
    year: i64,
    mon: u8, // 1..12
    mday: u8,
    hour: u8,
    min: u8,
    sec: u8, // 0..60 only for parsed leap seconds
    wday: u8, // 0 = Sunday
    yday: u16, // 0-based
    isdst: bool = false,
    gmtoff: i32 = 0,
    zone: [12]u8 = @splat(0),
    zone_len: u8 = 0,

    pub fn zoneName(t: *const Tm) []const u8 {
        return t.zone[0..t.zone_len];
    }
};

/// Broken-down representation of `epoch + utoff` (UTC arithmetic).
pub fn breakdown(epoch: i64, utoff: i32) Tm {
    const local = epoch + utoff;
    const days = @divFloor(local, 86400);
    const secs: i64 = @mod(local, 86400);
    const c = civilFromDays(days);
    const yday = days - daysFromCivil(c.year, 1, 1);
    return .{
        .year = c.year,
        .mon = c.month,
        .mday = c.day,
        .hour = @intCast(@divFloor(secs, 3600)),
        .min = @intCast(@divFloor(@mod(secs, 3600), 60)),
        .sec = @intCast(@mod(secs, 60)),
        .wday = @intCast(@mod(days + 4, 7)),
        .yday = @intCast(yday),
        .gmtoff = utoff,
    };
}

/// Local broken-down time of `epoch` in `zone`.
pub fn localtime(zone: *const Zone, epoch: i64) Tm {
    const ty = zone.at(epoch);
    var tm = breakdown(epoch, ty.utoff);
    tm.isdst = ty.isdst;
    tm.zone_len = ty.abbr_len;
    tm.zone = ty.abbr;
    return tm;
}

/// Seconds since the epoch of civil fields interpreted as UTC.
pub fn timegm(year: i64, mon: i64, mday: i64, hour: i64, min: i64, sec: i64) i64 {
    // Normalise the month first so daysFromCivil sees 1..12.
    const m0 = mon - 1;
    const y = year + @divFloor(m0, 12);
    const m = @mod(m0, 12) + 1;
    return (daysFromCivil(y, m, 1) + (mday - 1)) * 86400 + hour * 3600 + min * 60 + sec;
}

/// mktime: the epoch whose local time in `zone` has the given civil fields
/// (fields may be out of range and are normalised). For a skipped local time
/// the result is the instant `gap` seconds later as glibc mktime does with
/// tm_isdst = -1; for a repeated local time the earlier instant (DST) wins.
pub fn mktime(zone: *const Zone, year: i64, mon: i64, mday: i64, hour: i64, min: i64, sec: i64) i64 {
    const guess = timegm(year, mon, mday, hour, min, sec);
    // Candidate offsets: those in force within a day either side.
    var offs: [3]i32 = undefined;
    offs[0] = zone.at(guess - 86400).utoff;
    offs[1] = zone.at(guess).utoff;
    offs[2] = zone.at(guess + 86400).utoff;
    var best: ?i64 = null;
    for (offs) |o| {
        const t = guess - o;
        if (zone.at(t).utoff == o) {
            if (best == null or t < best.?) best = t;
        }
    }
    if (best) |b| return b;
    // Skipped local time: use the offset before the gap (moves the time forward).
    return guess - offs[0];
}

// -------------------------------------------------------------- rules

fn dayOfRule(year: i64, s: RuleSpec) i64 {
    // Day number (days since epoch) of the transition date.
    return switch (s.kind) {
        .julian1 => daysFromCivil(year, 1, 1) + @as(i64, s.d) - 1 + @intFromBool(isLeap(year) and s.d >= 60),
        .julian0 => daysFromCivil(year, 1, 1) + s.d,
        .mwd => blk: {
            const first = daysFromCivil(year, s.m, 1);
            const wd_first = @mod(first + 4, 7);
            var day: i64 = first + @mod(@as(i64, s.d) - wd_first + 7, 7) + 7 * (@as(i64, s.w) - 1);
            const dim = daysInMonth(year, s.m);
            while (day >= first + dim) day -= 7;
            break :blk day;
        },
    };
}

fn ruleAt(r: Rule, t: i64) Type {
    const dst = r.dst orelse return r.std;
    // Year of `t` in standard time.
    const year = breakdown(t, r.std.utoff).year;
    const start = dayOfRule(year, r.start) * 86400 + r.start.time - r.std.utoff;
    const end = dayOfRule(year, r.end) * 86400 + r.end.time - dst.utoff;
    const in_dst = if (start < end) (t >= start and t < end) else !(t >= end and t < start);
    return if (in_dst) dst else r.std;
}

// ------------------------------------------------------ POSIX TZ string

fn parseName(s: []const u8, i: *usize) ?[]const u8 {
    if (i.* < s.len and s[i.*] == '<') {
        const e = std.mem.indexOfScalarPos(u8, s, i.*, '>') orelse return null;
        const n = s[i.* + 1 .. e];
        i.* = e + 1;
        return n;
    }
    const st = i.*;
    while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) i.* += 1;
    if (i.* - st < 3) return null;
    return s[st..i.*];
}

fn parseOffset(s: []const u8, i: *usize) ?i32 {
    var neg = false;
    if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) {
        neg = s[i.*] == '-';
        i.* += 1;
    }
    var parts: [3]i32 = .{ 0, 0, 0 };
    var n: usize = 0;
    while (n < 3) {
        const st = i.*;
        var v: i32 = 0;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) {
            v = v * 10 + @as(i32, s[i.*] - '0');
            i.* += 1;
        }
        if (i.* == st) {
            if (n == 0) return null;
            break;
        }
        parts[n] = v;
        n += 1;
        if (i.* < s.len and s[i.*] == ':') i.* += 1 else break;
    }
    const total = parts[0] * 3600 + parts[1] * 60 + parts[2];
    return if (neg) -total else total;
}

fn parseRuleSpec(s: []const u8, i: *usize) ?RuleSpec {
    var r: RuleSpec = .{};
    if (i.* >= s.len) return null;
    if (s[i.*] == 'M') {
        i.* += 1;
        var v: [3]u16 = undefined;
        for (0..3) |k| {
            var x: u16 = 0;
            const st = i.*;
            while (i.* < s.len and std.ascii.isDigit(s[i.*])) {
                x = x * 10 + (s[i.*] - '0');
                i.* += 1;
            }
            if (st == i.*) return null;
            v[k] = x;
            if (k < 2) {
                if (i.* >= s.len or s[i.*] != '.') return null;
                i.* += 1;
            }
        }
        r = .{ .kind = .mwd, .m = @intCast(v[0]), .w = @intCast(v[1]), .d = v[2] };
        if (r.m < 1 or r.m > 12 or r.w < 1 or r.w > 5 or r.d > 6) return null;
    } else {
        const j = s[i.*] == 'J';
        if (j) i.* += 1;
        var x: u16 = 0;
        const st = i.*;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) {
            x = x * 10 + (s[i.*] - '0');
            i.* += 1;
        }
        if (st == i.*) return null;
        r = .{ .kind = if (j) .julian1 else .julian0, .d = x };
    }
    if (i.* < s.len and s[i.*] == '/') {
        i.* += 1;
        r.time = parseOffset(s, i) orelse return null;
    }
    return r;
}

/// Parse a POSIX TZ string such as "EST5EDT,M3.2.0,M11.1.0" or "<+0530>-5:30".
pub fn parsePosix(s: []const u8) ?Rule {
    var i: usize = 0;
    const std_name = parseName(s, &i) orelse return null;
    const std_off = parseOffset(s, &i) orelse return null;
    var r: Rule = .{ .std = mkType(-std_off, false, std_name) };
    if (i >= s.len) return r;
    const dst_name = parseName(s, &i) orelse return null;
    var dst_off = std_off - 3600;
    if (i < s.len and s[i] != ',') dst_off = parseOffset(s, &i) orelse return null;
    r.dst = mkType(-dst_off, true, dst_name);
    if (i < s.len and s[i] == ',') {
        i += 1;
        r.start = parseRuleSpec(s, &i) orelse return null;
        if (i >= s.len or s[i] != ',') return null;
        i += 1;
        r.end = parseRuleSpec(s, &i) orelse return null;
    } else {
        // glibc default when no rule is given: US rules.
        r.start = .{ .kind = .mwd, .m = 3, .w = 2, .d = 0 };
        r.end = .{ .kind = .mwd, .m = 11, .w = 1, .d = 0 };
    }
    return r;
}

// --------------------------------------------------------------- TZif

fn be32(b: []const u8) i32 {
    return std.mem.readInt(i32, b[0..4], .big);
}
fn be64(b: []const u8) i64 {
    return std.mem.readInt(i64, b[0..8], .big);
}

fn parseTzif(gpa: std.mem.Allocator, data: []const u8) ?Zone {
    if (data.len < 44 or !std.mem.eql(u8, data[0..4], "TZif")) return null;
    const version = data[4];
    var off: usize = 0;
    var tsize: usize = 4;
    var hdr: []const u8 = data[0..44];
    // Counts: isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt.
    var cnt: [6]usize = undefined;
    for (0..6) |k| cnt[k] = @intCast(std.mem.readInt(u32, hdr[20 + 4 * k ..][0..4], .big));
    if (version >= '2') {
        // Skip the 32-bit block.
        const skip = 44 + cnt[3] * 4 + cnt[3] + cnt[4] * 6 + cnt[5] + cnt[2] * 8 + cnt[1] + cnt[0];
        if (data.len < skip + 44) return null;
        off = skip;
        hdr = data[off .. off + 44];
        for (0..6) |k| cnt[k] = @intCast(std.mem.readInt(u32, hdr[20 + 4 * k ..][0..4], .big));
        tsize = 8;
    }
    var p = off + 44;
    const timecnt = cnt[3];
    const typecnt = cnt[4];
    const charcnt = cnt[5];
    if (data.len < p + timecnt * tsize + timecnt + typecnt * 6 + charcnt) return null;
    var z: Zone = .{ .gpa = gpa };
    z.trans = gpa.alloc(i64, timecnt) catch return null;
    z.trans_type = gpa.alloc(u8, timecnt) catch return null;
    z.types = gpa.alloc(Type, typecnt) catch return null;
    for (0..timecnt) |k| z.trans[k] = if (tsize == 8) be64(data[p + k * 8 ..]) else be32(data[p + k * 4 ..]);
    p += timecnt * tsize;
    for (0..timecnt) |k| z.trans_type[k] = data[p + k];
    p += timecnt;
    const types_at = p;
    p += typecnt * 6;
    const chars = data[p .. p + charcnt];
    p += charcnt;
    for (0..typecnt) |k| {
        const e = data[types_at + k * 6 ..];
        const ai = e[5];
        const end = std.mem.indexOfScalarPos(u8, chars, ai, 0) orelse chars.len;
        z.types[k] = mkType(be32(e), e[4] != 0, chars[ai..end]);
    }
    if (tsize == 8) {
        p += cnt[2] * 12 + cnt[1] + cnt[0];
        if (p < data.len and data[p] == '\n') {
            if (std.mem.indexOfScalarPos(u8, data, p + 1, '\n')) |e| {
                z.rule = parsePosix(data[p + 1 .. e]);
            }
        }
    }
    return z;
}

fn readWhole(gpa: std.mem.Allocator, io: Io, path: []const u8) ?[]u8 {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = f.readStreaming(io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => {
                list.deinit(gpa);
                return null;
            },
        };
        if (n == 0) break;
        list.appendSlice(gpa, buf[0..n]) catch {
            list.deinit(gpa);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

/// Zone for the TZ environment value `tz` (null = unset).
pub fn load(gpa: std.mem.Allocator, io: Io, tz: ?[]const u8) Zone {
    const spec: []const u8 = tz orelse return loadFile(gpa, io, "/etc/localtime") orelse Zone.utc(gpa);
    if (spec.len == 0) return Zone.utc(gpa);
    var name = spec;
    if (name[0] == ':') name = name[1..];
    if (name.len > 0) {
        var pathbuf: [512]u8 = undefined;
        const path = if (name[0] == '/') name else std.fmt.bufPrint(&pathbuf, "/usr/share/zoneinfo/{s}", .{name}) catch name;
        if (std.mem.indexOf(u8, name, "..") == null) {
            if (loadFile(gpa, io, path)) |z| return z;
        }
    }
    if (parsePosix(name)) |r| return .{ .gpa = gpa, .rule = r };
    // glibc falls back to UTC for an unusable TZ, keeping the name as its abbreviation.
    return Zone.utc(gpa);
}

fn loadFile(gpa: std.mem.Allocator, io: Io, path: []const u8) ?Zone {
    const data = readWhole(gpa, io, path) orelse return null;
    defer gpa.free(data);
    return parseTzif(gpa, data);
}

test "civil round trip" {
    const t = std.testing;
    for ([_]i64{ -1000000, -1, 0, 1, 59, 86399, 951782400, 1700000000, 4102444800 }) |e| {
        const tm = breakdown(e, 0);
        try t.expectEqual(e, timegm(tm.year, tm.mon, tm.mday, tm.hour, tm.min, tm.sec));
    }
    try t.expectEqual(@as(u8, 4), breakdown(0, 0).wday); // 1970-01-01 was a Thursday
}

test "posix TZ rule" {
    const t = std.testing;
    var z: Zone = .{ .gpa = t.allocator, .rule = parsePosix("EST5EDT,M3.2.0,M11.1.0").? };
    // 2026-07-01 12:00 UTC is EDT (UTC-4); 2026-01-15 is EST (UTC-5).
    try t.expectEqual(@as(i32, -4 * 3600), z.at(1782907200).utoff);
    try t.expectEqual(@as(i32, -5 * 3600), z.at(1768478400).utoff);
    z.rule = parsePosix("<+0530>-5:30").?;
    try t.expectEqual(@as(i32, 5 * 3600 + 1800), z.at(0).utoff);
}
