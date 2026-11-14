// SPDX-License-Identifier: GPL-2.0-or-later
//! `wc` results as data, and their `--json` form (decision 0003).
//!
//! Only the counts the command was asked for are present: an unselected count
//! is omitted, not null (null would mean "unknown"). One object per input,
//! then a last object with `total: true` when there was more than one input.

const std = @import("std");
const Io = std.Io;
const json = @import("json.zig");

pub const Entry = struct {
    /// The input; null for standard input read without an operand.
    file: ?[]const u8,
    total: bool = false,
    lines: ?u64 = null,
    words: ?u64 = null,
    chars: ?u64 = null,
    bytes: ?u64 = null,
    max_line_length: ?u64 = null,
};

/// Write one entry as a JSON object and a newline.
pub fn writeEntry(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    try w.writeAll("{\"file\":");
    try json.writeOptString(w, e.file);
    try w.print(",\"total\":{s}", .{if (e.total) "true" else "false"});
    inline for (.{ "lines", "words", "chars", "bytes", "max_line_length" }) |key| {
        if (@field(e, key)) |n| try w.print(",\"" ++ key ++ "\":{d}", .{n});
    }
    try w.writeAll("}\n");
}

test "json: only selected counts, stdin is null, total is flagged" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeEntry(&w, .{ .file = "a\"b", .lines = 3, .bytes = 10 });
    try writeEntry(&w, .{ .file = null, .words = 2 });
    try writeEntry(&w, .{ .file = null, .total = true, .lines = 1, .words = 2, .chars = 3, .bytes = 4, .max_line_length = 5 });
    try std.testing.expectEqualStrings(
        "{\"file\":\"a\\\"b\",\"total\":false,\"lines\":3,\"bytes\":10}\n" ++
            "{\"file\":null,\"total\":false,\"words\":2}\n" ++
            "{\"file\":null,\"total\":true,\"lines\":1,\"words\":2,\"chars\":3,\"bytes\":4,\"max_line_length\":5}\n",
        w.buffered(),
    );
}
