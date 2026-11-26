// SPDX-License-Identifier: GPL-2.0-or-later
//! cmp library (decision 0004): compare two inputs byte by byte.
//! References: GNU diffutils manual "Invoking cmp" (3.12); POSIX.1-2024 cmp.
//!
//! `compare` is the engine: it reports differences as events and returns a
//! summary; `run` formats those events as GNU's text or as `--json` (decision
//! 0003). Offsets and line numbers count from the first byte after the
//! skipped prefix of each input, as GNU does.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");
const json = @import("../json.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Mode = enum {
    /// Report the first difference only (default).
    first_diff,
    /// -l: report every difference.
    all_diffs,
    /// -s: no output, only the status.
    status,
};

pub const Options = struct {
    mode: Mode = .first_diff,
    /// -b: show the differing bytes (text output only).
    print_bytes: bool = false,
    /// -n: compare at most this many bytes.
    limit: u64 = std.math.maxInt(u64),
    /// -i: bytes to skip at the start of each input.
    skip: [2]u64 = .{ 0, 0 },
};

pub const Difference = struct {
    /// 1-based byte number after the skipped prefix.
    byte: u64,
    /// 1-based line number in the first input.
    line: u64,
    /// The differing bytes from the first and the second input.
    a: u8,
    b: u8,
};

/// One input ended before the other.
pub const Eof = struct {
    /// Which input ended (0 or 1).
    file: u1,
    /// Bytes compared before it ended.
    after_byte: u64,
    /// Complete lines before the end (`partial` false) or the number of the
    /// incomplete last line (`partial` true).
    line: u64,
    partial: bool,
};

pub const Event = union(enum) {
    /// Emitted once before the differences with the width GNU gives the byte
    /// number column of `-l`.
    start: u8,
    difference: Difference,
    eof: Eof,
    open_error: struct { file: u1, err: anyerror },
    read_error: struct { file: u1, err: anyerror },
};

pub const Sink = common.Observer(Event);

pub const Summary = struct {
    /// The inputs differ (a difference or one ended early).
    differ: bool = false,
    /// An input could not be opened or read.
    trouble: bool = false,
    /// Number of differing bytes reported.
    differences: u64 = 0,
    /// Bytes compared.
    compared: u64 = 0,
    eof: ?Eof = null,
    first: ?Difference = null,
};

const bufsize = 128 * 1024;

const Side = struct {
    file: Io.File,
    owned: bool,
    is_reg: bool,
    size: u64,
    is_dir: bool,
    buf: []u8,
    len: usize = 0,
    eof: bool = false,
};

fn fill(env: Env, s: *Side) !void {
    s.len = 0;
    while (s.len < s.buf.len and !s.eof) {
        const n = try common.readChunk(env.io, s.file, s.buf[s.len..]);
        if (n == 0) s.eof = true else s.len += n;
    }
}

/// Discard `n` bytes (or until the input ends).
fn skipBytes(env: Env, s: *Side, n: u64) !void {
    var left = n;
    var tmp: [8192]u8 = undefined;
    while (left > 0) {
        const want: usize = @intCast(@min(left, tmp.len));
        const got = try common.readChunk(env.io, s.file, tmp[0..want]);
        if (got == 0) {
            s.eof = true;
            return;
        }
        left -= got;
    }
}

fn digits(v: i128) u8 {
    var x = v;
    var w: u8 = 1;
    while (true) {
        x = @divTrunc(x, 10);
        if (x == 0) break;
        w += 1;
    }
    return w;
}

/// Compare two inputs. Differences and end-of-input conditions go to `sink`.
/// Errors that are not input errors (out of memory) are returned.
pub fn compare(env: Env, options: Options, inputs: [2]Input, sink: Sink) !Summary {
    var sum: Summary = .{};
    var sides: [2]Side = undefined;
    var opened: usize = 0;
    var bufs: [2][]u8 = .{ &.{}, &.{} };
    defer {
        for (bufs) |b| env.gpa.free(b);
    }
    defer {
        for (sides[0..opened]) |s| if (s.owned) s.file.close(env.io);
    }
    for (inputs, 0..) |in, f| {
        const o = openAllowDir(env.io, in) catch |e| {
            sink.emit(.{ .open_error = .{ .file = @intCast(f), .err = e } });
            sum.trouble = true;
            return sum;
        };
        var side: Side = .{ .file = o.file, .owned = o.owned, .is_reg = false, .size = 0, .is_dir = false, .buf = &.{} };
        if (o.file.stat(env.io)) |st| {
            side.is_reg = st.kind == .file;
            side.is_dir = st.kind == .directory;
            side.size = st.size;
        } else |_| {}
        sides[f] = side;
        opened += 1;
    }

    // The same file (same device and inode, same offsets) is equal without
    // reading; two standard inputs likewise.
    if (inputs[0].source == .file and inputs[1].source == .file and
        inputs[0].source.file.handle == inputs[1].source.file.handle and options.skip[0] == options.skip[1]) return sum;
    if (options.skip[0] == options.skip[1] and (sides[0].is_reg or sides[0].is_dir) and sameFile(sides[0].file, sides[1].file)) return sum;
    if (options.limit == 0) return sum;

    for (&sides, 0..) |*s, f| {
        bufs[f] = try env.gpa.alloc(u8, bufsize);
        s.buf = bufs[f];
    }

    var width: u8 = 1;
    if (options.mode == .all_diffs) {
        var maxv: i128 = options.limit;
        for (sides, 0..) |s, f| if (s.is_reg) {
            const fb: i128 = @as(i128, s.size) - @as(i128, options.skip[f]);
            if (fb < maxv) maxv = fb;
        };
        width = digits(maxv);
        sink.emit(.{ .start = width });
    }

    for (&sides, 0..) |*s, f| {
        skipBytes(env, s, options.skip[f]) catch |e| {
            sink.emit(.{ .read_error = .{ .file = @intCast(f), .err = e } });
            sum.trouble = true;
            return sum;
        };
    }

    var remaining: u64 = options.limit;
    var byte_no: u64 = 1; // number of the next byte
    var line_no: u64 = 1;
    var at_line_start = true;
    while (true) {
        inline for (0..2) |f| {
            fill(env, &sides[f]) catch |e| {
                sink.emit(.{ .read_error = .{ .file = @intCast(f), .err = e } });
                sum.trouble = true;
                return sum;
            };
        }
        const n0 = sides[0].len;
        const n1 = sides[1].len;
        var smaller = @min(n0, n1);
        if (remaining < smaller) smaller = @intCast(remaining);
        const a = sides[0].buf[0..smaller];
        const b = sides[1].buf[0..smaller];

        var pos: usize = 0;
        while (pos < smaller) {
            // Skip to the next difference.
            const off = std.mem.indexOfDiff(u8, a[pos..], b[pos..]) orelse smaller - pos;
            const stop = pos + off;
            // Count lines up to `stop` (exclusive).
            if (options.mode != .status) {
                const nl = std.mem.count(u8, a[pos..stop], "\n");
                line_no += nl;
            }
            if (stop >= smaller) {
                if (smaller > 0) at_line_start = a[smaller - 1] == '\n';
                pos = smaller;
                break;
            }
            const d: Difference = .{ .byte = byte_no + stop, .line = line_no, .a = a[stop], .b = b[stop] };
            sum.differ = true;
            sum.differences += 1;
            if (sum.first == null) sum.first = d;
            if (options.mode != .status) sink.emit(.{ .difference = d });
            if (options.mode != .all_diffs) {
                sum.compared = byte_no + stop;
                return sum;
            }
            if (a[stop] == '\n') line_no += 1;
            pos = stop + 1;
        }
        if (smaller > 0) at_line_start = a[smaller - 1] == '\n';
        byte_no += smaller;
        sum.compared += smaller;
        remaining -= smaller;
        if (remaining == 0) return sum;
        // Consume what was compared; bytes beyond `smaller` of the longer
        // input are discarded on EOF but must be kept otherwise.
        if (n0 != n1) {
            // One side ended (fill reads to a full buffer or EOF).
            const f: u1 = if (n0 < n1) 0 else 1;
            const e: Eof = .{
                .file = f,
                .after_byte = byte_no - 1,
                .line = if (at_line_start) line_no - 1 else line_no,
                .partial = !at_line_start,
            };
            if (byte_no - 1 == 0) {
                // nothing compared at all
            }
            sum.differ = true;
            sum.eof = e;
            if (options.mode != .status) sink.emit(.{ .eof = e });
            return sum;
        }
        if (n0 < bufsize) return sum; // both ended together
        // Both buffers were full and fully compared (smaller == n0 unless
        // the limit stopped us, handled above).
    }
}

/// Like `Input.open`, but a directory opens fine: GNU reports "Is a
/// directory" when it first reads, after both operands were opened.
fn openAllowDir(io: Io, in: Input) !Input.Opened {
    return switch (in.source) {
        .path => |p| .{ .file = try Io.Dir.cwd().openFile(io, p, .{ .allow_directory = true }), .owned = true },
        .file => |f| .{ .file = f, .owned = false },
    };
}

fn sameFile(a: Io.File, b: Io.File) bool {
    var e: std.os.linux.E = .SUCCESS;
    const sa = sys.fstatFd(a.handle, &e) orelse return false;
    const sb = sys.fstatFd(b.handle, &e) orelse return false;
    return sys.isSameFile(sa, sb);
}

fn sprintc(buf: *[4]u8, c0: u8) []const u8 {
    var c = c0;
    var n: usize = 0;
    if (c < 32 or c >= 127) {
        if (c >= 128) {
            buf[n] = 'M';
            buf[n + 1] = '-';
            n += 2;
            c -= 128;
        }
        if (c < 32) {
            buf[n] = '^';
            n += 1;
            c += 64;
        } else if (c == 127) {
            buf[n] = '^';
            n += 1;
            c = '?';
        }
    }
    buf[n] = c;
    return buf[0 .. n + 1];
}

fn padNum(w: *Io.Writer, v: u64, width: u8) Io.Writer.Error!void {
    const n = digits(v);
    if (width > n) try w.splatByteAll(' ', width - n);
    try w.print("{d}", .{v});
}

/// GNU's text for one difference.
pub fn writeDifference(w: *Io.Writer, options: Options, names: [2][]const u8, width: u8, d: Difference) Io.Writer.Error!void {
    var b0: [4]u8 = undefined;
    var b1: [4]u8 = undefined;
    switch (options.mode) {
        .first_diff => {
            if (options.print_bytes) {
                try w.print("{s} {s} differ: byte {d}, line {d} is {o: >3} {s} {o: >3} {s}\n", .{ names[0], names[1], d.byte, d.line, d.a, sprintc(&b0, d.a), d.b, sprintc(&b1, d.b) });
            } else {
                try w.print("{s} {s} differ: char {d}, line {d}\n", .{ names[0], names[1], d.byte, d.line });
            }
        },
        .all_diffs => {
            if (options.print_bytes) {
                try padNum(w, d.byte, width);
                try w.print(" {o: >3} {s: <4} {o: >3} {s}\n", .{ d.a, sprintc(&b0, d.a), d.b, sprintc(&b1, d.b) });
            } else {
                try padNum(w, d.byte, width);
                try w.print(" {o: >3} {o: >3}\n", .{ d.a, d.b });
            }
        },
        .status => {},
    }
}

/// The diagnostic GNU prints when one input ends first (without the
/// leading "cmp: " and the trailing newline).
pub fn writeEof(w: *Io.Writer, options: Options, names: [2][]const u8, e: Eof) Io.Writer.Error!void {
    const name = names[e.file];
    if (e.after_byte == 0) return w.print("EOF on '{s}' which is empty", .{name});
    try w.print("EOF on '{s}' after byte {d}", .{ name, e.after_byte });
    if (options.mode == .all_diffs) return;
    if (e.partial) try w.print(", in line {d}", .{e.line}) else try w.print(", line {d}", .{e.line});
}

pub const Format = enum { text, json };

pub const Result = struct {
    /// 0 same, 1 different, 2 trouble.
    status: u8,
};

/// Compare and write the result: GNU text on `writer`, or one JSON object
/// (`--json`). Input problems and EOF are reported to `observer` in text
/// mode; JSON mode carries EOF in the object and reports only problems.
pub fn run(env: Env, options: Options, inputs: [2]Input, format: Format, writer: *Io.Writer, observer: Sink) !Result {
    const names: [2][]const u8 = .{ inputs[0].name orelse "-", inputs[1].name orelse "-" };
    var ctx: RunCtx = .{ .options = options, .names = names, .writer = writer, .format = format, .observer = observer, .env = env };
    defer ctx.list.deinit(env.gpa);
    const sum = try compare(env, options, inputs, .{ .context = &ctx, .func = RunCtx.on });
    if (ctx.write_failed) return error.WriteFailed;
    if (format == .json and !sum.trouble) {
        writeJson(writer, names, options, sum, ctx.list.items) catch return error.WriteFailed;
    }
    return .{ .status = if (sum.trouble) 2 else if (sum.differ) 1 else 0 };
}

const RunCtx = struct {
    options: Options,
    names: [2][]const u8,
    writer: *Io.Writer,
    format: Format,
    observer: Sink,
    env: Env,
    width: u8 = 1,
    write_failed: bool = false,
    list: std.ArrayList(Difference) = .empty,

    fn on(context: ?*anyopaque, ev: Event) void {
        const c: *RunCtx = @ptrCast(@alignCast(context.?));
        switch (ev) {
            .start => |w| c.width = w,
            .difference => |d| switch (c.format) {
                .text => writeDifference(c.writer, c.options, c.names, c.width, d) catch {
                    c.write_failed = true;
                },
                .json => c.list.append(c.env.gpa, d) catch {
                    c.write_failed = true;
                },
            },
            .eof => if (c.format == .text) c.observer.emit(ev),
            else => c.observer.emit(ev),
        }
    }
};

/// The `--json` object for a finished comparison.
pub fn writeJson(w: *Io.Writer, names: [2][]const u8, options: Options, sum: Summary, diffs: []const Difference) Io.Writer.Error!void {
    try w.writeAll("{\"file1\":");
    try json.writeString(w, names[0]);
    try w.writeAll(",\"file2\":");
    try json.writeString(w, names[1]);
    try w.print(",\"equal\":{s}", .{if (sum.differ) "false" else "true"});
    try w.print(",\"bytes_compared\":{d}", .{sum.compared});
    if (sum.first) |d| {
        try w.writeAll(",\"first_difference\":");
        try writeDiffObject(w, d);
    } else try w.writeAll(",\"first_difference\":null");
    if (options.mode == .all_diffs) {
        try w.print(",\"difference_count\":{d},\"differences\":[", .{sum.differences});
        for (diffs, 0..) |d, i| {
            if (i > 0) try w.writeByte(',');
            try writeDiffObject(w, d);
        }
        try w.writeByte(']');
    }
    if (sum.eof) |e| {
        try w.print(",\"eof\":{{\"file\":", .{});
        try json.writeString(w, names[e.file]);
        try w.print(",\"after_byte\":{d},\"line\":{d},\"partial_line\":{s}}}", .{ e.after_byte, e.line, if (e.partial) "true" else "false" });
    } else try w.writeAll(",\"eof\":null");
    try w.writeAll("}\n");
}

fn writeDiffObject(w: *Io.Writer, d: Difference) Io.Writer.Error!void {
    try w.print("{{\"byte\":{d},\"line\":{d},\"byte1\":{d},\"byte2\":{d}}}", .{ d.byte, d.line, d.a, d.b });
}

test "sprintc" {
    var b: [4]u8 = undefined;
    try std.testing.expectEqualStrings("^A", sprintc(&b, 1));
    try std.testing.expectEqualStrings("M-^@", sprintc(&b, 128));
    try std.testing.expectEqualStrings("^?", sprintc(&b, 127));
    try std.testing.expectEqualStrings("M-^?", sprintc(&b, 255));
    try std.testing.expectEqualStrings("e", sprintc(&b, 'e'));
}

test "digits" {
    try std.testing.expectEqual(@as(u8, 1), digits(-5));
    try std.testing.expectEqual(@as(u8, 2), digits(12));
    try std.testing.expectEqual(@as(u8, 3), digits(-100));
}
