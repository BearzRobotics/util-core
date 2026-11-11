// SPDX-License-Identifier: GPL-2.0-or-later
//! Port of the quoting algorithm of GNU quotearg (C locale only), written
//! from the behaviour of coreutils 9.6's lib/quotearg.c (consulted
//! 2026-11-07). Used by ls for file names and by argument diagnostics.
//!
//! Only the C locale is modelled: every byte is its own character, `isprint`
//! is ASCII 0x20..0x7e, and locale quotes are `'...'` (clocale: `"..."`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Style = enum {
    literal,
    shell,
    shell_always,
    shell_escape,
    shell_escape_always,
    c,
    c_maybe,
    escape,
    locale,
    clocale,
};

/// Names accepted by `--quoting-style`, in GNU's order.
pub const style_names = [_][]const u8{
    "literal",
    "shell",
    "shell-always",
    "shell-escape",
    "shell-escape-always",
    "c",
    "c-maybe",
    "escape",
    "locale",
    "clocale",
};

pub const style_values = [_]Style{
    .literal,
    .shell,
    .shell_always,
    .shell_escape,
    .shell_escape_always,
    .c,
    .c_maybe,
    .escape,
    .locale,
    .clocale,
};

/// A set of extra bytes to quote (GNU set_char_quoting).
pub const ExtraSet = struct {
    bits: [256]bool = @splat(false),

    pub fn add(s: *ExtraSet, c: u8) void {
        s.bits[c] = true;
    }
};

fn isPrint(c: u8) bool {
    return c >= 0x20 and c <= 0x7e;
}

const Restyled = struct {
    out: *std.ArrayList(u8),
    gpa: Allocator,
    arg: []const u8,
    extra: ?*const ExtraSet,
};

fn store(r: *Restyled, c: u8) Allocator.Error!void {
    try r.out.append(r.gpa, c);
}

/// Append the quoted form of `arg`.
pub fn quote(out: *std.ArrayList(u8), gpa: Allocator, arg: []const u8, style: Style, extra: ?*const ExtraSet) Allocator.Error!void {
    var r: Restyled = .{ .out = out, .gpa = gpa, .arg = arg, .extra = extra };
    try restyled(&r, style, false);
}

/// Quote into a fresh allocation.
pub fn quoteAlloc(gpa: Allocator, arg: []const u8, style: Style, extra: ?*const ExtraSet) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try quote(&out, gpa, arg, style, extra);
    return out.toOwnedSlice(gpa);
}

fn restyled(r: *Restyled, style_in: Style, elide_flag: bool) Allocator.Error!void {
    const start = r.out.items.len;
    var style = style_in;
    var elide_outer_quotes = elide_flag;
    var extra = r.extra;
    var rerun: bool = true;
    // The loop re-enters once for the "concise single quote" rewrite.
    while (rerun) {
        rerun = false;
        const arg = r.arg;
        var backslash_escapes = false;
        var quote_string: []const u8 = "";
        var encountered_single_quote = false;
        var all_compat = true;
        var pending_shell_escape_end = false;
        var st = style;

        switch (st) {
            .c_maybe => {
                st = .c;
                elide_outer_quotes = true;
                if (!elide_outer_quotes) try store(r, '"');
                backslash_escapes = true;
                quote_string = "\"";
            },
            .c => {
                if (!elide_outer_quotes) try store(r, '"');
                backslash_escapes = true;
                quote_string = "\"";
            },
            .escape => {
                backslash_escapes = true;
                elide_outer_quotes = false;
            },
            .locale, .clocale => {
                const q: []const u8 = if (st == .clocale) "\"" else "'";
                if (!elide_outer_quotes) for (q) |c| try store(r, c);
                backslash_escapes = true;
                quote_string = q;
            },
            .shell_escape => {
                backslash_escapes = true;
                elide_outer_quotes = true;
                st = .shell_always;
                quote_string = "'";
            },
            .shell => {
                elide_outer_quotes = true;
                st = .shell_always;
                quote_string = "'";
            },
            .shell_escape_always => {
                if (!elide_outer_quotes) backslash_escapes = true;
                st = .shell_always;
                if (!elide_outer_quotes) try store(r, '\'');
                quote_string = "'";
            },
            .shell_always => {
                st = .shell_always;
                if (!elide_outer_quotes) try store(r, '\'');
                quote_string = "'";
            },
            .literal => elide_outer_quotes = false,
        }
        // The shell_escape/shell cases above skipped the opening quote: with
        // elide_outer_quotes set none is written, matching GNU.

        var i: usize = 0;
        main: while (i < arg.len) : (i += 1) {
            var c: u8 = arg[i];
            var is_right_quote = false;
            var escaping = false;
            var compat = false;
            var esc: u8 = 0;

            if (backslash_escapes and st != .shell_always and quote_string.len != 0 and
                i + quote_string.len <= arg.len and std.mem.eql(u8, arg[i .. i + quote_string.len], quote_string))
            {
                if (elide_outer_quotes) return force(r, start, st, backslash_escapes);
                is_right_quote = true;
            }

            // What to do after the switch.
            const Next = enum { none, store_c, store_escape, skip };
            var next: Next = .none;

            switch (c) {
                0 => {
                    if (backslash_escapes) {
                        if (elide_outer_quotes) return force(r, start, st, backslash_escapes);
                        escaping = true;
                        if (st == .shell_always and !pending_shell_escape_end) {
                            try store(r, '\'');
                            try store(r, '$');
                            try store(r, '\'');
                            pending_shell_escape_end = true;
                        }
                        try store(r, '\\');
                        if (st != .shell_always and i + 1 < arg.len and arg[i + 1] >= '0' and arg[i + 1] <= '9') {
                            try store(r, '0');
                            try store(r, '0');
                        }
                        c = '0';
                    }
                },
                '?' => {
                    // Trigraph splitting is a flag we never set.
                    if (st == .shell_always and elide_outer_quotes) return force(r, start, st, backslash_escapes);
                },
                7, 8, 12, 11 => {
                    esc = switch (c) {
                        7 => 'a',
                        8 => 'b',
                        12 => 'f',
                        else => 'v',
                    };
                    if (backslash_escapes) {
                        c = esc;
                        next = .store_escape;
                    }
                },
                '\n', '\r', '\t' => {
                    esc = switch (c) {
                        '\n' => 'n',
                        '\r' => 'r',
                        else => 't',
                    };
                    if (st == .shell_always and elide_outer_quotes) return force(r, start, st, backslash_escapes);
                    if (backslash_escapes) {
                        c = esc;
                        next = .store_escape;
                    }
                },
                '\\' => {
                    esc = c;
                    if (st == .shell_always) {
                        if (elide_outer_quotes) return force(r, start, st, backslash_escapes);
                        next = .store_c;
                    } else if (backslash_escapes and elide_outer_quotes and quote_string.len != 0) {
                        next = .store_c;
                    } else {
                        if (backslash_escapes) {
                            c = esc;
                            next = .store_escape;
                        }
                    }
                },
                '{', '}' => {
                    if (arg.len == 1) {
                        // Isolated brace: acts like the shell-special group.
                        if (st == .shell_always and elide_outer_quotes) return force(r, start, st, backslash_escapes);
                    }
                },
                '#', '~' => {
                    if (i == 0) {
                        compat = true;
                        if (st == .shell_always and elide_outer_quotes) return force(r, start, st, backslash_escapes);
                    }
                },
                ' ' => {
                    compat = true;
                    if (st == .shell_always and elide_outer_quotes) return force(r, start, st, backslash_escapes);
                },
                '!', '"', '$', '&', '(', ')', '*', ';', '<', '=', '>', '[', '^', '`', '|' => {
                    if (st == .shell_always and elide_outer_quotes) return force(r, start, st, backslash_escapes);
                },
                '\'' => {
                    encountered_single_quote = true;
                    compat = true;
                    if (st == .shell_always) {
                        if (elide_outer_quotes) return force(r, start, st, backslash_escapes);
                        try store(r, '\'');
                        try store(r, '\\');
                        try store(r, '\'');
                        pending_shell_escape_end = false;
                    }
                },
                '%', '+', ',', '-', '.', '/', '0'...'9', ':', 'A'...'Z', ']', '_', 'a'...'z' => {
                    compat = true;
                },
                else => {
                    const printable = isPrint(c);
                    compat = printable;
                    if (backslash_escapes and !printable) {
                        if (elide_outer_quotes) return force(r, start, st, backslash_escapes);
                        escaping = true;
                        if (st == .shell_always and !pending_shell_escape_end) {
                            try store(r, '\'');
                            try store(r, '$');
                            try store(r, '\'');
                            pending_shell_escape_end = true;
                        }
                        try store(r, '\\');
                        try store(r, '0' + (c >> 6));
                        try store(r, '0' + ((c >> 3) & 7));
                        c = '0' + (c & 7);
                        next = .store_c;
                    }
                },
            }

            if (next == .none) {
                const quoted_extra = ((backslash_escapes and st != .shell_always) or elide_outer_quotes) and
                    extra != null and extra.?.bits[c];
                if (!quoted_extra and !is_right_quote) {
                    next = .store_c;
                } else next = .store_escape;
            }
            if (next == .store_escape) {
                if (elide_outer_quotes) return force(r, start, st, backslash_escapes);
                escaping = true;
                if (st == .shell_always and !pending_shell_escape_end) {
                    try store(r, '\'');
                    try store(r, '$');
                    try store(r, '\'');
                    pending_shell_escape_end = true;
                }
                try store(r, '\\');
            }
            // store_c
            if (pending_shell_escape_end and !escaping) {
                try store(r, '\'');
                try store(r, '\'');
                pending_shell_escape_end = false;
            }
            try store(r, c);
            if (!compat) all_compat = false;
            continue :main;
        }

        if (r.out.items.len == start and st == .shell_always and elide_outer_quotes)
            return force(r, start, st, backslash_escapes);

        if (st == .shell_always and !elide_outer_quotes and encountered_single_quote and all_compat) {
            // A string whose only awkward byte is ' reads better as "...".
            r.out.shrinkRetainingCapacity(start);
            style = .c;
            elide_outer_quotes = false;
            extra = r.extra;
            rerun = true;
            continue;
        }
        if (!elide_outer_quotes) for (quote_string) |q| try store(r, q);
    }
}

/// The GNU `force_outer_quoting_style` path: restart without eliding.
fn force(r: *Restyled, start: usize, style: Style, backslash_escapes: bool) Allocator.Error!void {
    r.out.shrinkRetainingCapacity(start);
    const s: Style = if (style == .shell_always and backslash_escapes) .shell_escape_always else style;
    const saved = r.extra;
    r.extra = null;
    defer r.extra = saved;
    try restyled(r, s, false);
}

test "shell styles" {
    const t = std.testing;
    const a = t.allocator;
    const cases = [_]struct { s: Style, in: []const u8, out: []const u8 }{
        .{ .s = .shell, .in = "abc", .out = "abc" },
        .{ .s = .shell, .in = "a b", .out = "'a b'" },
        .{ .s = .shell, .in = "it's", .out = "\"it's\"" },
        .{ .s = .shell_escape, .in = "a\nb", .out = "'a'$'\\n''b'" },
        .{ .s = .c, .in = "a\"b", .out = "\"a\\\"b\"" },
        .{ .s = .escape, .in = "a\tb", .out = "a\\tb" },
        .{ .s = .literal, .in = "a b", .out = "a b" },
        .{ .s = .shell, .in = "", .out = "''" },
    };
    for (cases) |cs| {
        const got = try quoteAlloc(a, cs.in, cs.s, null);
        defer a.free(got);
        try t.expectEqualStrings(cs.out, got);
    }
}
