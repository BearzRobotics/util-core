// SPDX-License-Identifier: GPL-2.0-or-later
//! yes: repeatedly output a line (library form, decision 0004).
//!
//! The output line (strings joined by single spaces plus newline, default
//! "y\n") is replicated into a fixed 8 KiB buffer so each write is large.
//! Memory use is constant regardless of argument size, unless a single line
//! exceeds the buffer, in which case the line is written directly.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// Strings to repeat; empty means "y".
    strings: []const []const u8 = &.{},
    /// Stop after this many lines; null runs until a write fails (GNU).
    max_lines: ?u64 = null,
};

const buffer_size = 8192;

/// Builds the output line. The caller frees it.
pub fn buildLine(gpa: std.mem.Allocator, strings: []const []const u8) error{OutOfMemory}![]u8 {
    var line_len: usize = 0;
    if (strings.len == 0) {
        line_len = 2;
    } else {
        for (strings) |a| {
            line_len = std.math.add(usize, line_len, a.len + 1) catch return error.OutOfMemory;
        }
    }
    const line = try gpa.alloc(u8, line_len);
    if (strings.len == 0) {
        line[0] = 'y';
        line[1] = '\n';
    } else {
        var at: usize = 0;
        for (strings, 0..) |a, i| {
            @memcpy(line[at..][0..a.len], a);
            at += a.len;
            line[at] = if (i + 1 == strings.len) '\n' else ' ';
            at += 1;
        }
    }
    return line;
}

/// Writes the line over and over. Without `max_lines` it only returns when a
/// write fails (typically a closed pipe): the error is `WriteFailed`.
pub fn run(env: Env, opts: Options, out: *Io.Writer) (Io.Writer.Error || error{OutOfMemory})!void {
    const line = try buildLine(env.gpa, opts.strings);
    defer env.gpa.free(line);

    var buf: [buffer_size]u8 = undefined;
    var per_write: u64 = 1;
    const chunk: []const u8 = if (line.len > buf.len / 2) line else blk: {
        var filled: usize = 0;
        per_write = 0;
        while (filled + line.len <= buf.len) : (filled += line.len) {
            @memcpy(buf[filled..][0..line.len], line);
            per_write += 1;
        }
        break :blk buf[0..filled];
    };

    if (opts.max_lines) |limit| {
        var left = limit;
        while (left > 0) {
            if (left >= per_write) {
                try out.writeAll(chunk);
                left -= per_write;
            } else {
                try out.writeAll(line);
                left -= 1;
            }
        }
        return;
    }
    while (true) try out.writeAll(chunk);
}

test "yes default line" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try run(.{ .io = undefined, .gpa = std.testing.allocator }, .{ .max_lines = 3 }, &aw.writer);
    try std.testing.expectEqualStrings("y\ny\ny\n", aw.written());
}

test "yes joins strings" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try run(.{ .io = undefined, .gpa = std.testing.allocator }, .{ .strings = &.{ "a", "b" }, .max_lines = 2 }, &aw.writer);
    try std.testing.expectEqualStrings("a b\na b\n", aw.written());
}
