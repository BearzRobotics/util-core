// SPDX-License-Identifier: GPL-2.0-or-later
//! GNU-style quoting of file names for diagnostics (quotef, quoteaf, quote).
//! Pure formatting, shared by `cli.zig` and the command libraries.

const std = @import("std");
const Io = std.Io;
const unicode = @import("unicode.zig");

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

    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        const name = q.name;
        if (name.len == 0) return w.writeAll("''");
        var has_ctl = false;
        var needs = false;
        var has_squote = false;
        var has_other = false; // specials other than the single quote
        for (name, 0..) |c, i| {
            if (c < 0x20 or c >= 0x7f) {
                has_ctl = true;
                continue;
            }
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
            const ctl = name[i] < 0x20 or name[i] >= 0x7f;
            var j = i;
            while (j < name.len and ((name[j] < 0x20 or name[j] >= 0x7f) == ctl)) j += 1;
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
