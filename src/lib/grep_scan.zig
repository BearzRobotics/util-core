// SPDX-License-Identifier: GPL-2.0-or-later
//! Pattern analysis for grep's buffer-wide pre-filter. Given one translated
//! pattern (Perl-dialect source, as `posixre` emits it) this finds
//!
//!  - a literal every match must contain (`lit`), so whole buffers can be
//!    searched with a vectorised substring scan and only lines around hits
//!    reach the regex;
//!  - whether the pattern is nothing but that literal (`exact`), where a hit
//!    needs no regex run at all;
//!  - whether the pattern is `scannable`: it has no `^ $ \b \A \z`, look-around
//!    or back-reference, so a match in one line is also a match in the
//!    buffer holding that line, and a DFA may search the buffer instead of
//!    each line (a hit that spans two lines only costs one extra check).
//!
//! The analysis is conservative: anything it does not understand yields no
//! literal and `scannable = false`.

const std = @import("std");

pub const Opts = struct {
    icase: bool,
    utf8: bool,
    /// The source is for the regex package's UTF-8 mode: a quantifier takes
    /// a whole character, and `\xHH` is a code point.
    native: bool = false,
    /// The line terminator; a literal never contains it.
    eol: u8,
};

pub const Info = struct {
    /// Longest literal that every match contains (owned; empty = none).
    lit: []u8 = &.{},
    exact: bool = false,
    scannable: bool = false,
    /// The pattern is `^LIT`, `LIT$` or `^LIT$`; `exact` then describes LIT.
    anchor_start: bool = false,
    anchor_end: bool = false,

    pub fn deinit(i: *Info, gpa: std.mem.Allocator) void {
        gpa.free(i.lit);
        i.* = .{};
    }
};

/// In native source, whether `b[i]` is part of a non-ASCII character that a
/// quantifier applies to. Byte by byte the analysis would get that wrong.
fn quantifiedChar(b: []const u8, i: usize) bool {
    if (b[i] < 0x80) return false;
    var j = i + 1;
    while (j < b.len and b[j] & 0xc0 == 0x80) j += 1;
    return j < b.len and std.mem.indexOfScalar(u8, "*+?{", b[j]) != null;
}

fn hexVal(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// Index of the byte after the `]` that closes the class starting at `i`.
fn classEnd(b: []const u8, i: usize) ?usize {
    var j = i + 1;
    if (j < b.len and b[j] == '^') j += 1;
    if (j < b.len and b[j] == ']') j += 1;
    while (j < b.len and b[j] != ']') {
        if (b[j] == '[' and j + 1 < b.len and (b[j + 1] == ':' or b[j + 1] == '.' or b[j + 1] == '=')) {
            const close = std.mem.indexOfPos(u8, b, j + 2, &.{ b[j + 1], ']' }) orelse return null;
            j = close + 2;
        } else if (b[j] == '\\') {
            j += 2;
        } else j += 1;
    }
    if (j >= b.len) return null;
    return j + 1;
}

/// Index just after the group opened at `i`.
fn groupEnd(b: []const u8, i: usize) ?usize {
    var depth: usize = 0;
    var j = i;
    while (j < b.len) {
        switch (b[j]) {
            '\\' => j += 2,
            '[' => j = classEnd(b, j) orelse return null,
            '(' => {
                depth += 1;
                j += 1;
            },
            ')' => {
                depth -= 1;
                j += 1;
                if (depth == 0) return j;
            },
            else => j += 1,
        }
    }
    return null;
}

/// Does `inner` (the inside of a group) have a `|` outside nested groups?
fn hasTopAlt(inner: []const u8) bool {
    var j: usize = 0;
    while (j < inner.len) {
        switch (inner[j]) {
            '\\' => j += 2,
            '[' => j = classEnd(inner, j) orelse return true,
            '(' => j = groupEnd(inner, j) orelse return true,
            '|' => return true,
            else => j += 1,
        }
    }
    return false;
}

/// `body` with every `(?:X)` that holds no alternation and carries no
/// quantifier replaced by X (posixre writes a UTF-8 literal as such a group).
fn flatten(gpa: std.mem.Allocator, body: []const u8, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len) {
            try out.appendSlice(gpa, body[i .. i + 2]);
            i += 2;
        } else if (c == '[') {
            const e = classEnd(body, i) orelse body.len;
            try out.appendSlice(gpa, body[i..e]);
            i = e;
        } else if (c == '(' and std.mem.startsWith(u8, body[i..], "(?:")) {
            const e = groupEnd(body, i) orelse body.len;
            const inner = if (e <= body.len and e >= i + 4) body[i + 3 .. e - 1] else "";
            const quantified = e < body.len and std.mem.indexOfScalar(u8, "*+?{", body[e]) != null;
            if (e <= body.len and e >= i + 4 and !quantified and !hasTopAlt(inner)) {
                try flatten(gpa, inner, out);
            } else try out.appendSlice(gpa, body[i..e]);
            i = e;
        } else {
            try out.append(gpa, c);
            i += 1;
        }
    }
}

pub const Lit = struct { text: []u8, exact: bool };

/// Required literals of each top-level alternative of `body` appended to
/// `out` (owned); false when some alternative has none (then `out` may hold
/// partial results the caller frees).
pub fn literals(gpa: std.mem.Allocator, body: []const u8, o: Opts, out: *std.ArrayList(Lit)) std.mem.Allocator.Error!bool {
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(gpa);
    try flatten(gpa, body, &flat);
    var start: usize = 0;
    var j: usize = 0;
    const b = flat.items;
    while (j <= b.len) {
        const at_end = j == b.len;
        var split = at_end;
        if (!at_end) switch (b[j]) {
            '\\' => {
                j += 2;
                continue;
            },
            '[' => {
                j = classEnd(b, j) orelse return false;
                continue;
            },
            '(' => {
                j = groupEnd(b, j) orelse return false;
                continue;
            },
            '|' => split = true,
            else => {},
        };
        if (split) {
            var info = try analyze(gpa, b[start..j], o);
            if (info.lit.len == 0) {
                info.deinit(gpa);
                return false;
            }
            const exact = info.exact and !info.anchor_start and !info.anchor_end;
            try out.append(gpa, .{ .text = info.lit, .exact = exact });
            info.lit = &.{};
            start = j + 1;
        }
        j += 1;
    }
    return true;
}

/// Caps of `language`.
pub const lang_max_strings = 4096;
pub const lang_max_len = 256;

const Lang = struct {
    arena: std.mem.Allocator,
    o: Opts,
    src: []const u8,
    i: usize = 0,

    const Set = std.ArrayList([]const u8);

    fn byteOk(l: *const Lang, b: u8) bool {
        return literalOk(b, l.o);
    }

    fn alt(l: *Lang, depth: usize) ?Set {
        if (depth > 32) return null;
        var out: Set = .empty;
        while (true) {
            var sq = l.seq(depth) orelse return null;
            out.appendSlice(l.arena, sq.items) catch return null;
            sq.deinit(l.arena);
            if (out.items.len > lang_max_strings) return null;
            if (l.i < l.src.len and l.src[l.i] == '|') {
                l.i += 1;
                continue;
            }
            return out;
        }
    }

    fn seq(l: *Lang, depth: usize) ?Set {
        var cur: Set = .empty;
        cur.append(l.arena, "") catch return null;
        while (l.i < l.src.len) {
            const c = l.src[l.i];
            if (c == '|' or c == ')') break;
            var atom: Set = .empty;
            switch (c) {
                '(' => {
                    l.i += 1;
                    if (l.i < l.src.len and l.src[l.i] == '?') {
                        if (!(l.i + 1 < l.src.len and l.src[l.i + 1] == ':')) return null;
                        l.i += 2;
                    }
                    atom = l.alt(depth + 1) orelse return null;
                    if (l.i >= l.src.len or l.src[l.i] != ')') return null;
                    l.i += 1;
                },
                '[' => {
                    const e = classEnd(l.src, l.i) orelse return null;
                    const inner = l.src[l.i + 1 .. e - 1];
                    l.i = e;
                    if (inner.len == 0 or inner[0] == '^' or inner.len > 40) return null;
                    if (l.o.native) for (inner) |x| if (x >= 0x80) return null;
                    var k: usize = 0;
                    while (k < inner.len) {
                        const lo = inner[k];
                        if (lo == '[' or lo == '\\') return null;
                        var hi = lo;
                        if (k + 2 < inner.len and inner[k + 1] == '-') {
                            hi = inner[k + 2];
                            if (hi == '[' or hi == '\\' or hi < lo) return null;
                            k += 3;
                        } else k += 1;
                        if (@as(usize, hi) - lo > 16) return null;
                        var b: usize = lo;
                        while (b <= hi) : (b += 1) {
                            if (!l.byteOk(@intCast(b))) return null;
                            const one = l.arena.dupe(u8, &.{@as(u8, @intCast(b))}) catch return null;
                            atom.append(l.arena, one) catch return null;
                        }
                    }
                    if (atom.items.len > 32) return null;
                },
                '.', '^', '$', '*', '+', '?', '{' => return null,
                else => {
                    if (l.o.native and quantifiedChar(l.src, l.i)) return null;
                    var b = c;
                    l.i += 1;
                    if (c == '\\') {
                        if (l.i >= l.src.len) return null;
                        const n = l.src[l.i];
                        l.i += 1;
                        if (n == 'x') {
                            if (l.i + 1 >= l.src.len) return null;
                            const hi = hexVal(l.src[l.i]) orelse return null;
                            const lo = hexVal(l.src[l.i + 1]) orelse return null;
                            b = hi * 16 + lo;
                            if (l.o.native and b >= 0x80) return null;
                            l.i += 2;
                        } else if (std.ascii.isAlphanumeric(n)) return null else b = n;
                    }
                    if (!l.byteOk(b)) return null;
                    atom.append(l.arena, l.arena.dupe(u8, &.{b}) catch return null) catch return null;
                },
            }
            if (l.i < l.src.len and l.src[l.i] == '?') {
                l.i += 1;
                atom.append(l.arena, "") catch return null;
            }
            if (l.i < l.src.len and std.mem.indexOfScalar(u8, "*+?{", l.src[l.i]) != null) return null;
            var next: Set = .empty;
            for (cur.items) |x| for (atom.items) |y| {
                if (x.len + y.len > lang_max_len or next.items.len >= lang_max_strings) return null;
                const z = l.arena.alloc(u8, x.len + y.len) catch return null;
                @memcpy(z[0..x.len], x);
                @memcpy(z[x.len..], y);
                next.append(l.arena, z) catch return null;
            };
            cur = next;
        }
        return cur;
    }
};

/// The finite set of strings `body` matches, when it is built only from
/// literals, `(?:...)`/`(...)` groups, `|`, `?` on an atom and small plain
/// classes, has no anchors, and no string is empty: a line then matches
/// exactly when it contains one of them. Appends them (owned) to `out`;
/// false (with nothing the caller must free beyond `out`) when the pattern
/// is outside that shape or too large.
pub fn language(gpa: std.mem.Allocator, body: []const u8, o: Opts, out: *std.ArrayList([]u8)) std.mem.Allocator.Error!bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var l: Lang = .{ .arena = arena_state.allocator(), .o = o, .src = body };
    var set = l.alt(0) orelse return false;
    if (l.i != body.len) return false;
    for (set.items) |s| if (s.len == 0) return false;
    _ = &set;
    const start = out.items.len;
    for (set.items) |s| {
        const dup = gpa.dupe(u8, s) catch |e| {
            for (out.items[start..]) |x| gpa.free(x);
            out.shrinkRetainingCapacity(start);
            return e;
        };
        out.append(gpa, dup) catch |e| {
            gpa.free(dup);
            for (out.items[start..]) |x| gpa.free(x);
            out.shrinkRetainingCapacity(start);
            return e;
        };
    }
    return true;
}

pub fn analyze(gpa: std.mem.Allocator, raw_body: []const u8, o: Opts) std.mem.Allocator.Error!Info {
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(gpa);
    try flatten(gpa, raw_body, &flat);
    var body: []const u8 = flat.items;
    var a_start = false;
    var a_end = false;
    if (std.mem.startsWith(u8, body, "\\A")) {
        body = body[2..];
        a_start = true;
    }else if (std.mem.startsWith(u8, body, "^")) {
        body = body[1..];
        a_start = true;
    }
    if (std.mem.endsWith(u8, body, "\\z")) {
        body = body[0 .. body.len - 2];
        a_end = true;
    } else if (body.len > 0 and body[body.len - 1] == '$' and !(body.len > 1 and body[body.len - 2] == '\\')) {
        body = body[0 .. body.len - 1];
        a_end = true;
    }
    var run: std.ArrayList(u8) = .empty;
    defer run.deinit(gpa);
    var best: std.ArrayList(u8) = .empty;
    errdefer best.deinit(gpa);
    var other: usize = 0; // elements that are not plain literal bytes
    var alt = false;
    var scannable = !a_start and !a_end;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        var lit: ?u8 = null;
        var end = i + 1;
        switch (c) {
            '\\' => {
                if (i + 1 >= body.len) return bail(&best, gpa);
                const n = body[i + 1];
                end = i + 2;
                if (n == 'x') {
                    if (i + 3 >= body.len) return bail(&best, gpa);
                    const hi = hexVal(body[i + 2]) orelse return bail(&best, gpa);
                    const lo = hexVal(body[i + 3]) orelse return bail(&best, gpa);
                    lit = hi * 16 + lo;
                    end = i + 4;
                    if (o.native and lit.? >= 0x80) lit = null;
                } else if (std.ascii.isAlphanumeric(n)) {
                    switch (n) {
                        'd', 'D', 'w', 'W', 's', 'S' => {},
                        else => return bail(&best, gpa),
                    }
                } else lit = n;
            },
            '[' => end = classEnd(body, i) orelse return bail(&best, gpa),
            '(' => {
                end = groupEnd(body, i) orelse return bail(&best, gpa);
                var inner_at = i + 1;
                if (i + 1 < body.len and body[i + 1] == '?') {
                    // only (?: is understood; flags, look-around and named
                    // groups change what the literals around them mean
                    if (!(i + 2 < body.len and body[i + 2] == ':')) return bail(&best, gpa);
                    inner_at = i + 3;
                }
                var inner = try analyze(gpa, body[inner_at .. end - 1], o);
                defer inner.deinit(gpa);
                if (!inner.scannable) scannable = false;
            },
            ')', '*', '+', '?', '{' => return bail(&best, gpa),
            '|' => {
                alt = true;
                flush(gpa, &run, &best);
                i += 1;
                continue;
            },
            '.' => {},
            '^', '$' => scannable = false,
            else => {
                if (o.native and quantifiedChar(body, i)) return bail(&best, gpa);
                lit = c;
            },
        }
        // a quantifier on this atom
        var min: usize = 1;
        var quant = false;
        if (end < body.len) switch (body[end]) {
            '*', '?' => {
                min = 0;
                quant = true;
                end += 1;
            },
            '+' => {
                quant = true;
                end += 1;
            },
            '{' => {
                const close = std.mem.indexOfScalarPos(u8, body, end, '}') orelse return bail(&best, gpa);
                const spec = body[end + 1 .. close];
                const comma = std.mem.indexOfScalar(u8, spec, ',') orelse spec.len;
                min = if (comma == 0) 0 else std.fmt.parseInt(usize, spec[0..comma], 10) catch return bail(&best, gpa);
                quant = true;
                end = close + 1;
            },
            else => {},
        };
        if (quant and end < body.len) {
            if (body[end] == '?') end += 1 else if (body[end] == '+') {
                scannable = false; // possessive
                end += 1;
            }
        }
        const allowed = if (lit) |b| literalOk(b, o) else false;
        if (lit != null and allowed) {
            if (!quant) {
                try run.append(gpa, lit.?);
            } else {
                other += 1;
                if (min >= 1) try run.append(gpa, lit.?);
                flush(gpa, &run, &best);
            }
        } else {
            other += 1;
            flush(gpa, &run, &best);
        }
        i = end;
    }
    const whole = run.items.len;
    flush(gpa, &run, &best);
    var info: Info = .{ .scannable = scannable, .anchor_start = a_start, .anchor_end = a_end };
    if (!alt) info.lit = try best.toOwnedSlice(gpa) else best.deinit(gpa);
    info.exact = !alt and other == 0 and whole == info.lit.len and whole > 0;
    return info;
}

fn bail(best: *std.ArrayList(u8), gpa: std.mem.Allocator) Info {
    best.deinit(gpa);
    return .{};
}

fn flush(gpa: std.mem.Allocator, run: *std.ArrayList(u8), best: *std.ArrayList(u8)) void {
    if (run.items.len > best.items.len) {
        best.clearRetainingCapacity();
        best.appendSlice(gpa, run.items) catch {};
    }
    run.clearRetainingCapacity();
}

/// A byte that may appear in the required literal. Case-insensitive matching
/// of non-ASCII bytes, and of the ASCII letters with Unicode case partners
/// (k, s) in UTF-8 mode, is left to the regex.
fn literalOk(b: u8, o: Opts) bool {
    if (b == o.eol) return false;
    if (o.icase) {
        if (b >= 0x80) return false;
        if (o.utf8 and std.ascii.isAlphabetic(b) and std.ascii.toLower(b) == 'k') return false;
        if (o.utf8 and std.ascii.isAlphabetic(b) and std.ascii.toLower(b) == 's') return false;
    }
    return true;
}

test "in UTF-8 source a quantifier takes the whole character" {
    const gpa = std.testing.allocator;
    const o: Opts = .{ .icase = false, .utf8 = true, .native = true, .eol = '\n' };
    for ([_][]const u8{ "a\xc3\xa9?b", "a\xc3\xa9*", "\\xe9" }) |body| {
        var info = try analyze(gpa, body, o);
        defer info.deinit(gpa);
        try std.testing.expect(std.mem.indexOfScalar(u8, info.lit, 0xc3) == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, info.lit, 0xe9) == null);
        try std.testing.expect(!info.exact);
    }
    try expectInfo("a\xc3\xa9b", o, "a\xc3\xa9b", true, true);
}

fn expectInfo(body: []const u8, o: Opts, lit: []const u8, exact: bool, scannable: bool) !void {
    var i = try analyze(std.testing.allocator, body, o);
    defer i.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(lit, i.lit);
    try std.testing.expectEqual(exact, i.exact);
    try std.testing.expectEqual(scannable, i.scannable);
}

test "literals splits alternatives" {
    const o: Opts = .{ .icase = false, .utf8 = false, .eol = '\n' };
    var out: std.ArrayList(Lit) = .empty;
    defer {
        for (out.items) |l| std.testing.allocator.free(l.text);
        out.deinit(std.testing.allocator);
    }
    try std.testing.expect(try literals(std.testing.allocator, "zqxjv|qq+x|(a|b)cd", o, &out));
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("zqxjv", out.items[0].text);
    try std.testing.expect(out.items[0].exact);
    try std.testing.expectEqualStrings("qq", out.items[1].text);
    try std.testing.expect(!out.items[1].exact);
    try std.testing.expectEqualStrings("cd", out.items[2].text);
    var out2: std.ArrayList(Lit) = .empty;
    defer out2.deinit(std.testing.allocator);
    try std.testing.expect(!try literals(std.testing.allocator, "ab|c*", o, &out2));
    for (out2.items) |l| std.testing.allocator.free(l.text);
}

test "analyze finds required literals" {
    const o: Opts = .{ .icase = false, .utf8 = false, .eol = '\n' };
    try expectInfo("zqxjv", o, "zqxjv", true, true);
    try expectInfo("a\\.b\\x41", o, "a.bA", true, true);
    try expectInfo("ab+c", o, "ab", false, true);
    try expectInfo("abc*d", o, "ab", false, true);
    try expectInfo("(two|the)s?", o, "", false, true);
    try expectInfo("x(?:ab)y", o, "xaby", true, true);
    try expectInfo("x(?:ab)+y", o, "x", false, true);
    try expectInfo("(?:\\xc3\\xa9)", o, "\xc3\xa9", true, true);
    try expectInfo("\\Athe", o, "the", true, false);
    try expectInfo("e$", o, "e", true, false);
    try expectInfo("\\Ae\\z", o, "e", true, false);
    try expectInfo("^the", o, "the", true, false);
    try expectInfo("a|b", o, "", false, true);
    try expectInfo("(?<!x)abc", o, "", false, false);
    try expectInfo("(^a)", o, "", false, false);
    try expectInfo("(?i)abc", o, "", false, false);
    try expectInfo("([a-y])\\1", o, "", false, false);
    try expectInfo("[a-c]+\\.[a-z]-[a-z]_d[0-9]+", o, "_d", false, true);
    try expectInfo("ab{0,2}c", o, "a", false, true);
    try expectInfo("ab{2}c", o, "ab", false, true);
    try expectInfo("ab{2,}c", o, "ab", false, true);
    try expectInfo("\\Qab", o, "", false, false);
    const fi: Opts = .{ .icase = true, .utf8 = true, .eol = '\n' };
    try expectInfo("the", fi, "the", true, true);
    try expectInfo("kst", fi, "t", false, true);
}

test "language expands small finite patterns" {
    const o: Opts = .{ .icase = false, .utf8 = false, .eol = '\n' };
    var out: std.ArrayList([]u8) = .empty;
    defer {
        for (out.items) |x| std.testing.allocator.free(x);
        out.deinit(std.testing.allocator);
    }
    try std.testing.expect(try language(std.testing.allocator, "(two|the)s?", o, &out));
    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("twos", out.items[0]);
    try std.testing.expectEqualStrings("two", out.items[1]);
    try std.testing.expectEqualStrings("thes", out.items[2]);
    try std.testing.expectEqualStrings("the", out.items[3]);
    const n = out.items.len;
    try std.testing.expect(!try language(std.testing.allocator, "a*b", o, &out));
    try std.testing.expect(!try language(std.testing.allocator, "a?", o, &out));
    try std.testing.expect(!try language(std.testing.allocator, "^ab", o, &out));
    try std.testing.expect(!try language(std.testing.allocator, "a(b", o, &out));
    try std.testing.expectEqual(n, out.items.len);
    try std.testing.expect(try language(std.testing.allocator, "[Tt]h\\.e", o, &out));
    try std.testing.expectEqualStrings("Th.e", out.items[n]);
    const fi: Opts = .{ .icase = true, .utf8 = true, .eol = '\n' };
    try std.testing.expect(!try language(std.testing.allocator, "kx", fi, &out));
}
