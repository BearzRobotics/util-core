// SPDX-License-Identifier: GPL-2.0-or-later
//! A write-and-forget view of a caller-supplied `*Io.Writer` (decision 0004).
//!
//! Commands that emit many small pieces (ls, du, stat, df) record the first
//! write failure here instead of threading an error through every call; the
//! library entry point reports it once (`error.WriteFailed`) so the caller
//! can word the diagnostic. Nothing here touches standard output on its own.

const std = @import("std");
const Io = std.Io;

pub const Sink = struct {
    w: *Io.Writer,
    failed: bool = false,

    pub fn init(w: *Io.Writer) Sink {
        return .{ .w = w };
    }

    pub fn write(s: *Sink, bytes: []const u8) void {
        if (s.failed) return;
        s.w.writeAll(bytes) catch {
            s.failed = true;
        };
    }

    pub fn writeByte(s: *Sink, byte: u8) void {
        if (s.failed) return;
        s.w.writeByte(byte) catch {
            s.failed = true;
        };
    }

    pub fn print(s: *Sink, comptime fmt: []const u8, args: anytype) void {
        if (s.failed) return;
        s.w.print(fmt, args) catch {
            s.failed = true;
        };
    }

    pub fn flush(s: *Sink) void {
        if (s.failed) return;
        s.w.flush() catch {
            s.failed = true;
        };
    }

    /// `error.WriteFailed` when any write (or the last flush) failed.
    pub fn check(s: *const Sink) error{WriteFailed}!void {
        if (s.failed) return error.WriteFailed;
    }
};
