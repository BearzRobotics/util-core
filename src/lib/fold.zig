// SPDX-License-Identifier: GPL-2.0-or-later
//! fold library (decision 0004): wrap input lines to fit a given width.
//! References: GNU coreutils manual "fold invocation" (9.7); POSIX.1-2024.
//!
//! Columns follow POSIX: a tab advances to the next multiple of 8, backspace
//! decrements (never below 0), carriage return resets to 0; with `bytes`
//! every byte is one column. Characters are bytes (C locale); wide and
//! multibyte characters are not interpreted. With `spaces`, a line is broken
//! after the last blank (space or tab) in the pending segment when there is
//! one.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Options = struct {
    /// Maximum width; must be at least 1.
    width: usize = 80,
    /// Count bytes rather than columns.
    bytes: bool = false,
    /// Break at blanks.
    spaces: bool = false,
};

/// A problem with one input; the run continues with the next one. `err` is
/// the open error, or the read error (null: a failure not worth naming; GNU
/// words it "read error").
pub const Event = struct {
    name: []const u8,
    stage: enum { open, read },
    err: ?anyerror = null,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    var out = stickyout.Out.init(writer);
    var result: Result = .{};
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(env.gpa);
    for (inputs) |in| {
        const name = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            observer.emit(.{ .name = name, .stage = .open, .err = e });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        if (!foldFile(env, &out, opened.file, &line, options.width, options.bytes, options.spaces)) {
            observer.emit(.{ .name = name, .stage = .read });
            result.failed = true;
        }
        if (out.failed) break;
    }
    try out.finish();
    return result;
}

/// Column after printing `c` at column `col`.
fn advance(col: usize, c: u8, bytes_mode: bool) usize {
    if (bytes_mode) return col + 1;
    return switch (c) {
        '\r' => 0,
        '\t' => col + 8 - col % 8,
        '\x08' => if (col > 0) col - 1 else 0,
        else => col + 1,
    };
}

fn columnOf(text: []const u8, bytes_mode: bool) usize {
    var col: usize = 0;
    for (text) |c| col = advance(col, c, bytes_mode);
    return col;
}

/// Fold one file. `line` is the pending output segment (reused across files).
/// Returns false on a read error.
fn foldFile(env: Env, out: *stickyout.Out, file: Io.File, line: *std.ArrayList(u8), width: usize, bytes_mode: bool, spaces: bool) bool {
    var buf: [64 * 1024]u8 = undefined;
    var column: usize = 0;
    line.clearRetainingCapacity();
    while (true) {
        const n = common.readChunk(env.io, file, &buf) catch return false;
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c == '\n') {
                line.append(env.gpa, c) catch return false;
                out.write(line.items);
                line.clearRetainingCapacity();
                column = 0;
                continue;
            }
            while (true) {
                const newcol = advance(column, c, bytes_mode);
                if (newcol <= width) {
                    column = newcol;
                    line.append(env.gpa, c) catch return false;
                    break;
                }
                // The character does not fit: break the line first.
                if (spaces) {
                    var end = line.items.len;
                    var found = false;
                    while (end > 0) {
                        end -= 1;
                        if (line.items[end] == ' ' or line.items[end] == '\t') {
                            found = true;
                            break;
                        }
                    }
                    if (found) {
                        const upto = end + 1;
                        out.write(line.items[0..upto]);
                        out.writeByte('\n');
                        const rest = line.items.len - upto;
                        std.mem.copyForwards(u8, line.items[0..rest], line.items[upto..]);
                        line.shrinkRetainingCapacity(rest);
                        column = columnOf(line.items, bytes_mode);
                        continue;
                    }
                }
                if (line.items.len == 0) {
                    // A single character wider than the width: emit it alone.
                    line.append(env.gpa, c) catch return false;
                    column = newcol;
                    break;
                }
                line.append(env.gpa, '\n') catch return false;
                out.write(line.items);
                line.clearRetainingCapacity();
                column = 0;
            }
        }
        if (out.failed) return true;
    }
    if (line.items.len > 0) out.write(line.items);
    line.clearRetainingCapacity();
    return true;
}

test "advance and columnOf" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 8), advance(0, '\t', false));
    try t.expectEqual(@as(usize, 16), advance(8, '\t', false));
    try t.expectEqual(@as(usize, 8), advance(7, '\t', false));
    try t.expectEqual(@as(usize, 0), advance(0, '\x08', false));
    try t.expectEqual(@as(usize, 4), advance(5, '\x08', false));
    try t.expectEqual(@as(usize, 0), advance(9, '\r', false));
    try t.expectEqual(@as(usize, 1), advance(0, '\t', true));
    try t.expectEqual(@as(usize, 3), columnOf("abc", false));
}
