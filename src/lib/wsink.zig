// SPDX-License-Identifier: GPL-2.0-or-later
//! Sticky-failure output sink for command libraries (decision 0004). Same
//! call surface as the old `cli.Out` (write, writeByte, print, flush, `failed`)
//! but it writes to a caller-supplied `*Io.Writer` or an open `Io.File`
//! instead of standard output, so an algorithm that emits bytes from deep
//! inside recursive code does not have to thread an error through every call.
//! After the run, the entry point turns `failed` into `error.WriteFailed`.

const std = @import("std");
const Io = std.Io;

pub const Sink = struct {
    target: Target,
    failed: bool = false,
    /// Why a file target failed.
    file_error: ?Io.File.Writer.Error = null,
    /// The destination file for `initFile` sinks (null for writer sinks).
    file: ?Io.File = null,
    buf: [8192]u8 = undefined,
    len: usize = 0,

    pub const Target = union(enum) {
        writer: *Io.Writer,
        file: struct { io: Io, file: Io.File },
    };

    pub fn initWriter(w: *Io.Writer) Sink {
        return .{ .target = .{ .writer = w } };
    }

    /// A sink that writes straight to `file` (output files of split/csplit).
    pub fn initFile(io: Io, file: Io.File) Sink {
        return .{ .target = .{ .file = .{ .io = io, .file = file } }, .file = file };
    }

    fn emit(o: *Sink, bytes: []const u8) bool {
        switch (o.target) {
            .writer => |w| {
                // Pass through immediately, like the old Out writing to the
                // descriptor, so a later abort loses no more than it used to.
                w.writeAll(bytes) catch return false;
                w.flush() catch return false;
            },
            .file => |f| f.file.writeStreamingAll(f.io, bytes) catch |e| {
                o.file_error = e;
                return false;
            },
        }
        return true;
    }

    pub fn write(o: *Sink, bytes: []const u8) void {
        if (o.failed) return;
        if (bytes.len > o.buf.len - o.len) {
            o.flushLocal();
            if (o.failed) return;
            if (bytes.len >= o.buf.len) {
                if (!o.emit(bytes)) o.failed = true;
                return;
            }
        }
        @memcpy(o.buf[o.len..][0..bytes.len], bytes);
        o.len += bytes.len;
    }

    pub fn writeByte(o: *Sink, byte: u8) void {
        if (o.len < o.buf.len and !o.failed) {
            o.buf[o.len] = byte;
            o.len += 1;
            return;
        }
        o.write(&.{byte});
    }

    pub fn print(o: *Sink, comptime fmt: []const u8, args: anytype) void {
        var tmp: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch {
            o.failed = true;
            return;
        };
        o.write(s);
    }

    fn flushLocal(o: *Sink) void {
        if (o.failed or o.len == 0) return;
        if (!o.emit(o.buf[0..o.len])) o.failed = true;
        o.len = 0;
    }

    /// Push buffered bytes to the target. For a writer target the writer's own
    /// buffer is left for the caller to flush.
    pub fn flush(o: *Sink) void {
        o.flushLocal();
    }
};
