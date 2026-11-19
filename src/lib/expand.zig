// SPDX-License-Identifier: GPL-2.0-or-later
//! expand library (decision 0004): convert tabs to spaces.
//! References: GNU coreutils manual "expand invocation" (9.7); POSIX.1-2024
//! expand. Tab list syntax lives in src/tabs.zig.
//!
//! Columns count bytes (C locale); a backspace decrements the column (not
//! below 0). A tab beyond the last stop of a multi-stop list becomes one
//! space. `initial_only` converts only the tabs before the first non-blank
//! of a line.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const tabs = @import("../tabs.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Options = struct {
    stops: tabs.Stops = .{},
    /// Do not convert tabs after the first non-blank of a line.
    initial_only: bool = false,
};

/// A problem with one input; the run continues with the next one.
pub const Event = struct {
    name: []const u8,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{WriteFailed}!Result {
    const stops = options.stops;
    var out = stickyout.Out.init(writer);
    var result: Result = .{};
    var column: usize = 0;
    var convert = true;
    var buf: [64 * 1024]u8 = undefined;
    for (inputs) |in| {
        const name = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            observer.emit(.{ .name = name, .err = e });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        while (true) {
            const n = common.readChunk(env.io, opened.file, &buf) catch |e| {
                out.flush();
                observer.emit(.{ .name = name, .err = e });
                result.failed = true;
                break;
            };
            if (n == 0) break;
            for (buf[0..n]) |c| {
                if (c == '\n') {
                    out.writeByte('\n');
                    column = 0;
                    convert = true;
                    continue;
                }
                if (!convert) {
                    out.writeByte(c);
                    continue;
                }
                if (c == '\t') {
                    const next = stops.next(column) orelse column + 1;
                    var k = column;
                    while (k < next) : (k += 1) out.writeByte(' ');
                    column = next;
                } else {
                    if (c == '\x08') {
                        if (column > 0) column -= 1;
                    } else column += 1;
                    out.writeByte(c);
                    if (options.initial_only and c != ' ') convert = false;
                }
            }
            if (out.failed) break;
        }
        if (out.failed) break;
    }
    try out.finish();
    return result;
}
