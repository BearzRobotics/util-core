//! Date/time string parsing as done by GNU date -d and touch -d
//! (gnulib parse-datetime.y, coreutils 9.6 sources, consulted 2026-11-07).
//!
//! The yacc grammar is reproduced as a token-driven recursive descent that
//! takes the longest alternative wherever bison's default (shift) conflict
//! resolution does. Evaluation follows parse_datetime_body: build a local
//! struct tm from the current time overridden by the parsed pieces, normalise
//! it with mktime in the zone, then add the day-of-week, relative date,
//! zone-offset and relative time adjustments in that order.

const std = @import("std");
const Io = std.Io;
const tz = @import("tz.zig");

pub const Timespec = struct { sec: i64, nsec: u32 };

const Kind = enum {
    ago, dst, year_unit, month_unit, hour_unit, minute_unit, sec_unit, day_unit, day_shift, day,
    dayzone, local_zone, meridian, month, ordinal, zone, snumber, unumber, sdecimal, udecimal,
    ch, eof, bad,
};

const TextInt = struct { negative: bool = false, value: i64 = 0, digits: usize = 0 };

const Tok = struct {
    kind: Kind,
    value: i64 = 0, // intval for words, character code for ch
    ti: TextInt = .{},
    sec: i64 = 0, // decimals
    ns: i64 = 0,
};

const Table = struct { name: []const u8, kind: Kind, value: i32 };

const hour = 3600;
const meridian_table = [_]Table{
    .{ .name = "AM", .kind = .meridian, .value = 0 },
    .{ .name = "A.M.", .kind = .meridian, .value = 0 },
    .{ .name = "PM", .kind = .meridian, .value = 1 },
    .{ .name = "P.M.", .kind = .meridian, .value = 1 },
};
const month_day_table = [_]Table{
    .{ .name = "JANUARY", .kind = .month, .value = 1 },   .{ .name = "FEBRUARY", .kind = .month, .value = 2 },
    .{ .name = "MARCH", .kind = .month, .value = 3 },     .{ .name = "APRIL", .kind = .month, .value = 4 },
    .{ .name = "MAY", .kind = .month, .value = 5 },       .{ .name = "JUNE", .kind = .month, .value = 6 },
    .{ .name = "JULY", .kind = .month, .value = 7 },      .{ .name = "AUGUST", .kind = .month, .value = 8 },
    .{ .name = "SEPTEMBER", .kind = .month, .value = 9 }, .{ .name = "SEPT", .kind = .month, .value = 9 },
    .{ .name = "OCTOBER", .kind = .month, .value = 10 },  .{ .name = "NOVEMBER", .kind = .month, .value = 11 },
    .{ .name = "DECEMBER", .kind = .month, .value = 12 }, .{ .name = "SUNDAY", .kind = .day, .value = 0 },
    .{ .name = "MONDAY", .kind = .day, .value = 1 },      .{ .name = "TUESDAY", .kind = .day, .value = 2 },
    .{ .name = "TUES", .kind = .day, .value = 2 },        .{ .name = "WEDNESDAY", .kind = .day, .value = 3 },
    .{ .name = "WEDNES", .kind = .day, .value = 3 },      .{ .name = "THURSDAY", .kind = .day, .value = 4 },
    .{ .name = "THUR", .kind = .day, .value = 4 },        .{ .name = "THURS", .kind = .day, .value = 4 },
    .{ .name = "FRIDAY", .kind = .day, .value = 5 },      .{ .name = "SATURDAY", .kind = .day, .value = 6 },
};
const time_units_table = [_]Table{
    .{ .name = "YEAR", .kind = .year_unit, .value = 1 },
    .{ .name = "MONTH", .kind = .month_unit, .value = 1 },
    .{ .name = "FORTNIGHT", .kind = .day_unit, .value = 14 },
    .{ .name = "WEEK", .kind = .day_unit, .value = 7 },
    .{ .name = "DAY", .kind = .day_unit, .value = 1 },
    .{ .name = "HOUR", .kind = .hour_unit, .value = 1 },
    .{ .name = "MINUTE", .kind = .minute_unit, .value = 1 },
    .{ .name = "MIN", .kind = .minute_unit, .value = 1 },
    .{ .name = "SECOND", .kind = .sec_unit, .value = 1 },
    .{ .name = "SEC", .kind = .sec_unit, .value = 1 },
};
const relative_time_table = [_]Table{
    .{ .name = "TOMORROW", .kind = .day_shift, .value = 1 },
    .{ .name = "YESTERDAY", .kind = .day_shift, .value = -1 },
    .{ .name = "TODAY", .kind = .day_shift, .value = 0 },
    .{ .name = "NOW", .kind = .day_shift, .value = 0 },
    .{ .name = "LAST", .kind = .ordinal, .value = -1 },
    .{ .name = "THIS", .kind = .ordinal, .value = 0 },
    .{ .name = "NEXT", .kind = .ordinal, .value = 1 },
    .{ .name = "FIRST", .kind = .ordinal, .value = 1 },
    .{ .name = "THIRD", .kind = .ordinal, .value = 3 },
    .{ .name = "FOURTH", .kind = .ordinal, .value = 4 },
    .{ .name = "FIFTH", .kind = .ordinal, .value = 5 },
    .{ .name = "SIXTH", .kind = .ordinal, .value = 6 },
    .{ .name = "SEVENTH", .kind = .ordinal, .value = 7 },
    .{ .name = "EIGHTH", .kind = .ordinal, .value = 8 },
    .{ .name = "NINTH", .kind = .ordinal, .value = 9 },
    .{ .name = "TENTH", .kind = .ordinal, .value = 10 },
    .{ .name = "ELEVENTH", .kind = .ordinal, .value = 11 },
    .{ .name = "TWELFTH", .kind = .ordinal, .value = 12 },
    .{ .name = "AGO", .kind = .ago, .value = -1 },
    .{ .name = "HENCE", .kind = .ago, .value = 1 },
};
const universal_table = [_]Table{
    .{ .name = "GMT", .kind = .zone, .value = 0 },
    .{ .name = "UT", .kind = .zone, .value = 0 },
    .{ .name = "UTC", .kind = .zone, .value = 0 },
};
const zone_table = [_]Table{
    .{ .name = "WET", .kind = .zone, .value = 0 },           .{ .name = "WEST", .kind = .dayzone, .value = 0 },
    .{ .name = "BST", .kind = .dayzone, .value = 0 },        .{ .name = "ART", .kind = .zone, .value = -3 * hour },
    .{ .name = "BRT", .kind = .zone, .value = -3 * hour },   .{ .name = "BRST", .kind = .dayzone, .value = -3 * hour },
    .{ .name = "NST", .kind = .zone, .value = -(3 * hour + 1800) }, .{ .name = "NDT", .kind = .dayzone, .value = -(3 * hour + 1800) },
    .{ .name = "AST", .kind = .zone, .value = -4 * hour },   .{ .name = "ADT", .kind = .dayzone, .value = -4 * hour },
    .{ .name = "CLT", .kind = .zone, .value = -4 * hour },   .{ .name = "CLST", .kind = .dayzone, .value = -4 * hour },
    .{ .name = "EST", .kind = .zone, .value = -5 * hour },   .{ .name = "EDT", .kind = .dayzone, .value = -5 * hour },
    .{ .name = "CST", .kind = .zone, .value = -6 * hour },   .{ .name = "CDT", .kind = .dayzone, .value = -6 * hour },
    .{ .name = "MST", .kind = .zone, .value = -7 * hour },   .{ .name = "MDT", .kind = .dayzone, .value = -7 * hour },
    .{ .name = "PST", .kind = .zone, .value = -8 * hour },   .{ .name = "PDT", .kind = .dayzone, .value = -8 * hour },
    .{ .name = "AKST", .kind = .zone, .value = -9 * hour },  .{ .name = "AKDT", .kind = .dayzone, .value = -9 * hour },
    .{ .name = "HST", .kind = .zone, .value = -10 * hour },  .{ .name = "HAST", .kind = .zone, .value = -10 * hour },
    .{ .name = "HADT", .kind = .dayzone, .value = -10 * hour }, .{ .name = "SST", .kind = .zone, .value = -12 * hour },
    .{ .name = "WAT", .kind = .zone, .value = 1 * hour },    .{ .name = "CET", .kind = .zone, .value = 1 * hour },
    .{ .name = "CEST", .kind = .dayzone, .value = 1 * hour }, .{ .name = "MET", .kind = .zone, .value = 1 * hour },
    .{ .name = "MEZ", .kind = .zone, .value = 1 * hour },    .{ .name = "MEST", .kind = .dayzone, .value = 1 * hour },
    .{ .name = "MESZ", .kind = .dayzone, .value = 1 * hour }, .{ .name = "EET", .kind = .zone, .value = 2 * hour },
    .{ .name = "EEST", .kind = .dayzone, .value = 2 * hour }, .{ .name = "CAT", .kind = .zone, .value = 2 * hour },
    .{ .name = "SAST", .kind = .zone, .value = 2 * hour },   .{ .name = "EAT", .kind = .zone, .value = 3 * hour },
    .{ .name = "MSK", .kind = .zone, .value = 3 * hour },    .{ .name = "MSD", .kind = .dayzone, .value = 3 * hour },
    .{ .name = "IST", .kind = .zone, .value = 5 * hour + 1800 }, .{ .name = "SGT", .kind = .zone, .value = 8 * hour },
    .{ .name = "KST", .kind = .zone, .value = 9 * hour },    .{ .name = "JST", .kind = .zone, .value = 9 * hour },
    .{ .name = "GST", .kind = .zone, .value = 10 * hour },   .{ .name = "NZST", .kind = .zone, .value = 12 * hour },
    .{ .name = "NZDT", .kind = .dayzone, .value = 12 * hour },
};
const military = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const military_off = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 10, 11, 12, -1, -2, -3, -4, -5, -6, 0, -8, -9, -10, -11, -12, 0 };

const LocalZone = struct { name: [12]u8 = @splat(0), len: u8 = 0, isdst: i32 = 0, valid: bool = false };

const Rel = struct { year: i64 = 0, month: i64 = 0, day: i64 = 0, hour: i64 = 0, minutes: i64 = 0, seconds: i64 = 0, ns: i64 = 0 };

const MER_AM = 0;
const MER_PM = 1;
const MER24 = 2;

const Parser = struct {
    toks: []const Tok,
    pos: usize = 0,
    // parser_control
    day_ordinal: i64 = 0,
    day_number: i64 = 0,
    local_isdst: i32 = 0,
    time_zone: i64 = 0,
    meridian: i32 = MER24,
    year: TextInt = .{},
    month: i64 = 0,
    day: i64 = 0,
    hour: i64 = 0,
    minutes: i64 = 0,
    sec: i64 = 0,
    sec_ns: i64 = 0,
    rel: Rel = .{},
    timespec_seen: bool = false,
    rels_seen: bool = false,
    dates_seen: u32 = 0,
    days_seen: u32 = 0,
    j_zones_seen: u32 = 0,
    local_zones_seen: u32 = 0,
    dsts_seen: u32 = 0,
    times_seen: u32 = 0,
    zones_seen: u32 = 0,
    year_seen: bool = false,

    fn peek(p: *const Parser, k: usize) Tok {
        const i = p.pos + k;
        return if (i < p.toks.len) p.toks[i] else .{ .kind = .eof };
    }

    fn isCh(t: Tok, c: u8) bool {
        return t.kind == .ch and t.value == c;
    }

    fn isUnit(k: Kind) bool {
        return switch (k) {
            .year_unit, .month_unit, .hour_unit, .minute_unit, .sec_unit, .day_unit => true,
            else => false,
        };
    }

    fn digitsToDateTime(p: *Parser, ti: TextInt) void {
        if (p.dates_seen != 0 and p.year.digits == 0 and !p.rels_seen and (p.times_seen != 0 or ti.digits > 2)) {
            p.year_seen = true;
            p.year = ti;
        } else {
            if (ti.digits > 4) {
                p.dates_seen += 1;
                p.day = @mod(ti.value, 100);
                p.month = @mod(@divTrunc(ti.value, 100), 100);
                p.year.value = @divTrunc(ti.value, 10000);
                p.year.digits = ti.digits - 4;
            } else {
                p.times_seen += 1;
                if (ti.digits <= 2) {
                    p.hour = ti.value;
                    p.minutes = 0;
                } else {
                    p.hour = @divTrunc(ti.value, 100);
                    p.minutes = @mod(ti.value, 100);
                }
                p.sec = 0;
                p.sec_ns = 0;
                p.meridian = MER24;
            }
        }
    }

    fn applyRel(p: *Parser, r: Rel, factor: i64) bool {
        const f = factor;
        const fields = [_]struct { *i64, i64 }{
            .{ &p.rel.ns, r.ns },   .{ &p.rel.seconds, r.seconds }, .{ &p.rel.minutes, r.minutes },
            .{ &p.rel.hour, r.hour }, .{ &p.rel.day, r.day },       .{ &p.rel.month, r.month },
            .{ &p.rel.year, r.year },
        };
        for (fields) |fl| {
            const prod = @mulWithOverflow(fl[1], f);
            if (prod[1] != 0) return false;
            const sum = @addWithOverflow(fl[0].*, prod[0]);
            if (sum[1] != 0) return false;
            fl[0].* = sum[0];
        }
        p.rels_seen = true;
        return true;
    }

    fn setHhmmss(p: *Parser, h: i64, m: i64, s: i64, ns: i64) void {
        p.hour = h;
        p.minutes = m;
        p.sec = s;
        p.sec_ns = ns;
    }

    fn timeZoneHhmm(p: *Parser, s_in: TextInt, mm: i64) bool {
        var s = s_in;
        if (s.digits <= 2 and mm < 0) s.value *= 100;
        var n_minutes: i64 = undefined;
        if (mm < 0) {
            n_minutes = @divTrunc(s.value, 100) * 60 + @rem(s.value, 100);
        } else {
            const m = @mulWithOverflow(s.value, 60);
            if (m[1] != 0) return false;
            n_minutes = if (s.negative) m[0] - mm else m[0] + mm;
        }
        if (n_minutes < -24 * 60 or n_minutes > 24 * 60) return false;
        p.time_zone = n_minutes * 60;
        return true;
    }

    // o_colon_minutes: empty | ':' tUNUMBER ; returns -1 for empty.
    fn oColonMinutes(p: *Parser) i64 {
        if (isCh(p.peek(0), ':') and p.peek(1).kind == .unumber) {
            const v = p.peek(1).ti.value;
            p.pos += 2;
            return v;
        }
        return -1;
    }

    // zone_offset: tSNUMBER o_colon_minutes
    fn zoneOffset(p: *Parser) bool {
        const t = p.peek(0);
        if (t.kind != .snumber) return false;
        p.pos += 1;
        const mm = p.oColonMinutes();
        p.zones_seen += 1;
        return p.timeZoneHhmm(t.ti, mm);
    }

    fn secondsUnsigned(p: *Parser, sec: *i64, ns: *i64) bool {
        const t = p.peek(0);
        switch (t.kind) {
            .udecimal => {
                sec.* = t.sec;
                ns.* = t.ns;
                p.pos += 1;
                return true;
            },
            .unumber => {
                sec.* = t.ti.value;
                ns.* = 0;
                p.pos += 1;
                return true;
            },
            else => return false,
        }
    }

    // iso_8601_time / time forms starting at tUNUMBER (already known to be a time start).
    fn parseTimeFromUnumber(p: *Parser) bool {
        const h = p.peek(0);
        p.pos += 1;
        // tUNUMBER tMERIDIAN
        if (p.peek(0).kind == .meridian) {
            p.setHhmmss(h.ti.value, 0, 0, 0);
            p.meridian = @intCast(p.peek(0).value);
            p.pos += 1;
            return true;
        }
        if (isCh(p.peek(0), ':') and p.peek(1).kind == .unumber) {
            const m = p.peek(1);
            p.pos += 2;
            if (p.peek(0).kind == .meridian) {
                p.setHhmmss(h.ti.value, m.ti.value, 0, 0);
                p.meridian = @intCast(p.peek(0).value);
                p.pos += 1;
                return true;
            }
            if (isCh(p.peek(0), ':') and (p.peek(1).kind == .unumber or p.peek(1).kind == .udecimal)) {
                p.pos += 1;
                var s: i64 = 0;
                var ns: i64 = 0;
                _ = p.secondsUnsigned(&s, &ns);
                p.setHhmmss(h.ti.value, m.ti.value, s, ns);
                if (p.peek(0).kind == .meridian) {
                    p.meridian = @intCast(p.peek(0).value);
                    p.pos += 1;
                    return true;
                }
                p.meridian = MER24;
                if (p.peek(0).kind == .snumber) return p.zoneOffset();
                return true;
            }
            p.setHhmmss(h.ti.value, m.ti.value, 0, 0);
            p.meridian = MER24;
            if (p.peek(0).kind == .snumber) return p.zoneOffset();
            return true;
        }
        // tUNUMBER zone_offset
        p.setHhmmss(h.ti.value, 0, 0, 0);
        p.meridian = MER24;
        return p.zoneOffset();
    }

    fn relunitSnumber(p: *Parser) ?Rel {
        const t = p.peek(0);
        const u = p.peek(1);
        if (t.kind != .snumber or !isUnit(u.kind)) return null;
        p.pos += 2;
        var r: Rel = .{};
        const v = t.ti.value;
        switch (u.kind) {
            .year_unit => r.year = v,
            .month_unit => r.month = v,
            .day_unit => {
                const m = @mulWithOverflow(v, u.value);
                if (m[1] != 0) return null;
                r.day = m[0];
            },
            .hour_unit => r.hour = v,
            .minute_unit => r.minutes = v,
            else => r.seconds = v,
        }
        return r;
    }

    fn relunitFrom(p: *Parser, count: i64, u: Tok, has_count: bool) ?Rel {
        var r: Rel = .{};
        const c = if (has_count) count else 1;
        switch (u.kind) {
            .year_unit => r.year = c,
            .month_unit => r.month = c,
            .day_unit => {
                const m = @mulWithOverflow(if (has_count) count else u.value, if (has_count) u.value else 1);
                if (m[1] != 0) return null;
                r.day = m[0];
            },
            .hour_unit => r.hour = c,
            .minute_unit => r.minutes = c,
            else => r.seconds = c,
        }
        _ = p;
        return r;
    }

    // rel: relunit [tAGO] | dayshift ; called when the token starts a relunit.
    fn applyRelWithAgo(p: *Parser, r: Rel) bool {
        if (p.peek(0).kind == .ago) {
            const f = p.peek(0).value;
            p.pos += 1;
            return p.applyRel(r, f);
        }
        return p.applyRel(r, 1);
    }

    // Parses one item; false on syntax error.
    fn item(p: *Parser) bool {
        const t = p.peek(0);
        switch (t.kind) {
            .unumber => return p.itemUnumber(),
            .snumber => {
                const r = p.relunitSnumber() orelse return false;
                return p.applyRelWithAgo(r);
            },
            .sdecimal, .udecimal => {
                const u = p.peek(1);
                if (u.kind != .sec_unit) return false;
                p.pos += 2;
                const r: Rel = .{ .seconds = t.sec, .ns = t.ns };
                return p.applyRelWithAgo(r);
            },
            .ordinal => {
                const u = p.peek(1);
                if (u.kind == .day) {
                    p.pos += 2;
                    p.day_ordinal = t.value;
                    p.day_number = u.value;
                    p.days_seen += 1;
                    return true;
                }
                if (isUnit(u.kind)) {
                    p.pos += 2;
                    const r = p.relunitFrom(t.value, u, true) orelse return false;
                    return p.applyRelWithAgo(r);
                }
                return false;
            },
            .day => {
                p.pos += 1;
                if (isCh(p.peek(0), ',')) p.pos += 1;
                p.day_ordinal = 0;
                p.day_number = t.value;
                p.days_seen += 1;
                return true;
            },
            .month => return p.itemMonth(),
            .day_shift => {
                p.pos += 1;
                return p.applyRelWithAgo2(.{ .day = t.value });
            },
            .year_unit, .month_unit, .hour_unit, .minute_unit, .sec_unit, .day_unit => {
                p.pos += 1;
                const r = p.relunitFrom(0, t, false) orelse return false;
                return p.applyRelWithAgo(r);
            },
            .local_zone => {
                p.pos += 1;
                if (p.peek(0).kind == .dst) {
                    p.pos += 1;
                    p.local_isdst = 1;
                    p.dsts_seen += 1;
                } else p.local_isdst = @intCast(t.value);
                p.local_zones_seen += 1;
                return true;
            },
            .zone, .dayzone => return p.itemZone(),
            .ch => {
                if (t.value == 'J') {
                    p.pos += 1;
                    p.j_zones_seen += 1;
                    return true;
                }
                if (t.value == 'T') return p.itemZone();
                return false;
            },
            else => return false,
        }
    }

    // dayshift is a `rel` on its own (no tAGO).
    fn applyRelWithAgo2(p: *Parser, r: Rel) bool {
        return p.applyRel(r, 1);
    }

    fn itemZone(p: *Parser) bool {
        const t = p.peek(0);
        p.pos += 1;
        if (t.kind == .dayzone) {
            p.time_zone = t.value + 3600;
            p.zones_seen += 1;
            return true;
        }
        const base: i64 = if (t.kind == .zone) t.value else -7 * 3600; // 'T'
        // tZONE relunit_snumber / tZONE tSNUMBER o_colon_minutes / tZONE tDST
        if (p.peek(0).kind == .snumber) {
            if (isUnit(p.peek(1).kind)) {
                p.time_zone = base;
                const r = p.relunitSnumber() orelse return false;
                if (!p.applyRel(r, 1)) return false;
                p.zones_seen += 1;
                return true;
            }
            if (t.kind == .zone) {
                const s = p.peek(0);
                p.pos += 1;
                const mm = p.oColonMinutes();
                if (!p.timeZoneHhmm(s.ti, mm)) return false;
                p.time_zone += base;
                p.zones_seen += 1;
                return true;
            }
        }
        if (t.kind == .zone and p.peek(0).kind == .dst) {
            p.pos += 1;
            p.time_zone = base + 3600;
            p.zones_seen += 1;
            return true;
        }
        p.time_zone = base;
        p.zones_seen += 1;
        return true;
    }

    fn itemMonth(p: *Parser) bool {
        const m = p.peek(0);
        const a = p.peek(1);
        const b = p.peek(2);
        if (a.kind == .snumber and b.kind == .snumber) {
            // tMONTH tSNUMBER tSNUMBER  (JUN-17-1992)
            p.pos += 3;
            p.month = m.value;
            p.day = -a.ti.value;
            p.year.value = -b.ti.value;
            p.year.digits = b.ti.digits;
            p.dates_seen += 1;
            return true;
        }
        if (a.kind == .unumber) {
            p.month = m.value;
            if (isCh(b, ',') and p.peek(3).kind == .unumber) {
                p.day = a.ti.value;
                p.year = p.peek(3).ti;
                p.pos += 4;
            } else {
                p.day = a.ti.value;
                p.pos += 2;
            }
            p.dates_seen += 1;
            return true;
        }
        return false;
    }

    fn itemUnumber(p: *Parser) bool {
        const u = p.peek(0);
        const t1 = p.peek(1);
        const t2 = p.peek(2);
        switch (t1.kind) {
            .meridian => {
                if (!p.parseTimeFromUnumber()) return false;
                p.times_seen += 1;
                return true;
            },
            .ch => {
                if (t1.value == ':' and t2.kind == .unumber) {
                    if (!p.parseTimeFromUnumber()) return false;
                    p.times_seen += 1;
                    return true;
                }
                if (t1.value == '/') {
                    if (t2.kind != .unumber) return false;
                    const t3 = p.peek(3);
                    if (isCh(t3, '/') and p.peek(4).kind == .unumber) {
                        const y = p.peek(4).ti;
                        if (u.ti.digits >= 4) {
                            p.year = u.ti;
                            p.month = t2.ti.value;
                            p.day = y.value;
                        } else {
                            p.month = u.ti.value;
                            p.day = t2.ti.value;
                            p.year = y;
                        }
                        p.pos += 5;
                    } else {
                        p.month = u.ti.value;
                        p.day = t2.ti.value;
                        p.pos += 3;
                    }
                    p.dates_seen += 1;
                    return true;
                }
            },
            .month => {
                p.pos += 2;
                p.dates_seen += 1;
                if (t2.kind == .snumber) {
                    // 17-JUN-1992
                    p.day = u.ti.value;
                    p.month = t1.value;
                    p.year.value = -t2.ti.value;
                    p.year.digits = t2.ti.digits;
                    p.pos += 1;
                } else if (t2.kind == .unumber) {
                    p.day = u.ti.value;
                    p.month = t1.value;
                    p.year = t2.ti;
                    p.pos += 1;
                } else {
                    p.day = u.ti.value;
                    p.month = t1.value;
                }
                return true;
            },
            .snumber => {
                if (t2.kind == .snumber) {
                    // iso_8601_date, optionally followed by 'T' iso_8601_time
                    p.year = u.ti;
                    p.month = -t1.ti.value;
                    p.day = -t2.ti.value;
                    p.pos += 3;
                    if (isCh(p.peek(0), 'T') and p.peek(1).kind == .unumber) {
                        p.pos += 1;
                        if (!p.parseTimeFromUnumber()) return false;
                        p.times_seen += 1;
                    }
                    p.dates_seen += 1;
                    return true;
                }
                if (isUnit(t2.kind)) {
                    // hybrid: tUNUMBER relunit_snumber
                    p.pos += 1;
                    p.digitsToDateTime(u.ti);
                    const r = p.relunitSnumber() orelse return false;
                    return p.applyRelWithAgo2Hybrid(r);
                }
                // tUNUMBER zone_offset  (iso_8601_time)
                if (!p.parseTimeFromUnumber()) return false;
                p.times_seen += 1;
                return true;
            },
            .day => {
                p.pos += 2;
                p.day_ordinal = u.ti.value;
                p.day_number = t1.value;
                p.days_seen += 1;
                return true;
            },
            .year_unit, .month_unit, .hour_unit, .minute_unit, .sec_unit, .day_unit => {
                p.pos += 2;
                const r = p.relunitFrom(u.ti.value, t1, true) orelse return false;
                return p.applyRelWithAgo(r);
            },
            else => {},
        }
        // number
        p.pos += 1;
        p.digitsToDateTime(u.ti);
        return true;
    }

    fn applyRelWithAgo2Hybrid(p: *Parser, r: Rel) bool {
        // hybrid: tUNUMBER relunit_snumber -- no tAGO in the rule
        return p.applyRel(r, 1);
    }
};

fn lookupZone(local: []const LocalZone, name: []const u8) ?Table {
    for (universal_table) |t| if (std.mem.eql(u8, name, t.name)) return t;
    for (local) |l| if (l.valid and std.mem.eql(u8, name, l.name[0..l.len])) return .{ .name = name, .kind = .local_zone, .value = l.isdst };
    for (zone_table) |t| if (std.mem.eql(u8, name, t.name)) return t;
    return null;
}

fn lookupWord(local: []const LocalZone, word: []u8) ?Table {
    for (word) |*c| c.* = std.ascii.toUpper(c.*);
    for (meridian_table) |t| if (std.mem.eql(u8, word, t.name)) return t;
    const wl = word.len;
    const abbrev = wl == 3 or (wl == 4 and word[3] == '.');
    for (month_day_table) |t| {
        if (abbrev) {
            if (t.name.len >= 3 and std.mem.eql(u8, word[0..3], t.name[0..3])) return t;
        } else if (std.mem.eql(u8, word, t.name)) return t;
    }
    if (lookupZone(local, word)) |t| return t;
    if (std.mem.eql(u8, word, "DST")) return .{ .name = "DST", .kind = .dst, .value = 0 };
    for (time_units_table) |t| if (std.mem.eql(u8, word, t.name)) return t;
    if (wl > 0 and word[wl - 1] == 'S') {
        for (time_units_table) |t| if (std.mem.eql(u8, word[0 .. wl - 1], t.name)) return t;
    }
    for (relative_time_table) |t| if (std.mem.eql(u8, word, t.name)) return t;
    if (wl == 1) {
        if (std.mem.indexOfScalar(u8, military, word[0])) |i| {
            if (word[0] == 'J') return .{ .name = "J", .kind = .ch, .value = 'J' };
            if (word[0] == 'T') return .{ .name = "T", .kind = .ch, .value = 'T' };
            return .{ .name = "", .kind = .zone, .value = military_off[i] * 3600 };
        }
    }
    // Drop periods and retry the zone tables.
    var buf: [24]u8 = undefined;
    var n: usize = 0;
    var period = false;
    for (word) |c| {
        if (c == '.') {
            period = true;
        } else if (n < buf.len) {
            buf[n] = c;
            n += 1;
        }
    }
    if (period) if (lookupZone(local, buf[0..n])) |t| return t;
    return null;
}

fn isSpaceC(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

fn lex(gpa: std.mem.Allocator, text: []const u8, local: []const LocalZone) ![]Tok {
    var toks: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < text.len and isSpaceC(text[i])) i += 1;
        if (i >= text.len) break;
        const c = text[i];
        if (std.ascii.isDigit(c) or c == '-' or c == '+') {
            var p = i;
            var sign: i32 = 0;
            if (c == '-' or c == '+') {
                sign = if (c == '-') -1 else 1;
                p += 1;
                while (p < text.len and isSpaceC(text[p])) p += 1;
                i = p;
                if (p >= text.len or !std.ascii.isDigit(text[p])) continue;
            }
            var value: i64 = 0;
            const start = p;
            var overflow = false;
            while (p < text.len and std.ascii.isDigit(text[p])) : (p += 1) {
                const d: i64 = text[p] - '0';
                const m = @mulWithOverflow(value, 10);
                if (m[1] != 0) {
                    overflow = true;
                    break;
                }
                const a = if (sign < 0) @subWithOverflow(m[0], d) else @addWithOverflow(m[0], d);
                if (a[1] != 0) {
                    overflow = true;
                    break;
                }
                value = a[0];
            }
            if (overflow) {
                try toks.append(gpa, .{ .kind = .bad });
                return toks.toOwnedSlice(gpa);
            }
            if (p + 1 < text.len and (text[p] == '.' or text[p] == ',') and std.ascii.isDigit(text[p + 1])) {
                var s = value;
                p += 1;
                var ns: i64 = text[p] - '0';
                p += 1;
                var digits: usize = 2;
                while (digits <= 9) : (digits += 1) {
                    ns *= 10;
                    if (p < text.len and std.ascii.isDigit(text[p])) {
                        ns += text[p] - '0';
                        p += 1;
                    }
                }
                if (sign < 0) {
                    while (p < text.len and std.ascii.isDigit(text[p])) : (p += 1) {
                        if (text[p] != '0') {
                            ns += 1;
                            break;
                        }
                    }
                }
                while (p < text.len and std.ascii.isDigit(text[p])) p += 1;
                if (sign < 0 and ns != 0) {
                    s -= 1;
                    ns = 1000000000 - ns;
                }
                try toks.append(gpa, .{ .kind = if (sign != 0) .sdecimal else .udecimal, .sec = s, .ns = ns });
                i = p;
                continue;
            }
            try toks.append(gpa, .{
                .kind = if (sign != 0) .snumber else .unumber,
                .ti = .{ .negative = sign < 0, .value = value, .digits = p - start },
            });
            i = p;
            continue;
        }
        if (std.ascii.isAlphabetic(c)) {
            var buf: [20]u8 = undefined;
            var n: usize = 0;
            var p = i;
            while (p < text.len and (std.ascii.isAlphabetic(text[p]) or text[p] == '.')) : (p += 1) {
                if (n < buf.len - 1) {
                    buf[n] = text[p];
                    n += 1;
                }
            }
            i = p;
            const tp = lookupWord(local, buf[0..n]) orelse {
                try toks.append(gpa, .{ .kind = .bad });
                return toks.toOwnedSlice(gpa);
            };
            try toks.append(gpa, .{ .kind = tp.kind, .value = tp.value });
            continue;
        }
        if (c != '(') {
            try toks.append(gpa, .{ .kind = .ch, .value = c });
            i += 1;
            continue;
        }
        var count: i32 = 0;
        var done = false;
        while (!done) {
            if (i >= text.len) {
                done = true;
                break;
            }
            const ch = text[i];
            i += 1;
            if (ch == '(') count += 1 else if (ch == ')') count -= 1;
            if (count == 0) done = true;
        }
    }
    return toks.toOwnedSlice(gpa);
}

// ------------------------------------------------------------ evaluation

const BrokenDown = struct { year: i64, mon: i64, mday: i64, hour: i64, min: i64, sec: i64, isdst: i8 };

fn toHour(h: i64, meridian: i32) i64 {
    return switch (meridian) {
        MER_AM => if (h > 0 and h < 12) h else if (h == 12) 0 else -1,
        MER_PM => if (h > 0 and h < 12) h + 12 else if (h == 12) 12 else -1,
        else => if (h >= 0 and h < 24) h else -1,
    };
}

/// POSIX date/touch time operand: `[[CC]YY]MMDDhhmm[.ss]` (leading_year) or
/// `MMDDhhmm[[CC]YY][.ss]` (trailing year), interpreted in `zone`. Years
/// 69-99 are 19xx, 00-68 are 20xx; the result must round-trip through mktime.
pub fn posixTime(zone: *const tz.Zone, s: []const u8, leading_year: bool, now_year: i64) ?i64 {
    var body = s;
    var secs: i64 = 0;
    if (std.mem.indexOfScalar(u8, s, '.')) |dot| {
        body = s[0..dot];
        const ss = s[dot + 1 ..];
        if (ss.len != 2 or !std.ascii.isDigit(ss[0]) or !std.ascii.isDigit(ss[1])) return null;
        secs = (ss[0] - '0') * 10 + (ss[1] - '0');
        if (secs > 60) return null;
    }
    for (body) |c| if (!std.ascii.isDigit(c)) return null;
    if (body.len != 8 and body.len != 10 and body.len != 12) return null;
    const num = struct {
        fn f(t: []const u8) i64 {
            var v: i64 = 0;
            for (t) |c| v = v * 10 + (c - '0');
            return v;
        }
    }.f;
    var year = now_year;
    var rest = body;
    if (leading_year) {
        if (body.len == 10) {
            const yy = num(body[0..2]);
            year = if (yy < 69) 2000 + yy else 1900 + yy;
            rest = body[2..];
        } else if (body.len == 12) {
            year = num(body[0..4]);
            rest = body[4..];
        }
    } else if (body.len == 10) {
        const yy = num(body[8..10]);
        year = if (yy < 69) 2000 + yy else 1900 + yy;
        rest = body[0..8];
    } else if (body.len == 12) {
        year = num(body[8..12]);
        rest = body[0..8];
    }
    const mon = num(rest[0..2]);
    const day = num(rest[2..4]);
    const hh = num(rest[4..6]);
    const mi = num(rest[6..8]);
    if (mon < 1 or mon > 12 or day < 1 or day > 31 or hh > 23 or mi > 59) return null;
    // Seconds 60 and 61 (leap seconds) are added after resolving the minute.
    const t = tz.mktimeIsdst(zone, year, mon - 1, day, hh, mi, @min(secs, 59), -1);
    const back = tz.localtime(zone, t);
    if (back.mon != mon or back.mday != day or back.hour != hh or back.min != mi) return null;
    return t + (secs - @min(secs, 59));
}

/// Parse `text` relative to `now` in `zone`. Returns null for an invalid date.
/// `tzstring` is the TZ value the zone came from (used for a TZ="..." prefix
/// inside the text, which loads another zone).
pub fn parse(gpa: std.mem.Allocator, io: Io, text_in: []const u8, now: Timespec, zone_default: *const tz.Zone) ?Timespec {
    var text = text_in;
    while (text.len > 0 and isSpaceC(text[0])) text = text[1..];
    var own_zone: ?tz.Zone = null;
    defer if (own_zone) |*z| z.deinit();
    var zone: *const tz.Zone = zone_default;

    if (std.mem.startsWith(u8, text, "TZ=\"")) {
        var s: usize = 4;
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(gpa);
        while (s < text.len) {
            const ch = text[s];
            if (ch == '\\') {
                s += 1;
                if (s >= text.len or !(text[s] == '\\' or text[s] == '"')) break;
                name.append(gpa, text[s]) catch return null;
                s += 1;
            } else if (ch == '"') {
                own_zone = tz.load(gpa, io, name.items);
                zone = &own_zone.?;
                text = text[s + 1 ..];
                while (text.len > 0 and isSpaceC(text[0])) text = text[1..];
                break;
            } else {
                name.append(gpa, ch) catch return null;
                s += 1;
            }
        }
    }
    if (text.len == 0) text = "0";

    // Local zone abbreviations (this zone's names for standard and daylight time).
    var local: [2]LocalZone = .{ .{}, .{} };
    const cur = tz.localtime(zone, now.sec);
    const populate = struct {
        fn f(l: *[2]LocalZone, idx: usize, tm: tz.Tm) void {
            l[idx].valid = tm.zone_len > 0;
            l[idx].len = tm.zone_len;
            l[idx].name = tm.zone;
            l[idx].isdst = @intFromBool(tm.isdst);
        }
    }.f;
    populate(&local, 0, cur);
    var q: i64 = 1;
    while (q <= 3) : (q += 1) {
        const probe = now.sec + q * 90 * 86400;
        const ptm = tz.localtime(zone, probe);
        if (!local[0].valid or @as(i32, @intFromBool(ptm.isdst)) != local[0].isdst) {
            populate(&local, 1, ptm);
            if (local[1].valid) {
                if (std.mem.eql(u8, local[0].name[0..local[0].len], local[1].name[0..local[1].len])) {
                    local[0].isdst = -1;
                    local[1].valid = false;
                }
                break;
            }
        }
    }

    const toks = lex(gpa, text, &local) catch return null;
    defer gpa.free(toks);
    var ps: Parser = .{ .toks = toks };
    ps.year = .{ .value = cur.year, .digits = 0 };
    ps.month = cur.mon;
    ps.day = cur.mday;
    ps.hour = cur.hour;
    ps.minutes = cur.min;
    ps.sec = cur.sec;
    ps.sec_ns = now.nsec;
    const start_isdst: i8 = @intFromBool(cur.isdst);

    // Parse.
    for (toks) |t| if (t.kind == .bad) return null;
    if (toks.len > 0 and Parser.isCh(toks[0], '@')) {
        // timespec: '@' seconds
        if (toks.len != 2) return null;
        const t = toks[1];
        switch (t.kind) {
            .sdecimal, .udecimal => return .{ .sec = t.sec, .nsec = @intCast(t.ns) },
            .snumber, .unumber => return .{ .sec = t.ti.value, .nsec = 0 },
            else => return null,
        }
    }
    while (ps.pos < toks.len) {
        if (!ps.item()) return null;
    }

    // ---- parse_datetime_body, after the parse ----
    if (ps.times_seen > 1 or ps.dates_seen > 1 or ps.days_seen > 1 or ps.dsts_seen > 1 or (ps.j_zones_seen + ps.local_zones_seen + ps.zones_seen) > 1) return null;
    if (ps.times_seen | ps.dates_seen | ps.days_seen | ps.dsts_seen | (ps.j_zones_seen + ps.local_zones_seen + ps.zones_seen) > 1) return null;

    var tm: BrokenDown = undefined;
    // two-digit years: XPG4 pivot
    var year = ps.year.value;
    if (year >= 0 and ps.year.digits == 2) year += if (year < 69) 2000 else 1900;
    tm.year = year;
    tm.mon = ps.month - 1;
    tm.mday = ps.day;
    var result_ns: i64 = ps.sec_ns;
    if (ps.times_seen != 0 or (ps.rels_seen and ps.dates_seen == 0 and ps.days_seen == 0)) {
        const h = toHour(ps.hour, ps.meridian);
        if (h < 0) return null;
        tm.hour = h;
        tm.min = ps.minutes;
        tm.sec = ps.sec;
    } else {
        tm.hour = 0;
        tm.min = 0;
        tm.sec = 0;
        result_ns = 0;
    }
    tm.isdst = start_isdst;
    if (ps.dates_seen | ps.days_seen | ps.times_seen != 0) tm.isdst = -1;
    if (ps.local_zones_seen != 0) tm.isdst = @intCast(ps.local_isdst);
    const tm0 = tm;

    var start = tz.mktimeIsdst(zone, tm.year, tm.mon, tm.mday, tm.hour, tm.min, tm.sec, tm.isdst);
    var norm = tz.localtime(zone, start);
    const ok_fields = struct {
        fn f(a: BrokenDown, b: tz.Tm) bool {
            return a.year == b.year and a.mon == @as(i64, b.mon) - 1 and a.mday == b.mday and a.hour == b.hour and a.min == b.min and a.sec == b.sec;
        }
    }.f;
    if (!ok_fields(tm0, norm)) {
        var repaired = false;
        if (ps.zones_seen != 0) {
            // Retry in a fixed-offset zone to avoid false errors near time_t limits.
            var fixed = tz.Zone.utc(gpa);
            fixed.rule = .{ .std = .{ .utoff = @intCast(ps.time_zone), .isdst = false } };
            const s2 = tz.mktimeIsdst(&fixed, tm0.year, tm0.mon, tm0.mday, tm0.hour, tm0.min, tm0.sec, tm0.isdst);
            const n2 = tz.localtime(&fixed, s2);
            if (ok_fields(tm0, n2)) {
                // GNU continues with the struct tm and instant from this
                // fixed-offset mktime; the zone adjustment below then cancels.
                repaired = true;
                start = s2;
                norm = n2;
            }
        }
        if (!repaired) return null;
    }
    // tm now holds the normalised fields.
    tm = .{ .year = norm.year, .mon = @as(i64, norm.mon) - 1, .mday = norm.mday, .hour = norm.hour, .min = norm.min, .sec = norm.sec, .isdst = @intFromBool(norm.isdst) };
    var wday: i64 = norm.wday;

    if (ps.days_seen != 0 and ps.dates_seen == 0) {
        const day_ordinal = ps.day_ordinal - @as(i64, @intFromBool(ps.day_ordinal > 0 and wday != ps.day_number));
        const m = @mulWithOverflow(day_ordinal, 7);
        if (m[1] != 0) return null;
        const dayincr = m[0] + @mod(ps.day_number - wday + 7, 7);
        tm.mday += dayincr;
        start = tz.mktimeIsdst(zone, tm.year, tm.mon, tm.mday, tm.hour, tm.min, tm.sec, -1);
        norm = tz.localtime(zone, start);
        tm = .{ .year = norm.year, .mon = @as(i64, norm.mon) - 1, .mday = norm.mday, .hour = norm.hour, .min = norm.min, .sec = norm.sec, .isdst = @intFromBool(norm.isdst) };
        wday = norm.wday;
    }

    if (ps.rel.year != 0 or ps.rel.month != 0 or ps.rel.day != 0) {
        const y = @addWithOverflow(tm.year, ps.rel.year);
        const mo = @addWithOverflow(tm.mon, ps.rel.month);
        const d = @addWithOverflow(tm.mday, ps.rel.day);
        if (y[1] != 0 or mo[1] != 0 or d[1] != 0) return null;
        start = tz.mktimeIsdst(zone, y[0], mo[0], d[0], tm0.hour, tm0.min, tm0.sec, tm0.isdst);
        norm = tz.localtime(zone, start);
    }

    if (ps.zones_seen != 0) {
        const utcoff: i64 = norm.gmtoff;
        const delta = @subWithOverflow(ps.time_zone, utcoff);
        if (delta[1] != 0) return null;
        const t1 = @subWithOverflow(start, delta[0]);
        if (t1[1] != 0) return null;
        start = t1[0];
    }

    const sum_ns = result_ns + ps.rel.ns;
    const normalized_ns = @mod(sum_ns, 1000000000);
    const d4 = @divFloor(sum_ns - normalized_ns, 1000000000);
    const d1 = @mulWithOverflow(ps.rel.hour, 3600);
    const d2 = @mulWithOverflow(ps.rel.minutes, 60);
    if (d1[1] != 0 or d2[1] != 0) return null;
    var t = start;
    for ([_]i64{ d1[0], d2[0], ps.rel.seconds, d4 }) |dv| {
        const a = @addWithOverflow(t, dv);
        if (a[1] != 0) return null;
        t = a[0];
    }
    return .{ .sec = t, .nsec = @intCast(normalized_ns) };
}

test "parse basics" {
    const t = std.testing;
    var z = tz.Zone.utc(t.allocator);
    const r = parse(t.allocator, undefined, "2024-02-29", .{ .sec = 1700000000, .nsec = 0 }, &z);
    try t.expect(r != null);
    try t.expectEqual(@as(i64, 1709164800), r.?.sec);
}
