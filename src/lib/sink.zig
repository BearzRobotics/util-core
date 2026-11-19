// SPDX-License-Identifier: GPL-2.0-or-later
//! A failure-remembering output helper over a caller-supplied `*Io.Writer`.
//!
//! Several commands (printf, seq, factor, numfmt) keep producing output and
//! diagnostics after a write has failed and only report the failure once, at
//! the end. `Sink` gives them that behaviour: after the first failed write
//! nothing more is sent to the underlying writer and `failed` stays set; the
//! caller turns it into `error.WriteFailed`.

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
};
