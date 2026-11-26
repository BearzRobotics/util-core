// SPDX-License-Identifier: GPL-2.0-or-later
//! head library (decision 0004): output the first part of each input.
//! References: GNU coreutils manual "head invocation" (9.7); POSIX.1-2024.
//!
//! Inputs are streamed; "all but the last N" buffers the last N items in
//! memory (as GNU does for non-seekable input).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Header = enum { auto, always, never };

pub const Options = struct {
    /// Count bytes instead of lines.
    bytes: bool = false,
    count: u64 = 10,
    /// "all but the last `count`" instead of "the first `count`".
    skip_last: bool = false,
    delimiter: u8 = '\n',
    /// `auto`: a header only when there is more than one input.
    header: Header = .auto,
};

pub const Stage = enum { open, read };

/// A problem with one input; the run continues with the next one. An `open`
/// event with `error.IsDir` is reported by GNU as a read error (GNU opens a
/// directory fine and fails on the first read).
pub const Event = struct {
    name: []const u8,
    stage: Stage,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    const show_header = switch (options.header) {
        .always => true,
        .never => false,
        .auto => inputs.len > 1,
    };

    var out = stickyout.Out.init(writer);
    var result: Result = .{};
    var first = true;
    var buf: [64 * 1024]u8 = undefined;
    for (inputs) |in| {
        const name = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            if (e == error.IsDir and show_header) printHeader(&out, name, &first);
            observer.emit(.{ .name = name, .stage = .open, .err = e });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        const file = opened.file;
        if (show_header) printHeader(&out, name, &first);
        if (head(env, &out, file, options, &buf)) |unread| {
            giveBack(env.io, file, unread);
        } else |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            out.flush();
            observer.emit(.{ .name = name, .stage = .read, .err = e });
            result.failed = true;
        }
    }
    try out.finish();
    return result;
}

fn printHeader(out: *stickyout.Out, name: []const u8, first: *bool) void {
    if (!first.*) out.writeByte('\n');
    first.* = false;
    out.write("==> ");
    out.write(if (std.mem.eql(u8, name, "-")) "standard input" else name);
    out.write(" <==\n");
}

/// POSIX: a utility that stops reading a seekable input before end of file
/// must leave the offset just past the last byte it processed. A no-op for
/// pipes and terminals.
fn giveBack(io: Io, file: Io.File, unread: u64) void {
    if (unread == 0) return;
    const st = file.stat(io) catch return;
    if (st.kind != .file) return;
    io.vtable.fileSeekBy(io.userdata, file, -@as(i64, @intCast(@min(unread, std.math.maxInt(i63))))) catch {};
}

/// Copy the head of `file`. Returns how many bytes were read beyond what was
/// output (to be given back to a seekable input).
fn head(env: Env, out: *stickyout.Out, file: Io.File, cfg: Options, buf: []u8) !u64 {
    if (cfg.skip_last) return headAllButLast(env, out, file, cfg, buf);
    var remaining = cfg.count;
    while (remaining > 0) {
        const n = try common.readChunk(env.io, file, buf);
        if (n == 0) return 0;
        const chunk = buf[0..n];
        if (cfg.bytes) {
            const take: usize = @intCast(@min(remaining, n));
            out.write(chunk[0..take]);
            remaining -= take;
            if (remaining == 0) {
                return n - take;
            }
        } else {
            var start: usize = 0;
            while (remaining > 0) {
                const idx = std.mem.indexOfScalarPos(u8, chunk, start, cfg.delimiter) orelse {
                    start = chunk.len; // no delimiter left: the whole tail belongs to the current line
                    break;
                };
                remaining -= 1;
                start = idx + 1;
            }
            out.write(chunk[0..start]);
            if (remaining == 0) return chunk.len - start;
        }
        if (out.failed) return 0;
    }
    return 0;
}

/// Everything except the last `count` bytes/lines. Holds back at most
/// `count` items (plus one read chunk) in `pending`. Returns the number of
/// bytes held back, which were read but not output.
fn headAllButLast(env: Env, out: *stickyout.Out, file: Io.File, cfg: Options, buf: []u8) !u64 {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(env.gpa);
    var start: usize = 0; // bytes before `start` are already written
    var delims: u64 = 0; // delimiters in pending[start..]
    while (true) {
        const n = try common.readChunk(env.io, file, buf);
        if (n == 0) return pending.items.len - start;
        const chunk = buf[0..n];
        pending.appendSlice(env.gpa, chunk) catch return error.OutOfMemory;
        if (cfg.bytes) {
            const held = pending.items.len - start;
            if (held > cfg.count) {
                const emit: usize = @intCast(held - cfg.count);
                out.write(pending.items[start..][0..emit]);
                start += emit;
            }
        } else {
            for (chunk) |c| delims += @intFromBool(c == cfg.delimiter);
            // Held-back lines are the complete ones (`delims`) plus an unterminated
            // last line, which counts as a line. Release the oldest while more
            // than `count` are held. Only count == 0 can release a partial line.
            while (true) {
                const partial: u64 = @intFromBool(pending.items.len > start and pending.items[pending.items.len - 1] != cfg.delimiter);
                if (delims + partial <= cfg.count) break;
                if (delims == 0) {
                    out.write(pending.items[start..]);
                    start = pending.items.len;
                    break;
                }
                const idx = std.mem.indexOfScalarPos(u8, pending.items, start, cfg.delimiter).?;
                out.write(pending.items[start .. idx + 1]);
                start = idx + 1;
                delims -= 1;
            }
        }
        if (out.failed) return 0;
        // Compact so memory stays proportional to what is held back.
        if (start > 0 and start >= pending.items.len / 2) {
            const rest = pending.items.len - start;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[start..]);
            pending.shrinkRetainingCapacity(rest);
            start = 0;
        }
    }
}
