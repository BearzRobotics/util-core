// SPDX-License-Identifier: GPL-2.0-or-later
//! GNU-style quoting of a file name (`quotef` / `quoteaf`), usable from the
//! command libraries, which may not import cli.zig. `cli.Quoted` is the same
//! type's original definition (to be re-exported from here by the coordinator).

const std = @import("std");
const Io = std.Io;

/// A file name as GNU `quotef` prints it in diagnostics (shell-escape quoting
/// with ':' treated as special): plain when safe, otherwise in single quotes
/// (double quotes when the name contains only a ' as the problem), and
/// $'...' runs for control and non-ASCII bytes. Derived by probing GNU
/// coreutils 9.7 (`md5sum NAME` on every ASCII character).
/// Use with `{f}`.
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

