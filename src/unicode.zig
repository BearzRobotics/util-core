//! Minimal UTF-8 and Unicode support for locale-aware regexes and case
//! conversion: decoding, simple case mapping and translation of codepoint sets
//! into byte-level patterns for the regex package (which works on bytes).
//! Class membership follows glibc's C.UTF-8 as closely as unicodedata allows.

const std = @import("std");
const tables = @import("unicode_tables.zig");

pub const Decoded = struct { cp: u32, len: u8, valid: bool };

/// Decode one character at `s[i..]`. Invalid or truncated sequences decode
/// as a single invalid byte.
pub fn decode(s: []const u8, i: usize) Decoded {
    const b = s[i];
    if (b < 0x80) return .{ .cp = b, .len = 1, .valid = true };
    var need: u8 = 0;
    var cp: u32 = 0;
    var min: u32 = 0;
    if (b >= 0xc2 and b <= 0xdf) {
        need = 1;
        cp = b & 0x1f;
        min = 0x80;
    } else if (b >= 0xe0 and b <= 0xef) {
        need = 2;
        cp = b & 0x0f;
        min = 0x800;
    } else if (b >= 0xf0 and b <= 0xf4) {
        need = 3;
        cp = b & 0x07;
        min = 0x10000;
    } else return .{ .cp = b, .len = 1, .valid = false };
    if (i + need >= s.len) return .{ .cp = b, .len = 1, .valid = false };
    var k: u8 = 1;
    while (k <= need) : (k += 1) {
        const c = s[i + k];
        if (c & 0xc0 != 0x80) return .{ .cp = b, .len = 1, .valid = false };
        cp = (cp << 6) | (c & 0x3f);
    }
    if (cp < min or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return .{ .cp = b, .len = 1, .valid = false };
    return .{ .cp = cp, .len = need + 1, .valid = true };
}

pub fn encode(cp: u32, buf: *[4]u8) []const u8 {
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return buf[0..1];
    }
    if (cp < 0x800) {
        buf[0] = @intCast(0xc0 | (cp >> 6));
        buf[1] = @intCast(0x80 | (cp & 0x3f));
        return buf[0..2];
    }
    if (cp < 0x10000) {
        buf[0] = @intCast(0xe0 | (cp >> 12));
        buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3f));
        buf[2] = @intCast(0x80 | (cp & 0x3f));
        return buf[0..3];
    }
    buf[0] = @intCast(0xf0 | (cp >> 18));
    buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3f));
    buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3f));
    buf[3] = @intCast(0x80 | (cp & 0x3f));
    return buf[0..4];
}

fn lookup(table: []const [2]u32, cp: u32) ?u32 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (table[mid][0] == cp) return table[mid][1];
        if (table[mid][0] < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

pub fn toUpper(cp: u32) u32 {
    if (cp < 0x80) return if (cp >= 'a' and cp <= 'z') cp - 32 else cp;
    return lookup(&tables.to_upper, cp) orelse cp;
}

pub fn toLower(cp: u32) u32 {
    if (cp == 0x130) return 'i'; // glibc maps the dotted capital I to plain i
    if (cp < 0x80) return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    return lookup(&tables.to_lower, cp) orelse cp;
}

pub const Range = [2]u32;

pub const Class = enum { alpha, alnum, upper, lower, punct, space, blank, print, graph, cntrl, digit, xdigit };

pub fn classFromName(name: []const u8) ?Class {
    return std.meta.stringToEnum(Class, name);
}

const ascii_digit = [_]Range{.{ '0', '9' }};
const ascii_xdigit = [_]Range{ .{ '0', '9' }, .{ 'A', 'F' }, .{ 'a', 'f' } };

/// Codepoint ranges of a class: ASCII part from the C locale rules, the rest
/// from the generated tables.
pub fn classRanges(c: Class) []const Range {
    return switch (c) {
        .alpha => &tables.alpha,
        .alnum => &tables.alnum,
        .upper => &tables.upper,
        .lower => &tables.lower,
        .punct => &tables.punct,
        .space => &tables.space,
        .blank => &tables.blank,
        .print => &tables.print,
        .graph => &tables.graph,
        .cntrl => &tables.cntrl,
        .digit => &ascii_digit,
        .xdigit => &ascii_xdigit,
    };
}

/// A set of codepoints kept as sorted, merged ranges.
pub const Set = struct {
    ranges: std.ArrayList(Range) = .empty,

    pub fn deinit(s: *Set, gpa: std.mem.Allocator) void {
        s.ranges.deinit(gpa);
    }

    pub fn add(s: *Set, gpa: std.mem.Allocator, lo: u32, hi: u32) !void {
        try s.ranges.append(gpa, .{ lo, hi });
    }

    pub fn addAll(s: *Set, gpa: std.mem.Allocator, rs: []const Range) !void {
        try s.ranges.appendSlice(gpa, rs);
    }

    pub fn normalize(s: *Set) void {
        const items = s.ranges.items;
        std.mem.sort(Range, items, {}, struct {
            fn lt(_: void, a: Range, b: Range) bool {
                return a[0] < b[0];
            }
        }.lt);
        var out: usize = 0;
        for (items) |r| {
            if (out > 0 and r[0] <= items[out - 1][1] +| 1) {
                if (r[1] > items[out - 1][1]) items[out - 1][1] = r[1];
            } else {
                items[out] = r;
                out += 1;
            }
        }
        s.ranges.shrinkRetainingCapacity(out);
    }
};

fn hexByte(out: *std.ArrayList(u8), gpa: std.mem.Allocator, b: u8) !void {
    const hex = "0123456789abcdef";
    try out.appendSlice(gpa, &.{ '\\', 'x', hex[b >> 4], hex[b & 15] });
}

fn byteRange(out: *std.ArrayList(u8), gpa: std.mem.Allocator, lo: u8, hi: u8) !void {
    if (lo == hi) {
        try hexByte(out, gpa, lo);
        return;
    }
    try out.append(gpa, '[');
    try hexByte(out, gpa, lo);
    try out.append(gpa, '-');
    try hexByte(out, gpa, hi);
    try out.append(gpa, ']');
}

const Seq = struct { n: u8, lo: [4]u8, hi: [4]u8 };

fn splitInto(list: *std.ArrayList(Seq), gpa: std.mem.Allocator, lo_in: u32, hi_in: u32) !void {
    var lo = lo_in;
    var hi = hi_in;
    if (lo > hi) return;
    // surrogates are not characters
    if (lo <= 0xdfff and hi >= 0xd800) {
        if (lo < 0xd800) try splitInto(list, gpa, lo, 0xd7ff);
        if (hi > 0xdfff) try splitInto(list, gpa, 0xe000, hi);
        return;
    }
    // split by encoded length
    const bounds = [_]u32{ 0x7f, 0x7ff, 0xffff };
    for (bounds) |bd| {
        if (lo <= bd and hi > bd) {
            try splitInto(list, gpa, lo, bd);
            try splitInto(list, gpa, bd + 1, hi);
            return;
        }
    }
    if (hi < 0x80) {
        var s = Seq{ .n = 1, .lo = undefined, .hi = undefined };
        s.lo[0] = @intCast(lo);
        s.hi[0] = @intCast(hi);
        try list.append(gpa, s);
        return;
    }
    var i: u5 = 1;
    while (i < 4) : (i += 1) {
        const m: u32 = (@as(u32, 1) << (6 * i)) - 1;
        if ((lo & ~m) != (hi & ~m)) {
            if ((lo & m) != 0) {
                try splitInto(list, gpa, lo, lo | m);
                try splitInto(list, gpa, (lo | m) + 1, hi);
                return;
            }
            if ((hi & m) != m) {
                try splitInto(list, gpa, lo, (hi & ~m) - 1);
                try splitInto(list, gpa, hi & ~m, hi);
                return;
            }
        }
    }
    lo = lo_in;
    hi = hi_in;
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    const ea = encode(lo, &a);
    const eb = encode(hi, &b);
    var s = Seq{ .n = @intCast(ea.len), .lo = undefined, .hi = undefined };
    for (0..ea.len) |k| {
        s.lo[k] = ea[k];
        s.hi[k] = eb[k];
    }
    try list.append(gpa, s);
}

fn emitSeqs(out: *std.ArrayList(u8), gpa: std.mem.Allocator, seqs: []const Seq, depth: u8) !void {
    // Sequences sharing the same range at `depth` are grouped.
    var i: usize = 0;
    var first = true;
    while (i < seqs.len) {
        var j = i + 1;
        while (j < seqs.len and seqs[j].lo[depth] == seqs[i].lo[depth] and seqs[j].hi[depth] == seqs[i].hi[depth] and seqs[j].n > depth + 1 and seqs[i].n > depth + 1) : (j += 1) {}
        if (!first) try out.append(gpa, '|');
        first = false;
        try byteRange(out, gpa, seqs[i].lo[depth], seqs[i].hi[depth]);
        if (seqs[i].n > depth + 1) {
            if (j - i == 1) {
                // a single tail: emit the remaining bytes directly
                var d = depth + 1;
                while (d < seqs[i].n) : (d += 1) try byteRange(out, gpa, seqs[i].lo[d], seqs[i].hi[d]);
            } else {
                try out.appendSlice(gpa, "(?:");
                try emitSeqs(out, gpa, seqs[i..j], depth + 1);
                try out.append(gpa, ')');
            }
        }
        i = j;
    }
}

/// Append a Perl-dialect pattern (one unit, in a non-capturing group)
/// matching exactly the characters of `set` encoded as UTF-8.
pub fn appendSetRegex(gpa: std.mem.Allocator, out: *std.ArrayList(u8), set: *Set) !void {
    set.normalize();
    var seqs: std.ArrayList(Seq) = .empty;
    defer seqs.deinit(gpa);
    for (set.ranges.items) |r| try splitInto(&seqs, gpa, r[0], r[1]);
    if (seqs.items.len == 0) {
        // matches nothing
        try out.appendSlice(gpa, "(?!)");
        return;
    }
    try out.appendSlice(gpa, "(?:");
    // Group by length so equal-prefix sequences sit together.
    var n: u8 = 1;
    var first = true;
    while (n <= 4) : (n += 1) {
        var start: usize = 0;
        var cnt: usize = 0;
        var tmp: std.ArrayList(Seq) = .empty;
        defer tmp.deinit(gpa);
        for (seqs.items) |s| if (s.n == n) {
            try tmp.append(gpa, s);
            cnt += 1;
        };
        _ = &start;
        if (cnt == 0) continue;
        if (!first) try out.append(gpa, '|');
        first = false;
        try emitSeqs(out, gpa, tmp.items, 0);
    }
    try out.append(gpa, ')');
}

/// The set as top-level alternatives of fixed width (no nested groups), as a
/// look-behind requires. Not wrapped: the caller supplies the parentheses.
pub fn appendSetFlat(gpa: std.mem.Allocator, out: *std.ArrayList(u8), set: *Set) !void {
    set.normalize();
    var seqs: std.ArrayList(Seq) = .empty;
    defer seqs.deinit(gpa);
    for (set.ranges.items) |r| try splitInto(&seqs, gpa, r[0], r[1]);
    for (seqs.items, 0..) |sq, idx| {
        if (idx > 0) try out.append(gpa, '|');
        for (0..sq.n) |k| try byteRange(out, gpa, sq.lo[k], sq.hi[k]);
    }
}

/// Any one valid UTF-8 character.
pub const any_char = "(?:[\\x00-\\x7f]|[\\xc2-\\xdf][\\x80-\\xbf]|[\\xe0-\\xef][\\x80-\\xbf][\\x80-\\xbf]|[\\xf0-\\xf4][\\x80-\\xbf][\\x80-\\xbf][\\x80-\\xbf])";

test "decode and encode round trip" {
    var buf: [4]u8 = undefined;
    for ([_]u32{ 0x41, 0xe9, 0x20ac, 0x1f600 }) |cp| {
        const e = encode(cp, &buf);
        const d = decode(e, 0);
        try std.testing.expect(d.valid and d.cp == cp and d.len == e.len);
    }
    try std.testing.expect(!decode("\xc3", 0).valid);
    try std.testing.expect(!decode("\x80", 0).valid);
}

test "case mapping" {
    try std.testing.expectEqual(@as(u32, 0xc9), toUpper(0xe9));
    try std.testing.expectEqual(@as(u32, 0xe9), toLower(0xc9));
    try std.testing.expectEqual(@as(u32, 'A'), toUpper('a'));
}
