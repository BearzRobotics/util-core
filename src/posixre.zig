//! POSIX basic and extended regular expressions (with the GNU extensions
//! \| \+ \? in BRE), translated into the Perl dialect of the regex package
//! (~/de/regex-zig), which has no POSIX dialect yet.
//!
//! Known difference: Perl alternation is leftmost-first, POSIX is
//! leftmost-longest, so `a|ab` against "ab" matches "a" here. Everything else
//! (anchors, intervals, back-references, bracket expressions with character
//! classes) is translated faithfully.
//! References: POSIX.1-2024 XBD 9 (Regular Expressions); GNU grep manual
//! "Regular Expressions".

const std = @import("std");
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
                try out.appendSlice(gpa, "\\b");
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
                    'B' => try out.print(gpa, "(?:(?<={1s})(?={0s})|(?<!{1s})(?!{0s}))", .{ w.items, fl.items }),
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
    /// `(?:body)\z` for patterns with alternation: used to look for a longer
    /// match ending at a given offset (POSIX leftmost-longest).
    longest: ?regex.Regex = null,

    pub fn deinit(c: *Compiled, gpa: std.mem.Allocator) void {
        c.re.deinit(gpa);
        if (c.longest) |*l| l.deinit(gpa);
    }
};

/// Source of the "must end here" companion regex: only for patterns with an
/// alternation of their own and nothing that looks right of the match.
pub fn longestSource(gpa: std.mem.Allocator, body: []const u8, prefix: []const u8, flags: Flags) Error!?[]u8 {
    if (!flags.alt or flags.right) return null;
    return try std.fmt.allocPrint(gpa, "{s}(?:{s})\\z", .{ prefix, body });
}

/// Finds POSIX leftmost-longest matches on top of the leftmost-first engine.
pub const Finder = struct {
    sr: regex.Searcher,
    sr2: ?regex.Searcher,

    pub fn init(gpa: std.mem.Allocator, c: *const Compiled) !Finder {
        return initParts(gpa, &c.re, if (c.longest) |*l| l else null);
    }

    pub fn initParts(gpa: std.mem.Allocator, re: *const regex.Regex, longest: ?*const regex.Regex) !Finder {
        var sr = try re.searcher(gpa);
        errdefer sr.deinit();
        var sr2: ?regex.Searcher = null;
        if (longest) |l| sr2 = try l.searcher(gpa);
        return .{ .sr = sr, .sr2 = sr2 };
    }

    pub fn deinit(f: *Finder) void {
        f.sr.deinit();
        if (f.sr2) |*x| x.deinit();
    }

    pub fn find(f: *Finder, hay: []const u8, from: usize) regex.MatchError!?regex.Match {
        const m = (try f.sr.find(hay, from)) orelse return null;
        const sr2 = if (f.sr2) |*x| x else return m;
        const s0 = m.start();
        const e0 = m.end();
        if (hay.len - e0 > 4096) return m;
        var e = hay.len;
        while (e > e0) : (e -= 1) {
            if (try sr2.find(hay[0..e], s0)) |m2| {
                if (m2.start() == s0) return m2;
            }
        }
        return m;
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
    var longest: ?regex.Regex = null;
    if (try longestSource(gpa, body, "", flags)) |ls| {
        defer gpa.free(ls);
        longest = regex.Regex.compile(gpa, ls, .{ .dialect = .perl, .ignore_case = ignore_case, .limits = big_limits }, null) catch null;
    }
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
