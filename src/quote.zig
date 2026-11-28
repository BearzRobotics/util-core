// SPDX-License-Identifier: GPL-2.0-or-later
//! GNU-style quoting of file names for diagnostics (quotef, quoteaf, quote).
//! Pure formatting, shared by `cli.zig` and the command libraries.

const std = @import("std");
const Io = std.Io;
const unicode = @import("unicode.zig");

/// A name for a status line or a heading, where quoting would get in the way:
/// as it is, except that what a terminal could act on is shown as less shows
/// it: ^X for a control character (a newline too), <U+009B> for a C1 control,
/// <9B> for a byte that is not UTF-8. Use with `{f}`.
pub const Visible = struct {
    name: []const u8,

    pub fn format(v: Visible, w: *Io.Writer) Io.Writer.Error!void {
        var i: usize = 0;
        while (i < v.name.len) {
            const c = v.name[i];
            const d = unicode.decode(v.name, i);
            if (c < 0x20 or c == 0x7f) {
                try w.print("^{c}", .{@as(u8, if (c == 0x7f) '?' else c + '@')});
            } else if (!d.valid) {
                try w.print("<{X:0>2}>", .{c});
            } else if (d.cp >= 0x80 and d.cp < 0xa0) {
                try w.print("<U+{X:0>4}>", .{d.cp});
            } else try w.writeAll(v.name[i .. i + d.len]);
            i += d.len;
        }
    }
};

test "quoted names in a UTF-8 locale" {
    var buf: [128]u8 = undefined;
    for ([_][2][]const u8{
        .{ "caf\xc3\xa9", "caf\xc3\xa9" },
        .{ "caf\xc3\xa9 x", "'caf\xc3\xa9 x'" },
        .{ "c1\xc2\x9bz", "'c1'$'\\302\\233''z'" },
        .{ "bad\x9b", "'bad'$'\\233'" },
    }) |c| try std.testing.expectEqualStrings(c[1], try std.fmt.bufPrint(&buf, "{f}", .{Quoted{ .name = c[0], .utf8 = true }}));
}

test "visible names" {
    var buf: [128]u8 = undefined;
    const got = try std.fmt.bufPrint(&buf, "{f}", .{Visible{ .name = "a b\x1b]0;T\x07\n\x7f \xc3\xa9\xc2\x9b\x9b'" }});
    try std.testing.expectEqualStrings("a b^[]0;T^G^J^? \xc3\xa9<U+009B><9B>'", got);
}

/// A file name as GNU `quotef` prints it in diagnostics (shell-escape quoting
/// with ':' treated as special): plain when safe, otherwise in single quotes
/// (double quotes when the name contains only a ' as the problem), and
/// $'...' runs for control and non-ASCII bytes. Derived by probing GNU
/// coreutils 9.7 (`md5sum NAME` on every ASCII character).
/// Use with `{f}`: `cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), msg })`.
pub const Quoted = struct {
    name: []const u8,
    /// GNU `quoteaf`: quote even when nothing needs it.
    always: bool = false,
    /// A UTF-8 locale: characters from U+00A0 up are printable.
    utf8: bool = false,

    const Part = struct { len: usize, escaped: bool };

    /// The byte or character at `name[i]`, and whether it needs a $'...'.
    fn part(q: Quoted, i: usize) Part {
        const c = q.name[i];
        if (c >= 0x80 and q.utf8) {
            const d = unicode.decode(q.name, i);
            if (d.valid) return .{ .len = d.len, .escaped = d.cp < 0xa0 };
        }
        return .{ .len = 1, .escaped = c < 0x20 or c >= 0x7f };
    }

    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        const name = q.name;
        if (name.len == 0) return w.writeAll("''");
        var has_ctl = false;
        var needs = false;
        var has_squote = false;
        var has_other = false; // specials other than the single quote
        var at: usize = 0;
        while (at < name.len) {
            const i = at;
            const found = q.part(i);
            at += found.len;
            if (found.escaped) {
                has_ctl = true;
                continue;
            }
            const c = name[i];
            switch (c) {
                '\'' => has_squote = true,
                ' ', '!', '"', '$', '&', '(', ')', '*', ';', '<', '=', '>', '?', '[', '\\', '^', '`', '|', ':' => has_other = true,
                '#', '~' => if (i == 0) {
                    has_other = true;
                },
                '{', '}' => if (name.len == 1) {
                    has_other = true;
                },
                else => {},
            }
        }
        needs = has_ctl or has_squote or has_other;
        if (!needs) {
            if (!q.always) return w.writeAll(name);
            try w.writeByte('\'');
            try w.writeAll(name);
            return w.writeByte('\'');
        }
        if (!has_ctl and has_squote and !has_other and std.mem.indexOfAny(u8, name, "\"$`\\") == null) {
            try w.writeByte('"');
            try w.writeAll(name);
            return w.writeByte('"');
        }
        // Printable runs in '...' (a ' becomes '\''), other runs in $'...'.
        var i: usize = 0;
        var first = true;
        while (i < name.len) {
            const ctl = q.part(i).escaped;
            var j = i;
            while (j < name.len and q.part(j).escaped == ctl) j += q.part(j).len;
            if (ctl) {
                if (first) try w.writeAll("''");
                try w.writeAll("$'");
                for (name[i..j]) |c| switch (c) {
                    7 => try w.writeAll("\\a"),
                    8 => try w.writeAll("\\b"),
                    9 => try w.writeAll("\\t"),
                    10 => try w.writeAll("\\n"),
                    11 => try w.writeAll("\\v"),
                    12 => try w.writeAll("\\f"),
                    13 => try w.writeAll("\\r"),
                    else => try w.print("\\{o:0>3}", .{c}),
                };
                try w.writeByte('\'');
            } else {
                try w.writeByte('\'');
                for (name[i..j]) |c| {
                    if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
                }
                try w.writeByte('\'');
            }
            first = false;
            i = j;
        }
    }
};

pub fn quote(name: []const u8) Quoted {
    return .{ .name = name };
}

/// Like `quote`, but a name that needs no quoting is still put in single
/// quotes (GNU `quoteaf`, used in "cannot remove 'x'" style messages).
pub fn quoteA(name: []const u8) Quoted {
    return .{ .name = name, .always = true };
}

/// A string as GNU `quote()` prints it in messages such as "'abc' is not a
/// valid number": single-quoted with C escapes (\\ for a backslash, \' for a
/// quote, \a \b \t \n \v \f \r, and three-digit octal for other control
/// and non-ASCII bytes). Use with `{f}`.
pub const QuotedC = struct {
    text: []const u8,

    pub fn format(q: QuotedC, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('\'');
        for (q.text) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\'' => try w.writeAll("\\'"),
            7 => try w.writeAll("\\a"),
            8 => try w.writeAll("\\b"),
            9 => try w.writeAll("\\t"),
            10 => try w.writeAll("\\n"),
            11 => try w.writeAll("\\v"),
            12 => try w.writeAll("\\f"),
            13 => try w.writeAll("\\r"),
            else => if (c < 0x20 or c >= 0x7f) try w.print("\\{o:0>3}", .{c}) else try w.writeByte(c),
        };
        try w.writeByte('\'');
    }
};

pub fn quoteC(text: []const u8) QuotedC {
    return .{ .text = text };
}

/// Append a file name as GNU find and locate write it to a terminal: every
/// unprintable character becomes '?', so a name cannot send control sequences.
/// In the C locale that is each byte outside printable ASCII; with `utf8`, each
/// unprintable character and each byte that is not part of a valid sequence.
pub fn appendForTerminal(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, utf8: bool) std.mem.Allocator.Error!void {
    var i: usize = 0;
    while (i < name.len) {
        const d: unicode.Decoded = if (utf8) unicode.decode(name, i) else .{ .cp = name[i], .len = 1, .valid = name[i] < 0x80 };
        if (d.valid and unicode.isPrint(d.cp)) {
            try out.appendSlice(gpa, name[i..][0..d.len]);
        } else {
            try out.append(gpa, '?');
            // A character cut off by the end of the name is one '?'.
            if (utf8 and !d.valid and isCutShort(name[i..])) return;
        }
        i += d.len;
    }
}

/// Whether `s` is the beginning of a UTF-8 sequence and nothing else.
fn isCutShort(s: []const u8) bool {
    const need = std.unicode.utf8ByteSequenceLength(s[0]) catch return false;
    if (s.len >= need) return false;
    for (s[1..]) |c| if (c & 0xc0 != 0x80) return false;
    return true;
}

test "appendForTerminal" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try appendForTerminal(&out, t.allocator, "a\x1b[2J\n\x7f caf\xc3\xa9\xc2\x9b\xe9", true);
    try t.expectEqualStrings("a?[2J?? caf\xc3\xa9??", out.items);
    out.clearRetainingCapacity();
    try appendForTerminal(&out, t.allocator, "a\x1b\xc3\xa9", false);
    try t.expectEqualStrings("a???", out.items);
}
