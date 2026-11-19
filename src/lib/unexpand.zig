// SPDX-License-Identifier: GPL-2.0-or-later
//! unexpand library (decision 0004): convert spaces to tabs.
//! References: GNU coreutils manual "unexpand invocation" (9.7); POSIX.1-2024
//! unexpand. Tab list syntax lives in src/tabs.zig.
//!
//! Model (checked against GNU by differential and randomised tests): runs of
//! blanks are held back; when the column reaches a tab stop they are replaced
//! by one TAB. A single space that reaches a stop after some non-blank text
//! stays a space if the next character is not a blank (a TAB would not save
//! anything); if the run continues it becomes part of the TAB. Held blanks
//! that do not reach a stop are written unchanged. Without `all` only the
//! blanks before the first non-blank of a line are considered. Columns count
//! bytes (C locale).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const tabs = @import("../tabs.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Options = struct {
    stops: tabs.Stops = .{},
    /// Convert all blanks, not just the initial ones.
    all: bool = false,
};

/// A problem with one input; the run continues with the next one.
pub const Event = struct {
    name: []const u8,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    var out = stickyout.Out.init(writer);
    var st: State = .{ .stops = options.stops, .all = options.all, .gpa = env.gpa, .out = &out };
    defer st.pending.deinit(env.gpa);
    var result: Result = .{};
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
            for (buf[0..n]) |c| try st.feed(c);
            if (out.failed) break;
        }
        if (out.failed) break;
    }
    // GNU flushes held blanks at end of each input; here at the very end.
    st.flushPending();
    try out.finish();
    return result;
}

const State = struct {
    stops: tabs.Stops,
    all: bool,
    gpa: std.mem.Allocator,
    out: *stickyout.Out,
    pending: std.ArrayList(u8) = .empty,
    col: usize = 0,
    convert: bool = true,
    /// A non-blank has been seen on this line.
    seen_text: bool = false,
    /// `pending` is one space that reached a stop; undecided until the next byte.
    lone: bool = false,
    /// Blanks in the current run (since the last non-blank).
    run: usize = 0,

    fn flushPending(s: *State) void {
        s.out.write(s.pending.items);
        s.pending.clearRetainingCapacity();
        s.lone = false;
    }

    fn endRun(s: *State) void {
        s.run = 0;
    }

    fn feed(s: *State, c: u8) !void {
        if (s.lone) {
            // The deferred single space: a following blank turns it into a TAB.
            if (s.convert and (c == ' ' or c == '\t') and s.stops.next(s.col) != null) {
                s.out.writeByte('\t');
                s.pending.clearRetainingCapacity();
                s.lone = false;
            } else s.flushPending();
        }
        if (c == '\n') {
            s.flushPending();
            s.out.writeByte('\n');
            s.col = 0;
            s.convert = true;
            s.seen_text = false;
            s.endRun();
            return;
        }
        const blank = c == ' ' or c == '\t';
        if (s.convert and blank) {
            const nxt = s.stops.next(s.col) orelse {
                // Beyond the last tab stop: nothing more to convert on this line.
                s.flushPending();
                s.out.writeByte(c);
                s.convert = false;
                return;
            };
            try s.pending.append(s.gpa, c);
            s.run += 1;
            s.col = if (c == '\t') nxt else s.col + 1;
            if (s.col == nxt) {
                if (s.run == 1 and c == ' ' and s.seen_text) {
                    s.lone = true;
                } else {
                    s.out.writeByte('\t');
                    s.pending.clearRetainingCapacity();
                }
            }
            return;
        }
        s.flushPending();
        s.endRun();
        s.seen_text = true;
        if (s.convert) {
            if (c == '\x08') {
                if (s.col > 0) s.col -= 1;
            } else s.col += 1;
            if (!s.all) s.convert = false;
        }
        s.out.writeByte(c);
    }
};
