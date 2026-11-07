//! wc — count lines, words, characters, bytes and maximum line length.
//! Reference: GNU coreutils wc(1), POSIX wc.
//!
//! Deviations / limits (documented here until docs/compatibility/wc.md exists):
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
const cli = @import("../cli.zig");
const scan = @import("../bytes.zig");

const Counts = struct {
    lines: u64 = 0,
    words: u64 = 0,
    chars: u64 = 0,
    bytes: u64 = 0,
    max_line: u64 = 0,

    fn add(t: *Counts, o: Counts) void {
        t.lines += o.lines;
        t.words += o.words;
        t.chars += o.chars;
        t.bytes += o.bytes;
        t.max_line = @max(t.max_line, o.max_line);
    }
};

const Show = struct { lines: bool = false, words: bool = false, chars: bool = false, bytes: bool = false, max_line: bool = false };

/// Per-file scanning state carried across chunk boundaries.
const Scanner = struct {
    c: Counts = .{},
    in_word: bool = false,
    line_len: u64 = 0,
    /// Only lines and/or bytes are wanted: count newlines with a vector loop
    /// instead of running the per-byte state machine.
    lines_only: bool = false,

    fn feed(s: *Scanner, chunk: []const u8) void {
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

    fn finish(s: *Scanner) Counts {
        s.endLine();
        return s.c;
    }
};

const Result = struct { name: []const u8, counts: ?Counts };

pub fn main(ctx: cli.Context) u8 {
    var show: Show = .{};
    var any = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);

    var only_operands = false;
    for (ctx.args) |a| {
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
        } else if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            if (std.mem.eql(u8, a, "--help")) return help(ctx);
            if (std.mem.eql(u8, a, "--version")) return if (cli.printVersion(ctx)) 0 else 1;
            if (std.mem.eql(u8, a, "--lines")) {
                show.lines = true;
            } else if (std.mem.eql(u8, a, "--words")) {
                show.words = true;
            } else if (std.mem.eql(u8, a, "--chars")) {
                show.chars = true;
            } else if (std.mem.eql(u8, a, "--bytes")) {
                show.bytes = true;
            } else if (std.mem.eql(u8, a, "--max-line-length")) {
                show.max_line = true;
            } else if (std.mem.startsWith(u8, a, "--files0-from") or std.mem.startsWith(u8, a, "--total")) {
                cli.warn(ctx, "option '{s}' is not supported yet", .{a});
                return 1;
            } else return badOption(ctx, a);
            any = true;
        } else {
            for (a[1..]) |c| switch (c) {
                'l' => show.lines = true,
                'w' => show.words = true,
                'm' => show.chars = true,
                'c' => show.bytes = true,
                'L' => show.max_line = true,
                else => return badOption(ctx, a),
            };
            any = true;
        }
    }
    if (!any) show = .{ .lines = true, .words = true, .bytes = true };

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;

    var results: std.ArrayList(Result) = .empty;
    defer results.deinit(ctx.gpa);
    var total: Counts = .{};
    var status: u8 = 0;
    var size_sum: u64 = 0;
    var min_width: usize = 1;
    var buf: [64 * 1024]u8 = undefined;

    for (inputs) |path| {
        const counts = countFile(ctx, path, show, &buf, &size_sum, &min_width) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            status = 1;
            // GNU opens a directory fine and fails on the read, so it still
            // prints a line of zeros for it (and counts it in the total).
            const shown: ?Counts = if (e == error.IsDir) .{} else null;
            results.append(ctx.gpa, .{ .name = path, .counts = shown }) catch return oom(ctx);
            if (e == error.IsDir) min_width = @max(min_width, 7);
            continue;
        };
        total.add(counts);
        results.append(ctx.gpa, .{ .name = path, .counts = counts }) catch return oom(ctx);
    }

    const selected: u32 = @as(u32, @intFromBool(show.lines)) + @intFromBool(show.words) +
        @intFromBool(show.chars) + @intFromBool(show.bytes) + @intFromBool(show.max_line);
    var width: usize = 1;
    if (selected > 1 or inputs.len > 1) {
        width = @max(digits(size_sum), min_width);
    }

    var out = cli.Out.init(ctx.io);
    for (results.items) |r| {
        if (r.counts) |c| printLine(&out, show, c, width, if (files.items.len == 0) null else r.name);
    }
    if (inputs.len > 1) printLine(&out, show, total, width, "total");
    out.flush();
    return if (out.failed) 1 else status;
}

/// Counts one input. As a side effect records what GNU uses to size the
/// columns: the st_size of a regular file is added to `size_sum`; any other
/// kind of input raises `min_width` to 7.
fn countFile(ctx: cli.Context, path: []const u8, show: Show, buf: []u8, size_sum: *u64, min_width: *usize) !Counts {
    const file = try cli.openInput(ctx.io, path);
    defer cli.closeInput(ctx.io, file);
    if (file.stat(ctx.io)) |st| {
        if (st.kind == .file) size_sum.* +|= st.size else min_width.* = 7;
    } else |_| min_width.* = 7;
    var s: Scanner = .{ .lines_only = !show.words and !show.chars and !show.max_line };
    // -c alone: a regular file's size is its byte count (what GNU does too).
    // Size 0 may be a /proc-style file with real content, so read those.
    const only_bytes = show.bytes and !show.lines and !show.words and !show.chars and !show.max_line;
    if (only_bytes and !std.mem.eql(u8, path, "-")) {
        if (file.stat(ctx.io)) |st| {
            if (st.kind == .file and st.size > 0) return .{ .bytes = st.size };
        } else |_| {}
    }
    while (true) {
        const n = try cli.readChunk(ctx.io, file, buf);
        if (n == 0) break;
        s.feed(buf[0..n]);
    }
    return s.finish();
}

fn printLine(out: *cli.Out, show: Show, c: Counts, width: usize, name: ?[]const u8) void {
    var first = true;
    inline for (.{
        .{ show.lines, "lines" },
        .{ show.words, "words" },
        .{ show.chars, "chars" },
        .{ show.bytes, "bytes" },
        .{ show.max_line, "max_line" },
    }) |item| {
        if (item[0]) {
            if (!first) out.writeByte(' ');
            first = false;
            padNumber(out, @field(c, item[1]), width);
        }
    }
    if (name) |n| {
        out.writeByte(' ');
        out.write(n);
    }
    out.writeByte('\n');
}

fn padNumber(out: *cli.Out, value: u64, width: usize) void {
    var tmp: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    var i = s.len;
    while (i < width) : (i += 1) out.writeByte(' ');
    out.write(s);
}

fn digits(n: u64) usize {
    var d: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: wc [OPTION]... [FILE]...\n" ++
        "Print newline, word, and byte counts for each FILE, and a total line if\n" ++
        "more than one FILE is specified. With no FILE, or when FILE is -, read\n" ++
        "standard input.\n\n" ++
        "  -c, --bytes            print the byte counts\n" ++
        "  -m, --chars            print the character counts\n" ++
        "  -l, --lines            print the newline counts\n" ++
        "  -L, --max-line-length  print the maximum display width\n" ++
        "  -w, --words            print the word counts\n")) 0 else 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn badOption(ctx: cli.Context, opt: []const u8) u8 {
    cli.warn(ctx, "invalid option '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
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
