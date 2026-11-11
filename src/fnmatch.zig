// SPDX-License-Identifier: GPL-2.0-or-later
//! fnmatch(3) subset used by ls: `*`, `?`, bracket expressions with ranges,
//! negation and POSIX classes, backslash quoting, and FNM_PERIOD. C locale.

const std = @import("std");

pub const Flags = struct { period: bool = false, casefold: bool = false };

fn other(c: u8) u8 {
    return if (std.ascii.isUpper(c)) std.ascii.toLower(c) else if (std.ascii.isLower(c)) std.ascii.toUpper(c) else c;
}

fn ceq(a: u8, b: u8, cf: bool) bool {
    return a == b or (cf and other(a) == b);
}

pub fn match(pattern: []const u8, text: []const u8, flags: Flags) bool {
    return matchAt(pattern, 0, text, 0, flags);
}

fn classMatch(name: []const u8, c: u8) ?bool {
    const eql = std.mem.eql;
    if (eql(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (eql(u8, name, "digit")) return std.ascii.isDigit(c);
    if (eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (eql(u8, name, "upper")) return std.ascii.isUpper(c);
    if (eql(u8, name, "lower")) return std.ascii.isLower(c);
    if (eql(u8, name, "space")) return c == ' ' or (c >= 9 and c <= 13);
    if (eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (eql(u8, name, "punct")) return c > 32 and c < 127 and !std.ascii.isAlphanumeric(c);
    if (eql(u8, name, "print")) return c >= 32 and c < 127;
    if (eql(u8, name, "graph")) return c > 32 and c < 127;
    if (eql(u8, name, "cntrl")) return c < 32 or c == 127;
    if (eql(u8, name, "xdigit")) return std.ascii.isHex(c);
    return null;
}

/// Parse the bracket expression starting at pattern[start] == '['. Returns
/// whether `c` matches and the index after the closing ']', or null when the
/// expression is not terminated (the '[' is then literal).
fn bracket(pattern: []const u8, start: usize, c: u8, cf: bool) ?struct { matched: bool, next: usize } {
    var i = start + 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (true) {
        if (i >= pattern.len) return null;
        var lo = pattern[i];
        if (lo == ']' and !first) {
            i += 1;
            break;
        }
        first = false;
        if (lo == '[' and i + 1 < pattern.len and pattern[i + 1] == ':') {
            if (std.mem.indexOfPos(u8, pattern, i + 2, ":]")) |e| {
                if (classMatch(pattern[i + 2 .. e], c)) |m| {
                    if (m) matched = true;
                    i = e + 2;
                    continue;
                }
            }
        }
        if (lo == '\\' and i + 1 < pattern.len) {
            i += 1;
            lo = pattern[i];
        }
        i += 1;
        if (i + 1 < pattern.len and pattern[i] == '-' and pattern[i + 1] != ']') {
            var hi = pattern[i + 1];
            i += 2;
            if (hi == '\\' and i < pattern.len) {
                hi = pattern[i];
                i += 1;
            }
            if ((lo <= c and c <= hi) or (cf and lo <= other(c) and other(c) <= hi)) matched = true;
        } else if (ceq(lo, c, cf)) matched = true;
    }
    return .{ .matched = matched != negate, .next = i };
}

fn matchAt(pattern: []const u8, pi_in: usize, text: []const u8, ti_in: usize, flags: Flags) bool {
    var pi = pi_in;
    var ti = ti_in;
    while (pi < pattern.len) {
        const pc = pattern[pi];
        switch (pc) {
            '?' => {
                if (ti >= text.len) return false;
                if (flags.period and ti == 0 and text[0] == '.') return false;
                pi += 1;
                ti += 1;
            },
            '*' => {
                if (flags.period and ti == 0 and ti < text.len and text[0] == '.') return false;
                while (pi < pattern.len and pattern[pi] == '*') pi += 1;
                if (pi == pattern.len) return true;
                var k = ti;
                while (k <= text.len) : (k += 1) {
                    if (matchAt(pattern, pi, text, k, flags)) return true;
                }
                return false;
            },
            '[' => {
                if (ti >= text.len) return false;
                if (bracket(pattern, pi, text[ti], flags.casefold)) |b| {
                    if (flags.period and ti == 0 and text[0] == '.') return false;
                    if (!b.matched) return false;
                    pi = b.next;
                    ti += 1;
                } else {
                    if (text[ti] != '[') return false;
                    pi += 1;
                    ti += 1;
                }
            },
            '\\' => {
                var lit = pc;
                if (pi + 1 < pattern.len) {
                    pi += 1;
                    lit = pattern[pi];
                }
                if (ti >= text.len or !ceq(lit, text[ti], flags.casefold)) return false;
                pi += 1;
                ti += 1;
            },
            else => {
                if (ti >= text.len or !ceq(pc, text[ti], flags.casefold)) return false;
                pi += 1;
                ti += 1;
            },
        }
    }
    return ti == text.len;
}

test "fnmatch" {
    const t = std.testing;
    try t.expect(match("*.c", "a.c", .{}));
    try t.expect(!match("*", ".a", .{ .period = true }));
    try t.expect(match(".*", ".a", .{ .period = true }));
    try t.expect(match("[[:digit:]]x", "5x", .{}));
    try t.expect(!match("[!a]", "a", .{}));
}
