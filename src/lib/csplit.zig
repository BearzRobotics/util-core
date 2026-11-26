// SPDX-License-Identifier: GPL-2.0-or-later
//! csplit library — split a file into sections determined by context lines
//! (decision 0004). Argument parsing (including the pattern operands and the
//! --suffix-format check) and the GNU diagnostics are in
//! src/commands/csplit.zig.
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
const rx = @import("../regexutil.zig");
const Io = std.Io;
const common = @import("common.zig");
const wsink = @import("wsink.zig");
const posixre = @import("../posixre.zig");

pub const Env = common.Env;

pub const Control = struct {
    offset: i64 = 0,
    lines_required: i64 = 0,
    repeat: i64 = 0,
    /// Index of the pattern operand, for diagnostics (into `Options.args`).
    argnum: usize = 0,
    repeat_forever: bool = false,
    ignore: bool = false,
    regexpr: bool = false,
    re: ?posixre.Compiled = null,
};

const Line = struct { start: usize, len: usize };

pub const Options = struct {
    /// The pattern operands as given (index 0 is the input file name); only
    /// used to quote the offending pattern in events.
    args: []const []const u8,
    /// Parsed patterns, in order.
    controls: []Control,
    prefix: []const u8 = "xx",
    /// --suffix-format (already validated); null: zero-padded decimal.
    suffix_format: ?[]const u8 = null,
    /// -n: minimum digits of the default suffix.
    digits: usize = 2,
    /// -s/-q: do not print the byte counts.
    suppress_count: bool = false,
    /// -k: keep the files created so far when an error stops the run.
    keep_files: bool = false,
    /// -z: remove empty output files.
    elide_empty_files: bool = false,
    /// --suppress-matched.
    suppress_matched: bool = false,
};

/// Problems, reported before the run ends with status 1 (the byte counts of
/// pieces written so far have already been printed).
pub const Event = union(enum) {
    /// The input is a directory: GNU fails on the first read.
    read_error_directory,
    /// Reading the input failed.
    read_error,
    create_failed: struct { name: []const u8, err: anyerror },
    write_error: []const u8,
    delete_failed: struct { name: []const u8, err: anyerror },
    /// `text` is the pattern operand (or the line number); `repetition` 0 means none.
    line_out_of_range: struct { text: []const u8, repetition: i64 },
    match_not_found: struct { text: []const u8, repetition: i64 },
    memory_exhausted,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// Process exit status the run ended with (0 or 1).
    status: u8 = 0,
    /// Writing the byte counts to the caller's writer failed (only
    /// reported when the run otherwise ended normally, as before).
    stdout_failed: bool = false,
};

/// The run stopped (fatal condition already reported or a final success).
const Stop = error{Stop};

const State = struct {
    env: Env,
    obs: Observer,
    gpa: std.mem.Allocator, // arena
    out: wsink.Sink, // stdout (counts)
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
    controls: []Control = &.{},
    read_error: bool = false,
    status: u8 = 1,

    fn ensureLoaded(s: *State) Stop!void {
        if (s.read_error) {
            s.obs.emit(.read_error_directory);
            return s.cleanupFatal();
        }
    }

    fn lineAt(s: *const State, n: i64) ?Line {
        if (n < 1) return null;
        const i: usize = @intCast(n);
        if (i > s.lines.items.len) return null;
        return s.lines.items[i - 1];
    }

    fn findLine(s: *State, n: i64) Stop!?Line {
        try s.ensureLoaded();
        return s.lineAt(n);
    }

    /// First line not yet removed, or 0 when none is left.
    fn getFirstLine(s: *State) Stop!i64 {
        try s.ensureLoaded();
        return if (s.first_available <= s.lines.items.len) @intCast(s.first_available) else 0;
    }

    fn removeLine(s: *State) Stop!?Line {
        try s.ensureLoaded();
        if (s.first_available > s.lines.items.len) return null;
        if (s.current_line < @as(i64, @intCast(s.first_available))) s.current_line = @intCast(s.first_available);
        const l = s.lines.items[s.first_available - 1];
        s.first_available += 1;
        return l;
    }

    fn noMoreLines(s: *State) Stop!bool {
        return (try s.findLine(s.current_line + 1)) == null;
    }

    fn makeFilename(s: *State, num: usize, buf: *std.ArrayList(u8)) !void {
        buf.clearRetainingCapacity();
        try buf.appendSlice(s.gpa, s.prefix);
        if (s.suffix) |sf| {
            try formatSuffix(s.gpa, buf, sf, @intCast(num));
        } else {
            if (s.digits > max_field) return error.OutOfMemory;
            var tmp: [32]u8 = undefined;
            const d = std.fmt.bufPrint(&tmp, "{d}", .{num}) catch unreachable;
            if (d.len < s.digits) try buf.appendNTimes(s.gpa, '0', s.digits - d.len);
            try buf.appendSlice(s.gpa, d);
        }
    }

    fn createOutputFile(s: *State) Stop!void {
        var name: std.ArrayList(u8) = .empty;
        s.makeFilename(s.files_created, &name) catch return s.fatal();
        const file = Io.Dir.cwd().createFile(s.env.io, name.items, .{ .truncate = true }) catch |e| {
            s.obs.emit(.{ .create_failed = .{ .name = name.items, .err = e } });
            name.deinit(s.gpa);
            return s.cleanupFatal();
        };
        s.files_created += 1;
        if (s.out_name.len > 0) s.gpa.free(s.out_name);
        s.out_name = s.gpa.dupe(u8, name.items) catch return s.fatal();
        name.deinit(s.gpa);
        s.out_file = file;
        s.bytes_written = 0;
        s.wbuf.clearRetainingCapacity();
    }

    fn flushOut(s: *State) bool {
        if (s.out_file) |f| {
            if (s.wbuf.items.len > 0) {
                f.writeStreamingAll(s.env.io, s.wbuf.items) catch return false;
                s.wbuf.clearRetainingCapacity();
            }
        }
        return true;
    }

    fn closeOutputFile(s: *State) Stop!void {
        const f = s.out_file orelse return;
        if (!s.flushOut()) {
            s.obs.emit(.{ .write_error = s.out_name });
            s.out_file = null;
            f.close(s.env.io);
            return s.cleanupFatal();
        }
        f.close(s.env.io);
        s.out_file = null;
        if (s.bytes_written == 0 and s.elide_empty_files) {
            Io.Dir.cwd().deleteFile(s.env.io, s.out_name) catch {};
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
            Io.Dir.cwd().deleteFile(s.env.io, name.items) catch |e| {
                if (e != error.FileNotFound) s.obs.emit(.{ .delete_failed = .{ .name = name.items, .err = e } });
            };
        }
        s.files_created = 0;
    }

    /// End the run with status 1: close the current piece, remove the files
    /// (unless -k) and flush the counts.
    fn cleanupFatal(s: *State) Stop {
        // A failure to close the piece here ends the run just the same.
        s.closeOutputFile() catch {};
        s.deleteAllFiles();
        s.out.flush();
        s.status = 1;
        return error.Stop;
    }

    fn fatal(s: *State) Stop {
        s.obs.emit(.memory_exhausted);
        return s.cleanupFatal();
    }

    fn saveLine(s: *State, l: Line) Stop!void {
        s.wbuf.appendSlice(s.gpa, s.data[l.start .. l.start + l.len]) catch return s.fatal();
        s.bytes_written += @intCast(l.len);
        if (s.wbuf.items.len >= 1 << 16) {
            if (!s.flushOut()) {
                s.obs.emit(.{ .write_error = s.out_name });
                if (s.out_file) |f| f.close(s.env.io);
                s.out_file = null;
                return s.cleanupFatal();
            }
        }
    }

    fn dumpRestOfFile(s: *State) Stop!void {
        while (try s.removeLine()) |l| try s.saveLine(l);
    }

    fn writeToFile(s: *State, last_line: i64, ignore: bool, argnum: usize) Stop!void {
        const first = try s.getFirstLine();
        if (first == 0 or first > last_line) {
            s.obs.emit(.{ .line_out_of_range = .{ .text = s.args[argnum], .repetition = 0 } });
            return s.cleanupFatal();
        }
        var i: i64 = 0;
        const lines = last_line - first;
        while (i < lines) : (i += 1) {
            const l = (try s.removeLine()) orelse {
                s.obs.emit(.{ .line_out_of_range = .{ .text = s.args[argnum], .repetition = 0 } });
                return s.cleanupFatal();
            };
            if (!ignore) try s.saveLine(l);
        }
    }

    fn handleLineError(s: *State, p: *const Control, repetition: i64) Stop {
        s.out.flush();
        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "{d}", .{p.lines_required}) catch unreachable;
        s.obs.emit(.{ .line_out_of_range = .{ .text = n, .repetition = repetition } });
        return s.cleanupFatal();
    }

    fn processLineCount(s: *State, p: *const Control, repetition: i64) Stop!void {
        const last_line_to_save = p.lines_required * (repetition + 1);
        try s.createOutputFile();
        if ((try s.noMoreLines()) and s.suppress_matched) return s.handleLineError(p, repetition);
        var linenum = try s.getFirstLine();
        if (linenum == 0) return s.handleLineError(p, repetition);
        while (linenum < last_line_to_save) {
            linenum += 1;
            const l = (try s.removeLine()) orelse return s.handleLineError(p, repetition);
            try s.saveLine(l);
        }
        try s.closeOutputFile();
        if (s.suppress_matched) _ = try s.removeLine();
        if ((try s.noMoreLines()) and !s.suppress_matched) return s.handleLineError(p, repetition);
    }

    fn regexpError(s: *State, p: *const Control, repetition: i64, ignore: bool) Stop {
        s.out.flush();
        s.obs.emit(.{ .match_not_found = .{ .text = s.args[p.argnum], .repetition = repetition } });
        if (!ignore) {
            s.dumpRestOfFile() catch return error.Stop;
            s.closeOutputFile() catch return error.Stop;
        }
        return s.cleanupFatal();
    }

    fn matches(s: *State, p: *Control, l: Line) Stop!bool {
        var len = l.len;
        if (len > 0 and s.data[l.start + len - 1] == '\n') len -= 1;
        var searcher = rx.searcher(p.re.?.re, s.gpa) catch return s.fatal();
        defer searcher.deinit();
        return (searcher.find(s.data[l.start .. l.start + len], 0) catch null) != null;
    }

    /// The pattern ran off the end of the input with a `{*}` repeat: finish
    /// the piece and end the run successfully.
    fn finishRepeatForever(s: *State, ignore: bool) Stop {
        if (!ignore) {
            s.dumpRestOfFile() catch return error.Stop;
            s.closeOutputFile() catch return error.Stop;
        }
        s.out.flush();
        s.status = 0;
        return error.Stop;
    }

    fn processRegexp(s: *State, p: *Control, repetition: i64) Stop!void {
        const ignore = p.ignore;
        if (!ignore) try s.createOutputFile();
        if (p.offset >= 0) {
            while (true) {
                s.current_line += 1;
                const line = (try s.findLine(s.current_line)) orelse {
                    if (p.repeat_forever) return s.finishRepeatForever(ignore);
                    return s.regexpError(p, repetition, ignore);
                };
                if (!try s.matches(p, line)) {
                    const l = (try s.removeLine()).?;
                    if (!ignore) try s.saveLine(l);
                } else break;
            }
        } else {
            while (true) {
                s.current_line += 1;
                const line = (try s.findLine(s.current_line)) orelse {
                    if (p.repeat_forever) return s.finishRepeatForever(ignore);
                    return s.regexpError(p, repetition, ignore);
                };
                if (try s.matches(p, line)) break;
            }
        }
        // A line number that cannot be represented: nothing more is written.
        const break_line = std.math.add(i64, s.current_line, p.offset) catch {
            s.obs.emit(.{ .line_out_of_range = .{ .text = s.args[p.argnum], .repetition = 0 } });
            return s.cleanupFatal();
        };
        try s.writeToFile(break_line, ignore, p.argnum);
        if (!ignore) try s.closeOutputFile();
        if (p.offset > 0) s.current_line = break_line;
        if (s.suppress_matched) _ = try s.removeLine();
    }

    fn splitFile(s: *State) Stop!void {
        for (s.controls) |*c| {
            var j: i64 = 0;
            while (c.repeat_forever or j <= c.repeat) : (j += 1) {
                if (c.regexpr) try s.processRegexp(c, j) else try s.processLineCount(c, j);
            }
        }
        try s.createOutputFile();
        try s.dumpRestOfFile();
        try s.closeOutputFile();
    }
};
/// The largest --digits, field width or precision that is padded out. It is
/// far beyond any file name; larger ones are "memory exhausted" (GNU says so
/// from INT_MAX on) instead of gigabytes of padding.
const max_field = 1 << 20;

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
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) width = width *| 10 +| (fmt[i] - '0');
        var prec: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            var pv: usize = 0;
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) pv = pv *| 10 +| (fmt[i] - '0');
            prec = pv;
        }
        if (width > max_field or (prec orelse 0) > max_field) return error.OutOfMemory;
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

/// Split the input into pieces. `input` is the open input file; null means the
/// input operand was a directory (GNU opens it fine and fails on the first
/// read). The byte count of each piece is written to `out_w`; files are
/// created in the current directory.
pub fn run(env: Env, opts: Options, input: ?Io.File, out_w: *Io.Writer, obs: Observer) Result {
    var arena_state = std.heap.ArenaAllocator.init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = arena.create(State) catch return .{ .status = 1 };
    s.* = .{
        .env = env,
        .obs = obs,
        .gpa = arena,
        .out = wsink.Sink.initWriter(out_w),
        .prefix = opts.prefix,
        .suffix = opts.suffix_format,
        .digits = opts.digits,
        .suppress_count = opts.suppress_count,
        .remove_files = !opts.keep_files,
        .elide_empty_files = opts.elide_empty_files,
        .suppress_matched = opts.suppress_matched,
        .args = opts.args,
        .controls = opts.controls,
        .read_error = input == null,
    };

    // Read all input and index its lines.
    var data: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (input) |file| {
        const n = common.readChunk(env.io, file, &chunk) catch {
            obs.emit(.read_error);
            return .{ .status = 1 };
        };
        if (n == 0) break;
        data.appendSlice(arena, chunk[0..n]) catch return .{ .status = 1 };
    }
    s.data = data.items;
    var pos: usize = 0;
    while (pos < s.data.len) {
        const e = std.mem.indexOfScalarPos(u8, s.data, pos, '\n');
        const end = if (e) |x| x + 1 else s.data.len;
        s.lines.append(arena, .{ .start = pos, .len = end - pos }) catch return .{ .status = 1 };
        pos = end;
    }

    s.splitFile() catch return .{ .status = s.status };
    s.out.flush();
    if (s.out.failed) return .{ .status = 1, .stdout_failed = true };
    return .{ .status = 0 };
}
