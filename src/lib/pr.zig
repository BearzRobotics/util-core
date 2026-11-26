// SPDX-License-Identifier: GPL-2.0-or-later
//! pr library — convert text files for printing (decision 0004). Argument
//! parsing (including the obsolete -w/-s interplay and the +FIRST[:LAST] page
//! operand) and the GNU diagnostics are in src/commands/pr.zig.
//! Reference: GNU coreutils manual "pr invocation" (9.7); POSIX.1-2024 pr.
//!
//! A line-by-line port of GNU pr.c's page and column machinery: the same
//! state flags, stored-column buffers and parallel (-m) merging, so the layout
//! decisions come out identically.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const wsink = @import("wsink.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

/// The page layout settings; the defaults are GNU's.
pub const Options = struct {
    parallel_files: bool = false,
    explicit_columns: bool = false,
    extremities: bool = true,
    keep_ff: bool = false,
    use_form_feed: bool = false,
    print_across_flag: bool = false,
    storing_columns: bool = true,
    balance_columns: bool = false,
    lines_per_page: i32 = 66,
    chars_per_line: i32 = 72,
    truncate_lines: bool = false,
    join_lines: bool = false,
    untabify_input: bool = false,
    input_tab_char: u8 = '\t',
    chars_per_input_tab: i32 = 8,
    tabify_output: bool = false,
    output_tab_char: u8 = '\t',
    chars_per_output_tab: i32 = 8,
    chars_per_margin: i32 = 0,
    columns: i32 = 1,
    /// 0 means page 1.
    first_page_number: u64 = 0,
    last_page_number: u64 = std.math.maxInt(u64),
    numbered_lines: bool = false,
    number_separator: u8 = '\t',
    skip_count: bool = true,
    start_line_num: i32 = 1,
    chars_per_number: i32 = 5,
    use_esc_sequence: bool = false,
    use_cntrl_prefix: bool = false,
    double_space: bool = false,
    /// -r: do not report files that cannot be opened.
    ignore_failed_opens: bool = false,
    use_col_separator: bool = false,
    col_sep_string: []const u8 = "",
    col_sep_length: i32 = 0,
    /// -h: replaces the file name in the page header.
    custom_header: ?[]const u8 = null,
    /// -D: strftime format of the header date.
    date_format: ?[]const u8 = null,
    /// When set, standard input ("-" or no operand) is read from this buffer
    /// instead of the process's standard input (used by `diff -l`).
    stdin_data: ?[]const u8 = null,
};

pub const Event = union(enum) {
    page_width_too_narrow,
    /// A file could not be opened (not sent with -r).
    open_failed: struct { name: []const u8, err: anyerror },
    /// Reading a file failed. Sent when printing reaches the point where it
    /// did; nothing more is printed.
    read_failed: struct { name: []const u8, err: anyerror },
    start_page_exceeds: struct { page: u64, count: u64 },
    page_number_overflow,
    /// Lines per page, columns and column width are too large to lay out.
    integer_overflow,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// Some file could not be opened, or printing stopped on an error.
    failed: bool = false,
};

pub const Error = error{ OutOfMemory, WriteFailed };

/// Format `files` ("-" is standard input; none means standard input) onto
/// `out_w`. With `opts.parallel_files` they are merged side by side, otherwise
/// printed one after the other.
pub fn run(env: Env, opts: Options, files: []const []const u8, out_w: *Io.Writer, obs: Observer) Error!Result {
    const gpa = env.gpa;
    const pr = try gpa.create(Pr);
    pr.* = .{ .env = env, .obs = obs, .gpa = gpa, .out = wsink.Sink.initWriter(out_w), .zone = tzmod.load(gpa, env.io, env.getenv("TZ")) };
    defer {
        pr.zone.deinit();
        for (pr.streams.items) |s| gpa.destroy(s);
        pr.streams.deinit(gpa);
        for (pr.stream_data.items) |d| gpa.free(d);
        pr.stream_data.deinit(gpa);
        pr.columns_v.deinit(gpa);
        pr.buff.deinit(gpa);
        gpa.free(pr.line_vector);
        gpa.free(pr.end_vector);
        if (pr.date_text.len > 0) gpa.free(pr.date_text);
        gpa.destroy(pr);
    }
    pr.parallel_files = opts.parallel_files;
    pr.explicit_columns = opts.explicit_columns;
    pr.extremities = opts.extremities;
    pr.keep_ff = opts.keep_ff;
    pr.use_form_feed = opts.use_form_feed;
    pr.print_across_flag = opts.print_across_flag;
    pr.storing_columns = opts.storing_columns;
    pr.balance_columns = opts.balance_columns;
    pr.lines_per_page = opts.lines_per_page;
    pr.chars_per_line = opts.chars_per_line;
    pr.truncate_lines = opts.truncate_lines;
    pr.join_lines = opts.join_lines;
    pr.untabify_input = opts.untabify_input;
    pr.input_tab_char = opts.input_tab_char;
    pr.chars_per_input_tab = opts.chars_per_input_tab;
    pr.tabify_output = opts.tabify_output;
    pr.output_tab_char = opts.output_tab_char;
    pr.chars_per_output_tab = opts.chars_per_output_tab;
    pr.chars_per_margin = opts.chars_per_margin;
    pr.columns = opts.columns;
    pr.first_page_number = opts.first_page_number;
    pr.last_page_number = opts.last_page_number;
    pr.numbered_lines = opts.numbered_lines;
    pr.number_separator = opts.number_separator;
    pr.skip_count = opts.skip_count;
    pr.start_line_num = opts.start_line_num;
    pr.chars_per_number = opts.chars_per_number;
    pr.use_esc_sequence = opts.use_esc_sequence;
    pr.use_cntrl_prefix = opts.use_cntrl_prefix;
    pr.double_space = opts.double_space;
    pr.ignore_failed_opens = opts.ignore_failed_opens;
    pr.use_col_separator = opts.use_col_separator;
    pr.col_sep_string = opts.col_sep_string;
    pr.col_sep_length = opts.col_sep_length;
    pr.custom_header = opts.custom_header;
    pr.date_format = opts.date_format;
    pr.stdin_data = opts.stdin_data;
    if (pr.date_format == null) pr.date_format = "%Y-%m-%d %H:%M";
    if (pr.first_page_number == 0) pr.first_page_number = 1;

    var failed = false;
    if (files.len == 0) {
        failed = !pr.printFiles(&.{});
    } else if (pr.parallel_files) {
        failed = !pr.printFiles(files);
    } else {
        for (files) |f| {
            const one = [_][]const u8{f};
            if (!pr.printFiles(&one)) {
                failed = true;
                break;
            }
            if (pr.read_failed or pr.out_of_memory or pr.overflowed) break;
        }
    }
    pr.out.flush();
    if (pr.out_of_memory) return error.OutOfMemory;
    if (pr.out.failed) return error.WriteFailed;
    return .{ .failed = failed or pr.failed_opens or pr.read_failed or pr.overflowed };
}

fn openPath(io: Io, path: []const u8) !Io.File {
    return Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
}

const eof: i32 = -1;
const anywhere: i32 = 0;
const lines_per_header = 5;
const lines_per_footer = 5;

const Status = enum { open, ff_found, on_hold, closed };
const PrintFn = enum { read_line, print_stored };
const CharFn = enum { store_char, print_char };

const Stream = struct {
    data: []const u8,
    pos: usize = 0,
    /// Reading stopped on this error after `data`.
    err: ?anyerror = null,

    fn getc(s: *Stream) i32 {
        if (s.pos >= s.data.len) return eof;
        const c = s.data[s.pos];
        s.pos += 1;
        return c;
    }

    fn ungetc(s: *Stream, c: i32) void {
        if (c == eof) return;
        if (s.pos > 0) s.pos -= 1;
    }
};

const Column = struct {
    fp: *Stream = undefined,
    name: []const u8 = "",
    status: Status = .open,
    print_func: PrintFn = .read_line,
    char_func: CharFn = .print_char,
    current_line: i32 = 0,
    lines_stored: i32 = 0,
    lines_to_print: i32 = 0,
    start_position: i32 = 0,
    numbered: bool = false,
    full_page_printed: bool = false,
};

fn tabWidth(c: i32, h: i32) i32 {
    return c - @mod(h, c);
}
/// Positions saturate: tab and number widths may be as large as an i32.
fn posAfterTab(c: i32, h: i32) i32 {
    return h +| tabWidth(c, h);
}

const Pr = struct {
    env: Env,
    obs: Observer,
    gpa: std.mem.Allocator,
    out: wsink.Sink,
    zone: tzmod.Zone,

    columns_v: std.ArrayList(Column) = .empty,
    buff: std.ArrayList(u8) = .empty,
    line_vector: []i32 = &.{},
    end_vector: []i32 = &.{},

    parallel_files: bool = false,
    align_empty_cols: bool = false,
    empty_line: bool = false,
    ff_only: bool = false,
    explicit_columns: bool = false,
    extremities: bool = true,
    keep_ff: bool = false,
    print_a_ff: bool = false,
    print_a_header: bool = false,
    use_form_feed: bool = false,
    have_read_stdin: bool = false,
    stdin_data: ?[]const u8 = null,
    print_across_flag: bool = false,
    storing_columns: bool = true,
    balance_columns: bool = false,
    lines_per_page: i32 = 66,
    lines_per_body: i32 = 0,
    chars_per_line: i32 = 72,
    truncate_lines: bool = false,
    join_lines: bool = false,
    chars_per_column: i32 = 0,
    untabify_input: bool = false,
    input_tab_char: u8 = '\t',
    chars_per_input_tab: i32 = 8,
    tabify_output: bool = false,
    output_tab_char: u8 = '\t',
    chars_per_output_tab: i32 = 8,
    spaces_not_printed: i32 = 0,
    chars_per_margin: i32 = 0,
    output_position: i32 = 0,
    input_position: i32 = 0,
    failed_opens: bool = false,
    read_failed: bool = false,
    out_of_memory: bool = false,
    /// The layout asked for cannot be built; nothing more is printed.
    overflowed: bool = false,
    /// Takes what is formatted after a read error.
    discard: Io.Writer.Discarding = undefined,
    columns: i32 = 1,
    first_page_number: u64 = 0,
    last_page_number: u64 = std.math.maxInt(u64),
    files_ready_to_read: i32 = 0,
    page_number: u64 = 0,
    line_number: i32 = 0,
    numbered_lines: bool = false,
    number_separator: u8 = '\t',
    line_count: i32 = 1,
    skip_count: bool = true,
    start_line_num: i32 = 1,
    chars_per_number: i32 = 5,
    number_width: i32 = 0,
    use_esc_sequence: bool = false,
    use_cntrl_prefix: bool = false,
    double_space: bool = false,
    total_files: i32 = 0,
    ignore_failed_opens: bool = false,
    use_col_separator: bool = false,
    col_sep_string: []const u8 = "",
    col_sep_length: i32 = 0,
    separators_not_printed: i32 = 0,
    padding_not_printed: i32 = 0,
    pad_vertically: bool = false,
    custom_header: ?[]const u8 = null,
    date_format: ?[]const u8 = null,
    date_text: []u8 = &.{},
    file_text: []const u8 = "",
    header_width_available: i32 = 0,
    /// The form in which one input character is printed: `clump_buff`, or,
    /// for an expanded tab of any width, that many spaces.
    clump_buff: [4]u8 = undefined,
    clump_is_spaces: bool = false,
    last_line: bool = false,
    now_sec: ?i64 = null,
    now_nsec: u32 = 0,
    streams: std.ArrayList(*Stream) = .empty,
    stream_data: std.ArrayList([]u8) = .empty,

    fn putchar(p: *Pr, c: u8) void {
        p.out.writeByte(c);
    }

    fn col(p: *Pr, i: usize) *Column {
        return &p.columns_v.items[i];
    }

    fn colsReadyToPrint(p: *Pr) u32 {
        var n: u32 = 0;
        var i: usize = 0;
        while (i < @as(usize, @intCast(p.columns))) : (i += 1) {
            const q = p.col(i);
            if (q.status == .open or q.status == .ff_found or (p.storing_columns and q.lines_stored > 0 and q.lines_to_print > 0)) n += 1;
        }
        return n;
    }

    fn initParameters(p: *Pr, number_of_files: usize) bool {
        var chars_used_by_number: i32 = 0;
        p.lines_per_body = p.lines_per_page - lines_per_header - lines_per_footer;
        if (p.lines_per_body <= 0) {
            p.extremities = false;
            p.keep_ff = true;
        }
        if (!p.extremities) p.lines_per_body = p.lines_per_page;
        if (p.double_space) p.lines_per_body = @max(1, @divTrunc(p.lines_per_body, 2));
        if (number_of_files == 0) p.parallel_files = false;
        if (p.parallel_files) p.columns = @intCast(number_of_files);
        if (p.storing_columns) p.balance_columns = true;
        if (p.columns > 1) {
            if (!p.use_col_separator) {
                p.col_sep_string = if (p.join_lines) "\t" else " ";
                p.col_sep_length = 1;
                p.use_col_separator = true;
            } else if (!p.join_lines and p.col_sep_length == 1 and p.col_sep_string[0] == '\t') {
                p.col_sep_string = " ";
            }
            p.truncate_lines = true;
            if (!(p.col_sep_length == 1 and p.col_sep_string[0] == '\t')) p.untabify_input = true;
            p.tabify_output = true;
        } else p.storing_columns = false;
        if (p.join_lines) p.truncate_lines = false;
        if (p.numbered_lines) {
            p.line_count = p.start_line_num;
            if (p.number_separator == '\t') {
                p.number_width = p.chars_per_number +| tabWidth(8, p.chars_per_number);
            } else p.number_width = p.chars_per_number +| 1;
            if (p.parallel_files) chars_used_by_number = p.number_width;
        }
        const sep_chars: i64 = @as(i64, p.columns - 1) * p.col_sep_length;
        var useful: i64 = @as(i64, p.chars_per_line - chars_used_by_number) - sep_chars;
        if (useful < 0) useful = 0;
        p.chars_per_column = @intCast(@divTrunc(useful, p.columns));
        if (p.chars_per_column < 1) {
            p.obs.emit(.page_width_too_narrow);
            return false;
        }
        return true;
    }

    /// What could be read of a file, and the error that ended it, if any.
    const Contents = struct { data: []u8, err: ?anyerror = null };

    fn readStdin(p: *Pr) error{OutOfMemory}!Contents {
        if (p.stdin_data) |d| return .{ .data = try p.gpa.dupe(u8, d) };
        return p.readAll(Io.File.stdin());
    }

    fn readAll(p: *Pr, file: Io.File) error{OutOfMemory}!Contents {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(p.gpa);
        var chunk: [65536]u8 = undefined;
        var failure: ?anyerror = null;
        while (true) {
            const n = common.readChunk(p.env.io, file, &chunk) catch |e| {
                failure = e;
                break;
            };
            if (n == 0) break;
            try list.appendSlice(p.gpa, chunk[0..n]);
        }
        return .{ .data = try list.toOwnedSlice(p.gpa), .err = failure };
    }

    /// A stream over `contents`, which it takes over.
    fn newStream(p: *Pr, contents: Contents) error{OutOfMemory}!*Stream {
        p.stream_data.append(p.gpa, contents.data) catch |e| {
            p.gpa.free(contents.data);
            return e;
        };
        const s = try p.gpa.create(Stream);
        errdefer p.gpa.destroy(s);
        s.* = .{ .data = contents.data, .err = contents.err };
        try p.streams.append(p.gpa, s);
        return s;
    }

    fn attach(p: *Pr, c: *Column, contents: error{OutOfMemory}!Contents) bool {
        const s = p.newStream(contents catch return p.noMemory()) catch return p.noMemory();
        c.fp = s;
        c.status = .open;
        c.full_page_printed = false;
        p.total_files += 1;
        return true;
    }

    fn noMemory(p: *Pr) bool {
        p.out_of_memory = true;
        return false;
    }

    fn openFile(p: *Pr, name: []const u8, c: *Column) bool {
        if (std.mem.eql(u8, name, "-")) {
            c.name = "standard input";
            p.have_read_stdin = true;
            return p.attach(c, p.readStdin());
        }
        c.name = name;
        const f = openPath(p.env.io, name) catch |e| {
            p.failed_opens = true;
            if (!p.ignore_failed_opens) p.obs.emit(.{ .open_failed = .{ .name = name, .err = e } });
            return false;
        };
        defer f.close(p.env.io);
        return p.attach(c, p.readAll(f));
    }

    /// As in GNU, a read error ends the whole run where the reading failed:
    /// what is before it is printed, the error is reported, nothing follows.
    fn stopAtReadError(p: *Pr, name: []const u8, e: anyerror) void {
        if (p.read_failed) return;
        p.read_failed = true;
        p.out.flush();
        p.obs.emit(.{ .read_failed = .{ .name = name, .err = e } });
        if (!p.out.failed) {
            p.discard = .init(&.{});
            p.out = wsink.Sink.initWriter(&p.discard.writer);
        }
    }

    /// Called when a column reaches the end of what was read.
    fn closeFile(p: *Pr, c: *Column) void {
        if (c.status == .closed) return;
        if (c.fp.err) |e| p.stopAtReadError(c.name, e);
        if (!p.parallel_files) {
            var i: usize = 0;
            while (i < @as(usize, @intCast(p.columns))) : (i += 1) {
                const q = p.col(i);
                q.status = .closed;
                if (q.lines_stored == 0) q.lines_to_print = 0;
            }
        } else {
            c.status = .closed;
            c.lines_to_print = 0;
        }
        p.files_ready_to_read -= 1;
    }

    fn holdFile(p: *Pr, c: *Column) void {
        if (!p.parallel_files) {
            var i: usize = 0;
            while (i < @as(usize, @intCast(p.columns))) : (i += 1) {
                p.col(i).status = if (p.storing_columns) .ff_found else .on_hold;
            }
        } else c.status = .on_hold;
        c.lines_to_print = 0;
        p.files_ready_to_read -= 1;
    }

    fn resetStatus(p: *Pr) void {
        var i: usize = 0;
        while (i < @as(usize, @intCast(p.columns))) : (i += 1) {
            const c = p.col(i);
            if (c.status == .on_hold) {
                c.status = .open;
                p.files_ready_to_read += 1;
            }
        }
        if (p.storing_columns) {
            p.files_ready_to_read = if (p.col(0).status == .closed) 0 else 1;
        }
    }

    fn initFps(p: *Pr, names: []const []const u8) bool {
        p.total_files = 0;
        p.columns_v.clearRetainingCapacity();
        p.columns_v.resize(p.gpa, @intCast(@max(p.columns, 1))) catch return p.noMemory();
        for (p.columns_v.items) |*c| c.* = .{};
        if (p.parallel_files) {
            var idx: usize = 0;
            var cols_left = p.columns;
            for (names) |nm| {
                if (!p.openFile(nm, p.col(idx))) {
                    cols_left -= 1;
                } else idx += 1;
            }
            p.columns = cols_left;
            if (p.columns == 0) return false;
            p.initHeader("", -1, null);
        } else {
            var c0 = p.col(0);
            if (names.len > 0) {
                if (!p.openFile(names[0], c0)) return false;
                var mtime: ?struct { s: i64, ns: u32 } = null;
                if (!std.mem.eql(u8, names[0], "-")) {
                    var err: std.os.linux.E = .SUCCESS;
                    if (sys.fileStat(names[0], true, &err)) |st| mtime = .{ .s = st.mtime_s, .ns = st.mtime_ns };
                }
                p.initHeader(names[0], 0, if (mtime) |m| .{ m.s, m.ns } else null);
                c0.lines_stored = 0;
            } else {
                c0.name = "standard input";
                p.have_read_stdin = true;
                if (!p.attach(c0, p.readStdin())) return false;
                p.initHeader("", -1, null);
                c0.lines_stored = 0;
            }
            const first_name = c0.name;
            const first_fp = c0.fp;
            var i: usize = 1;
            while (i < @as(usize, @intCast(p.columns))) : (i += 1) {
                const q = p.col(i);
                q.name = first_name;
                q.fp = first_fp;
                q.status = .open;
                q.full_page_printed = false;
                q.lines_stored = 0;
            }
        }
        p.files_ready_to_read = p.total_files;
        return true;
    }

    fn initHeader(p: *Pr, filename: []const u8, desc0: i32, mtime: ?struct { i64, u32 }) void {
        var sec: i64 = 0;
        var nsec: u32 = 0;
        var desc = desc0;
        if (std.mem.eql(u8, filename, "-")) desc = -1; // standard input: current time, no name
        if (desc >= 0 and mtime != null and !std.mem.eql(u8, filename, "-")) {
            sec = mtime.?[0];
            nsec = mtime.?[1];
        } else {
            if (p.now_sec == null) {
                const ts = Io.Timestamp.now(p.env.io, .real);
                p.now_sec = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
                p.now_nsec = @intCast(@mod(ts.nanoseconds, std.time.ns_per_s));
            }
            sec = p.now_sec.?;
            nsec = p.now_nsec;
        }
        const tm = tzmod.localtime(&p.zone, sec);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(p.gpa);
        strftime.format(&buf, p.gpa, p.date_format.?, &tm, sec, nsec) catch {};
        if (p.date_text.len > 0) p.gpa.free(p.date_text);
        p.date_text = p.gpa.dupe(u8, buf.items) catch &.{};
        p.file_text = if (p.custom_header) |h| h else if (desc < 0) "" else filename;
        p.header_width_available = p.chars_per_line - printableWidth(p.date_text) - printableWidth(p.file_text);
    }

    fn initFuncs(p: *Pr) void {
        var h: i32 = p.chars_per_margin;
        var h_next: i32 = undefined;
        if (!p.truncate_lines) {
            h_next = anywhere;
        } else if (p.parallel_files and p.numbered_lines) {
            h_next = h +| p.chars_per_column +| p.number_width;
        } else h_next = h +| p.chars_per_column;
        h = h +| p.col_sep_length;
        var i: i32 = 1;
        while (i < p.columns) : (i += 1) {
            const c = p.col(@intCast(i - 1));
            if (p.storing_columns) {
                c.char_func = .store_char;
                c.print_func = .print_stored;
            } else {
                c.char_func = .print_char;
                c.print_func = .read_line;
            }
            c.numbered = p.numbered_lines and (!p.parallel_files or i == 1);
            c.start_position = h;
            if (!p.truncate_lines) {
                h = anywhere;
                h_next = anywhere;
            } else {
                h = h_next +| p.col_sep_length;
                h_next = h +| p.chars_per_column;
            }
        }
        const last = p.col(@intCast(p.columns - 1));
        if (p.storing_columns and p.balance_columns) {
            last.char_func = .store_char;
            last.print_func = .print_stored;
        } else {
            last.char_func = .print_char;
            last.print_func = .read_line;
        }
        last.numbered = p.numbered_lines and (!p.parallel_files or i == 1);
        last.start_position = h;
    }

    fn printFiles(p: *Pr, names: []const []const u8) bool {
        if (!p.initParameters(names.len)) return false;
        if (!p.initFps(names)) return true;
        if (p.storing_columns and !p.initStoreCols()) return true;
        if (p.first_page_number > 1) {
            if (!p.skipToPage(p.first_page_number)) return true;
            p.page_number = p.first_page_number;
        } else p.page_number = 1;
        p.initFuncs();
        p.line_number = p.line_count;
        while (p.printPage()) {}
        return true;
    }

    fn initStoreCols(p: *Pr) bool {
        // Stored lines are indexed with i32. As in GNU, their total width,
        // with one more byte per line, has to fit in one as well.
        const wanted = @as(i64, p.lines_per_body) * p.columns;
        const max = std.math.maxInt(i32);
        if (wanted >= max or wanted * (@as(i64, p.chars_per_column) + 1) > max) {
            p.obs.emit(.integer_overflow);
            p.overflowed = true;
            return false;
        }
        const total_lines: usize = @intCast(wanted);
        p.gpa.free(p.line_vector);
        p.gpa.free(p.end_vector);
        p.line_vector = &.{};
        p.end_vector = &.{};
        p.line_vector = p.gpa.alloc(i32, total_lines + 1) catch return p.noMemory();
        p.end_vector = p.gpa.alloc(i32, total_lines + 1) catch return p.noMemory();
        @memset(p.line_vector, 0);
        @memset(p.end_vector, 0);
        p.buff.clearRetainingCapacity();
        return true;
    }

    fn initPage(p: *Pr) void {
        if (p.storing_columns) {
            p.storeColumns();
            var j: i32 = 0;
            while (j < p.columns - 1) : (j += 1) {
                const c = p.col(@intCast(j));
                c.lines_to_print = c.lines_stored;
            }
            const last = p.col(@intCast(p.columns - 1));
            if (p.balance_columns) {
                last.lines_to_print = last.lines_stored;
            } else if (last.status == .open) {
                last.lines_to_print = p.lines_per_body;
            } else last.lines_to_print = 0;
        } else {
            var j: usize = 0;
            while (j < @as(usize, @intCast(p.columns))) : (j += 1) {
                const c = p.col(j);
                c.lines_to_print = if (c.status == .open) p.lines_per_body else 0;
            }
        }
    }

    fn alignColumn(p: *Pr, c: *Column) void {
        p.padding_not_printed = c.start_position;
        if (p.col_sep_length < p.padding_not_printed) {
            p.padAcrossTo(p.padding_not_printed - p.col_sep_length);
            p.padding_not_printed = anywhere;
        }
        if (p.use_col_separator) p.printSepString();
        if (c.numbered) p.addLineNumber(c);
    }

    fn callPrint(p: *Pr, c: *Column) bool {
        return switch (c.print_func) {
            .read_line => p.readLine(c),
            .print_stored => p.printStored(c),
        };
    }

    fn printPage(p: *Pr) bool {
        p.initPage();
        if (p.colsReadyToPrint() == 0) return false;
        if (p.extremities) p.print_a_header = true;
        p.pad_vertically = false;
        var pv = false;
        var lines_left_on_page = p.lines_per_body;
        if (p.double_space) lines_left_on_page *|= 2;
        while (lines_left_on_page > 0 and p.colsReadyToPrint() > 0) {
            p.output_position = 0;
            p.spaces_not_printed = 0;
            p.separators_not_printed = 0;
            p.pad_vertically = false;
            p.align_empty_cols = false;
            p.empty_line = true;
            var j: i32 = 1;
            while (j <= p.columns) : (j += 1) {
                const c = p.col(@intCast(j - 1));
                p.input_position = 0;
                if (c.lines_to_print > 0 or c.status == .ff_found) {
                    p.ff_only = false;
                    p.padding_not_printed = c.start_position;
                    if (!p.callPrint(c)) p.readRestOfLine(c);
                    pv = pv or p.pad_vertically;
                    c.lines_to_print -= 1;
                    if (c.lines_to_print <= 0) {
                        if (p.colsReadyToPrint() == 0) break;
                    }
                    if (p.parallel_files and c.status != .open) {
                        if (p.empty_line) {
                            p.align_empty_cols = true;
                        } else if (c.status == .closed or (c.status == .on_hold and p.ff_only)) {
                            p.alignColumn(c);
                        }
                    }
                } else if (p.parallel_files) {
                    if (p.empty_line) p.align_empty_cols = true else p.alignColumn(c);
                }
                if (p.use_col_separator) p.separators_not_printed += 1;
            }
            if (p.pad_vertically) {
                p.putchar('\n');
                lines_left_on_page -= 1;
            }
            if (p.colsReadyToPrint() == 0 and !p.extremities) break;
            if (p.double_space and pv) {
                p.putchar('\n');
                lines_left_on_page -= 1;
            }
        }
        if (lines_left_on_page == 0) {
            var j: usize = 0;
            while (j < @as(usize, @intCast(p.columns))) : (j += 1) {
                const c = p.col(j);
                if (c.status == .open) c.full_page_printed = true;
            }
        }
        p.pad_vertically = pv;
        if (p.pad_vertically and p.extremities) {
            p.padDown(@intCast(lines_left_on_page +| lines_per_footer));
        } else if (p.keep_ff and p.print_a_ff) {
            p.putchar('\x0c');
            p.print_a_ff = false;
        }
        p.page_number +%= 1;
        if (p.last_page_number < p.page_number) return false;
        p.resetStatus();
        return true;
    }

    fn storeColumns(p: *Pr) void {
        p.buff.clearRetainingCapacity();
        var line: usize = 0;
        var buff_start: usize = 0;
        const last_col: i32 = if (p.balance_columns) p.columns else p.columns - 1;
        var i: i32 = 1;
        while (i <= last_col) : (i += 1) p.col(@intCast(i - 1)).lines_stored = 0;
        i = 1;
        while (i <= last_col and p.files_ready_to_read != 0) : (i += 1) {
            const c = p.col(@intCast(i - 1));
            c.current_line = @intCast(line);
            var j = p.lines_per_body;
            while (j != 0 and p.files_ready_to_read != 0) : (j -= 1) {
                if (c.status == .open) {
                    p.input_position = 0;
                    if (!p.readLine(c)) p.readRestOfLine(c);
                    if (c.status == .open or buff_start != p.buff.items.len) {
                        c.lines_stored += 1;
                        p.line_vector[line] = @intCast(buff_start);
                        p.end_vector[line] = p.input_position;
                        line += 1;
                        buff_start = p.buff.items.len;
                    }
                }
            }
        }
        p.line_vector[line] = @intCast(buff_start);
        if (p.balance_columns) p.balance(@intCast(line));
    }

    fn balance(p: *Pr, total_stored: i32) void {
        var first_line: i32 = 0;
        var i: i32 = 1;
        while (i <= p.columns) : (i += 1) {
            const c = p.col(@intCast(i - 1));
            var lines = @divTrunc(total_stored, p.columns);
            if (i <= @mod(total_stored, p.columns)) lines += 1;
            c.lines_stored = lines;
            c.current_line = first_line;
            first_line += lines;
        }
    }

    fn emit(p: *Pr, c: *Column, ch: u8) void {
        switch (c.char_func) {
            .store_char => p.buff.append(p.gpa, ch) catch {
                p.out_of_memory = true;
            },
            .print_char => p.printChar(ch),
        }
    }

    fn emitSpaces(p: *Pr, c: *Column, count: i32) void {
        var i = count;
        while (i > 0 and !p.out_of_memory and !p.out.failed) : (i -= 1) p.emit(c, ' ');
    }

    /// The number right-aligned in `chars_per_number` columns, of which only
    /// the last that many digits are kept.
    fn addLineNumber(p: *Pr, c: *Column) void {
        var raw: [32]u8 = undefined;
        const digits_s = std.fmt.bufPrint(&raw, "{d}", .{p.line_number}) catch unreachable;
        const w: usize = @intCast(p.chars_per_number);
        p.line_number +%= 1;
        if (digits_s.len < w) p.emitSpaces(c, @intCast(w - digits_s.len));
        for (digits_s[digits_s.len -| w..]) |ch| p.emit(c, ch);
        if (p.columns > 1) {
            if (p.number_separator == '\t') {
                p.emitSpaces(c, p.number_width - p.chars_per_number);
            } else p.emit(c, p.number_separator);
        } else {
            p.emit(c, p.number_separator);
            if (p.number_separator == '\t') p.output_position = posAfterTab(p.chars_per_output_tab, p.output_position);
        }
        if (p.truncate_lines and !p.parallel_files) p.input_position +|= p.number_width;
    }

    fn padAcrossTo(p: *Pr, position: i32) void {
        if (p.tabify_output) {
            p.spaces_not_printed = position -| p.output_position;
        } else {
            p.putSpaces(position -| p.output_position);
            p.output_position = position;
        }
    }

    fn putSpaces(p: *Pr, count: i32) void {
        var i = count;
        while (i > 0 and !p.out.failed) : (i -= 1) p.putchar(' ');
    }

    fn padDown(p: *Pr, lines: u32) void {
        if (p.use_form_feed) {
            p.putchar('\x0c');
        } else {
            var i = lines;
            while (i > 0) : (i -= 1) p.putchar('\n');
        }
    }

    fn readRestOfLine(p: *Pr, c: *Column) void {
        const f = c.fp;
        while (true) {
            var ch = f.getc();
            if (ch == '\n') break;
            if (ch == 0x0c) {
                ch = f.getc();
                if (ch != '\n') f.ungetc(ch);
                if (p.keep_ff) p.print_a_ff = true;
                p.holdFile(c);
                break;
            } else if (ch == eof) {
                p.closeFile(c);
                break;
            }
        }
    }

    fn skipRead(p: *Pr, c: *Column, column_number: i32) void {
        const f = c.fp;
        var single_ff = false;
        var ch = f.getc();
        if (ch == 0x0c and c.full_page_printed) {
            ch = f.getc();
            if (ch == '\n') ch = f.getc();
        }
        c.full_page_printed = false;
        if (ch == 0x0c) single_ff = true;
        if (p.last_line) c.full_page_printed = true;
        while (ch != '\n') {
            if (ch == 0x0c) {
                if (p.last_line) {
                    if (!p.parallel_files) {
                        var i: usize = 0;
                        while (i < @as(usize, @intCast(p.columns))) : (i += 1) p.col(i).full_page_printed = false;
                    } else c.full_page_printed = false;
                }
                ch = f.getc();
                if (ch != '\n') f.ungetc(ch);
                p.holdFile(c);
                break;
            } else if (ch == eof) {
                p.closeFile(c);
                break;
            }
            ch = f.getc();
        }
        if (p.skip_count) {
            if ((!p.parallel_files or column_number == 1) and !single_ff) p.line_count +%= 1;
        }
    }

    fn printWhiteSpace(p: *Pr) void {
        var h_old = p.output_position;
        const goal = h_old +| p.spaces_not_printed;
        while (goal -| h_old > 1) {
            const h_new = posAfterTab(p.chars_per_output_tab, h_old);
            if (h_new > goal) break;
            p.putchar(p.output_tab_char);
            h_old = h_new;
        }
        p.putSpaces(goal -| h_old);
        p.output_position = goal;
        p.spaces_not_printed = 0;
    }

    fn printSepString(p: *Pr) void {
        const s = p.col_sep_string;
        if (p.separators_not_printed <= 0) {
            if (p.spaces_not_printed > 0) p.printWhiteSpace();
        } else {
            while (p.separators_not_printed > 0) : (p.separators_not_printed -= 1) {
                for (s[0..@intCast(p.col_sep_length)]) |ch| {
                    if (ch == ' ') {
                        p.spaces_not_printed +|= 1;
                    } else {
                        if (p.spaces_not_printed > 0) p.printWhiteSpace();
                        p.putchar(ch);
                        p.output_position += 1;
                    }
                }
                if (p.spaces_not_printed > 0) p.printWhiteSpace();
            }
        }
    }

    fn printChar(p: *Pr, ch: u8) void {
        if (p.tabify_output) {
            if (ch == ' ') {
                p.spaces_not_printed +|= 1;
                return;
            } else if (p.spaces_not_printed > 0) p.printWhiteSpace();
            if (!(ch >= 0x20 and ch < 0x7f)) {
                if (ch == 8) p.output_position -= 1;
            } else p.output_position +|= 1;
        }
        p.putchar(ch);
    }

    fn skipToPage(p: *Pr, page: u64) bool {
        var n: u64 = 1;
        while (n < page) : (n += 1) {
            var i: i32 = 1;
            while (i < p.lines_per_body) : (i += 1) {
                var j: i32 = 1;
                while (j <= p.columns) : (j += 1) {
                    const c = p.col(@intCast(j - 1));
                    if (c.status == .open) p.skipRead(c, j);
                }
            }
            p.last_line = true;
            var j: i32 = 1;
            while (j <= p.columns) : (j += 1) {
                const c = p.col(@intCast(j - 1));
                if (c.status == .open) p.skipRead(c, j);
            }
            if (p.storing_columns) {
                j = 1;
                while (j <= p.columns) : (j += 1) {
                    const c = p.col(@intCast(j - 1));
                    if (c.status != .closed) c.status = .on_hold;
                }
            }
            p.resetStatus();
            p.last_line = false;
            if (p.files_ready_to_read < 1) {
                if (!p.read_failed) p.obs.emit(.{ .start_page_exceeds = .{ .page = page, .count = n } });
                break;
            }
        }
        return p.files_ready_to_read > 0;
    }

    fn printHeader(p: *Pr) bool {
        p.output_position = 0;
        p.padAcrossTo(p.chars_per_margin);
        p.printWhiteSpace();
        if (p.page_number == 0) {
            p.obs.emit(.page_number_overflow);
            return false;
        }
        var pt: [64]u8 = undefined;
        const page_text = std.fmt.bufPrint(&pt, "Page {d}", .{p.page_number}) catch unreachable;
        var available = p.header_width_available - @as(i32, @intCast(page_text.len));
        if (available < 0) available = 0;
        const lhs: usize = @intCast(available >> 1);
        const rhs: usize = @intCast(available - @as(i32, @intCast(lhs)));
        p.out.write("\n\n");
        var i: i32 = 0;
        while (i < p.chars_per_margin) : (i += 1) p.putchar(' ');
        p.out.write(p.date_text);
        // printf("%*s", n, " "): a one-character string padded to width n.
        spacesWidth(p, lhs);
        p.out.write(p.file_text);
        spacesWidth(p, rhs);
        p.out.write(page_text);
        p.out.write("\n\n\n");
        p.print_a_header = false;
        p.output_position = 0;
        return true;
    }

    fn spacesWidth(p: *Pr, w: usize) void {
        // "%*s" with the string " " prints max(w, 1) characters.
        var n = if (w < 1) 1 else w;
        while (n > 0) : (n -= 1) p.putchar(' ');
    }

    fn readLine(p: *Pr, c: *Column) bool {
        var ch = c.fp.getc();
        var last_input_position = p.input_position;
        if (ch == 0x0c and c.full_page_printed) {
            ch = c.fp.getc();
            if (ch == '\n') ch = c.fp.getc();
        }
        c.full_page_printed = false;
        var chars: i32 = 0;
        switch (ch) {
            0x0c => {
                ch = c.fp.getc();
                if (ch != '\n') c.fp.ungetc(ch);
                p.ff_only = true;
                if (p.print_a_header and !p.storing_columns) {
                    p.pad_vertically = true;
                    _ = p.printHeader();
                } else if (p.keep_ff) p.print_a_ff = true;
                p.holdFile(c);
                return true;
            },
            eof => {
                p.closeFile(c);
                return true;
            },
            '\n' => {},
            else => chars = p.charToClump(@intCast(ch)),
        }
        if (p.truncate_lines and p.input_position > p.chars_per_column) {
            p.input_position = last_input_position;
            return false;
        }
        if (c.char_func != .store_char) {
            p.pad_vertically = true;
            if (p.print_a_header and !p.storing_columns) _ = p.printHeader();
            if (p.parallel_files and p.align_empty_cols) {
                const k = p.separators_not_printed;
                p.separators_not_printed = 0;
                var j: i32 = 1;
                while (j <= k) : (j += 1) {
                    p.alignColumn(p.col(@intCast(j - 1)));
                    p.separators_not_printed += 1;
                }
                p.padding_not_printed = c.start_position;
                p.spaces_not_printed = if (p.truncate_lines) p.chars_per_column else 0;
                p.align_empty_cols = false;
            }
            if (p.col_sep_length < p.padding_not_printed) {
                p.padAcrossTo(p.padding_not_printed - p.col_sep_length);
                p.padding_not_printed = anywhere;
            }
            if (p.use_col_separator) p.printSepString();
        }
        if (c.numbered) p.addLineNumber(c);
        p.empty_line = false;
        if (ch == '\n') return true;
        p.printClump(c, chars);
        while (true) {
            ch = c.fp.getc();
            switch (ch) {
                '\n' => return true,
                0x0c => {
                    ch = c.fp.getc();
                    if (ch != '\n') c.fp.ungetc(ch);
                    if (p.keep_ff) p.print_a_ff = true;
                    p.holdFile(c);
                    return true;
                },
                eof => {
                    p.closeFile(c);
                    return true;
                },
                else => {},
            }
            last_input_position = p.input_position;
            chars = p.charToClump(@intCast(ch));
            if (p.truncate_lines and p.input_position > p.chars_per_column) {
                p.input_position = last_input_position;
                return false;
            }
            p.printClump(c, chars);
        }
    }

    fn printClump(p: *Pr, c: *Column, n: i32) void {
        if (p.clump_is_spaces) return p.emitSpaces(c, n);
        for (p.clump_buff[0..@intCast(n)]) |ch| p.emit(c, ch);
    }

    fn printStored(p: *Pr, c: *Column) bool {
        const line: usize = @intCast(c.current_line);
        c.current_line += 1;
        const first: usize = @intCast(p.line_vector[line]);
        const last: usize = @intCast(p.line_vector[line + 1]);
        p.pad_vertically = true;
        if (p.print_a_header) _ = p.printHeader();
        if (c.status == .ff_found) {
            var i: usize = 0;
            while (i < @as(usize, @intCast(p.columns))) : (i += 1) p.col(i).status = .on_hold;
            if (p.col(0).lines_to_print <= 0) {
                if (!p.extremities) p.pad_vertically = false;
                return true;
            }
        }
        if (p.col_sep_length < p.padding_not_printed) {
            p.padAcrossTo(p.padding_not_printed - p.col_sep_length);
            p.padding_not_printed = anywhere;
        }
        if (p.use_col_separator) p.printSepString();
        var k = first;
        while (k != last) : (k += 1) p.printChar(p.buff.items[k]);
        if (p.spaces_not_printed == 0) {
            p.output_position = c.start_position +| p.end_vector[line];
            if (c.start_position - p.col_sep_length == p.chars_per_margin) p.output_position -= p.col_sep_length;
        }
        return true;
    }

    fn charToClump(p: *Pr, c: u8) i32 {
        var width: i32 = 0;
        var chars: i32 = 0;
        var chars_per_c: i32 = 8;
        if (c == p.input_tab_char) chars_per_c = p.chars_per_input_tab;
        p.clump_is_spaces = false;
        if (c == p.input_tab_char or c == '\t') {
            width = tabWidth(chars_per_c, p.input_position);
            if (p.untabify_input) {
                p.clump_is_spaces = true;
                chars = width;
            } else {
                p.clump_buff[0] = c;
                chars = 1;
            }
        } else if (!(c >= 0x20 and c < 0x7f)) {
            if (p.use_esc_sequence) {
                width = 4;
                chars = 4;
                _ = std.fmt.bufPrint(p.clump_buff[0..4], "\\{o:0>3}", .{c}) catch unreachable;
            } else if (p.use_cntrl_prefix) {
                if (c < 0o200) {
                    width = 2;
                    chars = 2;
                    p.clump_buff[0] = '^';
                    p.clump_buff[1] = c ^ 0o100;
                } else {
                    width = 4;
                    chars = 4;
                    _ = std.fmt.bufPrint(p.clump_buff[0..4], "\\{o:0>3}", .{c}) catch unreachable;
                }
            } else if (c == 8) {
                width = -1;
                chars = 1;
                p.clump_buff[0] = c;
            } else {
                width = 0;
                chars = 1;
                p.clump_buff[0] = c;
            }
        } else {
            width = 1;
            chars = 1;
            p.clump_buff[0] = c;
        }
        if (width < 0 and p.input_position == 0) {
            chars = 0;
            p.input_position = 0;
        } else if (width < 0 and p.input_position <= -width) {
            p.input_position = 0;
        } else p.input_position +|= width;
        return chars;
    }
};

/// mbswidth in the C locale: control characters take no columns.
fn printableWidth(text: []const u8) i32 {
    var w: i32 = 0;
    for (text) |c| if (c >= 0x20 and c < 0x7f) {
        w += 1;
    };
    return w;
}
