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

const Bracket = struct { matched: bool, next: usize };

/// A bracket expression that glibc gives up on: nothing matches it, negated
/// or not.
fn never(pattern: []const u8) Bracket {
    return .{ .matched = false, .next = pattern.len };
}

/// Parse the bracket expression starting at pattern[start] == '['. Returns
/// whether `c` matches and the index after the closing ']', or null when the
/// expression is not terminated (the '[' is then literal).
fn bracket(pattern: []const u8, start: usize, c: u8, cf: bool) ?Bracket {
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
        // "[=c=]" is a class of one in the C locale, and cannot end a range.
        // Broken, it stands for itself, except behind a match, where glibc
        // only looks for the end of the bracket and gives up.
        if (lo == '[' and i + 1 < pattern.len and pattern[i + 1] == '=') {
            if (i + 4 < pattern.len and pattern[i + 3] == '=' and pattern[i + 4] == ']') {
                if (ceq(pattern[i + 2], c, cf)) matched = true;
                i += 5;
                continue;
            }
            if (matched) return never(pattern);
        }
        if (lo == '[' and i + 1 < pattern.len and pattern[i + 1] == '.') {
            // "[.c.]". One without an end spoils the whole pattern, as does
            // an unknown name, unless it is behind a match.
            const end = std.mem.indexOfPos(u8, pattern, i + 2, ".]") orelse return never(pattern);
            if (end != i + 3) {
                if (!matched) return never(pattern);
                i = end + 2;
                continue;
            }
            lo = pattern[i + 2];
            i += 5;
        } else {
            if (lo == '\\' and i + 1 < pattern.len) {
                i += 1;
                lo = pattern[i];
            }
            i += 1;
        }
        if (i + 1 < pattern.len and pattern[i] == '-' and pattern[i + 1] != ']') {
            var hi = pattern[i + 1];
            if (hi == '[' and i + 2 < pattern.len and pattern[i + 2] == '.') {
                const end = std.mem.indexOfPos(u8, pattern, i + 3, ".]") orelse return never(pattern);
                if (end != i + 4) return never(pattern);
                hi = pattern[i + 3];
                i += 6;
            } else {
                i += 2;
                if (hi == '\\' and i < pattern.len) {
                    hi = pattern[i];
                    i += 1;
                }
            }
            if ((lo <= c and c <= hi) or (cf and lo <= other(c) and other(c) <= hi)) matched = true;
        } else if (ceq(lo, c, cf)) matched = true;
    }
    return .{ .matched = matched != negate, .next = i };
}

/// Match one pattern element other than '*' (each stands for exactly one byte)
/// against text[ti]. Returns the index of the next element, or null.
fn element(pattern: []const u8, pi: usize, text: []const u8, ti: usize, flags: Flags) ?usize {
    if (ti >= text.len) return null;
    const c = text[ti];
    // FNM_PERIOD: a leading period is matched only by a period.
    const hidden = flags.period and ti == 0 and c == '.';
    switch (pattern[pi]) {
        '?' => return if (hidden) null else pi + 1,
        '[' => {
            const b = bracket(pattern, pi, c, flags.casefold) orelse return if (c == '[') pi + 1 else null;
            return if (!hidden and b.matched) b.next else null;
        },
        '\\' => {
            // One that ends the pattern matches nothing, as in glibc.
            if (pi + 1 >= pattern.len) return null;
            const at = pi + 1;
            return if (ceq(pattern[at], c, flags.casefold)) at + 1 else null;
        },
        else => |literal| return if (ceq(literal, c, flags.casefold)) pi + 1 else null,
    }
}

/// Whole-string match in O(pattern * text). Only the last '*' is ever retried:
/// every other element takes exactly one byte, so whatever an earlier '*' could
/// take over is also within reach of the later one.
pub fn match(pattern: []const u8, text: []const u8, flags: Flags) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    // Where to resume: the element after the last '*', and the first byte of
    // the text that '*' has not yet taken.
    var star: ?struct { pi: usize, ti: usize } = null;
    while (pi < pattern.len or ti < text.len) {
        if (pi < pattern.len) {
            if (pattern[pi] == '*') {
                if (flags.period and ti == 0 and ti < text.len and text[0] == '.') return false;
                while (pi < pattern.len and pattern[pi] == '*') pi += 1;
                if (pi == pattern.len) return true;
                star = .{ .pi = pi, .ti = ti };
                continue;
            }
            if (element(pattern, pi, text, ti, flags)) |next| {
                pi = next;
                ti += 1;
                continue;
            }
        }
        // A mismatch: let the last '*' take one more byte and start over there.
        const s = &(star orelse return false);
        if (s.ti >= text.len) return false;
        s.ti += 1;
        pi = s.pi;
        ti = s.ti;
    }
    return true;
}

test "fnmatch" {
    const t = std.testing;
    try t.expect(match("*.c", "a.c", .{}));
    try t.expect(!match("*", ".a", .{ .period = true }));
    try t.expect(match(".*", ".a", .{ .period = true }));
    try t.expect(match("[[:digit:]]x", "5x", .{}));
    try t.expect(!match("[!a]", "a", .{}));
}

test "fnmatch with many stars" {
    const t = std.testing;
    try t.expect(match("a*b*c", "aXbYbZc", .{}));
    try t.expect(match("*ab", "aab", .{}));
    try t.expect(match("*?b*", "abb", .{}));
    try t.expect(match("a**", "a", .{}));
    try t.expect(!match("*a*b", "ab a", .{}));
    try t.expect(!match("*?", "", .{}));
    // Retrying every '*' would take longer than the universe has.
    const name: [4096]u8 = @splat('a');
    const stars = "*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a";
    try t.expect(!match(stars ++ "*b", &name, .{}));
    try t.expect(match(stars ++ "*", &name, .{}));
}
