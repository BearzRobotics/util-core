//! Line-at-a-time input for the filter utilities (cut, paste, uniq, fold, nl).
//!
//! A line may be arbitrarily long (POSIX: "line lengths shall be unlimited"),
//! so the buffer grows as needed; memory use is bounded by the longest line.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");

pub const Line = struct {
    /// The line without its terminator. Borrowed from the reader; valid until
    /// the next call to `next`.
    text: []const u8,
    /// False only for a final line that had no terminator.
    terminated: bool,
};

pub const LineReader = struct {
    io: Io,
    file: Io.File,
    gpa: Allocator,
    delim: u8,
    buf: []u8 = &.{},
    /// buf[pos..len] is data read but not yet returned.
    pos: usize = 0,
    len: usize = 0,
    eof: bool = false,

    pub fn init(gpa: Allocator, io: Io, file: Io.File, delim: u8) LineReader {
        return .{ .io = io, .file = file, .gpa = gpa, .delim = delim };
    }

    pub fn deinit(r: *LineReader) void {
        r.gpa.free(r.buf);
        r.buf = &.{};
    }

    /// Next line, or null at end of input. Read errors are returned.
    pub fn next(r: *LineReader) !?Line {
        var scanned: usize = 0; // bytes of buf[pos..len] already known to hold no delimiter
        while (true) {
            if (std.mem.indexOfScalarPos(u8, r.buf[0..r.len], r.pos + scanned, r.delim)) |i| {
                const text = r.buf[r.pos..i];
                r.pos = i + 1;
                return .{ .text = text, .terminated = true };
            }
            scanned = r.len - r.pos;
            if (r.eof) {
                if (r.pos == r.len) return null;
                const text = r.buf[r.pos..r.len];
                r.pos = r.len;
                return .{ .text = text, .terminated = false };
            }
            // Need more data: make room, then read.
            if (r.pos > 0 and (r.pos == r.len or r.pos >= r.buf.len / 2)) {
                const rest = r.len - r.pos;
                std.mem.copyForwards(u8, r.buf[0..rest], r.buf[r.pos..r.len]);
                r.pos = 0;
                r.len = rest;
            }
            if (r.len == r.buf.len) {
                const new_len = @max(r.buf.len * 2, 64 * 1024);
                r.buf = try r.gpa.realloc(r.buf, new_len);
            }
            const n = try cli.readChunk(r.io, r.file, r.buf[r.len..]);
            if (n == 0) r.eof = true else r.len += n;
        }
    }
};

test "LineReader splits lines and flags a missing final terminator" {
    // Exercised indirectly by the shell tests of cut/paste/uniq; this checks
    // the buffer logic with a memory-backed delimiter scan only.
    const t = std.testing;
    var data = [_]u8{ 'a', '\n', 'b', 'c' };
    var r: LineReader = .{ .io = undefined, .file = undefined, .gpa = t.allocator, .delim = '\n', .buf = &data, .pos = 0, .len = 4, .eof = true };
    const l1 = (try r.next()).?;
    try t.expectEqualStrings("a", l1.text);
    try t.expect(l1.terminated);
    const l2 = (try r.next()).?;
    try t.expectEqualStrings("bc", l2.text);
    try t.expect(!l2.terminated);
    try t.expect((try r.next()) == null);
}
