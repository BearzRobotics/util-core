// SPDX-License-Identifier: GPL-2.0-or-later
//! comm library (decision 0004): compare two sorted inputs line by line.
//! References: GNU coreutils manual "comm invocation" (9.7); POSIX.1-2024.
//!
//! Lines are compared bytewise (C locale; LC_COLLATE is not consulted).
//! Order checking follows GNU: by default an out-of-order input is reported
//! (once per input) only when an unpairable line has been seen; `.enabled`
//! makes it fatal at once and `.disabled` turns it off.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const lines = @import("../lines.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Check = enum { default, enabled, disabled };

pub const Options = struct {
    /// Suppress column 1, 2 and 3 (lines only in the first input, only in
    /// the second, in both).
    suppress: [3]bool = .{ false, false, false },
    check_order: Check = .default,
    /// Column separator; an empty string is a single NUL byte, as in GNU.
    delimiter: []const u8 = "\t",
    /// Print a summary line.
    total: bool = false,
    /// Line terminator for input and output.
    terminator: u8 = '\n',
};

pub const Kind = enum {
    /// An input could not be opened (`name`, `err`); nothing is compared.
    open_failed,
    /// A read failed; the comparison ends.
    read_failed,
    /// Input number `file` (1 or 2) is out of order.
    file_disorder,
    /// Summary after the run when some input was out of order.
    input_disorder,
};

pub const Event = struct {
    kind: Kind,
    file: u8 = 0,
    name: []const u8 = "",
    err: ?anyerror = null,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

const Side = struct {
    reader: lines.LineReader,
    cur: std.ArrayList(u8) = .empty,
    prev: std.ArrayList(u8) = .empty,
    present: bool = false,
    /// The line before `prev`, for the check made when the input ends.
    before: std.ArrayList(u8) = .empty,
    /// Lines read so far.
    count: u64 = 0,
    warned: bool = false,
    file: Io.File,
    owned: bool,
};

pub fn run(env: Env, options: Options, first: Input, second: Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    const term = options.terminator;
    const sep: []const u8 = if (options.delimiter.len == 0) "\x00" else options.delimiter;

    var sides: [2]Side = undefined;
    var opened: usize = 0;
    defer for (sides[0..opened]) |*s| {
        s.cur.deinit(env.gpa);
        s.prev.deinit(env.gpa);
        s.before.deinit(env.gpa);
        s.reader.deinit();
        if (s.owned) s.file.close(env.io);
    };
    const ins = [2]Input{ first, second };
    for (ins, 0..) |in, k| {
        const o = in.open(env.io) catch |e| {
            observer.emit(.{ .kind = .open_failed, .name = in.name orelse "-", .err = e });
            return .{ .failed = true };
        };
        sides[k] = .{ .reader = lines.LineReader.init(env.gpa, env.io, o.file, term), .file = o.file, .owned = o.owned };
        opened = k + 1;
    }

    var out = stickyout.Out.init(writer);
    const failed = try compare(env, &out, &sides, options, sep, term, observer);
    try out.finish();
    return .{ .failed = failed };
}

fn advance(env: Env, s: *Side) !void {
    std.mem.swap(std.ArrayList(u8), &s.before, &s.prev);
    std.mem.swap(std.ArrayList(u8), &s.prev, &s.cur);
    s.cur.clearRetainingCapacity();
    if (try s.reader.next()) |l| {
        try s.cur.appendSlice(env.gpa, l.text);
        s.present = true;
        s.count += 1;
    } else s.present = false;
}

/// Returns true when the run failed (disorder or a read error).
fn compare(env: Env, out: *stickyout.Out, sides: *[2]Side, options: Options, sep: []const u8, term: u8, observer: Observer) !bool {
    const suppress = options.suppress;
    const check = options.check_order;
    var counts = [3]u64{ 0, 0, 0 };
    var seen_unpairable = false;
    var disorder = false;
    // Prime both sides; the first line of each input is never order-checked.
    for (sides) |*s| advance(env, s) catch return readFail(out, observer);

    while (!out.failed and (sides[0].present or sides[1].present)) {
        const order: i32 = if (!sides[0].present) 1 else if (!sides[1].present) -1 else switch (std.mem.order(u8, sides[0].cur.items, sides[1].cur.items)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
        if (order == 0) {
            counts[2] += 1;
            if (!suppress[2]) emit(out, 2, sides[0].cur.items, suppress, sep, term);
        } else if (order < 0) {
            seen_unpairable = true;
            counts[0] += 1;
            if (!suppress[0]) emit(out, 0, sides[0].cur.items, suppress, sep, term);
        } else {
            seen_unpairable = true;
            counts[1] += 1;
            if (!suppress[1]) emit(out, 1, sides[1].cur.items, suppress, sep, term);
        }
        const checking = check == .enabled or (check == .default and seen_unpairable);
        for (sides, 0..) |*s, k| {
            const move = if (k == 0) order <= 0 else order >= 0;
            if (!move) continue;
            advance(env, s) catch return readFail(out, observer);
            // As in GNU, when an input ends its last two lines are checked
            // again: they may have been read before anything was unpairable.
            const out_of_order = if (s.present)
                std.mem.order(u8, s.prev.items, s.cur.items) == .gt
            else
                s.count >= 2 and std.mem.order(u8, s.before.items, s.prev.items) == .gt;
            if (checking and !s.warned and out_of_order) {
                out.flush();
                observer.emit(.{ .kind = .file_disorder, .file = @intCast(k + 1) });
                s.warned = true;
                disorder = true;
                if (check == .enabled) return true;
            }
        }
    }
    if (options.total) {
        var b: [64]u8 = undefined;
        for (counts) |c| {
            const t = std.fmt.bufPrint(&b, "{d}", .{c}) catch unreachable;
            out.write(t);
            out.write(sep);
        }
        out.write("total");
        out.writeByte(term);
    }
    if (disorder) {
        out.flush();
        observer.emit(.{ .kind = .input_disorder });
        return true;
    }
    return false;
}

/// Write one output line in column `col` (0, 1 or 2).
fn emit(out: *stickyout.Out, col: usize, line: []const u8, suppress: [3]bool, sep: []const u8, term: u8) void {
    var lead: usize = 0;
    if (col >= 1 and !suppress[0]) lead += 1;
    if (col >= 2 and !suppress[1]) lead += 1;
    while (lead > 0) : (lead -= 1) out.write(sep);
    out.write(line);
    out.writeByte(term);
}

fn readFail(out: *stickyout.Out, observer: Observer) bool {
    out.flush();
    observer.emit(.{ .kind = .read_failed });
    return true;
}
