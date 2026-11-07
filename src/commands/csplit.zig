//! csplit — split a file into sections determined by context lines.
//! Reference: GNU coreutils manual "csplit invocation" (9.7); POSIX.1-2024
//! csplit.
//!
//! The control flow of GNU csplit.c (coreutils 9.6 sources, consulted
//! 2026-11-07) is kept, including its order of side effects: output files are
//! created as each piece starts, the byte count of a piece is printed when it
//! is closed (also for the piece being written when an error stops the run),
//! and files created so far are removed on error unless -k is given. The whole
//! input is read into memory and indexed by line instead of being buffered in
//! 8 KiB blocks, which does not change observable behaviour.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const posixre = @import("../posixre.zig");
const Io = std.Io;

const help_text = @embedFile("../help/csplit.txt");

const Control = struct {
    offset: i64 = 0,
    lines_required: i64 = 0,
    repeat: i64 = 0,
    argnum: usize = 0,
    repeat_forever: bool = false,
    ignore: bool = false,
    regexpr: bool = false,
    re: ?posixre.Compiled = null,
};

const Line = struct { start: usize, len: usize };

const State = struct {
    ctx: cli.Context,
    gpa: std.mem.Allocator,
    out: cli.Out, // stdout (counts)
    data: []u8 = &.{},
    lines: std.ArrayList(Line) = .empty,
    first_available: usize = 1,
    current_line: i64 = 0,
    prefix: []const u8 = "xx",
    suffix: ?[]const u8 = null,
    digits: usize = 2,
    files_created: usize = 0,
    bytes_written: i64 = 0,
    out_file: ?Io.File = null,
    out_name: []const u8 = "",
    wbuf: std.ArrayList(u8) = .empty,
    suppress_count: bool = false,
    remove_files: bool = true,
    elide_empty_files: bool = false,
    suppress_matched: bool = false,
    args: []const []const u8 = &.{},
    controls: std.ArrayList(Control) = .empty,
    read_error: ?[]const u8 = null,

    fn ensureLoaded(s: *State) void {
        if (s.read_error) |msg| {
            cli.warn(s.ctx, "{s}", .{msg});
            s.cleanupFatal();
        }
    }

    fn lineAt(s: *const State, n: i64) ?Line {
        if (n < 1) return null;
        const i: usize = @intCast(n);
        if (i > s.lines.items.len) return null;
        return s.lines.items[i - 1];
    }

    fn findLine(s: *State, n: i64) ?Line {
        s.ensureLoaded();
        return s.lineAt(n);
    }

    /// First line not yet removed, or 0 when none is left.
    fn getFirstLine(s: *State) i64 {
        s.ensureLoaded();
        return if (s.first_available <= s.lines.items.len) @intCast(s.first_available) else 0;
    }

    fn removeLine(s: *State) ?Line {
        s.ensureLoaded();
        if (s.first_available > s.lines.items.len) return null;
        if (s.current_line < @as(i64, @intCast(s.first_available))) s.current_line = @intCast(s.first_available);
        const l = s.lines.items[s.first_available - 1];
        s.first_available += 1;
        return l;
    }

    fn noMoreLines(s: *State) bool {
        return s.findLine(s.current_line + 1) == null;
    }

    fn makeFilename(s: *State, num: usize, buf: *std.ArrayList(u8)) !void {
        buf.clearRetainingCapacity();
        try buf.appendSlice(s.gpa, s.prefix);
        if (s.suffix) |sf| {
            try formatSuffix(s.gpa, buf, sf, @intCast(num));
        } else {
            var tmp: [32]u8 = undefined;
            const d = std.fmt.bufPrint(&tmp, "{d}", .{num}) catch unreachable;
            if (d.len < s.digits) try buf.appendNTimes(s.gpa, '0', s.digits - d.len);
            try buf.appendSlice(s.gpa, d);
        }
    }

    fn createOutputFile(s: *State) void {
        var name: std.ArrayList(u8) = .empty;
        s.makeFilename(s.files_created, &name) catch s.fatal();
        const file = Io.Dir.cwd().createFile(s.ctx.io, name.items, .{ .truncate = true }) catch |e| {
            cli.warn(s.ctx, "{f}: {s}", .{ cli.quote(name.items), cli.errText(e) });
            name.deinit(s.gpa);
            s.cleanupFatal();
        };
        s.files_created += 1;
        if (s.out_name.len > 0) s.gpa.free(s.out_name);
        s.out_name = s.gpa.dupe(u8, name.items) catch s.fatal();
        name.deinit(s.gpa);
        s.out_file = file;
        s.bytes_written = 0;
        s.wbuf.clearRetainingCapacity();
    }

    fn flushOut(s: *State) bool {
        if (s.out_file) |f| {
            if (s.wbuf.items.len > 0) {
                f.writeStreamingAll(s.ctx.io, s.wbuf.items) catch return false;
                s.wbuf.clearRetainingCapacity();
            }
        }
        return true;
    }

    fn closeOutputFile(s: *State) void {
        const f = s.out_file orelse return;
        if (!s.flushOut()) {
            cli.warn(s.ctx, "write error for {f}", .{cli.quoteA(s.out_name)});
            s.out_file = null;
            s.cleanupFatal();
        }
        f.close(s.ctx.io);
        s.out_file = null;
        if (s.bytes_written == 0 and s.elide_empty_files) {
            Io.Dir.cwd().deleteFile(s.ctx.io, s.out_name) catch {};
            s.files_created -= 1;
        } else if (!s.suppress_count) {
            s.out.print("{d}\n", .{s.bytes_written});
        }
    }

    fn deleteAllFiles(s: *State) void {
        if (!s.remove_files) return;
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(s.gpa);
        var i = s.files_created;
        while (i > 0) {
            i -= 1;
            s.makeFilename(i, &name) catch continue;
            Io.Dir.cwd().deleteFile(s.ctx.io, name.items) catch |e| {
                if (e != error.FileNotFound) cli.warn(s.ctx, "{f}: {s}", .{ cli.quote(name.items), cli.errText(e) });
            };
        }
        s.files_created = 0;
    }

    fn cleanupFatal(s: *State) noreturn {
        s.closeOutputFile();
        s.deleteAllFiles();
        s.out.flush();
        std.process.exit(1);
    }

    fn fatal(s: *State) noreturn {
        cli.warn(s.ctx, "memory exhausted", .{});
        s.cleanupFatal();
    }

    fn saveLine(s: *State, l: Line) void {
        s.wbuf.appendSlice(s.gpa, s.data[l.start .. l.start + l.len]) catch s.fatal();
        s.bytes_written += @intCast(l.len);
        if (s.wbuf.items.len >= 1 << 16) {
            if (!s.flushOut()) {
                cli.warn(s.ctx, "write error for {f}", .{cli.quoteA(s.out_name)});
                s.out_file = null;
                s.cleanupFatal();
            }
        }
    }

    fn dumpRestOfFile(s: *State) void {
        while (s.removeLine()) |l| s.saveLine(l);
    }

    fn writeToFile(s: *State, last_line: i64, ignore: bool, argnum: usize) void {
        const first = s.getFirstLine();
        if (first == 0 or first > last_line) {
            cli.warn(s.ctx, "{f}: line number out of range", .{cli.quoteC(s.args[argnum])});
            s.cleanupFatal();
        }
        var i: i64 = 0;
        const lines = last_line - first;
        while (i < lines) : (i += 1) {
            const l = s.removeLine() orelse {
                cli.warn(s.ctx, "{f}: line number out of range", .{cli.quoteC(s.args[argnum])});
                s.cleanupFatal();
            };
            if (!ignore) s.saveLine(l);
        }
    }

    fn handleLineError(s: *State, p: *const Control, repetition: i64) noreturn {
        s.out.flush();
        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "{d}", .{p.lines_required}) catch unreachable;
        if (repetition != 0)
            cli.warn(s.ctx, "{f}: line number out of range on repetition {d}", .{ cli.quoteC(n), repetition })
        else
            cli.warn(s.ctx, "{f}: line number out of range", .{cli.quoteC(n)});
        s.cleanupFatal();
    }

    fn processLineCount(s: *State, p: *const Control, repetition: i64) void {
        const last_line_to_save = p.lines_required * (repetition + 1);
        s.createOutputFile();
        if (s.noMoreLines() and s.suppress_matched) s.handleLineError(p, repetition);
        var linenum = s.getFirstLine();
        if (linenum == 0) s.handleLineError(p, repetition);
        while (linenum < last_line_to_save) {
            linenum += 1;
            const l = s.removeLine() orelse s.handleLineError(p, repetition);
            s.saveLine(l);
        }
        s.closeOutputFile();
        if (s.suppress_matched) _ = s.removeLine();
        if (s.noMoreLines() and !s.suppress_matched) s.handleLineError(p, repetition);
    }

    fn regexpError(s: *State, p: *const Control, repetition: i64, ignore: bool) noreturn {
        s.out.flush();
        if (repetition != 0)
            cli.warn(s.ctx, "{f}: match not found on repetition {d}", .{ cli.quoteC(s.args[p.argnum]), repetition })
        else
            cli.warn(s.ctx, "{f}: match not found", .{cli.quoteC(s.args[p.argnum])});
        if (!ignore) {
            s.dumpRestOfFile();
            s.closeOutputFile();
        }
        s.cleanupFatal();
    }

    fn matches(s: *State, p: *Control, l: Line) bool {
        var len = l.len;
        if (len > 0 and s.data[l.start + len - 1] == '\n') len -= 1;
        var searcher = p.re.?.re.searcher(s.gpa) catch s.fatal();
        defer searcher.deinit();
        return (searcher.find(s.data[l.start .. l.start + len], 0) catch null) != null;
    }

    fn processRegexp(s: *State, p: *Control, repetition: i64) void {
        const ignore = p.ignore;
        if (!ignore) s.createOutputFile();
        if (p.offset >= 0) {
            while (true) {
                s.current_line += 1;
                const line = s.findLine(s.current_line) orelse {
                    if (p.repeat_forever) {
                        if (!ignore) {
                            s.dumpRestOfFile();
                            s.closeOutputFile();
                        }
                        s.out.flush();
                        std.process.exit(0);
                    } else s.regexpError(p, repetition, ignore);
                };
                if (!s.matches(p, line)) {
                    const l = s.removeLine().?;
                    if (!ignore) s.saveLine(l);
                } else break;
            }
        } else {
            while (true) {
                s.current_line += 1;
                const line = s.findLine(s.current_line) orelse {
                    if (p.repeat_forever) {
                        if (!ignore) {
                            s.dumpRestOfFile();
                            s.closeOutputFile();
                        }
                        s.out.flush();
                        std.process.exit(0);
                    } else s.regexpError(p, repetition, ignore);
                };
                if (s.matches(p, line)) break;
            }
        }
        const break_line = s.current_line + p.offset;
        s.writeToFile(break_line, ignore, p.argnum);
        if (!ignore) s.closeOutputFile();
        if (p.offset > 0) s.current_line = break_line;
        if (s.suppress_matched) _ = s.removeLine();
    }

    fn splitFile(s: *State) void {
        for (s.controls.items) |*c| {
            var j: i64 = 0;
            while (c.repeat_forever or j <= c.repeat) : (j += 1) {
                if (c.regexpr) s.processRegexp(c, j) else s.processLineCount(c, j);
            }
        }
        s.createOutputFile();
        s.dumpRestOfFile();
        s.closeOutputFile();
    }
};

/// sprintf(format, num) for the integer conversions allowed in --suffix-format.
fn formatSuffix(gpa: std.mem.Allocator, out: *std.ArrayList(u8), fmt: []const u8, num: i32) !void {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            try out.append(gpa, '%');
            i += 1;
            continue;
        }
        var left = false;
        var zero = false;
        var alt = false;
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-' => left = true,
                '0' => zero = true,
                '#' => alt = true,
                '\'' => {},
                else => break,
            }
        }
        var width: usize = 0;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) width = width * 10 + (fmt[i] - '0');
        var prec: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            var pv: usize = 0;
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) pv = pv * 10 + (fmt[i] - '0');
            prec = pv;
        }
        const conv = if (i < fmt.len) fmt[i] else 'd';
        i += 1;
        var digits_buf: [48]u8 = undefined;
        var prefix: []const u8 = "";
        var neg = false;
        const body: []const u8 = switch (conv) {
            'o' => blk: {
                if (alt) prefix = "0";
                break :blk std.fmt.bufPrint(&digits_buf, "{o}", .{@as(u32, @bitCast(num))}) catch unreachable;
            },
            'x' => blk: {
                if (alt and num != 0) prefix = "0x";
                break :blk std.fmt.bufPrint(&digits_buf, "{x}", .{@as(u32, @bitCast(num))}) catch unreachable;
            },
            'X' => blk: {
                if (alt and num != 0) prefix = "0X";
                break :blk std.fmt.bufPrint(&digits_buf, "{X}", .{@as(u32, @bitCast(num))}) catch unreachable;
            },
            else => blk: {
                neg = num < 0;
                break :blk std.fmt.bufPrint(&digits_buf, "{d}", .{@abs(@as(i64, num))}) catch unreachable;
            },
        };
        var digits: []const u8 = body;
        var zeros_needed: usize = 0;
        if (prec) |pv| {
            if (pv == 0 and num == 0) digits = "";
            if (digits.len < pv) zeros_needed = pv - digits.len;
        }
        if (conv == 'o' and alt and zeros_needed == 0 and digits.len > 0 and digits[0] == '0') prefix = "";
        const sign: []const u8 = if (neg) "-" else "";
        const total = sign.len + prefix.len + zeros_needed + digits.len;
        if (total < width and !left and zero and prec == null) zeros_needed += width - total;
        const total2 = sign.len + prefix.len + zeros_needed + digits.len;
        if (!left and total2 < width) try out.appendNTimes(gpa, ' ', width - total2);
        try out.appendSlice(gpa, sign);
        try out.appendSlice(gpa, prefix);
        try out.appendNTimes(gpa, '0', zeros_needed);
        try out.appendSlice(gpa, digits);
        if (left and total2 < width) try out.appendNTimes(gpa, ' ', width - total2);
    }
}

/// Validate a --suffix-format (max_out in GNU). Returns false after printing.
fn checkSuffixFormat(ctx: cli.Context, fmt: []const u8) bool {
    var percent = false;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%') continue;
        i += 1;
        if (i < fmt.len and fmt[i] == '%') continue;
        if (percent) {
            cli.warn(ctx, "too many % conversion specifications in suffix", .{});
            return false;
        }
        percent = true;
        var alt = false;
        var thousands = false;
        while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '0' or fmt[i] == '\'' or fmt[i] == '#')) : (i += 1) {
            if (fmt[i] == '#') alt = true;
            if (fmt[i] == '\'') thousands = true;
        }
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
        }
        if (i >= fmt.len) {
            cli.warn(ctx, "missing conversion specifier in suffix", .{});
            return false;
        }
        const ch = fmt[i];
        var compatible_thousands = true;
        switch (ch) {
            'd', 'i', 'u' => {},
            'o', 'x', 'X' => compatible_thousands = false,
            else => {
                if (std.ascii.isPrint(ch))
                    cli.warn(ctx, "invalid conversion specifier in suffix: {c}", .{ch})
                else
                    cli.warn(ctx, "invalid conversion specifier in suffix: \\{o:0>3}", .{ch});
                return false;
            },
        }
        if ((alt and compatible_thousands) or (thousands and !compatible_thousands)) {
            cli.warn(ctx, "invalid flags in conversion specification: %{c}{c}", .{ @as(u8, if (alt and compatible_thousands) '#' else '\''), ch });
            return false;
        }
    }
    if (!percent) {
        cli.warn(ctx, "missing % conversion specification in suffix", .{});
        return false;
    }
    return true;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = arena.create(State) catch return 1;
    s.* = .{ .ctx = ctx, .gpa = arena, .out = cli.Out.init(ctx.io) };

    var parser = getopt.Parser.init(ctx, "f:b:kn:sqz", &.{
        .{ .name = "digits", .arg = .required, .id = 'n' },
        .{ .name = "quiet", .id = 'q' },
        .{ .name = "silent", .id = 's' },
        .{ .name = "keep-files", .id = 'k' },
        .{ .name = "elide-empty-files", .id = 'z' },
        .{ .name = "prefix", .arg = .required, .id = 'f' },
        .{ .name = "suffix-format", .arg = .required, .id = 'b' },
        .{ .name = "suppress-matched", .id = 1100 },
    });
    defer parser.deinit();
    while (true) switch (parser.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'f' => s.prefix = o.arg.?,
            'b' => s.suffix = o.arg.?,
            'k' => s.remove_files = false,
            'n' => {
                const v = std.fmt.parseInt(i64, o.arg.?, 10) catch -1;
                if (v < 0 or v > std.math.maxInt(i32)) {
                    const bad_syntax = std.fmt.parseInt(i64, o.arg.?, 10) catch null == null;
                    cli.warn(ctx, "invalid number: {f}{s}", .{ cli.quoteC(o.arg.?), if (bad_syntax) "" else ": Value too large for defined data type" });
                    return 1;
                }
                s.digits = @intCast(v);
            },
            's', 'q' => s.suppress_count = true,
            'z' => s.elide_empty_files = true,
            1100 => s.suppress_matched = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const ops = parser.operands.items;
    if (ops.len < 2) {
        if (ops.len == 0)
            getopt.usageError(ctx, "missing operand", .{})
        else
            getopt.usageError(ctx, "missing operand after {f}", .{cli.quoteC(ops[ops.len - 1])});
        return 1;
    }
    if (s.suffix) |sf| if (!checkSuffixFormat(ctx, sf)) return 1;
    // global_argv in GNU is argv with the program name at 0; patterns are indexed from the operands.
    s.args = ops;

    // Open the input.
    var file_opt: ?Io.File = null;
    if (cli.openInput(ctx.io, ops[0])) |f| {
        file_opt = f;
    } else |e| {
        // GNU opens a directory fine and fails on the first read.
        if (e == error.IsDir) {
            s.read_error = "read error: Is a directory";
        } else {
            cli.warn(ctx, "cannot open {f} for reading: {s}", .{ cli.quoteA(ops[0]), cli.errText(e) });
            return 1;
        }
    }
    defer if (file_opt) |f| cli.closeInput(ctx.io, f);

    // Parse the patterns (before reading input, like GNU).
    var last_val: i64 = 0;
    var i: usize = 1;
    while (i < ops.len) : (i += 1) {
        const a = ops[i];
        var c: Control = .{ .argnum = i };
        if (a.len > 0 and (a[0] == '/' or a[0] == '%')) {
            const delim = a[0];
            const close = std.mem.lastIndexOfScalar(u8, a[1..], delim) orelse {
                cli.warn(ctx, "{s}: closing delimiter '{c}' missing", .{ a, delim });
                return 1;
            };
            const pat = a[1 .. 1 + close];
            c.regexpr = true;
            c.ignore = delim == '%';
            c.re = posixre.compile(arena, pat, false, false) catch {
                cli.warn(ctx, "{f}: invalid regular expression: {s}", .{ cli.quoteC(a), posixre.diagnose(pat) });
                return 1;
            };
            const rest = a[1 + close + 1 ..];
            if (rest.len > 0) {
                c.offset = parseSigned(rest) orelse {
                    cli.warn(ctx, "{f}: integer expected after delimiter", .{cli.quoteC(a)});
                    return 1;
                };
            }
        } else {
            const v = std.fmt.parseInt(i64, a, 10) catch {
                cli.warn(ctx, "{f}: invalid pattern", .{cli.quoteC(a)});
                return 1;
            };
            if (v < 0 or (a.len > 0 and a[0] == '-')) {
                cli.warn(ctx, "{f}: invalid pattern", .{cli.quoteC(a)});
                return 1;
            }
            if (v == 0) {
                cli.warn(ctx, "{s}: line number must be greater than zero", .{a});
                return 1;
            }
            if (v < last_val) {
                cli.warn(ctx, "line number {f} is smaller than preceding line number, {d}", .{ cli.quoteC(a), last_val });
                return 1;
            }
            if (v == last_val) cli.warn(ctx, "warning: line number {f} is the same as preceding line number", .{cli.quoteC(a)});
            last_val = v;
            c.lines_required = v;
        }
        if (i + 1 < ops.len and ops[i + 1].len > 0 and ops[i + 1][0] == '{') {
            i += 1;
            const r = ops[i];
            if (r[r.len - 1] != '}') {
                cli.warn(ctx, "{f}: '}}' is required in repeat count", .{cli.quoteC(r)});
                return 1;
            }
            const inner = r[1 .. r.len - 1];
            if (std.mem.eql(u8, inner, "*")) {
                c.repeat_forever = true;
            } else {
                const v = std.fmt.parseInt(i64, inner, 10) catch -1;
                if (v < 0 or inner.len == 0 or inner[0] == '-' or inner[0] == '+') {
                    cli.warn(ctx, "{f}}}: integer required between '{{' and '}}'", .{cli.quoteC(r)});
                    return 1;
                }
                c.repeat = v;
            }
        }
        s.controls.append(arena, c) catch return 1;
    }

    // Read all input and index its lines.
    var data: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (file_opt) |file| {
        const n = cli.readChunk(ctx.io, file, &chunk) catch {
            cli.warn(ctx, "read error", .{});
            return 1;
        };
        if (n == 0) break;
        data.appendSlice(arena, chunk[0..n]) catch return 1;
    }
    s.data = data.items;
    var pos: usize = 0;
    while (pos < s.data.len) {
        const e = std.mem.indexOfScalarPos(u8, s.data, pos, '\n');
        const end = if (e) |x| x + 1 else s.data.len;
        s.lines.append(arena, .{ .start = pos, .len = end - pos }) catch return 1;
        pos = end;
    }

    s.splitFile();
    s.out.flush();
    if (s.out.failed) return 1;
    return 0;
}

fn parseSigned(text: []const u8) ?i64 {
    var t = text;
    var neg = false;
    if (t.len > 0 and (t[0] == '+' or t[0] == '-')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    if (t.len == 0) return null;
    const v = std.fmt.parseInt(i64, t, 10) catch return null;
    return if (neg) -v else v;
}
