// SPDX-License-Identifier: GPL-2.0-or-later
//! POSIX basic and extended regular expressions (with the GNU extensions
//! \| \+ \? in BRE), translated into the Perl dialect of the regex package
//! (~/de/regex-zig), which has no POSIX dialect yet.
//!
//! Perl alternation is leftmost-first and POSIX is leftmost-longest; `Finder`
//! makes up the difference (see `Longest` for when it cannot). Everything else
//! (anchors, intervals, back-references, bracket expressions with character
//! classes) is translated faithfully.
//! References: POSIX.1-2024 XBD 9 (Regular Expressions); GNU grep manual
//! "Regular Expressions".

const std = @import("std");
const rx = @import("regexutil.zig");
const regex = @import("regex");
const unicode = @import("unicode.zig");

pub const Error = error{ OutOfMemory, BadPattern };

/// UTF-8 classes make large patterns; the package defaults are too small.
pub const big_limits: regex.Limits = .{ .max_pattern_len = 1 << 22, .max_program_len = 1 << 21 };

/// Perl-dialect source equivalent to the BRE (or ERE) in `pat`.
pub fn translate(gpa: std.mem.Allocator, pat: []const u8, ere: bool) Error![]u8 {
    return translateOpts(gpa, pat, ere, .{});
}

pub const Opts = struct {
    /// UTF-8 locale: `.`, bracket expressions and classes work on characters.
    utf8: bool = false,
    /// Case-insensitive matching (needed here only for non-ASCII literals).
    icase: bool = false,
    /// GNU grep -E: a `{` that does not start a valid interval is literal.
    lenient_brace: bool = false,
};

/// `rest` follows a `{`: true for `n}`, `n,}`, `,m}` and `n,m}`.
fn validInterval(rest: []const u8) bool {
    var i: usize = 0;
    var digits1: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) digits1 += 1;
    var digits2: usize = 0;
    var comma = false;
    if (i < rest.len and rest[i] == ',') {
        comma = true;
        i += 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) digits2 += 1;
    }
    if (i >= rest.len or rest[i] != '}') return false;
    if (!comma) return digits1 > 0;
    return digits1 > 0 or digits2 > 0;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether anything matching the pattern text `rest` surely begins with an
/// ASCII word character: it starts with a literal one, or \w, that cannot be
/// repeated zero times. False when in doubt.
fn startsWithWord(rest: []const u8) bool {
    var after: []const u8 = undefined;
    if (std.mem.startsWith(u8, rest, "\\w")) {
        after = rest[2..];
    } else if (rest.len > 0 and isWordByte(rest[0])) {
        after = rest[1..];
    } else return false;
    // "+" keeps one, but may itself be made optional.
    if (std.mem.startsWith(u8, after, "\\+")) after = after[2..] else if (std.mem.startsWith(u8, after, "+")) after = after[1..];
    for ([_][]const u8{ "*", "?", "{", "\\?", "\\{" }) |q| if (std.mem.startsWith(u8, after, q)) return false;
    return true;
}

/// Whether anything matching the pattern text `before` surely ends with an
/// ASCII word character. False when in doubt.
fn endsWithWord(before: []const u8, ere: bool) bool {
    const plus: []const u8 = if (ere) "+" else "\\+";
    const atom = if (std.mem.endsWith(u8, before, plus)) before[0 .. before.len - plus.len] else before;
    if (atom.len == 0) return false;
    const last = atom[atom.len - 1];
    // An escaped letter or digit is something else (\W, \s, \1), except \w.
    var slashes: usize = 0;
    while (slashes + 1 < atom.len and atom[atom.len - 2 - slashes] == '\\') slashes += 1;
    if (slashes % 2 == 1) return last == 'w';
    return isWordByte(last);
}

test "word start and end in the C locale" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "\\<foo\\>", "\\bfoo\\b" },
        .{ "\\<\\w\\+\\>", "\\b\\w+\\b" },
        .{ "\\>", "\\b(?![0-9A-Za-z_])" },
        .{ "\\<.", "\\b(?=[0-9A-Za-z_])." },
        .{ "\\<a*x", "\\b(?=[0-9A-Za-z_])a*x" },
        .{ "ab*\\>", "ab*\\b(?![0-9A-Za-z_])" },
        .{ "\\W\\>", "\\W\\b(?![0-9A-Za-z_])" },
    };
    for (cases) |c| {
        const got = try translate(gpa, c[0], false);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

/// What the pattern contains that matters for longest-match emulation.
pub const Flags = struct {
    /// The pattern itself has an alternation.
    alt: bool = false,
    /// The match depends on the text right of it (`$`, word boundaries, `\'`).
    right: bool = false,
    /// Uses a construct glibc treats as multibyte-aware (`.`, bracket
    /// expressions, \\w \\s, word boundaries) in a UTF-8 locale.
    mb: bool = false,
    /// First operator ignored at the start of an ERE (grep warns about it).
    leading_op: u8 = 0,
};

pub fn translateOpts(gpa: std.mem.Allocator, pat: []const u8, ere: bool, opts: Opts) Error![]u8 {
    var flags: Flags = .{};
    return translateFlags(gpa, pat, ere, opts, &flags);
}

pub fn translateFlags(gpa: std.mem.Allocator, pat: []const u8, ere: bool, opts: Opts, flags: *Flags) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    // In a BRE, `*` is literal at the start of an expression, and `^`/`$` are
    // anchors only at the edges of (sub)expressions.
    var at_start = true;
    var depth: usize = 0;
    while (i < pat.len) {
        const c = pat[i];
        if (c == '\\' and i + 1 >= pat.len) return error.BadPattern;
        if (c == '\\' and i + 1 < pat.len) {
            const n = pat[i + 1];
            i += 2;
            if (!ere and n == '(') {
                try out.append(gpa, '(');
                depth += 1;
                at_start = true;
                continue;
            }
            if (!ere and n == ')') {
                if (depth == 0) return error.BadPattern;
                depth -= 1;
                try out.append(gpa, ')');
                at_start = false;
                continue;
            }
            if (!ere and n == '{') {
                // interval up to \}
                const close = std.mem.indexOfPos(u8, pat, i, "\\}") orelse return error.BadPattern;
                try out.append(gpa, '{');
                if (close > i and pat[i] == ',') try out.append(gpa, '0');
                try out.appendSlice(gpa, pat[i..close]);
                try out.append(gpa, '}');
                i = close + 2;
                at_start = false;
                continue;
            }
            if (!ere and n == '|') {
                flags.alt = true;
                try out.append(gpa, '|');
                at_start = true;
                continue;
            }
            if (!ere and (n == '+' or n == '?')) {
                try out.append(gpa, n);
                at_start = false;
                continue;
            }
            if (std.ascii.isDigit(n) and n != '0') {
                try out.append(gpa, '\\');
                try out.append(gpa, n);
                at_start = false;
                continue;
            }
            if (n == '<' or n == '>' or n == 'b' or n == 'B' or n == '\'') flags.right = true;
            if ((n == '<' or n == '>') and !opts.utf8) {
                // The Perl dialect has only \b. That is the same as \< or
                // \> where the pattern puts a word character on the inner
                // side. Elsewhere a lookahead says which end is meant, at the
                // price of the backtracking engine, so it is not added
                // without need.
                try out.appendSlice(gpa, "\\b");
                if (n == '<') {
                    if (!startsWithWord(pat[i..])) try out.appendSlice(gpa, "(?=[0-9A-Za-z_])");
                } else if (!endsWithWord(pat[0 .. i - 2], ere)) try out.appendSlice(gpa, "(?![0-9A-Za-z_])");
                continue;
            }
            if (opts.utf8 and (n == 'w' or n == 'W' or n == 's' or n == 'S')) {
                flags.mb = true;
                var set: unicode.Set = .{};
                defer set.deinit(gpa);
                if (n == 'w' or n == 'W') {
                    try set.addAll(gpa, unicode.classRanges(.alnum));
                    try set.add(gpa, '_', '_');
                } else try set.addAll(gpa, unicode.classRanges(.space));
                try emitSet(gpa, &out, &set, n == 'W' or n == 'S');
                at_start = false;
                continue;
            }
            if (opts.utf8 and (n == 'b' or n == 'B' or n == '<' or n == '>')) {
                flags.mb = true;
                var set: unicode.Set = .{};
                defer set.deinit(gpa);
                try set.addAll(gpa, unicode.classRanges(.alnum));
                try set.add(gpa, '_', '_');
                var w: std.ArrayList(u8) = .empty;
                defer w.deinit(gpa);
                try unicode.appendSetRegex(gpa, &w, &set);
                var fl: std.ArrayList(u8) = .empty;
                defer fl.deinit(gpa);
                try unicode.appendSetFlat(gpa, &fl, &set);
                switch (n) {
                    'b' => try out.print(gpa, "(?:(?<={1s})(?!{0s})|(?<!{1s})(?={0s}))", .{ w.items, fl.items }),
                    // Only the second branch can hold inside a character.
                    'B' => try out.print(gpa, "(?:(?<={1s})(?={0s})|(?<!{1s})(?!{0s}){2s})", .{ w.items, fl.items, unicode.not_inside_char }),
                    '<' => try out.print(gpa, "(?:(?<!{1s})(?={0s}))", .{ w.items, fl.items }),
                    else => try out.print(gpa, "(?:(?<={1s})(?!{0s}))", .{ w.items, fl.items }),
                }
                continue;
            }
            if (n == 'b' or n == 'B' or n == 'w' or n == 'W' or n == 's' or n == 'S') {
                try out.append(gpa, '\\');
                try out.append(gpa, n);
                at_start = false;
                continue;
            }
            if (n == '`') {
                try out.appendSlice(gpa, "\\A");
                continue;
            }
            if (n == '\'') {
                try out.appendSlice(gpa, "\\z");
                continue;
            }
            // Any other escaped character is that literal character.
            try literal(gpa, &out, n);
            at_start = false;
            continue;
        }
        i += 1;
        switch (c) {
            '[' => {
                if (opts.utf8) flags.mb = true;
                const end = if (opts.utf8) try bracketUtf8(gpa, &out, pat, i, opts) else try bracket(gpa, &out, pat, i);
                i = end;
                at_start = false;
            },
            '.' => {
                if (opts.utf8) {
                    flags.mb = true;
                    try out.appendSlice(gpa, unicode.any_char);
                } else try out.append(gpa, '.');
                at_start = false;
            },
            '*' => {
                if (at_start and !ere) {
                    try out.appendSlice(gpa, "\\*");
                } else if (at_start and ere) {
                    if (!opts.lenient_brace) return error.BadPattern;
                    if (flags.leading_op == 0) flags.leading_op = '*';
                    i += 0;
                    continue;
                } else {
                    if (!ere and !opts.lenient_brace and out.items.len > 0 and out.items[out.items.len - 1] == '*' and (out.items.len < 2 or out.items[out.items.len - 2] != '\\')) return error.BadPattern;
                    try out.append(gpa, '*');
                }
                at_start = false;
            },
            '^' => {
                if (ere or at_start) {
                    try out.append(gpa, '^');
                    // BRE keeps "start" status so "^*" has a literal star.
                } else {
                    try out.appendSlice(gpa, "\\^");
                    at_start = false;
                }
            },
            '$' => {
                const edge = ere or i == pat.len or (!ere and (std.mem.startsWith(u8, pat[i..], "\\)") or std.mem.startsWith(u8, pat[i..], "\\|")));
                if (edge) flags.right = true;
                if (edge) try out.append(gpa, '$') else try out.appendSlice(gpa, "\\$");
                at_start = false;
            },
            '(' => {
                if (ere) {
                    try out.append(gpa, '(');
                    depth += 1;
                    at_start = true;
                } else try out.appendSlice(gpa, "\\(");
                if (!ere) at_start = false;
            },
            ')' => {
                if (ere) {
                    if (depth == 0) {
                        if (!opts.lenient_brace) return error.BadPattern;
                        try out.appendSlice(gpa, "\\)");
                    } else {
                        depth -= 1;
                        try out.append(gpa, ')');
                    }
                } else try out.appendSlice(gpa, "\\)");
                at_start = false;
            },
            '|' => {
                if (ere) {
                    flags.alt = true;
                    try out.append(gpa, '|');
                    at_start = true;
                } else {
                    try out.appendSlice(gpa, "\\|");
                    at_start = false;
                }
            },
            '+', '?' => {
                if (ere and at_start) {
                    if (!opts.lenient_brace) return error.BadPattern;
                    if (flags.leading_op == 0) flags.leading_op = c;
                    continue;
                }
                if (ere and !at_start) try out.append(gpa, c) else {
                    try out.append(gpa, '\\');
                    try out.append(gpa, c);
                }
                at_start = false;
            },
            '{' => {
                if (ere and opts.lenient_brace and !validInterval(pat[i..])) {
                    try out.appendSlice(gpa, "\\{");
                } else if (ere and at_start and opts.lenient_brace) {
                    if (flags.leading_op == 0) flags.leading_op = '{';
                    i = (std.mem.indexOfScalarPos(u8, pat, i, '}') orelse pat.len - 1) + 1;
                    continue;
                } else if (ere and !at_start) {
                    const close = std.mem.indexOfScalarPos(u8, pat, i, '}') orelse return error.BadPattern;
                    try out.append(gpa, '{');
                    if (close > i and pat[i] == ',') try out.append(gpa, '0');
                    try out.appendSlice(gpa, pat[i..close]);
                    try out.append(gpa, '}');
                    i = close + 1;
                } else if (ere) {
                    return error.BadPattern;
                } else try out.appendSlice(gpa, "\\{");
                at_start = false;
            },
            '}' => {
                try out.appendSlice(gpa, "\\}");
                at_start = false;
            },
            else => {
                if (opts.utf8 and c >= 0x80) {
                    const d = unicode.decode(pat, i - 1);
                    if (d.valid) {
                        try utf8Literal(gpa, &out, d.cp, opts.icase);
                        i += d.len - 1;
                        at_start = false;
                        continue;
                    }
                }
                try literal(gpa, &out, c);
                at_start = false;
            },
        }
    }
    if (depth != 0) return error.BadPattern;
    defer out.deinit(gpa);
    return wrapStacked(gpa, out.items);
}

/// Perl treats `a*?` as lazy and `a*+` as possessive, whereas POSIX stacks
/// the quantifiers; wrap the quantified atom so that the stack is explicit.
fn wrapStacked(gpa: std.mem.Allocator, src: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var groups: std.ArrayList(usize) = .empty;
    defer groups.deinit(gpa);
    var atom: ?usize = null;
    var quant = false;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '\\' => {
                atom = out.items.len;
                quant = false;
                var n: usize = 2;
                if (i + 1 < src.len and src[i + 1] == 'x') n = 4;
                const e = @min(i + n, src.len);
                try out.appendSlice(gpa, src[i..e]);
                i = e;
            },
            '[' => {
                atom = out.items.len;
                quant = false;
                var j = i + 1;
                if (j < src.len and src[j] == '^') j += 1;
                if (j < src.len and src[j] == ']') j += 1;
                while (j < src.len and src[j] != ']') : (j += 1) {
                    if (src[j] == '[' and j + 1 < src.len and src[j + 1] == ':') {
                        j = std.mem.indexOfPos(u8, src, j + 2, ":]") orelse src.len - 1;
                        j += 1;
                    } else if (src[j] == '\\') j += 1;
                }
                const e = @min(j + 1, src.len);
                try out.appendSlice(gpa, src[i..e]);
                i = e;
            },
            '(' => {
                try groups.append(gpa, out.items.len);
                try out.append(gpa, '(');
                atom = null;
                quant = false;
                i += 1;
            },
            ')' => {
                const st = groups.pop() orelse return error.BadPattern;
                try out.append(gpa, ')');
                atom = st;
                quant = false;
                i += 1;
            },
            '|' => {
                try out.append(gpa, '|');
                atom = null;
                quant = false;
                i += 1;
            },
            '*', '+', '?', '{' => {
                var e = i + 1;
                if (c == '{') e = (std.mem.indexOfScalarPos(u8, src, i, '}') orelse src.len - 1) + 1;
                if (quant) if (atom) |a| {
                    try out.insertSlice(gpa, a, "(?:");
                    try out.append(gpa, ')');
                };
                try out.appendSlice(gpa, src[i..e]);
                quant = true;
                i = e;
            },
            else => {
                atom = out.items.len;
                quant = false;
                try out.append(gpa, c);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn utf8Literal(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cp: u32, icase: bool) !void {
    var buf: [4]u8 = undefined;
    const up = unicode.toUpper(cp);
    const lo = unicode.toLower(cp);
    try out.appendSlice(gpa, "(?:");
    const variants = [_]u32{ cp, up, lo };
    var seen: [3]u32 = .{ cp, cp, cp };
    var n: usize = 1;
    for (variants[0..1]) |v| {
        for (unicode.encode(v, &buf)) |b| try out.appendSlice(gpa, &hexEsc(b));
    }
    if (icase) {
        for (variants[1..]) |v| {
            var dup = false;
            for (seen[0..n]) |x| if (x == v) {
                dup = true;
            };
            if (dup) continue;
            seen[n] = v;
            n += 1;
            try out.append(gpa, '|');
            for (unicode.encode(v, &buf)) |b| try out.appendSlice(gpa, &hexEsc(b));
        }
    }
    try out.append(gpa, ')');
}

fn hexEsc(b: u8) [4]u8 {
    const hex = "0123456789abcdef";
    return .{ '\\', 'x', hex[b >> 4], hex[b & 15] };
}

/// Emit `set` (or its complement among valid characters) as one unit.
fn emitSet(gpa: std.mem.Allocator, out: *std.ArrayList(u8), set: *unicode.Set, negate: bool) !void {
    set.normalize();
    var ascii_only = true;
    for (set.ranges.items) |r| {
        if (r[1] >= 0x80) ascii_only = false;
    }
    if (!negate) {
        try unicode.appendSetRegex(gpa, out, set);
        return;
    }
    if (ascii_only) {
        try out.appendSlice(gpa, "(?:[^");
        for (set.ranges.items) |r| {
            try out.appendSlice(gpa, &hexEsc(@intCast(r[0])));
            if (r[1] != r[0]) {
                try out.append(gpa, '-');
                try out.appendSlice(gpa, &hexEsc(@intCast(r[1])));
            }
        }
        try out.appendSlice(gpa, "\\x80-\\xff]|[\\xc2-\\xdf][\\x80-\\xbf]|[\\xe0-\\xef][\\x80-\\xbf][\\x80-\\xbf]|[\\xf0-\\xf4][\\x80-\\xbf][\\x80-\\xbf][\\x80-\\xbf])");
        return;
    }
    try out.appendSlice(gpa, "(?:(?!");
    try unicode.appendSetRegex(gpa, out, set);
    try out.append(gpa, ')');
    try out.appendSlice(gpa, unicode.any_char);
    try out.append(gpa, ')');
}

/// Bracket expression in a UTF-8 locale. Returns the index after the ']'.
fn bracketUtf8(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pat: []const u8, start: usize, opts: Opts) Error!usize {
    var set: unicode.Set = .{};
    defer set.deinit(gpa);
    var i = start;
    var negate = false;
    if (i < pat.len and pat[i] == '^') {
        negate = true;
        i += 1;
    }
    var first = true;
    while (i < pat.len) {
        var c = pat[i];
        if (c == ']' and !first) {
            if (opts.icase) try addCaseVariants(gpa, &set);
            try emitSet(gpa, out, &set, negate);
            return i + 1;
        }
        first = false;
        if (c == '[' and i + 1 < pat.len and (pat[i + 1] == ':' or pat[i + 1] == '.' or pat[i + 1] == '=')) {
            const kind = pat[i + 1];
            const close = std.mem.indexOfPos(u8, pat, i + 2, &[_]u8{ kind, ']' }) orelse return error.BadPattern;
            const name = pat[i + 2 .. close];
            i = close + 2;
            if (kind == ':') {
                const cl = unicode.classFromName(name) orelse return error.BadPattern;
                try set.addAll(gpa, unicode.classRanges(cl));
                continue;
            }
            if (name.len == 0) return error.BadPattern;
            const d = unicode.decode(name, 0);
            try set.add(gpa, d.cp, d.cp);
            continue;
        }
        const d = unicode.decode(pat, i);
        if (!d.valid) {
            // a stray byte of an invalid sequence matches nothing
            i += 1;
            continue;
        }
        var lo = d.cp;
        i += d.len;
        _ = &c;
        var hi = lo;
        if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
            const d2 = unicode.decode(pat, i + 1);
            hi = d2.cp;
            i += 1 + d2.len;
            if (hi < lo) return error.BadPattern;
            // glibc's C.UTF-8 has no collation order for non-ASCII ranges.
            if (hi >= 0x80 or lo >= 0x80) return error.BadPattern;
        }
        if (lo > hi) {
            const t = lo;
            lo = hi;
            hi = t;
        }
        try set.add(gpa, lo, hi);
    }
    return error.BadPattern;
}

fn addCaseVariants(gpa: std.mem.Allocator, set: *unicode.Set) !void {
    const n = set.ranges.items.len;
    for (0..n) |k| {
        const r = set.ranges.items[k];
        if (r[1] - r[0] > 0x500) continue;
        var cp = r[0];
        while (cp <= r[1]) : (cp += 1) {
            const u = unicode.toUpper(cp);
            const l = unicode.toLower(cp);
            if (u != cp) try set.add(gpa, u, u);
            if (l != cp) try set.add(gpa, l, l);
        }
    }
}

/// Append `c` so that the Perl dialect reads it as that literal byte.
fn literal(gpa: std.mem.Allocator, out: *std.ArrayList(u8), c: u8) !void {
    if (std.mem.indexOfScalar(u8, "\\^$.|?*+()[]{}/#", c) != null) try out.append(gpa, '\\');
    if (c < 0x20 or c >= 0x7f) {
        const hex = "0123456789abcdef";
        try out.appendSlice(gpa, &.{ '\\', 'x', hex[c >> 4], hex[c & 15] });
        return;
    }
    try out.append(gpa, c);
}

/// Copy the bracket expression whose body starts at `pat[i]` (after the '[').
/// Returns the index after the closing ']'.
fn bracket(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pat: []const u8, start: usize) Error!usize {
    var i = start;
    try out.append(gpa, '[');
    if (i < pat.len and pat[i] == '^') {
        try out.append(gpa, '^');
        i += 1;
    }
    var first = true;
    while (i < pat.len) {
        const c = pat[i];
        if (c == ']' and !first) {
            try out.append(gpa, ']');
            return i + 1;
        }
        first = false;
        if (c == '[' and i + 1 < pat.len and (pat[i + 1] == ':' or pat[i + 1] == '.' or pat[i + 1] == '=')) {
            const kind = pat[i + 1];
            const close = std.mem.indexOfPos(u8, pat, i + 2, &[_]u8{ kind, ']' }) orelse return error.BadPattern;
            if (kind == ':') {
                try out.appendSlice(gpa, pat[i .. close + 2]); // [:alpha:]
            } else {
                // [.x.] and [=x=] name a single character.
                for (pat[i + 2 .. close]) |ch| try bracketLiteral(gpa, out, ch);
            }
            i = close + 2;
            continue;
        }
        if (c == '-' ) {
            try out.append(gpa, '-');
            i += 1;
            continue;
        }
        try bracketLiteral(gpa, out, c);
        i += 1;
    }
    return error.BadPattern;
}

fn bracketLiteral(gpa: std.mem.Allocator, out: *std.ArrayList(u8), c: u8) !void {
    // Backslash is an ordinary character in a POSIX bracket expression.
    if (c == '\\' or c == '[' or c == ']' or c == '^') try out.append(gpa, '\\');
    try out.append(gpa, c);
}

pub const Compiled = struct {
    re: regex.Regex,
    groups: u32,
    /// Set for patterns with alternation, for POSIX leftmost-longest.
    longest: ?Longest = null,

    pub fn deinit(c: *Compiled, gpa: std.mem.Allocator) void {
        c.re.deinit(gpa);
        if (c.longest) |*l| l.deinit(gpa);
    }
};

/// What it takes to turn the leftmost-first match of the translated pattern
/// into the longest one that starts at the same place.
pub const Longest = struct {
    /// `(?:body)\z` in the translation's dialect: the match, with its
    /// groups, that ends at the end of the text given.
    ends_here: regex.Regex,
    /// The untranslated pattern in the package's own POSIX dialect, which is
    /// leftmost-longest and so says in one pass where the match ends. Null
    /// when that parser rejects the pattern (it has less of GNU's leniency).
    oracle: ?regex.Regex,
    /// `^` also matches after a newline (sed's M flag).
    multiline: bool,

    pub const Source = struct {
        /// The POSIX pattern and which kind it is.
        pattern: []const u8,
        ere: bool,
        /// Its translation, and the flag group to put before that.
        body: []const u8,
        prefix: []const u8 = "",
        flags: Flags,
        ignore_case: bool = false,
        utf8: bool = false,
        multiline: bool = false,
    };

    /// Null for patterns that need no such help: those without an
    /// alternation of their own, and those with something that looks right
    /// of the match (where a shortened text would change the answer).
    pub fn compile(gpa: std.mem.Allocator, src: Source) error{OutOfMemory}!?Longest {
        if (!src.flags.alt or src.flags.right) return null;
        const text = try std.fmt.allocPrint(gpa, "{s}(?:{s})\\z", .{ src.prefix, src.body });
        defer gpa.free(text);
        var ends_here = regex.Regex.compile(gpa, text, .{ .dialect = .perl, .ignore_case = src.ignore_case, .limits = big_limits }, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        errdefer ends_here.deinit(gpa);
        const native = try oracleSource(gpa, src.pattern, src.ere);
        defer gpa.free(native);
        const oracle: ?regex.Regex = regex.Regex.compile(gpa, native, .{
            .dialect = if (src.ere) .posix_ere else .posix_bre,
            .ignore_case = src.ignore_case,
            .utf8 = src.utf8,
            .limits = big_limits,
        }, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        return .{ .ends_here = ends_here, .oracle = oracle, .multiline = src.multiline };
    }

    pub fn deinit(l: *Longest, gpa: std.mem.Allocator) void {
        l.ends_here.deinit(gpa);
        if (l.oracle) |*o| o.deinit(gpa);
    }
};

/// `pat` for the package's POSIX parser, which reads GNU's `{,n}` as text:
/// written `{0,n}`. Bracket expressions are copied as they are.
fn oracleSource(gpa: std.mem.Allocator, pat: []const u8, ere: bool) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < pat.len) {
        const start = i;
        var interval = false;
        if (pat[i] == '\\' and i + 1 < pat.len) {
            interval = !ere and pat[i + 1] == '{';
            i += 2;
        } else if (pat[i] == '[') {
            i += 1;
            if (i < pat.len and pat[i] == '^') i += 1;
            if (i < pat.len and pat[i] == ']') i += 1;
            while (i < pat.len and pat[i] != ']') {
                // "[:alpha:]" and the like have their own closing bracket.
                if (pat[i] == '[' and i + 1 < pat.len and (pat[i + 1] == ':' or pat[i + 1] == '.' or pat[i + 1] == '=')) {
                    if (std.mem.indexOfPos(u8, pat, i + 2, &.{ pat[i + 1], ']' })) |close| i = close + 1;
                }
                i += 1;
            }
            i = @min(i + 1, pat.len);
        } else {
            interval = ere and pat[i] == '{';
            i += 1;
        }
        try out.appendSlice(gpa, pat[start..i]);
        if (interval and i + 1 < pat.len and pat[i] == ',' and std.ascii.isDigit(pat[i + 1])) try out.append(gpa, '0');
    }
    return out.toOwnedSlice(gpa);
}

/// Without the oracle every end has to be tried in turn, which costs the
/// square of this per match, so only this far from the start of the match.
const search_window = 512;

/// Finds POSIX leftmost-longest matches on top of the leftmost-first engine.
pub const Finder = struct {
    sr: regex.Searcher,
    ends_here: ?regex.Searcher,
    oracle: ?regex.Searcher,
    multiline: bool,

    pub fn init(gpa: std.mem.Allocator, c: *const Compiled) !Finder {
        return initParts(gpa, &c.re, if (c.longest) |*l| l else null);
    }

    pub fn initParts(gpa: std.mem.Allocator, re: *const regex.Regex, longest: ?*const Longest) !Finder {
        var f: Finder = .{ .sr = try rx.searcher(re, gpa), .ends_here = null, .oracle = null, .multiline = false };
        errdefer f.deinit();
        if (longest) |l| {
            f.multiline = l.multiline;
            f.ends_here = try rx.searcher(&l.ends_here, gpa);
            if (l.oracle) |*o| f.oracle = try rx.searcher(o, gpa);
        }
        return f;
    }

    pub fn deinit(f: *Finder) void {
        f.sr.deinit();
        if (f.ends_here) |*x| x.deinit();
        if (f.oracle) |*x| x.deinit();
    }

    pub fn find(f: *Finder, hay: []const u8, from: usize) regex.MatchError!?regex.Match {
        const m = (try f.sr.find(hay, from)) orelse return null;
        const ends_here = if (f.ends_here) |*x| x else return m;
        const s0 = m.start();
        const e0 = m.end();
        if (e0 == hay.len) return m;
        if (f.oracle) |*oracle| {
            // The oracle's `^` is the start of its text only.
            const cut: usize = if (f.multiline and s0 > 0 and hay[s0 - 1] == '\n') s0 else 0;
            const best = oracle.find(hay[cut..], s0 - cut) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                // Back-references can exhaust its limits.
                else => return m,
            };
            const found = best orelse return m;
            const end = cut + found.end();
            if (cut + found.start() != s0 or end <= e0) return m;
            return try endingAt(ends_here, hay, s0, end) orelse m;
        }
        var e = @min(hay.len, s0 +| search_window);
        while (e > e0) : (e -= 1) {
            if (try endingAt(ends_here, hay, s0, e)) |longer| return longer;
        }
        return m;
    }

    fn endingAt(sr: *regex.Searcher, hay: []const u8, start: usize, end: usize) regex.MatchError!?regex.Match {
        const m = (try sr.find(hay[0..end], start)) orelse return null;
        return if (m.start() == start) m else null;
    }
};

pub fn compile(gpa: std.mem.Allocator, pat: []const u8, ere: bool, ignore_case: bool) Error!Compiled {
    return compileMode(gpa, pat, ere, ignore_case, false);
}

/// `anchored` demands a match at the start of the subject (expr's `:`).
pub fn compileMode(gpa: std.mem.Allocator, pat: []const u8, ere: bool, ignore_case: bool, anchored: bool) Error!Compiled {
    return compileFull(gpa, pat, ere, ignore_case, anchored, .{});
}

pub fn compileFull(gpa: std.mem.Allocator, pat: []const u8, ere: bool, ignore_case: bool, anchored: bool, opts_in: Opts) Error!Compiled {
    var opts = opts_in;
    opts.icase = ignore_case;
    var flags: Flags = .{};
    const body = try translateFlags(gpa, pat, ere, opts, &flags);
    defer gpa.free(body);
    const src = if (anchored) try std.fmt.allocPrint(gpa, "^(?:{s})", .{body}) else try gpa.dupe(u8, body);
    defer gpa.free(src);
    var re = regex.Regex.compile(gpa, src, .{ .dialect = .perl, .ignore_case = ignore_case, .limits = big_limits }, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPattern,
    };
    errdefer re.deinit(gpa);
    // An anchored match starts at the start, so the oracle needs no anchor.
    const longest = try Longest.compile(gpa, .{ .pattern = pat, .ere = ere, .body = body, .flags = flags, .ignore_case = ignore_case, .utf8 = opts.utf8 });
    return .{ .re = re, .groups = re.groupCount(), .longest = longest };
}

test "translate basic forms" {
    const t = std.testing;
    const gpa = t.allocator;
    const cases = [_][3][]const u8{
        .{ "a\\(b\\)c", "BRE", "a(b)c" },
        .{ "a*", "BRE", "a*" },
        .{ "*a", "BRE", "\\*a" },
        .{ "a+b", "BRE", "a\\+b" },
        .{ "a\\+b", "BRE", "a+b" },
        .{ "a|b", "BRE", "a\\|b" },
        .{ "a\\|b", "BRE", "a|b" },
        .{ "a{2}", "BRE", "a\\{2\\}" },
        .{ "a\\{2,3\\}", "BRE", "a{2,3}" },
        .{ "a(b)+", "ERE", "a(b)+" },
        .{ "^a$", "BRE", "^a$" },
        .{ "a^b", "BRE", "a\\^b" },
        .{ "a$b", "BRE", "a\\$b" },
        .{ "[[:digit:]]", "BRE", "[[:digit:]]" },
        .{ "[\\.]", "BRE", "[\\\\.]" },
    };
    for (cases) |c| {
        const got = try translate(gpa, c[0], std.mem.eql(u8, c[1], "ERE"));
        defer gpa.free(got);
        try t.expectEqualStrings(c[2], got);
    }
}

/// glibc's wording for the common malformed basic regular expressions;
/// posixre only reports that the pattern is bad.
pub fn diagnose(pat: []const u8) []const u8 {
    return diagnoseMode(pat, false);
}

pub fn diagnoseMode(pat: []const u8, ere: bool) []const u8 {
    if (nonAsciiRange(pat)) return "Invalid collation character";
    if (ere and std.mem.eql(u8, pat, "[")) return "Invalid regular expression";
    if (ere) {
        var at_start = true;
        var depth: i32 = 0;
        var i: usize = 0;
        while (i < pat.len) : (i += 1) {
            switch (pat[i]) {
                '\\' => {
                    if (i + 1 >= pat.len) return "Trailing backslash";
                    i += 1;
                    at_start = false;
                },
                '[' => {
                    var j = i + 1;
                    if (j < pat.len and pat[j] == '^') j += 1;
                    if (j < pat.len and pat[j] == ']') j += 1;
                    while (j < pat.len and pat[j] != ']') j += 1;
                    if (j >= pat.len) return "Unmatched [, [^, [:, [., or [=";
                    i = j;
                    at_start = false;
                },
                '(' => {
                    depth += 1;
                    at_start = true;
                },
                ')' => {
                    depth -= 1;
                    if (depth < 0) return "Unmatched ) or \\)";
                    at_start = false;
                },
                '|' => at_start = true,
                '^' => {},
                '*', '+', '?' => {
                    if (at_start) return "Invalid preceding regular expression";
                },
                '{' => {
                    if (at_start) return "Invalid preceding regular expression";
                    const close = std.mem.indexOfScalarPos(u8, pat, i, '}') orelse return "Unmatched { or \\{";
                    _ = close;
                    return "Invalid content of \\{\\}";
                },
                else => at_start = false,
            }
        }
        if (depth > 0) return "Unmatched ( or \\(";
        return "Invalid regular expression";
    }
    if (std.mem.indexOf(u8, pat, "**") != null and std.mem.indexOf(u8, pat, "[") == null and std.mem.indexOf(u8, pat, "\\") == null) return "Invalid preceding regular expression";
    // glibc reports a lone '[' with the generic message.
    if (std.mem.eql(u8, pat, "[")) return "Invalid regular expression";
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        switch (pat[i]) {
            '\\' => {
                if (i + 1 >= pat.len) return "Trailing backslash";
                i += 1;
                switch (pat[i]) {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if (depth < 0) return "Unmatched ) or \\)";
                    },
                    '{' => {
                        const close = std.mem.indexOfPos(u8, pat, i, "\\}") orelse return "Unmatched \\{";
                        _ = close;
                        return "Invalid content of \\{\\}";
                    },
                    else => {},
                }
            },
            '[' => {
                var j = i + 1;
                if (j < pat.len and pat[j] == '^') j += 1;
                if (j < pat.len and pat[j] == ']') j += 1;
                while (j < pat.len and pat[j] != ']') j += 1;
                if (j >= pat.len) return "Unmatched [, [^, [:, [., or [=";
                // Unknown character class names, e.g. [[:foo:]].
                var q = i + 1;
                while (q + 1 < j) : (q += 1) {
                    if (pat[q] == '[' and pat[q + 1] == ':') {
                        const e = std.mem.indexOfPos(u8, pat, q + 2, ":]") orelse break;
                        const name = pat[q + 2 .. e];
                        const known = [_][]const u8{ "alpha", "digit", "alnum", "upper", "lower", "space", "blank", "punct", "print", "graph", "cntrl", "xdigit" };
                        var ok = false;
                        for (known) |k| if (std.mem.eql(u8, k, name)) {
                            ok = true;
                        };
                        if (!ok) return "Invalid character class name";
                        q = e + 1;
                    }
                }
                i = j;
            },
            else => {},
        }
    }
    if (depth > 0) return "Unmatched ( or \\(";
    return "Invalid regular expression";
}


/// True when a bracket expression holds a range with a non-ASCII endpoint.
fn nonAsciiRange(pat: []const u8) bool {
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\') {
            i += 1;
            continue;
        }
        if (pat[i] != '[') continue;
        var j = i + 1;
        if (j < pat.len and pat[j] == '^') j += 1;
        if (j < pat.len and pat[j] == ']') j += 1;
        while (j < pat.len and pat[j] != ']') : (j += 1) {
            if (pat[j] == '-' and j + 1 < pat.len and pat[j + 1] != ']' and j > i + 1) {
                if (pat[j - 1] >= 0x80 or pat[j + 1] >= 0x80) return true;
            }
        }
        i = j;
    }
    return false;
}

/// GNU grep's wording for malformed patterns (dfa.c and glibc regcomp).
pub fn diagnoseGrep(pat: []const u8, ere: bool) []const u8 {
    if (std.mem.eql(u8, pat, "[")) return "Invalid regular expression";
    var open: i32 = 0;
    var closed: u32 = 0;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        const c = pat[i];
        if (c == '\\') {
            if (i + 1 >= pat.len) return "Trailing backslash";
            const n = pat[i + 1];
            i += 1;
            if (!ere and n == '(') {
                open += 1;
            } else if (!ere and n == ')') {
                if (open == 0) return "Unmatched ) or \\)";
                open -= 1;
                closed += 1;
            } else if (!ere and n == '{') {
                const close = std.mem.indexOfPos(u8, pat, i, "\\}") orelse return "Unmatched \\{";
                if (intervalProblem(pat[i + 1 .. close])) |m| return m;
                i = close + 1;
            } else if (n >= '1' and n <= '9') {
                if (n - '0' > closed) return "Invalid back reference";
            }
            continue;
        }
        if (c == '[') {
            var j = i + 1;
            if (j < pat.len and pat[j] == '^') j += 1;
            if (j < pat.len and pat[j] == ']') j += 1;
            var end: ?usize = null;
            var k = j;
            while (k < pat.len) : (k += 1) {
                if (pat[k] == '[' and k + 1 < pat.len and (pat[k + 1] == ':' or pat[k + 1] == '.' or pat[k + 1] == '=')) {
                    const kind = pat[k + 1];
                    const cl = std.mem.indexOfPos(u8, pat, k + 2, &[_]u8{ kind, ']' }) orelse return "Unmatched [, [^, [:, [., or [=";
                    if (kind == ':') {
                        const name = pat[k + 2 .. cl];
                        const known = [_][]const u8{ "alpha", "digit", "alnum", "upper", "lower", "space", "blank", "punct", "print", "graph", "cntrl", "xdigit" };
                        var ok = false;
                        for (known) |kn| if (std.mem.eql(u8, kn, name)) {
                            ok = true;
                        };
                        if (!ok) return "Invalid character class name";
                    }
                    k = cl + 1;
                    continue;
                }
                if (pat[k] == ']') {
                    end = k;
                    break;
                }
                if (pat[k] == '-' and k > j and k + 1 < pat.len and pat[k + 1] != ']' and pat[k - 1] != '[') {
                    if (pat[k - 1] > pat[k + 1] and pat[k - 1] < 0x80 and pat[k + 1] < 0x80) return "Invalid range end";
                }
            }
            if (end == null) return "Unmatched [, [^, [:, [., or [=";
            i = end.?;
            continue;
        }
        if (ere) {
            if (c == '(') open += 1;
            if (c == ')' and open > 0) {
                open -= 1;
                closed += 1;
            }
            if (c == '{' and validInterval(pat[i + 1 ..])) {
                const close = std.mem.indexOfScalarPos(u8, pat, i, '}').?;
                if (intervalProblem(pat[i + 1 .. close])) |m| return m;
                i = close;
            }
        }
    }
    if (open > 0) return "Unmatched ( or \\(";
    return "Invalid regular expression";
}

fn intervalProblem(body: []const u8) ?[]const u8 {
    var lo: u64 = 0;
    var hi: ?u64 = null;
    var comma = false;
    var cur: u64 = 0;
    var have = false;
    for (body) |ch| {
        if (ch == ',') {
            if (comma) return "Invalid content of \\{\\}";
            comma = true;
            lo = cur;
            cur = 0;
            have = false;
        } else if (std.ascii.isDigit(ch)) {
            cur = cur *| 10 +| (ch - '0');
            have = true;
        } else return "Invalid content of \\{\\}";
    }
    if (comma) {
        if (have) hi = cur;
    } else lo = cur;
    if (lo > 0x7fff or (hi != null and hi.? > 0x7fff)) return "Regular expression too big";
    if (hi != null and hi.? < lo) return "Invalid content of \\{\\}";
    return null;
}

/// `[:class:]` written without the outer brackets (a GNU grep error).
pub fn bareClass(pat: []const u8) bool {
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\') {
            i += 1;
            continue;
        }
        if (pat[i] == '[' and i + 1 < pat.len and pat[i + 1] == ':') {
            const close = std.mem.indexOfScalarPos(u8, pat, i + 2, ']') orelse return false;
            if (close >= 2 and pat[close - 1] == ':') return true;
            i = close;
        } else if (pat[i] == '[') {
            const close = std.mem.indexOfScalarPos(u8, pat, i + 1, ']') orelse return false;
            i = close;
        }
    }
    return false;
}

// ---- regex dialect converters shared by find and locate

/// Emacs regex syntax to POSIX ERE: groups, alternation and intervals are
/// backslashed in Emacs and plain in ERE; the postfix operators agree. In the
/// Emacs syntax proper `.` does not match a newline and bracket expressions
/// have no character classes.
pub fn emacsToEre(gpa: std.mem.Allocator, pat: []const u8, strict_emacs: bool) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var at_start = true;
    while (i < pat.len) {
        const c = pat[i];
        if (c == '[') {
            // collect the set up to the first ']' (no [:class:] support)
            i += 1;
            var neg = false;
            if (i < pat.len and pat[i] == '^') {
                neg = true;
                i += 1;
            }
            var members: std.ArrayList(u8) = .empty;
            var has_close = false;
            var has_open = false;
            if (i < pat.len and pat[i] == ']') {
                has_close = true;
                i += 1;
            }
            while (i < pat.len and pat[i] != ']') : (i += 1) {
                if (pat[i] == '[') has_open = true else members.append(gpa, pat[i]) catch return pat;
            }
            const closed = i < pat.len;
            if (closed) i += 1;
            out.append(gpa, '[') catch return pat;
            if (neg) out.append(gpa, '^') catch return pat;
            if (has_close) out.append(gpa, ']') catch return pat;
            out.appendSlice(gpa, members.items) catch return pat;
            if (has_open) out.append(gpa, '[') catch return pat;
            if (closed) out.append(gpa, ']') catch return pat;
            at_start = false;
            continue;
        }
        if (c == '\\' and i + 1 < pat.len) {
            const n = pat[i + 1];
            i += 2;
            switch (n) {
                '(' => {
                    out.append(gpa, '(') catch return pat;
                    at_start = true;
                    continue;
                },
                '|' => {
                    out.append(gpa, '|') catch return pat;
                    at_start = true;
                    continue;
                },
                ')' => out.append(gpa, n) catch return pat,
                '{', '}' => {
                    out.append(gpa, '\\') catch return pat;
                    out.append(gpa, n) catch return pat;
                },
                else => {
                    out.append(gpa, '\\') catch return pat;
                    out.append(gpa, n) catch return pat;
                },
            }
            at_start = false;
            continue;
        }
        switch (c) {
            '.' => {
                if (strict_emacs) out.appendSlice(gpa, "[^\n]") catch return pat else out.append(gpa, '.') catch return pat;
                at_start = false;
            },
            '*', '+', '?' => {
                if (at_start) out.append(gpa, '\\') catch return pat;
                out.append(gpa, c) catch return pat;
            },
            '(', ')', '|', '{', '}' => {
                out.append(gpa, '\\') catch return pat;
                out.append(gpa, c) catch return pat;
                at_start = false;
            },
            '^' => {
                out.append(gpa, c) catch return pat;
            },
            else => {
                out.append(gpa, c) catch return pat;
                at_start = false;
            },
        }
        i += 1;
    }
    return out.items;
}

/// GNU awk syntax: ERE in which a leading repetition operator is literal and
/// (for plain `awk`) intervals are not available.
pub fn awkEre(gpa: std.mem.Allocator, pat: []const u8, no_intervals: bool) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at_start = true;
    var in_br = false;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        const c = pat[i];
        if (in_br) {
            out.append(gpa, c) catch return pat;
            if (c == ']') in_br = false;
            continue;
        }
        if (c == '\\' and i + 1 < pat.len) {
            out.append(gpa, c) catch return pat;
            i += 1;
            out.append(gpa, pat[i]) catch return pat;
            at_start = false;
            continue;
        }
        switch (c) {
            '[' => {
                in_br = true;
                out.append(gpa, c) catch return pat;
                if (i + 1 < pat.len and pat[i + 1] == '^') {
                    i += 1;
                    out.append(gpa, '^') catch return pat;
                }
                if (i + 1 < pat.len and pat[i + 1] == ']') {
                    i += 1;
                    out.append(gpa, ']') catch return pat;
                }
                at_start = false;
            },
            '*', '+', '?' => {
                if (at_start) out.append(gpa, '\\') catch return pat;
                out.append(gpa, c) catch return pat;
            },
            '{', '}' => {
                if (no_intervals or at_start) out.append(gpa, '\\') catch return pat;
                out.append(gpa, c) catch return pat;
                at_start = false;
            },
            '(', '|' => {
                out.append(gpa, c) catch return pat;
                at_start = true;
            },
            '^' => out.append(gpa, c) catch return pat,
            else => {
                out.append(gpa, c) catch return pat;
                at_start = false;
            },
        }
    }
    return out.items;
}

/// POSIX minimal basic syntax: the GNU extensions \| \+ \? are ordinary.
pub fn minimalBasic(gpa: std.mem.Allocator, pat: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pat.len) {
        if (pat[i] == '\\' and i + 1 < pat.len) {
            const n = pat[i + 1];
            i += 2;
            if (n == '|' or n == '+' or n == '?') {
                out.append(gpa, n) catch return pat;
            } else {
                out.append(gpa, '\\') catch return pat;
                out.append(gpa, n) catch return pat;
            }
            continue;
        }
        out.append(gpa, pat[i]) catch return pat;
        i += 1;
    }
    return out.items;
}


test "leftmost-longest agrees with trying every end" {
    const gpa = std.testing.allocator;
    const Case = struct { pattern: []const u8, ere: bool = true, utf8: bool = false };
    const cases = [_]Case{
        .{ .pattern = "a|ab|abc" },
        .{ .pattern = "(a|ab)(c|bcd)?" },
        .{ .pattern = "a|a.*c" },
        .{ .pattern = "(a|b)*c|ab{,2}" },
        .{ .pattern = "[]a{,]|x{,2}b" },
        .{ .pattern = "[[:alpha:]]+|a[^b]*b" },
        .{ .pattern = "^a|^ab|b\\w+" },
        .{ .pattern = "a\\|ab\\{,3\\}\\|\\(c\\|cc\\)", .ere = false },
        .{ .pattern = "(a)\\1|a+b" },
        .{ .pattern = "a|a.c", .utf8 = true },
        // Rejected by the native parser: every end is tried.
        .{ .pattern = "*a|abc" },
    };
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (cases) |case| {
        var c = try compileFull(gpa, case.pattern, case.ere, false, false, .{ .utf8 = case.utf8, .lenient_brace = true });
        defer c.deinit(gpa);
        var finder = try Finder.init(gpa, &c);
        defer finder.deinit();
        var first = try rx.searcher(&c.re, gpa);
        defer first.deinit();
        var ends_here = try rx.searcher(&c.longest.?.ends_here, gpa);
        defer ends_here.deinit();
        for (0..60) |_| {
            var buf: [14]u8 = undefined;
            const hay = buf[0..random.uintLessThan(usize, buf.len)];
            for (hay) |*h| h.* = "aaabbcccd x{,"[random.uintLessThan(usize, 13)];
            var want: ?[2]usize = null;
            if (try first.find(hay, 0)) |m| {
                const start = m.start();
                want = .{ start, m.end() };
                var end = hay.len;
                while (end > want.?[1]) : (end -= 1) {
                    const longer = try Finder.endingAt(&ends_here, hay, start, end) orelse continue;
                    want = .{ start, longer.end() };
                    break;
                }
            }
            const got = try finder.find(hay, 0);
            const span: ?[2]usize = if (got) |m| .{ m.start(), m.end() } else null;
            std.testing.expectEqual(want, span) catch |e| {
                std.debug.print("pattern {s} on '{s}'\n", .{ case.pattern, hay });
                return e;
            };
        }
    }
}
