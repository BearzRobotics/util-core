//! pr — paginate or columnate files for printing.
//! Reference: GNU coreutils manual "pr invocation" (9.7); POSIX.1-2024 pr.
//!
//! pr's page layout is intricate (form feeds, balanced columns, merged
//! files, tab handling), and its observable behaviour is defined by the
//! control flow of GNU pr.c (coreutils 9.6 sources, consulted 2026-11-07).
//! This file follows that structure function by function, with the global
//! state gathered into one struct, so the output is identical. Input files are
//! read completely before formatting (a stream with one character of push
//! back replaces stdio). Widths count bytes (C locale).

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const Io = std.Io;

const help_text = @embedFile("../help/pr.txt");

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
fn posAfterTab(c: i32, h: i32) i32 {
    return h + tabWidth(c, h);
}

const Pr = struct {
    ctx: cli.Context,
    gpa: std.mem.Allocator,
    out: cli.Out,
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
    clump_buff: [64]u8 = undefined,
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
                p.number_width = p.chars_per_number + tabWidth(8, p.chars_per_number);
            } else p.number_width = p.chars_per_number + 1;
            if (p.parallel_files) chars_used_by_number = p.number_width;
        }
        const sep_chars: i64 = @as(i64, p.columns - 1) * p.col_sep_length;
        var useful: i64 = @as(i64, p.chars_per_line - chars_used_by_number) - sep_chars;
        if (useful < 0) useful = 0;
        p.chars_per_column = @intCast(@divTrunc(useful, p.columns));
        if (p.chars_per_column < 1) {
            cli.warn(p.ctx, "page width too narrow", .{});
            return false;
        }
        return true;
    }

    fn readAll(p: *Pr, file: Io.File) ?[]u8 {
        var list: std.ArrayList(u8) = .empty;
        var chunk: [65536]u8 = undefined;
        while (true) {
            const n = cli.readChunk(p.ctx.io, file, &chunk) catch return null;
            if (n == 0) break;
            list.appendSlice(p.gpa, chunk[0..n]) catch return null;
        }
        return list.toOwnedSlice(p.gpa) catch null;
    }

    fn openFile(p: *Pr, name: []const u8, c: *Column) bool {
        var file: ?Io.File = null;
        var data: ?[]u8 = null;
        if (std.mem.eql(u8, name, "-")) {
            c.name = "standard input";
            p.have_read_stdin = true;
            file = Io.File.stdin();
            data = p.readAll(file.?);
        } else {
            c.name = name;
            if (cli.openInput(p.ctx.io, name)) |f| {
                file = f;
                data = p.readAll(f);
                cli.closeInput(p.ctx.io, f);
            } else |e| {
                p.failed_opens = true;
                if (!p.ignore_failed_opens) cli.warn(p.ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
                return false;
            }
        }
        const s = p.gpa.create(Stream) catch return false;
        s.* = .{ .data = data orelse &.{} };
        p.streams.append(p.gpa, s) catch return false;
        if (data) |d| p.stream_data.append(p.gpa, d) catch return false;
        c.fp = s;
        c.status = .open;
        c.full_page_printed = false;
        p.total_files += 1;
        return true;
    }

    fn closeFile(p: *Pr, c: *Column) void {
        if (c.status == .closed) return;
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
        p.columns_v.resize(p.gpa, @intCast(@max(p.columns, 1))) catch return false;
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
                const s = p.gpa.create(Stream) catch return false;
                s.* = .{ .data = p.readAll(Io.File.stdin()) orelse &.{} };
                p.streams.append(p.gpa, s) catch return false;
                p.stream_data.append(p.gpa, @constCast(s.data)) catch return false;
                c0.fp = s;
                c0.status = .open;
                c0.full_page_printed = false;
                p.total_files += 1;
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
                const ts = Io.Timestamp.now(p.ctx.io, .real);
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
            h_next = h + p.chars_per_column + p.number_width;
        } else h_next = h + p.chars_per_column;
        h = h + p.col_sep_length;
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
                h = h_next + p.col_sep_length;
                h_next = h + p.chars_per_column;
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
        if (p.storing_columns) p.initStoreCols();
        if (p.first_page_number > 1) {
            if (!p.skipToPage(p.first_page_number)) return true;
            p.page_number = p.first_page_number;
        } else p.page_number = 1;
        p.initFuncs();
        p.line_number = p.line_count;
        while (p.printPage()) {}
        return true;
    }

    fn initStoreCols(p: *Pr) void {
        const total_lines: usize = @intCast(@as(i64, p.lines_per_body) * p.columns);
        p.gpa.free(p.line_vector);
        p.gpa.free(p.end_vector);
        p.line_vector = p.gpa.alloc(i32, total_lines + 1) catch &.{};
        p.end_vector = p.gpa.alloc(i32, total_lines + 1) catch &.{};
        @memset(p.line_vector, 0);
        @memset(p.end_vector, 0);
        p.buff.clearRetainingCapacity();
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
        if (p.double_space) lines_left_on_page *= 2;
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
            p.padDown(@intCast(lines_left_on_page + lines_per_footer));
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
            .store_char => p.buff.append(p.gpa, ch) catch {},
            .print_char => p.printChar(ch),
        }
    }

    fn addLineNumber(p: *Pr, c: *Column) void {
        var nb: [96]u8 = undefined;
        var raw: [32]u8 = undefined;
        const digits_s = std.fmt.bufPrint(&raw, "{d}", .{p.line_number}) catch unreachable;
        const w: usize = @intCast(p.chars_per_number);
        const pad = if (digits_s.len < w) w - digits_s.len else 0;
        @memset(nb[0..pad], ' ');
        @memcpy(nb[pad .. pad + digits_s.len], digits_s);
        const s = nb[0 .. pad + digits_s.len];
        p.line_number +%= 1;
        const cut: usize = s.len - @as(usize, @intCast(p.chars_per_number));
        for (s[cut..]) |ch| p.emit(c, ch);
        if (p.columns > 1) {
            if (p.number_separator == '\t') {
                var i = p.number_width - p.chars_per_number;
                while (i > 0) : (i -= 1) p.emit(c, ' ');
            } else p.emit(c, p.number_separator);
        } else {
            p.emit(c, p.number_separator);
            if (p.number_separator == '\t') p.output_position = posAfterTab(p.chars_per_output_tab, p.output_position);
        }
        if (p.truncate_lines and !p.parallel_files) p.input_position += p.number_width;
    }

    fn padAcrossTo(p: *Pr, position: i32) void {
        var h = p.output_position;
        if (p.tabify_output) {
            p.spaces_not_printed = position - p.output_position;
        } else {
            h += 1;
            while (h <= position) : (h += 1) p.putchar(' ');
            p.output_position = position;
        }
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
        const goal = h_old + p.spaces_not_printed;
        while (goal - h_old > 1) {
            const h_new = posAfterTab(p.chars_per_output_tab, h_old);
            if (h_new > goal) break;
            p.putchar(p.output_tab_char);
            h_old = h_new;
        }
        h_old += 1;
        while (h_old <= goal) : (h_old += 1) p.putchar(' ');
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
                        p.spaces_not_printed += 1;
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
                p.spaces_not_printed += 1;
                return;
            } else if (p.spaces_not_printed > 0) p.printWhiteSpace();
            if (!(ch >= 0x20 and ch < 0x7f)) {
                if (ch == 8) p.output_position -= 1;
            } else p.output_position += 1;
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
                cli.warn(p.ctx, "starting page number {d} exceeds page count {d}", .{ page, n });
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
            cli.warn(p.ctx, "page number overflow", .{});
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
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) : (i += 1) p.emit(c, p.clump_buff[i]);
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
            p.output_position = c.start_position + p.end_vector[line];
            if (c.start_position - p.col_sep_length == p.chars_per_margin) p.output_position -= p.col_sep_length;
        }
        return true;
    }

    fn charToClump(p: *Pr, c: u8) i32 {
        var n: usize = 0;
        var width: i32 = 0;
        var chars: i32 = 0;
        var chars_per_c: i32 = 8;
        if (c == p.input_tab_char) chars_per_c = p.chars_per_input_tab;
        if (c == p.input_tab_char or c == '\t') {
            width = tabWidth(chars_per_c, p.input_position);
            if (p.untabify_input) {
                var i = width;
                while (i > 0) : (i -= 1) {
                    p.clump_buff[n] = ' ';
                    n += 1;
                }
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
        } else p.input_position += width;
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

fn parseNum(ctx: cli.Context, text: []const u8, min: i64, err: []const u8) ?i32 {
    const v = std.fmt.parseInt(i64, text, 10) catch |e| {
        cli.warn(ctx, "{s}: {f}{s}", .{ err, cli.quoteC(text), if (e == error.Overflow) ": Value too large for defined data type" else "" });
        return null;
    };
    if (v < min or v > std.math.maxInt(i32)) {
        // xnumtoimax: below a positive minimum is ERANGE, anything else EOVERFLOW.
        const why: []const u8 = if (v < min and min > 0) ": Numerical result out of range" else ": Value too large for defined data type";
        cli.warn(ctx, "{s}: {f}{s}", .{ err, cli.quoteC(text), why });
        return null;
    }
    return @intCast(v);
}

fn getoptarg(ctx: cli.Context, arg: []const u8, sw: u8, character: *u8, number: *i32) bool {
    var a = arg;
    if (a.len == 0) {
        getopt.usageError(ctx, "'-{c}': Invalid argument: {f}", .{ sw, cli.quoteC(arg) });
        return false;
    }
    if (!std.ascii.isDigit(a[0])) {
        character.* = a[0];
        a = a[1..];
    }
    if (a.len > 0) {
        const v = std.fmt.parseInt(i64, a, 10) catch -1;
        if (v <= 0 or v > std.math.maxInt(i32)) {
            getopt.usageError(ctx, "'-{c}' extra characters or invalid number in the argument: {f}", .{ sw, cli.quoteC(a) });
            return false;
        }
        number.* = @intCast(v);
    }
    return true;
}

const PageParse = enum { ok, not_pages, fatal };

/// first_last_page: ok, "not a page spec" (treated as a file name), or a
/// fatal xstrtol-style diagnostic already printed.
fn firstLastPage(p: *Pr, ctx: cli.Context, pages: []const u8, option: []const u8) PageParse {
    var i: usize = 0;
    var first: u64 = 0;
    var overflow = false;
    while (i < pages.len and std.ascii.isDigit(pages[i])) : (i += 1) {
        const m = @mulWithOverflow(first, 10);
        const a = @addWithOverflow(m[0], pages[i] - '0');
        if (m[1] != 0 or a[1] != 0) overflow = true;
        first = a[0];
    }
    if (overflow) {
        cli.warn(ctx, "{s} argument {f} too large", .{ option, cli.quoteC(pages) });
        return .fatal;
    }
    if (i == 0) {
        // No digits: xstrtoumax reports an invalid number.
        cli.warn(ctx, "invalid {s} argument {f}", .{ option, cli.quoteC(pages) });
        return .fatal;
    }
    if (first == 0) return .not_pages;
    var last: u64 = std.math.maxInt(u64);
    if (i < pages.len and pages[i] == ':') {
        i += 1;
        const st = i;
        last = 0;
        while (i < pages.len and std.ascii.isDigit(pages[i])) : (i += 1) {
            const m = @mulWithOverflow(last, 10);
            const a = @addWithOverflow(m[0], pages[i] - '0');
            if (m[1] != 0 or a[1] != 0) overflow = true;
            last = a[0];
        }
        if (overflow) {
            cli.warn(ctx, "{s} argument {f} too large", .{ option, cli.quoteC(pages) });
            return .fatal;
        }
        if (i == st) {
            cli.warn(ctx, "invalid {s} argument {f}", .{ option, cli.quoteC(pages) });
            return .fatal;
        }
        if (last < first) return .not_pages;
        if (i < pages.len) {
            cli.warn(ctx, "invalid suffix in {s} argument {f}", .{ option, cli.quoteC(pages) });
            return .fatal;
        }
    } else if (i < pages.len) return .not_pages;
    p.first_page_number = first;
    p.last_page_number = last;
    return .ok;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var tz_env: ?[]const u8 = null;
    if (ctx.environ) |m| tz_env = m.get("TZ");
    const pr = gpa.create(Pr) catch return 1;
    pr.* = .{ .ctx = ctx, .gpa = gpa, .out = cli.Out.init(ctx.io), .zone = tzmod.load(gpa, ctx.io, tz_env) };
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

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var old_w = false;
    var old_s = false;
    var old_options = false;
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(gpa);
    var digit_run = false;

    var parser = getopt.Parser.init(ctx, "-0123456789D:FJN:S::TW:abcde::fh:i::l:mn::o:rs::tvw:", &.{
        .{ .name = "pages", .arg = .required, .id = 1100 },
        .{ .name = "columns", .arg = .required, .id = 1101 },
        .{ .name = "across", .id = 'a' },
        .{ .name = "show-control-chars", .id = 'c' },
        .{ .name = "double-space", .id = 'd' },
        .{ .name = "date-format", .arg = .required, .id = 'D' },
        .{ .name = "expand-tabs", .arg = .optional, .id = 'e' },
        .{ .name = "form-feed", .id = 'f' },
        .{ .name = "header", .arg = .required, .id = 'h' },
        .{ .name = "output-tabs", .arg = .optional, .id = 'i' },
        .{ .name = "join-lines", .id = 'J' },
        .{ .name = "length", .arg = .required, .id = 'l' },
        .{ .name = "merge", .id = 'm' },
        .{ .name = "number-lines", .arg = .optional, .id = 'n' },
        .{ .name = "first-line-number", .arg = .required, .id = 'N' },
        .{ .name = "indent", .arg = .required, .id = 'o' },
        .{ .name = "no-file-warnings", .id = 'r' },
        .{ .name = "separator", .arg = .optional, .id = 's' },
        .{ .name = "sep-string", .arg = .optional, .id = 'S' },
        .{ .name = "omit-header", .id = 't' },
        .{ .name = "omit-pagination", .id = 'T' },
        .{ .name = "show-nonprinting", .id = 'v' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "page-width", .arg = .required, .id = 'W' },
    });
    defer parser.deinit();
    while (true) {
        const item = parser.next();
        const o = switch (item) {
            .done => break,
            .bad => return 1,
            .opt => |o| o,
        };
        if (o.id >= '0' and o.id <= '9') {
            if (!digit_run) digits.clearRetainingCapacity();
            digit_run = true;
            digits.append(gpa, @intCast(o.id)) catch return 1;
            continue;
        }
        digit_run = false;
        switch (o.id) {
            getopt.operand_id => {
                const a = o.arg.?;
                var consumed = false;
                if (pr.first_page_number == 0 and a.len > 0 and a[0] == '+') {
                    switch (firstLastPage(pr, ctx, a[1..], "+")) {
                        .ok => consumed = true,
                        .fatal => return 1,
                        .not_pages => {},
                    }
                }
                if (!consumed) files.append(gpa, a) catch return 1;
            },
            1100 => {
                switch (firstLastPage(pr, ctx, o.arg.?, "--pages")) {
                    .ok => {},
                    .fatal => return 1,
                    .not_pages => {
                        cli.warn(ctx, "invalid page range {f}", .{cli.quoteC(o.arg.?)});
                        return 1;
                    },
                }
            },
            1101 => {
                pr.columns = parseNum(ctx, o.arg.?, 1, "invalid number of columns") orelse return 1;
                pr.explicit_columns = true;
                digits.clearRetainingCapacity(); // --columns overrides -NUM
            },
            'a' => {
                pr.print_across_flag = true;
                pr.storing_columns = false;
            },
            'b' => pr.balance_columns = true,
            'c' => pr.use_cntrl_prefix = true,
            'd' => pr.double_space = true,
            'D' => pr.date_format = o.arg,
            'e' => {
                if (o.arg) |a| if (!getoptarg(ctx, a, 'e', &pr.input_tab_char, &pr.chars_per_input_tab)) return 1;
                pr.untabify_input = true;
            },
            'f', 'F' => pr.use_form_feed = true,
            'h' => pr.custom_header = o.arg,
            'i' => {
                if (o.arg) |a| if (!getoptarg(ctx, a, 'i', &pr.output_tab_char, &pr.chars_per_output_tab)) return 1;
                pr.tabify_output = true;
            },
            'J' => pr.join_lines = true,
            'l' => pr.lines_per_page = parseNum(ctx, o.arg.?, 1, "'-l PAGE_LENGTH' invalid number of lines") orelse return 1,
            'm' => {
                pr.parallel_files = true;
                pr.storing_columns = false;
            },
            'n' => {
                pr.numbered_lines = true;
                if (o.arg) |a| if (!getoptarg(ctx, a, 'n', &pr.number_separator, &pr.chars_per_number)) return 1;
            },
            'N' => {
                pr.skip_count = false;
                pr.start_line_num = parseNum(ctx, o.arg.?, std.math.minInt(i32), "'-N NUMBER' invalid starting line number") orelse return 1;
            },
            'o' => pr.chars_per_margin = parseNum(ctx, o.arg.?, 0, "'-o MARGIN' invalid line offset") orelse return 1,
            'r' => pr.ignore_failed_opens = true,
            's' => {
                old_options = true;
                old_s = true;
                if (!pr.use_col_separator) if (o.arg) |a| {
                    pr.col_sep_string = a;
                    pr.col_sep_length = @intCast(a.len);
                };
            },
            'S' => {
                old_s = false;
                pr.col_sep_string = "";
                pr.col_sep_length = 0;
                pr.use_col_separator = true;
                if (o.arg) |a| {
                    pr.col_sep_string = a;
                    pr.col_sep_length = @intCast(a.len);
                }
            },
            't' => {
                pr.extremities = false;
                pr.keep_ff = true;
            },
            'T' => {
                pr.extremities = false;
                pr.keep_ff = false;
            },
            'v' => pr.use_esc_sequence = true,
            'w' => {
                old_options = true;
                old_w = true;
                const tmp = parseNum(ctx, o.arg.?, 1, "'-w PAGE_WIDTH' invalid number of characters") orelse return 1;
                if (!pr.truncate_lines) pr.chars_per_line = tmp;
            },
            'W' => {
                old_w = false;
                pr.truncate_lines = true;
                pr.chars_per_line = parseNum(ctx, o.arg.?, 1, "'-W PAGE_WIDTH' invalid number of characters") orelse return 1;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        }
    }
    if (digits.items.len > 0) {
        pr.columns = parseNum(ctx, digits.items, 1, "invalid number of columns") orelse return 1;
        pr.explicit_columns = true;
    }
    return finish(pr, ctx, &files, &digits, old_options, old_w, old_s);
}

fn finish(pr: *Pr, ctx: cli.Context, files: *std.ArrayList([]const u8), digits: *std.ArrayList(u8), old_options: bool, old_w: bool, old_s: bool) u8 {
    _ = digits;
    if (pr.date_format == null) pr.date_format = "%Y-%m-%d %H:%M";
    if (pr.first_page_number == 0) pr.first_page_number = 1;
    if (pr.parallel_files and pr.explicit_columns) {
        cli.warn(ctx, "cannot specify number of columns when printing in parallel", .{});
        return 1;
    }
    if (pr.parallel_files and pr.print_across_flag) {
        cli.warn(ctx, "cannot specify both printing across and printing in parallel", .{});
        return 1;
    }
    if (old_options) {
        if (old_w) {
            if (pr.parallel_files or pr.explicit_columns) {
                pr.truncate_lines = true;
                if (old_s) pr.use_col_separator = true;
            } else pr.join_lines = true;
        } else if (!pr.use_col_separator) {
            if (old_s and (pr.parallel_files or pr.explicit_columns)) {
                if (!pr.truncate_lines) {
                    pr.join_lines = true;
                    if (pr.col_sep_length > 0) pr.use_col_separator = true;
                } else pr.use_col_separator = true;
            }
        }
    }
    if (files.items.len == 0) {
        _ = pr.printFiles(&.{});
    } else if (pr.parallel_files) {
        _ = pr.printFiles(files.items);
    } else {
        for (files.items) |f| {
            const one = [_][]const u8{f};
            if (!pr.printFiles(&one)) {
                pr.out.flush();
                return 1;
            }
        }
    }
    pr.out.flush();
    if (pr.out.failed) return 1;
    return if (pr.failed_opens) 1 else 0;
}
