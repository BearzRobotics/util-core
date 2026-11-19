// SPDX-License-Identifier: GPL-2.0-or-later
//! A write adapter over a caller-supplied `*Io.Writer` whose failures are
//! sticky: after the first failed write `failed` is set and further writes are
//! dropped, so a command library checks once at the end (decision 0004). It
//! has no buffer of its own; buffering belongs to the caller's writer.

const std = @import("std");
const Io = std.Io;

pub const Out = struct {
    w: *Io.Writer,
    failed: bool = false,

    pub fn init(w: *Io.Writer) Out {
        return .{ .w = w };
    }

    pub fn write(o: *Out, bytes: []const u8) void {
        if (o.failed) return;
        o.w.writeAll(bytes) catch {
            o.failed = true;
        };
    }

    pub fn writeByte(o: *Out, byte: u8) void {
        if (o.failed) return;
        o.w.writeByte(byte) catch {
            o.failed = true;
        };
    }

    pub fn print(o: *Out, comptime fmt: []const u8, args: anytype) void {
        if (o.failed) return;
        o.w.print(fmt, args) catch {
            o.failed = true;
        };
    }

    pub fn flush(o: *Out) void {
        if (o.failed) return;
        o.w.flush() catch {
            o.failed = true;
        };
    }

    /// Flush and report the sticky failure as an error.
    pub fn finish(o: *Out) error{WriteFailed}!void {
        o.flush();
        if (o.failed) return error.WriteFailed;
    }
};
