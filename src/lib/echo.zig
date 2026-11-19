// SPDX-License-Identifier: GPL-2.0-or-later
//! echo: write strings separated by spaces (library form, decision 0004).
//!
//! Backslash escapes are interpreted only with `escapes`. POSIXLY_CORRECT/XSI
//! behaviour is not implemented.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// Output the trailing newline (off with -n).
    newline: bool = true,
    /// Interpret backslash escapes (-e).
    escapes: bool = false,
};

/// Writes `strings` separated by spaces. With `escapes`, `\c` stops all
/// output, including the newline.
pub fn run(env: Env, opts: Options, strings: []const []const u8, out: *Io.Writer) Io.Writer.Error!void {
    _ = env;
    for (strings, 0..) |a, i| {
        if (i > 0) try out.writeByte(' ');
        if (opts.escapes) {
            if (try writeEscaped(out, a)) return;
        } else try out.writeAll(a);
    }
    if (opts.newline) try out.writeByte('\n');
}

/// Writes `s` with escapes interpreted. Returns true if \c was seen.
pub fn writeEscaped(out: *Io.Writer, s: []const u8) Io.Writer.Error!bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 == s.len) {
            try out.writeByte(s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'a' => try out.writeByte(7),
            'b' => try out.writeByte(8),
            'c' => return true,
            'e' => try out.writeByte(27),
            'f' => try out.writeByte(12),
            'n' => try out.writeByte('\n'),
            'r' => try out.writeByte('\r'),
            't' => try out.writeByte('\t'),
            'v' => try out.writeByte(11),
            '\\' => try out.writeByte('\\'),
            '0' => { // \0NNN: up to three octal digits after the 0
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i + 1 < s.len and isOct(s[i + 1])) : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                try out.writeByte(@truncate(v));
            },
            'x' => { // \xHH: one or two hex digits; none -> literal "\x"
                var v: u8 = 0;
                var n: usize = 0;
                while (n < 2 and i + 1 < s.len) : (n += 1) {
                    const d = std.fmt.charToDigit(s[i + 1], 16) catch break;
                    i += 1;
                    v = v * 16 + d;
                }
                if (n == 0) try out.writeAll("\\x") else try out.writeByte(v);
            },
            else => {
                try out.writeByte('\\');
                try out.writeByte(s[i]);
            },
        }
    }
    return false;
}

fn isOct(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn render(opts: Options, strings: []const []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    try run(.{ .io = undefined, .gpa = std.testing.allocator }, opts, strings, &aw.writer);
    return aw.toOwnedSlice();
}

test "echo plain and -n" {
    const a = try render(.{}, &.{ "a", "b" });
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("a b\n", a);
    const b = try render(.{ .newline = false }, &.{"x"});
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("x", b);
}

test "echo escapes" {
    const a = try render(.{ .escapes = true }, &.{ "a\\tb\\x41\\0101", "c\\cd", "never" });
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("a\tbAA c", a);
    const b = try render(.{}, &.{"a\\tb"});
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("a\\tb\n", b);
}
