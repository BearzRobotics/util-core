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

pub const Error = error{ OutOfMemory, BadPattern };

/// Perl-dialect source equivalent to the BRE (or ERE) in `pat`.
pub fn translate(gpa: std.mem.Allocator, pat: []const u8, ere: bool) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    // In a BRE, `*` is literal at the start of an expression, and `^`/`$` are
    // anchors only at the edges of (sub)expressions.
    var at_start = true;
    var depth: usize = 0;
    while (i < pat.len) {
        const c = pat[i];
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
            if (n == '<' or n == '>') {
                try out.appendSlice(gpa, "\\b");
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
                const end = try bracket(gpa, &out, pat, i);
                i = end;
                at_start = false;
            },
            '.' => {
                try out.append(gpa, '.');
                at_start = false;
            },
            '*' => {
                if (at_start and !ere) {
                    try out.appendSlice(gpa, "\\*");
                } else if (at_start and ere) {
                    return error.BadPattern;
                } else {
                    if (!ere and out.items.len > 0 and out.items[out.items.len - 1] == '*' and (out.items.len < 2 or out.items[out.items.len - 2] != '\\')) return error.BadPattern;
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
                    if (depth == 0) return error.BadPattern;
                    depth -= 1;
                    try out.append(gpa, ')');
                } else try out.appendSlice(gpa, "\\)");
                at_start = false;
            },
            '|' => {
                if (ere) {
                    try out.append(gpa, '|');
                    at_start = true;
                } else {
                    try out.appendSlice(gpa, "\\|");
                    at_start = false;
                }
            },
            '+', '?' => {
                if (ere and at_start) return error.BadPattern;
                if (ere and !at_start) try out.append(gpa, c) else {
                    try out.append(gpa, '\\');
                    try out.append(gpa, c);
                }
                at_start = false;
            },
            '{' => {
                if (ere and !at_start) {
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

/// Source of the "must end here" companion regex when `body` (Perl dialect,
/// as produced by `translate`) has an alternation and nothing that looks at
/// the text to the right of the match (`$`, `\b`, `\B`, `\z`, `\Z`).
pub fn longestSource(gpa: std.mem.Allocator, body: []const u8, prefix: []const u8) Error!?[]u8 {
    var alt = false;
    var i: usize = 0;
    var in_br = false;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '\\') {
            if (i + 1 < body.len and !in_br) {
                switch (body[i + 1]) {
                    'b', 'B', 'z', 'Z' => return null,
                    else => {},
                }
            }
            i += 1;
            continue;
        }
        if (in_br) {
            if (c == ']') in_br = false;
            continue;
        }
        switch (c) {
            '[' => {
                in_br = true;
                if (i + 1 < body.len and body[i + 1] == '^') i += 1;
                if (i + 1 < body.len and body[i + 1] == ']') i += 1;
            },
            '$' => return null,
            '|' => alt = true,
            else => {},
        }
    }
    if (!alt) return null;
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
    const body = try translate(gpa, pat, ere);
    defer gpa.free(body);
    const src = if (anchored) try std.fmt.allocPrint(gpa, "^(?:{s})", .{body}) else try gpa.dupe(u8, body);
    defer gpa.free(src);
    var re = regex.Regex.compile(gpa, src, .{ .dialect = .perl, .ignore_case = ignore_case }, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPattern,
    };
    errdefer re.deinit(gpa);
    var longest: ?regex.Regex = null;
    if (try longestSource(gpa, body, "")) |ls| {
        defer gpa.free(ls);
        longest = regex.Regex.compile(gpa, ls, .{ .dialect = .perl, .ignore_case = ignore_case }, null) catch null;
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

