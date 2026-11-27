// SPDX-License-Identifier: GPL-2.0-or-later
//! The integrity checks of compressed data that Zig's decoders read past: the
//! trailer of a gzip member or zlib stream, the block checks of an xz stream
//! and the content checksum of a zstd frame.

const std = @import("std");
const flate = std.compress.flate;
const zstd = std.compress.zstd;

/// Whether `out`, all that was decoded from one gzip member or zlib stream,
/// agrees with its trailer.
pub fn flateOk(metadata: flate.Container.Metadata, out: []const u8) bool {
    return switch (metadata) {
        .gzip => |m| m.crc == std.hash.Crc32.hash(out) and m.count == @as(u32, @truncate(out.len)),
        .zlib => |m| m.adler == std.hash.Adler32.hash(out),
        .raw => true,
    };
}

/// Whether the blocks of `stream`, one whole xz stream that has been decoded
/// to `out`, pass their checks. The index at its end says where each block is
/// and how much it decoded to; the check closes the block. A kind of check
/// the format reserves is passed over, as by xz.
pub fn xzOk(stream: []const u8, out: []const u8) bool {
    const header_len = 12;
    const footer_len = 12;
    if (stream.len < header_len + footer_len) return false;
    // The footer repeats the header's flags.
    if (!std.mem.eql(u8, stream[6..8], stream[stream.len - 4 .. stream.len - 2])) return false;
    const kind = stream[7] & 0x0f;
    const size: usize = if (kind == 0) 0 else @as(usize, 4) << @intCast((kind - 1) / 3);
    const backward = (@as(u64, std.mem.readInt(u32, stream[stream.len - 8 ..][0..4], .little)) + 1) * 4;
    if (backward > stream.len - header_len - footer_len) return false;
    const index_at = stream.len - footer_len - @as(usize, @intCast(backward));
    var index = std.Io.Reader.fixed(stream[index_at .. stream.len - footer_len]);
    if ((index.takeByte() catch return false) != 0) return false;
    var count = index.takeLeb128(u64) catch return false;
    var at: usize = header_len;
    var done: usize = 0;
    while (count > 0) : (count -= 1) {
        const unpadded = index.takeLeb128(u64) catch return false;
        const decoded = index.takeLeb128(u64) catch return false;
        if (unpadded < size or unpadded > index_at - at or decoded > out.len - done) return false;
        // The check follows the padding, which rounds the block to four.
        const total = std.mem.alignForward(usize, @intCast(unpadded), 4);
        if (total > index_at - at) return false;
        const stored = stream[at + total - size .. at + total];
        const padding = stream[at + total - size - (total - @as(usize, @intCast(unpadded))) .. at + total - size];
        if (!std.mem.allEqual(u8, padding, 0)) return false;
        const block = out[done..][0..@intCast(decoded)];
        switch (kind) {
            1 => if (std.mem.readInt(u32, stored[0..4], .little) != std.hash.Crc32.hash(block)) return false,
            4 => if (std.mem.readInt(u64, stored[0..8], .little) != std.hash.crc.@"CRC-64/XZ".hash(block)) return false,
            10 => {
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(block, &digest, .{});
                if (!std.mem.eql(u8, stored, &digest)) return false;
            },
            else => {},
        }
        at += total;
        done += block.len;
    }
    return at == index_at and done == out.len;
}

pub const ZstdFrame = struct {
    /// Bytes the frame takes.
    len: usize,
    /// The low half of the XXH64 of its content, when it carries one.
    checksum: ?u32 = null,
};

/// The frame at the start of `data`, found from its headers alone; null when
/// `data` does not start with a whole frame.
pub fn zstdFrame(data: []const u8) ?ZstdFrame {
    var in = std.Io.Reader.fixed(data);
    const magic = in.takeEnum(zstd.Decompress.Frame.Magic, .little) catch return null;
    switch (magic.kind() orelse return null) {
        .skippable => {
            const n = in.takeInt(u32, .little) catch return null;
            in.discardAll(n) catch return null;
            return .{ .len = in.seek };
        },
        .zstandard => {},
    }
    const header = zstd.Decompress.Frame.Zstandard.Header.decode(&in) catch return null;
    while (true) {
        const block = in.takeStruct(zstd.Decompress.Frame.Zstandard.Block.Header, .little) catch return null;
        // A run of one byte is stored as that byte.
        in.discardAll(if (block.type == .rle) 1 else block.size) catch return null;
        if (block.last) break;
    }
    var checksum: ?u32 = null;
    if (header.descriptor.content_checksum_flag) checksum = in.takeInt(u32, .little) catch return null;
    return .{ .len = in.seek, .checksum = checksum };
}

/// Whether `out`, decoded from one zstd frame, has the frame's checksum.
pub fn zstdOk(frame: ZstdFrame, out: []const u8) bool {
    const want = frame.checksum orelse return true;
    return want == @as(u32, @truncate(std.hash.XxHash64.hash(0, out)));
}
