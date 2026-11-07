//! ptx — produce a permuted index of file contents.
//! Reference: GNU coreutils manual "ptx invocation" (9.7). POSIX does not
//! specify ptx.
//!
//! The field layout (tail, before, keyword+after, head, reference), the
//! truncation marks and the wrap-around rules follow GNU ptx.c (coreutils 9.6
//! sources, consulted 2026-11-07). Input is processed as bytes (C locale).
//! The default end-of-sentence pattern is matched by hand; user supplied
//! -S/-W expressions use the project's regex engine after translating GNU
//! Emacs-style syntax (\( \) \|) to extended syntax, so unusual patterns can
//! behave differently from glibc's matcher.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const posixre = @import("../posixre.zig");
const Io = std.Io;

const help_text = @embedFile("../help/ptx.txt");

const Format = enum { unknown, dumb, roff, tex };

const Occurs = struct {
    key_start: usize,
    key_size: usize,
    left: isize,
    right: isize,
    reference: i64,
    file_index: usize,
};

const Ptx = struct {
    ctx: cli.Context,
    gpa: std.mem.Allocator,
    out: cli.Out,
    gnu_extensions: bool = true,
    auto_reference: bool = false,
    input_reference: bool = false,
    right_reference: bool = false,
    line_width: isize = 72,
    gap_size: isize = 3,
    truncation_string: ?[]const u8 = "/",
    macro_name: []const u8 = "xx",
    output_format: Format = .unknown,
    ignore_case: bool = false,
    break_file: ?[]const u8 = null,
    only_file: ?[]const u8 = null,
    ignore_file: ?[]const u8 = null,
    context_regex: ?[]const u8 = null,
    word_regex: ?[]const u8 = null,
    context_re: ?posixre.Compiled = null,
    word_re: ?posixre.Compiled = null,
    word_re_anch: ?posixre.Compiled = null,
    word_fastmap: [256]bool = @splat(false),
    default_context: bool = false,
    maximum_word_length: usize = 0,
    reference_max_width: isize = 0,
    ignore_table: std.ArrayList([]const u8) = .empty,
    only_table: std.ArrayList([]const u8) = .empty,
    names: [][]const u8 = &.{},
    file_names: []?[]const u8 = &.{},
    file_line_count: []i64 = &.{},
    buffers: [][]u8 = &.{},
    total_line_count: i64 = 0,
    occurs: std.ArrayList(Occurs) = .empty,
    // output state
    edited: [256]bool = @splat(false),
    half_line_width: isize = 0,
    before_max_width: isize = 0,
    keyafter_max_width: isize = 0,
    truncation_len: isize = 0,
    // fields as [start,end) offsets into the current file buffer
    tail: [2]usize = .{ 0, 0 },
    tail_truncation: bool = false,
    before: [2]usize = .{ 0, 0 },
    before_truncation: bool = false,
    keyafter: [2]usize = .{ 0, 0 },
    keyafter_truncation: bool = false,
    head: [2]usize = .{ 0, 0 },
    head_truncation: bool = false,
    reference: []const u8 = "",
    ref_buf: [4096]u8 = undefined,

    fn fold(p: *const Ptx, c: u8) u8 {
        return if (p.ignore_case) std.ascii.toUpper(c) else c;
    }

    fn compareWords(p: *const Ptx, a: []const u8, b: []const u8) std.math.Order {
        const n = @min(a.len, b.len);
        for (0..n) |i| {
            const x = p.fold(a[i]);
            const y = p.fold(b[i]);
            if (x != y) return std.math.order(x, y);
        }
        return std.math.order(a.len, b.len);
    }

    fn searchTable(p: *const Ptx, word: []const u8, table: []const []const u8) bool {
        var lo: usize = 0;
        var hi: usize = table.len;
        while (lo < hi) {
            const mid = (lo >> 1) + (hi >> 1) + (lo & hi & 1);
            switch (p.compareWords(word, table[mid])) {
                .lt => hi = mid,
                .gt => lo = mid + 1,
                .eq => return true,
            }
        }
        return false;
    }

    /// SKIP_SOMETHING: advance over one word (or one separator character).
    fn skipSomething(p: *Ptx, buf: []const u8, cursor: usize, limit: usize) usize {
        if (cursor >= limit) return cursor + 1;
        if (p.word_re_anch) |*re| {
            var s = re.re.searcher(p.gpa) catch return cursor + 1;
            defer s.deinit();
            const m = (s.find(buf[cursor..limit], 0) catch null) orelse return cursor + 1;
            return cursor + m.end();
        }
        if (p.word_fastmap[buf[cursor]]) {
            var c = cursor;
            while (c < limit and p.word_fastmap[buf[c]]) c += 1;
            return c;
        }
        return cursor + 1;
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or (c >= 9 and c <= 13);
    }

    fn skipNonWhite(buf: []const u8, c0: usize, limit: usize) usize {
        var c = c0;
        while (c < limit and !isSpace(buf[c])) c += 1;
        return c;
    }
    fn skipWhite(buf: []const u8, c0: usize, limit: usize) usize {
        var c = c0;
        while (c < limit and isSpace(buf[c])) c += 1;
        return c;
    }
    fn skipWhiteBackwards(buf: []const u8, c0: usize, start: usize) usize {
        var c = c0;
        while (c > start and isSpace(buf[c - 1])) c -= 1;
        return c;
    }

    /// Next end of context (sentence or line) from `cursor`, as an offset, or
    /// null when there is no separator.
    fn contextZero(p: *Ptx) noreturn {
        // re_search returns the match start; 0 means the separator begins at
        // the cursor, which GNU reports as a zero-length match.
        const text: []const u8 = if (p.default_context) "[.?!][]\"')}]*\\($\\|\t\\|  \\)[ \t\n]*" else p.context_regex.?;
        cli.warn(p.ctx, "error: regular expression has a match of length zero: {f}", .{cli.quoteC(text)});
        std.process.exit(1);
    }

    fn findContextEnd(p: *Ptx, buf: []const u8, cursor: usize) !?usize {
        if (p.default_context) {
            // [.?!][]"')}]*\($\|\t\|  \)[ \t\n]*
            var i = cursor;
            while (i < buf.len) : (i += 1) {
                const c = buf[i];
                if (c != '.' and c != '?' and c != '!') continue;
                var j = i + 1;
                while (j < buf.len and std.mem.indexOfScalar(u8, "]\"')}", buf[j]) != null) j += 1;
                var end: usize = undefined;
                if (j >= buf.len or buf[j] == '\n') {
                    end = j;
                } else if (buf[j] == '\t') {
                    end = j + 1;
                } else if (j + 1 < buf.len and buf[j] == ' ' and buf[j + 1] == ' ') {
                    end = j + 2;
                } else continue;
                if (i == cursor) p.contextZero();
                while (end < buf.len and (buf[end] == ' ' or buf[end] == '\t' or buf[end] == '\n')) end += 1;
                return end;
            }
            return null;
        }
        if (p.context_re) |*re| {
            var s = try re.re.searcher(p.gpa);
            defer s.deinit();
            const m = (try s.find(buf[cursor..], 0)) orelse return null;
            if (m.start() == 0) p.contextZero();
            return cursor + m.end();
        }
        return null;
    }

    fn findOccursInText(p: *Ptx, file_index: usize) !void {
        const buf = p.buffers[file_index];
        var line_start: usize = 0;
        var line_scan: usize = 0;
        var reference_length: usize = 0;
        if (p.input_reference) {
            line_scan = skipNonWhite(buf, line_scan, buf.len);
            reference_length = line_scan - line_start;
            line_scan = skipWhite(buf, line_scan, buf.len);
        }
        var cursor: usize = 0;
        var next_context_start: usize = 0;
        while (cursor < buf.len) : (cursor = next_context_start) {
            var context_start = cursor;
            next_context_start = buf.len;
            if (p.default_context or p.context_re != null) {
                if (try p.findContextEnd(buf, cursor)) |e| next_context_start = e;
            }
            const context_end = skipWhiteBackwards(buf, next_context_start, context_start);
            while (true) {
                var word_start: usize = undefined;
                var word_end: usize = undefined;
                if (p.word_re) |*re| {
                    if (cursor > context_end) break;
                    var s = try re.re.searcher(p.gpa);
                    defer s.deinit();
                    const m = (try s.find(buf[cursor..context_end], 0)) orelse break;
                    word_start = cursor + m.start();
                    word_end = cursor + m.end();
                } else {
                    var scan = cursor;
                    while (scan < context_end and !p.word_fastmap[buf[scan]]) scan += 1;
                    if (scan == context_end) break;
                    word_start = scan;
                    while (scan < context_end and p.word_fastmap[buf[scan]]) scan += 1;
                    word_end = scan;
                }
                cursor = word_start;
                if (word_end == word_start) {
                    cursor += 1;
                    continue;
                }
                const key_size = word_end - word_start;
                cursor += key_size;
                if (key_size > p.maximum_word_length) p.maximum_word_length = key_size;
                if (p.input_reference) {
                    while (line_scan < word_start) {
                        if (buf[line_scan] == '\n') {
                            p.total_line_count += 1;
                            line_scan += 1;
                            line_start = line_scan;
                            line_scan = skipNonWhite(buf, line_scan, buf.len);
                            reference_length = line_scan - line_start;
                        } else line_scan += 1;
                    }
                    if (line_scan > word_start) continue;
                }
                const key = buf[word_start..word_end];
                if (p.ignore_file != null and p.searchTable(key, p.ignore_table.items)) continue;
                if (p.only_file != null and !p.searchTable(key, p.only_table.items)) continue;
                var oc: Occurs = undefined;
                if (p.auto_reference) {
                    while (line_scan < word_start) {
                        if (buf[line_scan] == '\n') {
                            p.total_line_count += 1;
                            line_scan += 1;
                            line_start = line_scan;
                            line_scan = skipNonWhite(buf, line_scan, buf.len);
                        } else line_scan += 1;
                    }
                    oc.reference = p.total_line_count;
                } else if (p.input_reference) {
                    oc.reference = @as(i64, @intCast(line_start)) - @as(i64, @intCast(word_start));
                    if (@as(isize, @intCast(reference_length)) > p.reference_max_width) p.reference_max_width = @intCast(reference_length);
                } else oc.reference = 0;
                if (p.input_reference and line_start == context_start) {
                    context_start = skipNonWhite(buf, context_start, context_end);
                    context_start = skipWhite(buf, context_start, context_end);
                }
                oc.key_start = word_start;
                oc.key_size = key_size;
                oc.left = @as(isize, @intCast(context_start)) - @as(isize, @intCast(word_start));
                oc.right = @as(isize, @intCast(context_end)) - @as(isize, @intCast(word_start));
                oc.file_index = file_index;
                try p.occurs.append(p.gpa, oc);
            }
        }
    }

    // ----------------------------------------------------------- output

    fn spaces(p: *Ptx, n: isize) void {
        var i = n;
        while (i > 0) : (i -= 1) p.out.writeByte(' ');
    }

    fn printField(p: *Ptx, text: []const u8) void {
        for (text) |c| {
            if (p.edited[c]) {
                switch (c) {
                    '"' => p.out.write("\"\""),
                    '$', '%', '&', '#', '_' => {
                        p.out.writeByte('\\');
                        p.out.writeByte(c);
                    },
                    '{', '}' => p.out.print("$\\{c}$", .{c}),
                    '\\' => p.out.write("\\backslash{}"),
                    else => p.out.writeByte(' '),
                }
            } else p.out.writeByte(c);
        }
    }

    fn fixOutputParameters(p: *Ptx) void {
        if (p.auto_reference) {
            p.reference_max_width = 0;
            for (0..p.names.len) |fi| {
                var ordinal = p.file_line_count[fi] + 1;
                if (fi > 0) ordinal -= p.file_line_count[fi - 1];
                var nb: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&nb, "{d}", .{ordinal}) catch unreachable;
                var w: isize = @intCast(s.len);
                if (p.file_names[fi]) |fname| w += @intCast(fname.len);
                if (w > p.reference_max_width) p.reference_max_width = w;
            }
            p.reference_max_width += 1;
        }
        if ((p.auto_reference or p.input_reference) and !p.right_reference)
            p.line_width = @max(0, p.line_width - (p.reference_max_width + p.gap_size));
        p.half_line_width = p.line_width >> 1;
        p.before_max_width = p.half_line_width - p.gap_size;
        p.keyafter_max_width = p.half_line_width;
        if (p.truncation_string) |t| {
            if (t.len > 0) p.truncation_len = @intCast(t.len) else p.truncation_string = null;
        }
        if (p.gnu_extensions) {
            p.before_max_width -= 2 * p.truncation_len;
            if (p.before_max_width < 0) p.before_max_width = 0;
            p.keyafter_max_width -= 2 * p.truncation_len;
        } else {
            p.keyafter_max_width -= 2 * p.truncation_len + 1;
        }
        for (0..256) |c| p.edited[c] = isSpace(@intCast(c));
        p.edited[0x0c] = true;
        switch (p.output_format) {
            .roff => p.edited['"'] = true,
            .tex => for ("$%&#_{}\\") |c| {
                p.edited[c] = true;
            },
            else => {},
        }
    }

    fn defineAllFields(p: *Ptx, oc: *const Occurs) void {
        const buf = p.buffers[oc.file_index];
        const ks: isize = @intCast(oc.key_start);
        const key_start = oc.key_start;
        var keyafter_end = key_start + oc.key_size;
        const left_context_start: usize = @intCast(ks + oc.left);
        const right_context_end: usize = @intCast(ks + oc.right);
        const buffer_end = buf.len;

        var cursor = keyafter_end;
        const ka_limit: isize = ks + p.keyafter_max_width;
        while (cursor < right_context_end and @as(isize, @intCast(cursor)) <= ka_limit) {
            keyafter_end = cursor;
            cursor = p.skipSomething(buf, cursor, right_context_end);
        }
        if (@as(isize, @intCast(cursor)) <= ka_limit) keyafter_end = cursor;
        p.keyafter_truncation = p.truncation_string != null and keyafter_end < right_context_end;
        keyafter_end = skipWhiteBackwards(buf, keyafter_end, key_start);
        p.keyafter = .{ key_start, keyafter_end };

        var left_field_start: usize = undefined;
        if (-oc.left > p.half_line_width + @as(isize, @intCast(p.maximum_word_length))) {
            left_field_start = @intCast(ks - (p.half_line_width + @as(isize, @intCast(p.maximum_word_length))));
            left_field_start = p.skipSomething(buf, left_field_start, key_start);
        } else left_field_start = @intCast(ks + oc.left);

        var before_start = left_field_start;
        const before_end = skipWhiteBackwards(buf, key_start, before_start);
        while (@as(isize, @intCast(before_start)) + p.before_max_width < @as(isize, @intCast(before_end)))
            before_start = p.skipSomething(buf, before_start, before_end);
        if (p.truncation_string != null) {
            const c = skipWhiteBackwards(buf, before_start, 0);
            p.before_truncation = c > left_context_start;
        } else p.before_truncation = false;
        before_start = skipWhite(buf, before_start, buffer_end);
        p.before = .{ before_start, before_end };

        const tail_max_width: isize = p.before_max_width - dif(before_end, before_start) - p.gap_size;
        if (tail_max_width > 0) {
            var tail_start = skipWhite(buf, keyafter_end, buffer_end);
            var tail_end = tail_start;
            cursor = tail_end;
            while (cursor < right_context_end and @as(isize, @intCast(cursor)) < @as(isize, @intCast(tail_start)) + tail_max_width) {
                tail_end = cursor;
                cursor = p.skipSomething(buf, cursor, right_context_end);
            }
            if (@as(isize, @intCast(cursor)) < @as(isize, @intCast(tail_start)) + tail_max_width) tail_end = cursor;
            if (tail_end > tail_start) {
                p.keyafter_truncation = false;
                p.tail_truncation = p.truncation_string != null and tail_end < right_context_end;
            } else p.tail_truncation = false;
            tail_end = skipWhiteBackwards(buf, tail_end, tail_start);
            if (tail_end < tail_start) tail_start = tail_end;
            p.tail = .{ tail_start, tail_end };
        } else {
            p.tail = .{ 0, 0 };
            p.tail_truncation = false;
        }

        const head_max_width: isize = p.keyafter_max_width - dif(keyafter_end, key_start) - p.gap_size;
        if (head_max_width > 0) {
            const head_end = skipWhiteBackwards(buf, before_start, 0);
            var head_start = left_field_start;
            while (@as(isize, @intCast(head_start)) + head_max_width < @as(isize, @intCast(head_end)))
                head_start = p.skipSomething(buf, head_start, head_end);
            if (head_end > head_start) {
                p.before_truncation = false;
                p.head_truncation = p.truncation_string != null and head_start > left_context_start;
            } else p.head_truncation = false;
            head_start = skipWhite(buf, head_start, head_end);
            p.head = .{ head_start, head_end };
        } else {
            p.head = .{ 0, 0 };
            p.head_truncation = false;
        }

        if (p.auto_reference) {
            const fname = p.file_names[oc.file_index] orelse "";
            var ordinal = oc.reference + 1;
            if (oc.file_index > 0) ordinal -= p.file_line_count[oc.file_index - 1];
            p.reference = std.fmt.bufPrint(&p.ref_buf, "{s}:{d}", .{ fname, ordinal }) catch "";
        } else if (p.input_reference) {
            const rs: usize = @intCast(ks + oc.reference);
            const re = skipNonWhite(buf, rs, right_context_end);
            p.reference = buf[rs..re];
        }
    }

    fn truncMark(p: *Ptx) []const u8 {
        return p.truncation_string orelse "";
    }

    fn outputRoff(p: *Ptx, buf: []const u8) void {
        p.out.print(".{s} \"", .{p.macro_name});
        p.printField(seg(buf, p.tail[0], p.tail[1]));
        if (p.tail_truncation) p.out.write(p.truncMark());
        p.out.writeByte('"');
        p.out.write(" \"");
        if (p.before_truncation) p.out.write(p.truncMark());
        p.printField(seg(buf, p.before[0], p.before[1]));
        p.out.writeByte('"');
        p.out.write(" \"");
        p.printField(seg(buf, p.keyafter[0], p.keyafter[1]));
        if (p.keyafter_truncation) p.out.write(p.truncMark());
        p.out.writeByte('"');
        p.out.write(" \"");
        if (p.head_truncation) p.out.write(p.truncMark());
        p.printField(seg(buf, p.head[0], p.head[1]));
        p.out.writeByte('"');
        if (p.auto_reference or p.input_reference) {
            p.out.write(" \"");
            p.printField(p.reference);
            p.out.writeByte('"');
        }
        p.out.writeByte('\n');
    }

    fn outputTex(p: *Ptx, buf: []const u8) void {
        p.out.print("\\{s} ", .{p.macro_name});
        p.out.writeByte('{');
        p.printField(seg(buf, p.tail[0], p.tail[1]));
        p.out.write("}{");
        p.printField(seg(buf, p.before[0], p.before[1]));
        p.out.write("}{");
        const key_start = p.keyafter[0];
        const after_end = p.keyafter[1];
        const key_end = p.skipSomething(buf, key_start, after_end);
        p.printField(seg(buf, key_start, @min(key_end, after_end)));
        p.out.write("}{");
        p.printField(seg(buf, @min(key_end, after_end), after_end));
        p.out.write("}{");
        p.printField(seg(buf, p.head[0], p.head[1]));
        p.out.writeByte('}');
        if (p.auto_reference or p.input_reference) {
            p.out.writeByte('{');
            p.printField(p.reference);
            p.out.writeByte('}');
        }
        p.out.writeByte('\n');
    }

    fn outputDumb(p: *Ptx, buf: []const u8) void {
        const reflen: isize = @intCast(p.reference.len);
        if (!p.right_reference) {
            if (p.auto_reference) {
                p.printField(p.reference);
                p.out.writeByte(':');
                p.spaces(p.reference_max_width + p.gap_size - reflen - 1);
            } else {
                p.printField(p.reference);
                p.spaces(p.reference_max_width + p.gap_size - reflen);
            }
        }
        const before_len: isize = dif(p.before[1], p.before[0]);
        if (p.tail[0] < p.tail[1]) {
            p.printField(seg(buf, p.tail[0], p.tail[1]));
            if (p.tail_truncation) p.out.write(p.truncMark());
            p.spaces(p.half_line_width - p.gap_size - before_len -
                (if (p.before_truncation) p.truncation_len else 0) -
                dif(p.tail[1], p.tail[0]) -
                (if (p.tail_truncation) p.truncation_len else 0));
        } else {
            p.spaces(p.half_line_width - p.gap_size - before_len - (if (p.before_truncation) p.truncation_len else 0));
        }
        if (p.before_truncation) p.out.write(p.truncMark());
        p.printField(seg(buf, p.before[0], p.before[1]));
        p.spaces(p.gap_size);
        p.printField(seg(buf, p.keyafter[0], p.keyafter[1]));
        if (p.keyafter_truncation) p.out.write(p.truncMark());
        const ka_len: isize = dif(p.keyafter[1], p.keyafter[0]);
        if (p.head[0] < p.head[1]) {
            p.spaces(p.half_line_width - ka_len - (if (p.keyafter_truncation) p.truncation_len else 0) -
                dif(p.head[1], p.head[0]) - (if (p.head_truncation) p.truncation_len else 0));
            if (p.head_truncation) p.out.write(p.truncMark());
            p.printField(seg(buf, p.head[0], p.head[1]));
        } else if ((p.auto_reference or p.input_reference) and p.right_reference) {
            p.spaces(p.half_line_width - ka_len - (if (p.keyafter_truncation) p.truncation_len else 0));
        }
        if ((p.auto_reference or p.input_reference) and p.right_reference) {
            p.spaces(p.gap_size);
            p.printField(p.reference);
        }
        p.out.writeByte('\n');
    }

    fn generateAllOutput(p: *Ptx) void {
        p.tail = .{ 0, 0 };
        p.tail_truncation = false;
        p.head = .{ 0, 0 };
        p.head_truncation = false;
        for (p.occurs.items) |*oc| {
            p.defineAllFields(oc);
            const buf = p.buffers[oc.file_index];
            switch (p.output_format) {
                .roff => p.outputRoff(buf),
                .tex => p.outputTex(buf),
                else => p.outputDumb(buf),
            }
        }
    }
};

/// Difference of two offsets as a signed length (C pointer subtraction).
fn parseBase0(text: []const u8) isize {
    // xstrtoimax base 0: 0x hex, leading 0 octal, otherwise decimal.
    var t = text;
    var neg = false;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    const v: isize = if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X'))
        std.fmt.parseInt(isize, t[2..], 16) catch 0
    else if (t.len > 1 and t[0] == '0')
        std.fmt.parseInt(isize, t[1..], 8) catch 0
    else
        std.fmt.parseInt(isize, t, 10) catch 0;
    return if (neg) -v else v;
}

fn dif(a: usize, b: usize) isize {
    return @as(isize, @intCast(a)) - @as(isize, @intCast(b));
}

/// buf[a..b] or empty when the range is inverted (a C loop `a < b` prints nothing).
fn seg(buf: []const u8, a: usize, b: usize) []const u8 {
    return if (a < b) buf[a..b] else buf[0..0];
}

fn unescapeString(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) break;
        switch (s[i]) {
            'x' => {
                i += 1;
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i < s.len and std.ascii.isHex(s[i])) : (n += 1) {
                    v = v * 16 + (std.fmt.charToDigit(s[i], 16) catch 0);
                    i += 1;
                }
                if (n == 0) {
                    try out.appendSlice(gpa, "\\x");
                } else try out.append(gpa, @truncate(v));
            },
            '0' => {
                i += 1;
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i < s.len and s[i] >= '0' and s[i] <= '7') : (n += 1) {
                    v = v * 8 + (s[i] - '0');
                    i += 1;
                }
                try out.append(gpa, @truncate(v));
            },
            'a' => {
                try out.append(gpa, 7);
                i += 1;
            },
            'b' => {
                try out.append(gpa, 8);
                i += 1;
            },
            'c' => i = s.len,
            'f' => {
                try out.append(gpa, 12);
                i += 1;
            },
            'n' => {
                try out.append(gpa, 10);
                i += 1;
            },
            'r' => {
                try out.append(gpa, 13);
                i += 1;
            },
            't' => {
                try out.append(gpa, 9);
                i += 1;
            },
            'v' => {
                try out.append(gpa, 11);
                i += 1;
            },
            else => {
                try out.append(gpa, '\\');
                try out.append(gpa, s[i]);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Emacs-syntax regular expression (GNU re_compile_pattern default) to ERE.
fn emacsToEre(gpa: std.mem.Allocator, pat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_bracket = false;
    while (i < pat.len) : (i += 1) {
        const c = pat[i];
        if (in_bracket) {
            try out.append(gpa, c);
            if (c == ']' and !(out.items.len >= 2 and (out.items[out.items.len - 2] == '[' or out.items[out.items.len - 2] == '^'))) in_bracket = false;
            continue;
        }
        if (c == '[') {
            in_bracket = true;
            try out.append(gpa, c);
            if (i + 1 < pat.len and pat[i + 1] == '^') {
                i += 1;
                try out.append(gpa, '^');
            }
            if (i + 1 < pat.len and pat[i + 1] == ']') {
                i += 1;
                try out.append(gpa, ']');
            }
            continue;
        }
        if (c == '\\' and i + 1 < pat.len) {
            i += 1;
            switch (pat[i]) {
                '(', ')', '|' => try out.append(gpa, pat[i]),
                '+', '?', '{', '}' => {
                    try out.append(gpa, '\\');
                    try out.append(gpa, pat[i]);
                },
                else => {
                    try out.append(gpa, '\\');
                    try out.append(gpa, pat[i]);
                },
            }
            continue;
        }
        switch (c) {
            '(', ')', '|', '{', '}' => {
                try out.append(gpa, '\\');
                try out.append(gpa, c);
            },
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

fn readFile(p: *Ptx, name: ?[]const u8) ?[]u8 {
    const nm: []const u8 = name orelse "-";
    const f = cli.openInput(p.ctx.io, nm) catch |e| {
        cli.warn(p.ctx, "{f}: {s}", .{ cli.quote(nm), cli.errText(e) });
        return null;
    };
    defer cli.closeInput(p.ctx.io, f);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = cli.readChunk(p.ctx.io, f, &chunk) catch |e| {
            cli.warn(p.ctx, "{f}: {s}", .{ cli.quote(nm), cli.errText(e) });
            list.deinit(p.gpa);
            return null;
        };
        if (n == 0) break;
        list.appendSlice(p.gpa, chunk[0..n]) catch return null;
    }
    return list.toOwnedSlice(p.gpa) catch null;
}

fn digestWordFile(p: *Ptx, name: []const u8, table: *std.ArrayList([]const u8)) bool {
    const data = readFile(p, name) orelse return false;
    var pos: usize = 0;
    while (pos < data.len) {
        const e = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        if (e > pos) table.append(p.gpa, data[pos..e]) catch return false;
        pos = if (e < data.len) e + 1 else e;
    }
    std.mem.sort([]const u8, table.items, p, struct {
        fn lt(pp: *Ptx, a: []const u8, b: []const u8) bool {
            return pp.compareWords(a, b) == .lt;
        }
    }.lt);
    return true;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = arena.create(Ptx) catch return 1;
    p.* = .{ .ctx = ctx, .gpa = arena, .out = cli.Out.init(ctx.io) };

    var fmt_arg: ?[]const u8 = null;
    var parser = getopt.Parser.init(ctx, "AF:GM:ORS:TW:b:i:fg:o:trw:", &.{
        .{ .name = "auto-reference", .id = 'A' },
        .{ .name = "break-file", .arg = .required, .id = 'b' },
        .{ .name = "flag-truncation", .arg = .required, .id = 'F' },
        .{ .name = "ignore-case", .id = 'f' },
        .{ .name = "gap-size", .arg = .required, .id = 'g' },
        .{ .name = "ignore-file", .arg = .required, .id = 'i' },
        .{ .name = "macro-name", .arg = .required, .id = 'M' },
        .{ .name = "only-file", .arg = .required, .id = 'o' },
        .{ .name = "references", .id = 'r' },
        .{ .name = "right-side-refs", .id = 'R' },
        .{ .name = "format", .arg = .required, .id = 1100 },
        .{ .name = "sentence-regexp", .arg = .required, .id = 'S' },
        .{ .name = "traditional", .id = 'G' },
        .{ .name = "typeset-mode", .id = 't' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "word-regexp", .arg = .required, .id = 'W' },
    });
    defer parser.deinit();
    while (true) switch (parser.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'G' => p.gnu_extensions = false,
            'b' => p.break_file = o.arg,
            'f' => p.ignore_case = true,
            'g' => {
                const v = parseBase0(o.arg.?);
                if (v <= 0) {
                    cli.warn(ctx, "invalid gap width: {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                }
                p.gap_size = v;
            },
            'i' => p.ignore_file = o.arg,
            'o' => p.only_file = o.arg,
            'r' => p.input_reference = true,
            't' => {},
            'w' => {
                const v = parseBase0(o.arg.?);
                if (v <= 0) {
                    cli.warn(ctx, "invalid line width: {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                }
                p.line_width = v;
            },
            'A' => p.auto_reference = true,
            'F' => p.truncation_string = unescapeString(arena, o.arg.?) catch return 1,
            'M' => p.macro_name = o.arg.?,
            'O' => p.output_format = .roff,
            'R' => p.right_reference = true,
            'S' => p.context_regex = unescapeString(arena, o.arg.?) catch return 1,
            'T' => p.output_format = .tex,
            'W' => {
                const w = unescapeString(arena, o.arg.?) catch return 1;
                p.word_regex = if (w.len == 0) null else w;
            },
            1100 => fmt_arg = o.arg,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (fmt_arg) |fa| {
        const names = [_][]const u8{ "roff", "tex" };
        var found: ?usize = null;
        var amb = false;
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, n, fa)) {
                found = i;
                amb = false;
                break;
            }
            if (std.mem.startsWith(u8, n, fa)) {
                if (found != null) amb = true;
                found = i;
            }
        }
        if (found == null or amb) {
            cli.warn(ctx, "{s} argument {f} for '--format'\nValid arguments are:\n  - 'roff'\n  - 'tex'\nTry '{s} --help' for more information.", .{ if (amb) "ambiguous" else "invalid", cli.quoteC(fa), ctx.name });
            return 1;
        }
        p.output_format = if (found.? == 0) .roff else .tex;
    }

    const operands = parser.operands.items;
    var names_list: std.ArrayList([]const u8) = .empty;
    var fnames: std.ArrayList(?[]const u8) = .empty;
    var out_redirect: ?[]const u8 = null;
    if (operands.len == 0) {
        fnames.append(arena, null) catch return 1;
    } else if (p.gnu_extensions) {
        for (operands) |o| fnames.append(arena, if (o.len == 0 or std.mem.eql(u8, o, "-")) null else o) catch return 1;
    } else {
        fnames.append(arena, if (operands[0].len == 0 or std.mem.eql(u8, operands[0], "-")) null else operands[0]) catch return 1;
        if (operands.len > 1) out_redirect = operands[1];
        if (operands.len > 2) {
            getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(operands[2])});
            return 1;
        }
    }
    _ = &names_list;
    if (out_redirect) |of| {
        // GNU reopens standard output while processing the operands.
        const f = Io.Dir.cwd().createFile(ctx.io, of, .{ .truncate = true }) catch |e| {
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(of), cli.errText(e) });
            return 1;
        };
        p.out = cli.Out.initFile(ctx.io, f);
    }
    p.file_names = fnames.items;
    p.names = arena.alloc([]const u8, fnames.items.len) catch return 1;
    p.file_line_count = arena.alloc(i64, fnames.items.len) catch return 1;
    p.buffers = arena.alloc([]u8, fnames.items.len) catch return 1;

    if (p.output_format == .unknown) p.output_format = if (p.gnu_extensions) .dumb else .roff;

    // initialize_regex
    if (p.context_regex) |cr| {
        if (cr.len == 0) p.context_regex = null;
    } else if (p.gnu_extensions and !p.input_reference) {
        p.default_context = true;
    } else p.context_regex = "\n";
    if (p.context_regex) |cr| {
        const ere = emacsToEre(arena, cr) catch return 1;
        p.context_re = posixre.compile(arena, ere, true, p.ignore_case) catch {
            cli.warn(ctx, "Invalid regular expression (for regexp {f})", .{cli.quoteC(cr)});
            return 1;
        };
    }
    if (p.word_regex) |wr| {
        const ere = emacsToEre(arena, wr) catch return 1;
        p.word_re = posixre.compile(arena, ere, true, p.ignore_case) catch {
            cli.warn(ctx, "Invalid regular expression (for regexp {f})", .{cli.quoteC(wr)});
            return 1;
        };
        p.word_re_anch = posixre.compileMode(arena, ere, true, p.ignore_case, true) catch return 1;
    } else if (p.break_file == null) {
        if (p.gnu_extensions) {
            for (0..256) |c| p.word_fastmap[c] = std.ascii.isAlphabetic(@intCast(c));
        } else {
            @memset(&p.word_fastmap, true);
            p.word_fastmap[' '] = false;
            p.word_fastmap['\t'] = false;
            p.word_fastmap['\n'] = false;
        }
    }
    if (p.break_file) |bf| {
        const data = readFile(p, bf) orelse return 1;
        @memset(&p.word_fastmap, true);
        for (data) |c| p.word_fastmap[c] = false;
        if (!p.gnu_extensions) {
            p.word_fastmap[' '] = false;
            p.word_fastmap['\t'] = false;
            p.word_fastmap['\n'] = false;
        }
    }
    if (p.ignore_file) |f| {
        if (!digestWordFile(p, f, &p.ignore_table)) return 1;
        if (p.ignore_table.items.len == 0) p.ignore_file = null;
    }
    if (p.only_file) |f| {
        if (!digestWordFile(p, f, &p.only_table)) return 1;
        if (p.only_table.items.len == 0) p.only_file = null;
    }

    for (0..fnames.items.len) |fi| {
        p.buffers[fi] = readFile(p, fnames.items[fi]) orelse return 1;
        p.findOccursInText(fi) catch return 1;
        p.total_line_count += 1;
        p.file_line_count[fi] = p.total_line_count;
    }

    // Sort the occurrences: by key (case folded when requested), then by position.
    std.mem.sort(Occurs, p.occurs.items, p, struct {
        fn lt(pp: *Ptx, a: Occurs, b: Occurs) bool {
            const ka = pp.buffers[a.file_index][a.key_start .. a.key_start + a.key_size];
            const kb = pp.buffers[b.file_index][b.key_start .. b.key_start + b.key_size];
            switch (pp.compareWords(ka, kb)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            if (a.file_index != b.file_index) return a.file_index < b.file_index;
            return a.key_start < b.key_start;
        }
    }.lt);
    p.fixOutputParameters();
    p.generateAllOutput();
    p.out.flush();
    if (p.out.failed) return 1;
    return 0;
}
