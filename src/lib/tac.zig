// SPDX-License-Identifier: GPL-2.0-or-later
//! tac library (decision 0004): concatenate inputs in reverse record order.
//! Reference: GNU coreutils manual "tac invocation" (9.7). The regular-
//! expression separator (-r) is not implemented.
//!
//! A named regular file is read backwards in windows, so memory stays
//! proportional to the window (and the longest record); pipes, an already
//! open file and size-0 pseudo files are read whole first.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const scan = @import("../bytes.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Options = struct {
    /// The separator is attached to the start of the following record.
    before: bool = false,
    /// Record separator; empty means NUL, as in GNU.
    separator: []const u8 = "\n",
};

pub const Stage = enum { open, read };

/// A problem with one input; the run continues with the next one.
pub const Event = struct {
    name: []const u8,
    stage: Stage,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    const sep: []const u8 = if (options.separator.len == 0) "\x00" else options.separator;
    var out = stickyout.Out.init(writer);
    var result: Result = .{};
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(env.gpa);
    for (inputs) |in| {
        data.clearRetainingCapacity();
        const name = in.name orelse "-";
        tacInput(env, &out, in, sep, options.before, &data, observer) catch |e| {
            if (e != error.Reported) observer.emit(.{ .name = name, .stage = .read, .err = e });
            result.failed = true;
            continue;
        };
    }
    try out.finish();
    return result;
}

fn tacInput(env: Env, out: *stickyout.Out, in: Input, sep: []const u8, before: bool, data: *std.ArrayList(u8), observer: Observer) !void {
    const opened = in.open(env.io) catch |e| {
        observer.emit(.{ .name = in.name orelse "-", .stage = .open, .err = e });
        return error.Reported;
    };
    defer opened.close(env.io);
    const file = opened.file;

    if (in.source == .path) {
        if (file.stat(env.io)) |st| {
            if (st.kind == .file and try common.sizeIsReal(env.io, file, st.size)) return tacBackwards(env, out, file, st.size, sep, before);
        } else |_| {}
    }
    while (true) {
        try data.ensureUnusedCapacity(env.gpa, 64 * 1024);
        const n = try common.readChunk(env.io, file, data.unusedCapacitySlice());
        if (n == 0) break;
        data.items.len += n;
    }
    _ = reverseWindow(out, data.items, sep, before, true);
}

const window_size = 64 * 1024;

/// Read `file` (of `size` bytes) from the end in windows. `carry` is the
/// leftmost piece of the previous window whose beginning is not known yet;
/// it is glued to the right end of the next window and rescanned.
fn tacBackwards(env: Env, out: *stickyout.Out, file: Io.File, size: u64, sep: []const u8, before: bool) !void {
    var window: std.ArrayList(u8) = .empty;
    defer window.deinit(env.gpa);
    var carry_len: usize = 0; // the carry is window.items[0..carry_len] after each pass
    var scratch: std.ArrayList(u8) = .empty; // old carry while the window is rebuilt
    defer scratch.deinit(env.gpa);
    var pos = size;
    while (pos > 0) {
        // Grow the window with the carry so one huge record costs O(n), not O(n^2).
        const want: usize = @intCast(@min(pos, @max(@as(u64, window_size), carry_len)));
        pos -= want;
        try scratch.resize(env.gpa, carry_len);
        @memcpy(scratch.items, window.items[0..carry_len]);
        try window.resize(env.gpa, want + carry_len);
        const got = try file.readPositionalAll(env.io, window.items[0..want], pos);
        if (got != want) return error.UnexpectedEof; // file shrank while reading
        @memcpy(window.items[want..], scratch.items);
        carry_len = reverseWindow(out, window.items, sep, before, pos == 0);
        if (out.failed) return;
    }
}

/// Write the complete records of `data` from the last to the first and return
/// the length of the unfinished piece at the start of `data` (0 when `final`:
/// that piece is then a record too).
///
/// Records end with `sep` (default) or start with it (`before`). With the
/// default, a separator at the very end of `data` terminates the last record
/// and the unterminated piece after the last separator is a record of its own,
/// printed first (GNU). Separators are found right to left, which fixes how
/// overlapping occurrences of a multi-byte separator are paired.
fn reverseWindow(out: *stickyout.Out, data: []const u8, sep: []const u8, before: bool, final: bool) usize {
    var end = data.len; // exclusive end of the not yet written suffix
    if (before) {
        while (lastIndexOfSep(data[0..end], sep)) |p| {
            out.write(data[p..end]);
            end = p;
        }
    } else {
        var cur = data.len;
        if (std.mem.endsWith(u8, data, sep)) cur -= sep.len; // terminator of the last record
        while (lastIndexOfSep(data[0..cur], sep)) |p| {
            out.write(data[p + sep.len .. end]);
            end = p + sep.len;
            cur = p;
        }
    }
    if (final) {
        out.write(data[0..end]);
        return 0;
    }
    return end;
}

fn lastIndexOfSep(hay: []const u8, sep: []const u8) ?usize {
    if (sep.len == 1) return scan.lastIndexOf(hay, sep[0]);
    return std.mem.lastIndexOf(u8, hay, sep);
}
