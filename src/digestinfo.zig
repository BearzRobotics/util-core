// SPDX-License-Identifier: GPL-2.0-or-later
//! A computed checksum as data, and its `--json` form (decision 0003).
//!
//! Message digests (md5, sha*, blake2b, sm3) are byte strings, written as
//! lowercase hex in `digest`; the legacy numeric algorithms (crc, crc32b,
//! bsd, sysv) have a `checksum` number instead and `digest` is null.

const std = @import("std");
const Io = std.Io;
const json = @import("json.zig");

pub const Entry = struct {
    /// The input; null for standard input read without an operand.
    file: ?[]const u8,
    algorithm: []const u8,
    /// Raw digest bytes; null for the numeric algorithms.
    digest: ?[]const u8 = null,
    /// The number the numeric algorithms produce; null for digests.
    checksum: ?u64 = null,
    /// Bytes read, when the algorithm counts them; null otherwise.
    size: ?u64 = null,
    /// 1024-byte blocks for bsd, 512-byte blocks for sysv; null otherwise.
    blocks: ?u64 = null,
};

fn writeOpt(w: *Io.Writer, key: []const u8, v: ?u64) Io.Writer.Error!void {
    try w.print(",\"{s}\":", .{key});
    if (v) |n| try w.print("{d}", .{n}) else try w.writeAll("null");
}

/// Write one entry as a JSON object and a newline.
pub fn writeJson(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    try w.writeAll("{\"file\":");
    try json.writeOptString(w, e.file);
    try w.print(",\"algorithm\":\"{s}\",\"digest\":", .{e.algorithm});
    if (e.digest) |d| {
        try w.writeByte('"');
        for (d) |b| try w.print("{x:0>2}", .{b});
        try w.writeByte('"');
    } else try w.writeAll("null");
    try writeOpt(w, "checksum", e.checksum);
    try writeOpt(w, "size", e.size);
    try writeOpt(w, "blocks", e.blocks);
    try w.writeAll("}\n");
}

test "json: a digest and a numeric checksum" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJson(&w, .{ .file = "f", .algorithm = "md5", .digest = &.{ 0x00, 0xab, 0xff } });
    try writeJson(&w, .{ .file = null, .algorithm = "bsd", .checksum = 7, .size = 10, .blocks = 1 });
    try std.testing.expectEqualStrings(
        "{\"file\":\"f\",\"algorithm\":\"md5\",\"digest\":\"00abff\",\"checksum\":null,\"size\":null,\"blocks\":null}\n" ++
            "{\"file\":null,\"algorithm\":\"bsd\",\"digest\":null,\"checksum\":7,\"size\":10,\"blocks\":1}\n",
        w.buffered(),
    );
}
