// SPDX-License-Identifier: GPL-2.0-or-later
//! wc library: count lines, words, characters, bytes and maximum line length
//! of a set of inputs and write the GNU-format table (or the `--json` form).
//! Reference: GNU coreutils wc(1), POSIX wc.
//!
//! Deviations / limits (also in docs/compatibility/wc.md):
//!   - --files0-from, --total=WHEN and locale-specific multibyte handling are
//!     not implemented; -m counts UTF-8 code points (bytes that are not
//!     continuation bytes), independent of locale.
//!   - Column width follows GNU wc.c compute_number_width (behaviour confirmed
//!     against GNU wc 9.7): the width is the digit count of the summed st_size
//!     of the regular-file inputs (stdin included when it is a regular file);
//!     any input that is not a regular file (pipe, tty, device) forces a width
//!     of at least 7; inputs that cannot be opened are ignored.
//!   - Words are separated by ASCII whitespace (space, \t \n \v \f \r).
//!   - -L expands tabs to multiples of 8; printable ASCII has width 1 and every
//!     other byte (controls, bytes >= 0x80) width 0, as in the C locale.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const scan = @import("../bytes.zig");
const wordcount = @import("../wordcount.zig");

pub const Input = common.Input;
pub const Env = common.Env;

pub const Counts = struct {
    lines: u64 = 0,
    words: u64 = 0,
    chars: u64 = 0,
    bytes: u64 = 0,
    max_line: u64 = 0,

    pub fn add(t: *Counts, o: Counts) void {
        t.lines += o.lines;
        t.words += o.words;
        t.chars += o.chars;
        t.bytes += o.bytes;
        t.max_line = @max(t.max_line, o.max_line);
    }
};

/// Which counts to print. All false means the default (lines, words, bytes).
pub const Show = struct { lines: bool = false, words: bool = false, chars: bool = false, bytes: bool = false, max_line: bool = false };

pub const Options = struct {
    show: Show = .{},
    /// One JSON object per input instead of the table.
    json: bool = false,
};

/// Something went wrong with one input; the run continues with the next.
pub const Event = struct {
    /// The input as the caller named it ("-" for standard input).
    name: []const u8,
    err: anyerror,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// True when at least one input failed (the wrapper exits 1).
    failed: bool = false,
};

/// Per-file scanning state carried across chunk boundaries.
pub const Scanner = struct {
    c: Counts = .{},
    in_word: bool = false,
    line_len: u64 = 0,
    /// Only lines and/or bytes are wanted: count newlines with a vector loop
    /// instead of running the per-byte state machine.
    lines_only: bool = false,

    pub fn feed(s: *Scanner, chunk: []const u8) void {
        s.c.bytes += chunk.len;
        if (s.lines_only) {
            s.c.lines += scan.count(chunk, '\n');
            return;
        }
        for (chunk) |b| {
            if ((b & 0xC0) != 0x80) s.c.chars += 1;
            switch (b) {
                '\n' => {
                    s.c.lines += 1;
                    s.endLine();
                    s.in_word = false;
                },
                // GNU: \r and \f end the line for -L purposes.
                '\r', 0x0c => {
                    s.endLine();
                    s.in_word = false;
                },
                '\t' => {
                    s.line_len = (s.line_len / 8 + 1) * 8;
                    s.in_word = false;
                },
                ' ' => {
                    s.line_len += 1;
                    s.in_word = false;
                },
                0x0b => s.in_word = false,
                else => {
                    if (!s.in_word) s.c.words += 1;
                    s.in_word = true;
                    // Only printable ASCII has width (C-locale behaviour).
                    if (b > 0x20 and b < 0x7f) s.line_len += 1;
                },
            }
        }
    }

    fn endLine(s: *Scanner) void {
        s.c.max_line = @max(s.c.max_line, s.line_len);
        s.line_len = 0;
    }

    pub fn finish(s: *Scanner) Counts {
        s.endLine();
        return s.c;
    }
};

const Result_ = struct { name: ?[]const u8, counts: ?Counts };

/// Count every input and write the report to `out`.
pub fn run(env: Env, opts: Options, inputs: []const Input, out: *Io.Writer, obs: Observer) (Io.Writer.Error || error{OutOfMemory})!Result {
    var show = opts.show;
    const any = show.lines or show.words or show.chars or show.bytes or show.max_line;
    if (!any) show = .{ .lines = true, .words = true, .bytes = true };

    var results: std.ArrayList(Result_) = .empty;
    defer results.deinit(env.gpa);
    var total: Counts = .{};
    var res: Result = .{};
    var size_sum: u64 = 0;
    var min_width: usize = 1;
    var buf: [64 * 1024]u8 = undefined;

    for (inputs) |in| {
        const counts = countInput(env, in, show, &buf, &size_sum, &min_width) catch |e| {
            obs.emit(.{ .name = in.name orelse "-", .err = e });
            res.failed = true;
            // GNU opens a directory fine and fails on the read, so it still
            // prints a line of zeros for it (and counts it in the total).
            const shown: ?Counts = if (e == error.IsDir) .{} else null;
            try results.append(env.gpa, .{ .name = in.name, .counts = shown });
            if (e == error.IsDir) min_width = @max(min_width, 7);
            continue;
        };
        total.add(counts);
        try results.append(env.gpa, .{ .name = in.name, .counts = counts });
    }

    const selected: u32 = @as(u32, @intFromBool(show.lines)) + @intFromBool(show.words) +
        @intFromBool(show.chars) + @intFromBool(show.bytes) + @intFromBool(show.max_line);
    var width: usize = 1;
    if (selected > 1 or inputs.len > 1) width = @max(digits(size_sum), min_width);

    if (opts.json) {
        for (results.items) |r| {
            const c = r.counts orelse continue;
            try wordcount.writeEntry(out, jsonEntry(show, c, r.name, false));
        }
        if (inputs.len > 1) try wordcount.writeEntry(out, jsonEntry(show, total, null, true));
        return res;
    }
    for (results.items) |r| {
        if (r.counts) |c| try printLine(out, show, c, width, r.name);
    }
    if (inputs.len > 1) try printLine(out, show, total, width, "total");
    return res;
}

/// The selected counts of one input as a `wordcount.Entry`.
fn jsonEntry(show: Show, c: Counts, file: ?[]const u8, is_total: bool) wordcount.Entry {
    return .{
        .file = file,
        .total = is_total,
        .lines = if (show.lines) c.lines else null,
        .words = if (show.words) c.words else null,
        .chars = if (show.chars) c.chars else null,
        .bytes = if (show.bytes) c.bytes else null,
        .max_line_length = if (show.max_line) c.max_line else null,
    };
}

/// Counts one input. As a side effect records what GNU uses to size the
/// columns: the st_size of a regular file is added to `size_sum`; any other
/// kind of input raises `min_width` to 7.
fn countInput(env: Env, in: Input, show: Show, buf: []u8, size_sum: *u64, min_width: *usize) !Counts {
    const opened = try in.open(env.io);
    defer opened.close(env.io);
    const file = opened.file;
    if (file.stat(env.io)) |st| {
        if (st.kind == .file) size_sum.* +|= st.size else min_width.* = 7;
    } else |_| min_width.* = 7;
    var s: Scanner = .{ .lines_only = !show.words and !show.chars and !show.max_line };
    // -c alone: a regular file's size is its byte count (what GNU does too),
    // when the size can be trusted.
    const only_bytes = show.bytes and !show.lines and !show.words and !show.chars and !show.max_line;
    if (only_bytes and in.source == .path) {
        if (file.stat(env.io)) |st| {
            if (st.kind == .file and try common.sizeIsReal(env.io, file, st.size)) return .{ .bytes = st.size };
        } else |_| {}
    }
    while (true) {
        const n = try common.readChunk(env.io, file, buf);
        if (n == 0) break;
        s.feed(buf[0..n]);
    }
    return s.finish();
}

fn printLine(out: *Io.Writer, show: Show, c: Counts, width: usize, name: ?[]const u8) Io.Writer.Error!void {
    var first = true;
    inline for (.{
        .{ show.lines, "lines" },
        .{ show.words, "words" },
        .{ show.chars, "chars" },
        .{ show.bytes, "bytes" },
        .{ show.max_line, "max_line" },
    }) |item| {
        if (item[0]) {
            if (!first) try out.writeByte(' ');
            first = false;
            try padNumber(out, @field(c, item[1]), width);
        }
    }
    if (name) |n| {
        try out.writeByte(' ');
        try out.writeAll(n);
    }
    try out.writeByte('\n');
}

fn padNumber(out: *Io.Writer, value: u64, width: usize) Io.Writer.Error!void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    var i = s.len;
    while (i < width) : (i += 1) try out.writeByte(' ');
    try out.writeAll(s);
}

fn digits(n: u64) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

test "scanner counts" {
    var s: Scanner = .{};
    s.feed("hello wor");
    s.feed("ld\n\tfoo  bar\n");
    const c = s.finish();
    try std.testing.expectEqual(@as(u64, 2), c.lines);
    try std.testing.expectEqual(@as(u64, 4), c.words);
    try std.testing.expectEqual(@as(u64, 22), c.bytes);
    try std.testing.expectEqual(@as(u64, 16), c.max_line); // "\tfoo  bar" = 8+3+2+3
}
