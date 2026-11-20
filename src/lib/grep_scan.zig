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
    /// The line terminator; a literal never contains it.
    eol: u8,
};

pub const Info = struct {
    /// Longest literal that every match contains (owned; empty = none).
    lit: []u8 = &.{},
    exact: bool = false,
    scannable: bool = false,

    pub fn deinit(i: *Info, gpa: std.mem.Allocator) void {
        gpa.free(i.lit);
        i.* = .{};
    }
};

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

pub fn analyze(gpa: std.mem.Allocator, body: []const u8, o: Opts) std.mem.Allocator.Error!Info {
    var run: std.ArrayList(u8) = .empty;
    defer run.deinit(gpa);
    var best: std.ArrayList(u8) = .empty;
    errdefer best.deinit(gpa);
    var other: usize = 0; // elements that are not plain literal bytes
    var alt = false;
    var scannable = true;
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
            else => lit = c,
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
    var info: Info = .{ .scannable = scannable };
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

fn expectInfo(body: []const u8, o: Opts, lit: []const u8, exact: bool, scannable: bool) !void {
    var i = try analyze(std.testing.allocator, body, o);
    defer i.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(lit, i.lit);
    try std.testing.expectEqual(exact, i.exact);
    try std.testing.expectEqual(scannable, i.scannable);
}

test "analyze finds required literals" {
    const o: Opts = .{ .icase = false, .utf8 = false, .eol = '\n' };
    try expectInfo("zqxjv", o, "zqxjv", true, true);
    try expectInfo("a\\.b\\x41", o, "a.bA", true, true);
    try expectInfo("ab+c", o, "ab", false, true);
    try expectInfo("abc*d", o, "ab", false, true);
    try expectInfo("(two|the)s?", o, "", false, true);
    try expectInfo("x(?:ab)y", o, "x", false, true);
    try expectInfo("^the", o, "the", false, false);
    try expectInfo("e$", o, "e", false, false);
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
