// SPDX-License-Identifier: GPL-2.0-or-later
//! File system usage as data, and its `--json` form (decision 0003).
//!
//! `df` prints text from the same numbers: see `getFieldValues` in
//! src/commands/df.zig. This module holds only the finished values; it reads
//! no mount table and calls no statfs.
//!
//! Units: sizes are always bytes and counts are always plain numbers,
//! whatever block size or human-readable option the text output uses. An
//! unknown value is null. `used` may be negative (a file system reporting
//! more free than total blocks), as in the text output.

const std = @import("std");
const Io = std.Io;
const json = @import("json.zig");

pub const Entry = struct {
    /// The "total" line of `df --total`; the string fields are null then.
    total: bool = false,
    source: ?[]const u8 = null,
    fstype: ?[]const u8 = null,
    target: ?[]const u8 = null,
    /// The operand the entry was requested for, when one was given.
    file: ?[]const u8 = null,
    /// Fundamental block size in bytes.
    block_size: ?u64 = null,
    size: ?i128 = null,
    used: ?i128 = null,
    /// Space available to an unprivileged user.
    avail: ?i128 = null,
    /// Free space including the part reserved for root.
    free: ?i128 = null,
    use_percent: ?u64 = null,
    inodes: ?i128 = null,
    inodes_used: ?i128 = null,
    inodes_avail: ?i128 = null,
    inodes_use_percent: ?u64 = null,
};

fn writeNum(w: *Io.Writer, key: []const u8, v: anytype) Io.Writer.Error!void {
    try w.print(",\"{s}\":", .{key});
    if (v) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
}

/// Write the entries as one JSON array, one object per line.
pub fn writeJson(w: *Io.Writer, entries: []const Entry) Io.Writer.Error!void {
    try w.writeByte('[');
    for (entries, 0..) |e, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try w.print("{{\"total\":{s},\"source\":", .{if (e.total) "true" else "false"});
        try json.writeOptString(w, e.source);
        try w.writeAll(",\"fstype\":");
        try json.writeOptString(w, e.fstype);
        try w.writeAll(",\"target\":");
        try json.writeOptString(w, e.target);
        try w.writeAll(",\"file\":");
        try json.writeOptString(w, e.file);
        try writeNum(w, "block_size", e.block_size);
        try writeNum(w, "size", e.size);
        try writeNum(w, "used", e.used);
        try writeNum(w, "avail", e.avail);
        try writeNum(w, "free", e.free);
        try writeNum(w, "use_percent", e.use_percent);
        try writeNum(w, "inodes", e.inodes);
        try writeNum(w, "inodes_used", e.inodes_used);
        try writeNum(w, "inodes_avail", e.inodes_avail);
        try writeNum(w, "inodes_use_percent", e.inodes_use_percent);
        try w.writeByte('}');
    }
    try w.writeAll(if (entries.len == 0) "]\n" else "\n]\n");
}

test "json: a normal entry, a negative used, unknowns and a total" {
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const entries = [_]Entry{
        .{ .source = "/dev/sda1", .fstype = "ext4", .target = "/", .block_size = 4096, .size = 1000, .used = -5, .avail = 300, .free = 400, .use_percent = 3, .inodes = 10, .inodes_used = 4, .inodes_avail = 6, .inodes_use_percent = 40 },
        .{ .source = "proc", .target = "/proc" },
        .{ .total = true, .size = 5 },
    };
    try writeJson(&w, &entries);
    try std.testing.expectEqualStrings(
        "[\n" ++
            "{\"total\":false,\"source\":\"/dev/sda1\",\"fstype\":\"ext4\",\"target\":\"/\",\"file\":null,\"block_size\":4096,\"size\":1000,\"used\":-5," ++
            "\"avail\":300,\"free\":400,\"use_percent\":3,\"inodes\":10,\"inodes_used\":4,\"inodes_avail\":6,\"inodes_use_percent\":40},\n" ++
            "{\"total\":false,\"source\":\"proc\",\"fstype\":null,\"target\":\"/proc\",\"file\":null,\"block_size\":null,\"size\":null,\"used\":null," ++
            "\"avail\":null,\"free\":null,\"use_percent\":null,\"inodes\":null,\"inodes_used\":null,\"inodes_avail\":null,\"inodes_use_percent\":null},\n" ++
            "{\"total\":true,\"source\":null,\"fstype\":null,\"target\":null,\"file\":null,\"block_size\":null,\"size\":5,\"used\":null," ++
            "\"avail\":null,\"free\":null,\"use_percent\":null,\"inodes\":null,\"inodes_used\":null,\"inodes_avail\":null,\"inodes_use_percent\":null}\n]\n",
        w.buffered(),
    );
}

test "json: no entries is an empty array" {
    var buf: [16]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJson(&w, &.{});
    try std.testing.expectEqualStrings("[]\n", w.buffered());
}
