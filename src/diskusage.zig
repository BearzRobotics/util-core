// SPDX-License-Identifier: GPL-2.0-or-later
//! Disk usage per path as data, and its `--json` form (decision 0003).
//!
//! `du` accumulates the same numbers (`Dui` in src/commands/du.zig) and prints
//! them as text; this module holds the finished per-path result. Sizes are
//! bytes, whatever block size or human-readable option the text output uses.
//! `size` is the disk usage (blocks * 512), or the apparent size when the
//! command ran with `--apparent-size`/`-b`.

const std = @import("std");
const Io = std.Io;
const json = @import("json.zig");

pub const Entry = struct {
    path: []const u8,
    /// Bytes; null when the sum overflowed (the text form prints "Infinity").
    size: ?u64,
    /// Number of inodes counted under (and including) the path.
    inodes: u64,
    /// Latest time under the path, per the `--time` kind; null when there is none.
    time: ?i64,
    time_nsec: ?u32,
    /// "mtime", "atime" or "ctime".
    time_kind: []const u8,
    /// The `--total` line (the path is then "total").
    total: bool = false,
};

/// Write one entry as a JSON object (no surrounding brackets, no newline).
pub fn writeEntry(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    try w.writeAll("{\"path\":");
    try json.writeString(w, e.path);
    try w.writeAll(",\"size\":");
    if (e.size) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    try w.print(",\"inodes\":{d},\"time\":", .{e.inodes});
    if (e.time) |t| try w.print("{d}", .{t}) else try w.writeAll("null");
    try w.writeAll(",\"time_nsec\":");
    if (e.time_nsec) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
    try w.print(",\"time_kind\":\"{s}\",\"total\":{s}}}", .{ e.time_kind, if (e.total) "true" else "false" });
}

/// Write the entries as one JSON array, one object per line.
pub fn writeJson(w: *Io.Writer, entries: []const Entry) Io.Writer.Error!void {
    try w.writeByte('[');
    for (entries, 0..) |e, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try writeEntry(w, e);
    }
    try w.writeAll(if (entries.len == 0) "]\n" else "\n]\n");
}

test "json: entries, an overflowed size and a total" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJson(&w, &.{
        .{ .path = "./a\"b", .size = 4096, .inodes = 3, .time = 100, .time_nsec = 5, .time_kind = "mtime" },
        .{ .path = "x", .size = null, .inodes = 1, .time = null, .time_nsec = null, .time_kind = "atime" },
        .{ .path = "total", .size = 8192, .inodes = 4, .time = 100, .time_nsec = 5, .time_kind = "mtime", .total = true },
    });
    try std.testing.expectEqualStrings(
        "[\n{\"path\":\"./a\\\"b\",\"size\":4096,\"inodes\":3,\"time\":100,\"time_nsec\":5,\"time_kind\":\"mtime\",\"total\":false},\n" ++
            "{\"path\":\"x\",\"size\":null,\"inodes\":1,\"time\":null,\"time_nsec\":null,\"time_kind\":\"atime\",\"total\":false},\n" ++
            "{\"path\":\"total\",\"size\":8192,\"inodes\":4,\"time\":100,\"time_nsec\":5,\"time_kind\":\"mtime\",\"total\":true}\n]\n",
        w.buffered(),
    );
}
