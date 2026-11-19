// SPDX-License-Identifier: GPL-2.0-or-later
//! sum library: checksum and block count (BSD or System V algorithm).
//! Reference: GNU coreutils manual "sum invocation" (9.7).
//!
//! Output: "SUM BLOCKS [NAME]". The BSD form (default, -r) writes the 16-bit
//! checksum with five digits and the block count (1024-byte blocks) right
//! aligned in five columns; the System V form (-s) uses plain numbers and
//! 512-byte blocks. A name is printed when the input has one.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const hash = @import("../hash.zig");

pub const Input = common.Input;
pub const Env = common.Env;

pub const Options = struct {
    /// System V algorithm (-s) instead of BSD (-r, the default).
    sysv: bool = false,
};

/// One input could not be opened or read; the run continues with the next.
pub const Event = struct {
    name: []const u8,
    err: anyerror,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// True when at least one input failed (the wrapper exits 1).
    failed: bool = false,
};

/// A computed checksum.
pub const Sum = struct {
    checksum: u64,
    blocks: u64,
};

/// Write one "SUM BLOCKS" line for `s` (the name, when given, follows).
pub fn writeLine(out: *Io.Writer, options: Options, s: Sum, name: ?[]const u8) Io.Writer.Error!void {
    if (options.sysv) {
        try out.print("{d} {d}", .{ s.checksum, s.blocks });
    } else {
        try out.print("{d:0>5} {d: >5}", .{ s.checksum, s.blocks });
    }
    if (name) |n| {
        try out.writeByte(' ');
        try out.writeAll(n);
    }
    try out.writeByte('\n');
}

/// Checksum every input, writing one line each to `out` (the caller flushes
/// it). An input with `name == null` is standard input given implicitly and is
/// printed without a name.
pub fn run(env: Env, options: Options, inputs: []const Input, out: *Io.Writer, observer: Observer) Io.Writer.Error!Result {
    var buf: [64 * 1024]u8 = undefined;
    var result: Result = .{};
    for (inputs) |in| {
        const shown = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            observer.emit(.{ .name = shown, .err = e });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        var bsd: hash.BsdSum = .{};
        var sys5: hash.SysvSum = .{};
        var failed = false;
        while (true) {
            const n = common.readChunk(env.io, opened.file, &buf) catch |e| {
                observer.emit(.{ .name = shown, .err = e });
                failed = true;
                break;
            };
            if (n == 0) break;
            if (options.sysv) sys5.update(buf[0..n]) else bsd.update(buf[0..n]);
        }
        if (failed) {
            result.failed = true;
            continue;
        }
        const s: Sum = if (options.sysv)
            .{ .checksum = sys5.final(), .blocks = (sys5.len + 511) / 512 }
        else
            .{ .checksum = bsd.sum, .blocks = (bsd.len + 1023) / 1024 };
        try writeLine(out, options, s, in.name);
    }
    return result;
}

test "BSD and System V lines" {
    var storage: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&storage);
    try writeLine(&w, .{}, .{ .checksum = 12, .blocks = 3 }, "f");
    try writeLine(&w, .{ .sysv = true }, .{ .checksum = 12, .blocks = 3 }, null);
    try std.testing.expectEqualStrings("00012     3 f\n12 3\n", w.buffered());
}
