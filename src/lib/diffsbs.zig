// SPDX-License-Identifier: GPL-2.0-or-later
//! Side-by-side (-y) and if-then-else (--line-format, -D) output for diff.
//! The column layout was settled against GNU diff 3.12 output for many
//! widths and tab sizes; the group formats follow the manual's description.

const std = @import("std");
const Io = std.Io;
const diff = @import("diff.zig");

fn isPrint(c: u8) bool {
    return c >= 32 and c < 127;
}

const Layout = struct {
    /// Bound of the text in each half.
    bound: usize,
    marker: usize,
    col2: usize,
};

fn layout(width: usize, tabsize: usize, expand: bool) Layout {
    const hw0: usize = if (width >= 3) (width - 3) / 2 else 0;
    if (expand) return .{ .bound = hw0, .marker = hw0 + 1, .col2 = width - hw0 };
    var col2 = (width + 3 + tabsize) / 2 / tabsize * tabsize;
    if (col2 == 0 or col2 > width) col2 = width;
    const b = @min(hw0, @min(width -| col2, col2 -| 3));
    return .{ .bound = b, .marker = @min(hw0 + 1, col2 -| 2), .col2 = col2 };
}

fn tabFromTo(w: *Io.Writer, expand: bool, tabsize: usize, from_in: usize, to: usize) Io.Writer.Error!usize {
    var from = from_in;
    if (!expand) {
        var tab = from + tabsize - from % tabsize;
        while (tab <= to) : (tab += tabsize) {
            try w.writeByte('\t');
            from = tab;
        }
    }
    while (from < to) : (from += 1) try w.writeByte(' ');
    return if (to > from_in) to else from;
}

/// Print one half line, at most `out_bound` columns; returns the column reached.
fn printHalf(w: *Io.Writer, o: diff.Options, text: []const u8, out_bound: usize, indent: usize) Io.Writer.Error!usize {
    var cr_seen = false;
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    for (text) |c| {
        switch (c) {
            '\t' => {
                const spaces = o.tab_size - in_pos % o.tab_size;
                if (in_pos == out_pos) {
                    var tabstop = out_pos + spaces;
                    if (o.expand_tabs) {
                        if (out_bound < tabstop) tabstop = out_bound;
                        while (out_pos < tabstop) : (out_pos += 1) try w.writeByte(' ');
                    } else if (tabstop < out_bound) {
                        out_pos = tabstop;
                        try w.writeByte(c);
                    }
                }
                in_pos += spaces;
            },
            '\r' => {
                try w.writeByte(c);
                in_pos = 0;
                cr_seen = true;
                out_pos = 0;
            },
            '\x08' => {
                if (in_pos != 0) {
                    const was = in_pos;
                    in_pos -= 1;
                    if (was == out_pos) {
                        out_pos -= 1;
                        try w.writeByte(c);
                    }
                }
            },
            else => {
                if (!isPrint(c)) continue;
                if (in_pos < out_bound) {
                    in_pos += 1;
                    out_pos = in_pos;
                    try w.writeByte(c);
                } else in_pos += 1;
            },
        }
    }
    if (cr_seen and out_pos < indent) return try tabFromTo(w, o.expand_tabs, o.tab_size, out_pos, indent);
    return out_pos;
}

fn endsNl(t: []const u8) bool {
    return t.len > 0 and t[t.len - 1] == '\n';
}

/// One output row: GNU's print_1sdiff_line.
pub fn row(w: *Io.Writer, o: diff.Options, left: ?[]const u8, sep_in: u8, right: ?[]const u8) Io.Writer.Error!void {
    const lay = layout(o.width, o.tab_size, o.expand_tabs);
    var sep = sep_in;
    var col: usize = 0;
    var put_newline = false;
    if (left) |l| {
        put_newline = put_newline or endsNl(l);
        col = try printHalf(w, o, l, lay.bound, 0);
    }
    if (sep != ' ') {
        col = try tabFromTo(w, o.expand_tabs, o.tab_size, col, lay.marker);
        if (sep == '|' and put_newline != endsNl(right.?)) sep = if (put_newline) '/' else '\\';
        try w.writeByte(sep);
        col += 1;
    }
    if (right) |r| {
        put_newline = put_newline or endsNl(r);
        if (!(r.len > 0 and r[0] == '\n')) {
            col = try tabFromTo(w, o.expand_tabs, o.tab_size, col, lay.col2);
            _ = try printHalf(w, o, r, lay.bound, col);
        }
    }
    if (put_newline) try w.writeByte('\n');
}

pub fn printSideBySide(p: anytype, items: anytype) !void {
    const o = p.options;
    try p.begin();
    var next0: usize = 0;
    var next1: usize = 0;
    for (0..items.len) |k| {
        const hunk = items[k .. k + 1];
        const an = diff.analyze(p.c, o, p.m, hunk);
        if (an.changes == .unchanged) continue;
        try p.begin();
        const f0: usize = @intCast(an.first0);
        const f1: usize = @intCast(an.first1);
        try common(p, &next0, &next1, f0, f1);
        var i: isize = an.first0;
        var j: isize = an.first1;
        while (i <= an.last0 and j <= an.last1) : ({
            i += 1;
            j += 1;
        }) try row(p.w, o, p.c.a.raw(@intCast(i)), '|', p.c.b.raw(@intCast(j)));
        while (i <= an.last0) : (i += 1) try row(p.w, o, p.c.a.raw(@intCast(i)), '<', null);
        while (j <= an.last1) : (j += 1) try row(p.w, o, null, '>', p.c.b.raw(@intCast(j)));
        next0 = @intCast(an.last0 + 1);
        next1 = @intCast(an.last1 + 1);
    }
    // Common lines after the last change; only if something was printed or
    // the files have no differences at all (then nothing is called).
    try common(p, &next0, &next1, p.c.a.count(), p.c.b.count());
}

fn common(p: anytype, next0: *usize, next1: *usize, limit0: usize, limit1: usize) !void {
    var q0 = next0.*;
    var q1 = next1.*;
    const o = p.options;
    if (!o.suppress_common_lines and (q0 != limit0 or q1 != limit1)) {
        if (!o.left_column) {
            while (q0 != limit0 and q1 != limit1) {
                try row(p.w, o, p.c.a.raw(q0), ' ', p.c.b.raw(q1));
                q0 += 1;
                q1 += 1;
            }
            while (q1 != limit1) {
                try row(p.w, o, null, ')', p.c.b.raw(q1));
                q1 += 1;
            }
        }
        while (q0 != limit0) {
            try row(p.w, o, p.c.a.raw(q0), '(', null);
            q0 += 1;
        }
    }
    next0.* = limit0;
    next1.* = limit1;
}

// ------------------------------------------------------------------- ifdef

const Group = struct { file: u1, beg: usize, end: usize }; // 0-based, end exclusive

fn defaultGroup(o: diff.Options, which: u2, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) ![]const u8 {
    const f = o.formats;
    const given: ?[]const u8 = switch (which) {
        0 => f.old_group,
        1 => f.new_group,
        2 => f.unchanged_group,
        else => f.changed_group,
    };
    if (given) |g| return g;
    if (which < 2) if (f.changed_group) |g| return g;
    if (o.ifdef_name) |n| {
        buf.clearRetainingCapacity();
        switch (which) {
            0 => try buf.print(gpa, "#ifndef {s}\n%<#endif /* ! {s} */\n", .{ n, n }),
            1 => try buf.print(gpa, "#ifdef {s}\n%>#endif /* {s} */\n", .{ n, n }),
            2 => try buf.appendSlice(gpa, "%="),
            else => try buf.print(gpa, "#ifndef {s}\n%<#else /* {s} */\n%>#endif /* {s} */\n", .{ n, n, n }),
        }
        return buf.items;
    }
    if (which == 3) {
        const og = f.old_group orelse "%<";
        const ng = f.new_group orelse "%>";
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, og);
        try buf.appendSlice(gpa, ng);
        return buf.items;
    }
    return switch (which) {
        0 => "%<",
        1 => "%>",
        else => "%=",
    };
}

fn lineFormat(o: diff.Options, which: u2) []const u8 {
    const f = o.formats;
    return switch (which) {
        0 => f.old_line orelse "%l\n",
        1 => f.new_line orelse "%l\n",
        else => f.unchanged_line orelse "%l\n",
    };
}

/// A parsed printf-like directive: `%[-'0]*[0-9]*(.[0-9]*)?[doxXc]`.
const Spec = struct {
    minus: bool = false,
    zero: bool = false,
    width: usize = 0,
    prec: ?usize = null,
    conv: u8 = 'd',
    /// The letter after the conversion (`n`, or a group letter), or the quote of `%c'x'`.
    arg: u8 = 0,
    /// Index just after the directive.
    end: usize = 0,
};

fn at(fmt: []const u8, i: usize) u8 {
    return if (i < fmt.len) fmt[i] else 0;
}

/// Scan the directive whose `%` is at `start`; null when it is not one.
fn scanSpec(fmt: []const u8, start: usize) ?Spec {
    var s: Spec = .{};
    var f = start + 1;
    var c = at(fmt, f);
    f += 1;
    while (c == '-' or c == '\'' or c == '0') {
        if (c == '-') s.minus = true;
        if (c == '0') s.zero = true;
        c = at(fmt, f);
        f += 1;
    }
    while (std.ascii.isDigit(c)) {
        s.width = s.width *| 10 +| (c - '0');
        c = at(fmt, f);
        f += 1;
    }
    if (c == '.') {
        var pv: usize = 0;
        while (true) {
            c = at(fmt, f);
            f += 1;
            if (!std.ascii.isDigit(c)) break;
            pv = pv *| 10 +| (c - '0');
        }
        s.prec = pv;
    }
    const c1 = at(fmt, f);
    f += 1;
    s.conv = c;
    s.arg = c1;
    s.end = f;
    switch (c) {
        'c', 'd', 'o', 'x', 'X' => return s,
        else => return null,
    }
}

fn printNum(w: *Io.Writer, s: Spec, v: usize) Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    const t: []const u8 = switch (s.conv) {
        'o' => std.fmt.bufPrint(&buf, "{o}", .{v}) catch "",
        'x' => std.fmt.bufPrint(&buf, "{x}", .{v}) catch "",
        'X' => std.fmt.bufPrint(&buf, "{X}", .{v}) catch "",
        else => std.fmt.bufPrint(&buf, "{d}", .{v}) catch "",
    };
    const digits: []const u8 = if (s.prec != null and s.prec.? == 0 and v == 0) "" else t;
    var zeros: usize = 0;
    if (s.prec) |pv| {
        if (pv > digits.len) zeros = pv - digits.len;
    } else if (s.zero and !s.minus and s.width > digits.len) zeros = s.width - digits.len;
    const total = digits.len + zeros;
    const pad = if (s.width > total) s.width - total else 0;
    if (!s.minus) try w.splatByteAll(' ', pad);
    try w.splatByteAll('0', zeros);
    try w.writeAll(digits);
    if (s.minus) try w.splatByteAll(' ', pad);
}

const Literal = struct { value: u8, end: usize };

/// The character literal of `%c'C'` or `%c'\OOO'`; `lit` is the index just
/// after the opening quote. Returns the value and the index after the closing quote.
fn charLiteral(fmt: []const u8, lit: usize) ?Literal {
    var p = lit;
    const c = at(fmt, p);
    p += 1;
    switch (c) {
        0, '\'' => return null,
        '\\' => {
            var value: u32 = 0;
            while (true) {
                const d = at(fmt, p);
                p += 1;
                if (d == '\'') break;
                if (d < '0' or d > '7') return null;
                value = value * 8 + (d - '0');
            }
            const digits = p - lit - 2;
            if (digits < 1 or digits > 3) return null;
            return .{ .value = @truncate(value), .end = p };
        },
        else => {
            if (at(fmt, p) != '\'') return null;
            return .{ .value = c, .end = p + 1 };
        },
    }
}

fn letterValue(l: u8, g0: Group, g1: Group) ?usize {
    const g = if (std.ascii.isUpper(l)) g1 else g0;
    const f = g.beg + 1; // first line number
    const last = g.end; // last line number (1-based) = end exclusive 0-based
    return switch (std.ascii.toLower(l)) {
        'f' => f,
        'l' => last,
        'n' => last - g.beg,
        'e' => f - 1,
        'm' => last + 1,
        else => null,
    };
}

/// One directive other than the fixed ones: a number (`%dn` of a line,
/// `%dF` of a group) or a character literal. Returns the index after it, or
/// null when `fmt` has no valid directive there.
fn printfSpec(w: *Io.Writer, fmt: []const u8, start: usize, line_no: ?usize, groups: ?[2]Group, out: bool) !?usize {
    const s = scanSpec(fmt, start) orelse return null;
    switch (s.conv) {
        'c' => {
            if (s.arg != '\'') return null;
            const lit = charLiteral(fmt, s.end) orelse return null;
            if (out) try w.writeByte(lit.value);
            return lit.end;
        },
        else => {
            var v: usize = undefined;
            if (line_no) |n| {
                if (s.arg != 'n') return null;
                v = n;
            } else v = letterValue(s.arg, groups.?[0], groups.?[1]) orelse return null;
            if (out) try printNum(w, s, v);
            return s.end;
        },
    }
}

fn printLines(p: anytype, fmt: []const u8, g: Group) !void {
    const lines = if (g.file == 0) p.c.a else p.c.b;
    var k = g.beg;
    while (k < g.end) : (k += 1) {
        var i: usize = 0;
        while (i < fmt.len) {
            const c = fmt[i];
            i += 1;
            if (c != '%') {
                try p.w.writeByte(c);
                continue;
            }
            switch (at(fmt, i)) {
                '%' => {
                    i += 1;
                    try p.w.writeByte('%');
                },
                'l' => {
                    i += 1;
                    try p.outputLine(lines.body(k));
                },
                'L' => {
                    i += 1;
                    try p.outputLine(lines.raw(k));
                },
                else => {
                    if (try printfSpec(p.w, fmt, i - 1, k + 1, null, true)) |e| i = e else try p.w.writeByte('%');
                },
            }
        }
    }
}

/// Scan (and, when `out`, print) a group format up to the first free `endchar`
/// (0: the whole string); returns the index of the terminator.
fn formatScan(p: anytype, fmt: []const u8, start: usize, endchar: u8, out: bool, g0: Group, g1: Group) Io.Writer.Error!usize {
    const o = p.options;
    var i = start;
    while (i < fmt.len and fmt[i] != endchar) {
        var c = fmt[i];
        i += 1;
        const after = i;
        if (c == '%') {
            c = at(fmt, i);
            i += 1;
            switch (c) {
                '%' => {},
                '(' => {
                    if (try ifThenElse(p, fmt, &i, out, g0, g1)) continue;
                    c = '%';
                    i = after;
                },
                '<' => {
                    if (out) try printLines(p, lineFormat(o, 0), g0);
                    continue;
                },
                '=' => {
                    if (out) try printLines(p, lineFormat(o, 2), g0);
                    continue;
                },
                '>' => {
                    if (out) try printLines(p, lineFormat(o, 1), g1);
                    continue;
                },
                else => {
                    if (try printfSpec(p.w, fmt, i - 2, null, .{ g0, g1 }, out)) |e| {
                        i = e;
                        continue;
                    }
                    c = '%';
                    i = after;
                },
            }
        }
        if (out) try p.w.writeByte(c);
    }
    return i;
}

/// `%(A=B?then:else)`, with `i` just after the `(`. False (and `i`
/// unspecified) when the condition is malformed.
fn ifThenElse(p: anytype, fmt: []const u8, i_ptr: *usize, out: bool, g0: Group, g1: Group) Io.Writer.Error!bool {
    var i = i_ptr.*;
    var vals: [2]usize = undefined;
    for (0..2) |k| {
        if (std.ascii.isDigit(at(fmt, i))) {
            var v: usize = 0;
            while (std.ascii.isDigit(at(fmt, i))) : (i += 1) {
                const m = std.math.mul(usize, v, 10) catch return false;
                v = std.math.add(usize, m, at(fmt, i) - '0') catch return false;
            }
            vals[k] = v;
        } else {
            vals[k] = letterValue(at(fmt, i), g0, g1) orelse return false;
            i += 1;
        }
        const want: u8 = if (k == 0) '=' else '?';
        const got = at(fmt, i);
        i += 1;
        if (got != want) return false;
    }
    const eq = vals[0] == vals[1];
    i = try formatScan(p, fmt, i, ':', out and eq, g0, g1);
    if (i < fmt.len) {
        i = try formatScan(p, fmt, i + 1, ')', out and !eq, g0, g1);
        if (i < fmt.len) i += 1;
    }
    i_ptr.* = i;
    return true;
}

fn formatGroup(p: anytype, fmt: []const u8, g0: Group, g1: Group) !void {
    _ = try formatScan(p, fmt, 0, 0, true, g0, g1);
}

pub fn printIfdef(p: anytype, items: anytype) !void {
    const o = p.options;
    const gpa = p.gpa;
    var bufs: [4]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty };
    defer for (&bufs) |*b| b.deinit(gpa);
    var gf: [4][]const u8 = undefined;
    for (0..4) |k| gf[k] = try defaultGroup(o, @intCast(k), &bufs[k], gpa);
    var next0: usize = 0;
    var next1: usize = 0;
    for (0..items.len) |k| {
        const hunk = items[k .. k + 1];
        const an = diff.analyze(p.c, o, p.m, hunk);
        if (an.changes == .unchanged) continue;
        try p.begin();
        const f0: usize = @intCast(an.first0);
        const f1: usize = @intCast(an.first1);
        if (next0 < f0 or next1 < f1) try formatGroup(p, gf[2], .{ .file = 0, .beg = next0, .end = f0 }, .{ .file = 1, .beg = next1, .end = f1 });
        const l0: usize = @intCast(an.last0 + 1);
        const l1: usize = @intCast(an.last1 + 1);
        const which: usize = switch (an.changes) {
            .old => 0,
            .new => 1,
            else => 3,
        };
        try formatGroup(p, gf[which], .{ .file = 0, .beg = f0, .end = l0 }, .{ .file = 1, .beg = f1, .end = l1 });
        next0 = l0;
        next1 = l1;
    }
    const n0 = p.c.a.count();
    const n1 = p.c.b.count();
    if (next0 < n0 or next1 < n1) {
        try p.begin();
        try formatGroup(p, gf[2], .{ .file = 0, .beg = next0, .end = n0 }, .{ .file = 1, .beg = next1, .end = n1 });
    }
}

/// GNU's no_diff_means_no_output: identical inputs may be skipped without
/// reading them only when nothing would be printed for them.
pub fn noDiffMeansNoOutput(o: diff.Options) bool {
    switch (o.style) {
        .ifdef => {
            const ug = o.formats.unchanged_group orelse "%=";
            if (ug.len == 0) return true;
            const ul = o.formats.unchanged_line orelse "%l\n";
            return std.mem.eql(u8, ug, "%=") and ul.len == 0;
        },
        .side_by_side => return o.suppress_common_lines,
        else => return true,
    }
}
