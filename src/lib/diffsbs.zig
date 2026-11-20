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
fn printHalf(w: *Io.Writer, o: diff.Options, text: []const u8, out_bound: usize) Io.Writer.Error!usize {
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
                _ = try tabFromTo(w, o.expand_tabs, o.tab_size, 0, in_pos);
                in_pos = 0;
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
        col = try printHalf(w, o, l, lay.bound);
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
            _ = try printHalf(w, o, r, lay.bound);
        }
    }
    if (put_newline) try w.writeByte('\n');
}

pub fn printSideBySide(p: anytype, items: anytype) !void {
    const o = p.options;
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
    if (items.len > 0) try common(p, &next0, &next1, p.c.a.count(), p.c.b.count());
}

fn common(p: anytype, next0: *usize, next1: *usize, limit0: usize, limit1: usize) !void {
    var q0 = next0.*;
    var q1 = next1.*;
    const o = p.options;
    if (!o.suppress_common_lines and (q0 != limit0 or q1 != limit1)) {
        while (q0 != limit0 and q1 != limit1) {
            if (o.left_column) try row(p.w, o, p.c.a.raw(q0), '(', null) else try row(p.w, o, p.c.a.raw(q0), ' ', p.c.b.raw(q1));
            q0 += 1;
            q1 += 1;
        }
        while (q1 != limit1) {
            try row(p.w, o, null, ')', p.c.b.raw(q1));
            q1 += 1;
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
    return switch (which) {
        0 => "%<",
        1 => "%>",
        2 => "%=",
        else => "%<%>",
    };
}

fn lineFormat(o: diff.Options, which: u2) []const u8 {
    const f = o.formats;
    return switch (which) {
        0 => f.old_line orelse "%L",
        1 => f.new_line orelse "%L",
        else => f.unchanged_line orelse "%L",
    };
}

fn printLines(p: anytype, fmt: []const u8, g: Group) !void {
    const lines = if (g.file == 0) p.c.a else p.c.b;
    var k = g.beg;
    while (k < g.end) : (k += 1) {
        const raw = lines.raw(k);
        var i: usize = 0;
        while (i < fmt.len) {
            const c = fmt[i];
            i += 1;
            if (c != '%') {
                try p.w.writeByte(c);
                continue;
            }
            if (i >= fmt.len) {
                try p.w.writeByte('%');
                break;
            }
            const spec = try parseSpec(fmt, &i, "n");
            const d = fmt[i - 1];
            _ = d;
            const t = fmt[i - 1];
            switch (t) {
                '%' => try p.w.writeByte('%'),
                'L' => try p.w.writeAll(raw),
                'l' => try p.w.writeAll(lines.body(k)),
                'n' => try printNum(p.w, spec, k + 1),
                'c' => try charLiteral(p.w, fmt, &i),
                else => {
                    try p.w.writeByte('%');
                    try p.w.writeAll(fmt[spec.start .. i]);
                },
            }
        }
    }
}

const Spec = struct {
    start: usize,
    minus: bool = false,
    width: usize = 0,
    prec: ?usize = null,
    conv: u8 = 'd',
};

/// Parse `[-][WIDTH][.[PREC]]{doxX}` after a '%'; leaves `i` just after the
/// final specifier character (the conversion for numbers, or the letter).
fn parseSpec(fmt: []const u8, i: *usize, letters: []const u8) !Spec {
    var s: Spec = .{ .start = i.* };
    var j = i.*;
    if (j < fmt.len and fmt[j] == '-') {
        s.minus = true;
        j += 1;
    }
    while (j < fmt.len and std.ascii.isDigit(fmt[j])) : (j += 1) s.width = s.width * 10 + (fmt[j] - '0');
    if (j < fmt.len and fmt[j] == '.') {
        j += 1;
        var pv: usize = 0;
        while (j < fmt.len and std.ascii.isDigit(fmt[j])) : (j += 1) pv = pv * 10 + (fmt[j] - '0');
        s.prec = pv;
    }
    if (j < fmt.len and std.mem.indexOfScalar(u8, "doxX", fmt[j]) != null and j + 1 < fmt.len and std.mem.indexOfScalar(u8, letters, fmt[j + 1]) != null) {
        s.conv = fmt[j];
        i.* = j + 2;
        return s;
    }
    if (j < fmt.len and std.mem.indexOfScalar(u8, "doxX", fmt[j]) != null and j + 1 < fmt.len and fmt[j + 1] == 'n') {
        s.conv = fmt[j];
        i.* = j + 2;
        return s;
    }
    // Plain `%X` forms.
    i.* = i.* + 1;
    s.start = i.* - 1;
    s.width = 0;
    return s;
}

fn printNum(w: *Io.Writer, s: Spec, v: usize) Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    var t: []const u8 = switch (s.conv) {
        'o' => std.fmt.bufPrint(&buf, "{o}", .{v}) catch "",
        'x' => std.fmt.bufPrint(&buf, "{x}", .{v}) catch "",
        'X' => std.fmt.bufPrint(&buf, "{X}", .{v}) catch "",
        else => std.fmt.bufPrint(&buf, "{d}", .{v}) catch "",
    };
    var zeros: usize = 0;
    if (s.prec) |pv| {
        if (pv > t.len) zeros = pv - t.len;
    }
    const total = t.len + zeros;
    const pad = if (s.width > total) s.width - total else 0;
    if (!s.minus) try w.splatByteAll(' ', pad);
    try w.splatByteAll('0', zeros);
    try w.writeAll(t);
    if (s.minus) try w.splatByteAll(' ', pad);
    t = "";
}

fn charLiteral(w: *Io.Writer, fmt: []const u8, i: *usize) Io.Writer.Error!void {
    // %c'C' or %c'\OOO'
    if (i.* < fmt.len and fmt[i.*] == '\'') {
        i.* += 1;
        if (i.* < fmt.len and fmt[i.*] == '\\') {
            i.* += 1;
            var v: u32 = 0;
            var n: usize = 0;
            while (n < 3 and i.* < fmt.len and fmt[i.*] >= '0' and fmt[i.*] <= '7') : (n += 1) {
                v = v * 8 + (fmt[i.*] - '0');
                i.* += 1;
            }
            try w.writeByte(@truncate(v));
        } else if (i.* < fmt.len) {
            try w.writeByte(fmt[i.*]);
            i.* += 1;
        }
        if (i.* < fmt.len and fmt[i.*] == '\'') i.* += 1;
    }
}

fn letterValue(l: u8, g0: Group, g1: Group) ?usize {
    const g = if (std.ascii.isUpper(l)) g1 else g0;
    const f = g.beg + 1; // first line number
    const last = g.end; // last line number (1-based) = end exclusive 0-based
    return switch (std.ascii.toUpper(l)) {
        'F' => f,
        'L' => last,
        'N' => last + 1 - f,
        'E' => f - 1,
        'M' => last + 1,
        else => null,
    };
}

fn formatGroup(p: anytype, fmt: []const u8, g0: Group, g1: Group) !void {
    const o = p.options;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        i += 1;
        if (c != '%') {
            try p.w.writeByte(c);
            continue;
        }
        if (i >= fmt.len) {
            try p.w.writeByte('%');
            break;
        }
        const nc = fmt[i];
        switch (nc) {
            '%' => {
                try p.w.writeByte('%');
                i += 1;
            },
            'c' => {
                i += 1;
                try charLiteral(p.w, fmt, &i);
            },
            '<' => {
                i += 1;
                try printLines(p, lineFormat(o, 0), g0);
            },
            '>' => {
                i += 1;
                try printLines(p, lineFormat(o, 1), g1);
            },
            '=' => {
                i += 1;
                try printLines(p, lineFormat(o, 2), g0);
            },
            '(' => {
                // %(A=B?T:E)
                i += 1;
                const a = fmt[i];
                const b = if (i + 2 < fmt.len) fmt[i + 2] else 0;
                if (i + 3 < fmt.len and fmt[i + 1] == '=' and fmt[i + 3] == '?') {
                    const av = letterValue(a, g0, g1);
                    const bv = letterValue(b, g0, g1);
                    const equal = av != null and bv != null and av.? == bv.?;
                    i += 4;
                    const then_start = i;
                    while (i < fmt.len and fmt[i] != ':') i += 1;
                    const then_text = fmt[then_start..i];
                    if (i < fmt.len) i += 1;
                    const else_start = i;
                    while (i < fmt.len and fmt[i] != ')') i += 1;
                    const else_text = fmt[else_start..i];
                    if (i < fmt.len) i += 1;
                    try formatGroup(p, if (equal) then_text else else_text, g0, g1);
                } else try p.w.writeAll("%(");
            },
            else => {
                var j = i;
                const spec = try parseSpec(fmt, &j, "FLNEMflnem");
                const l = fmt[j - 1];
                if (spec.conv != 'd' or (j - i >= 2)) {
                    if (letterValue(l, g0, g1)) |v| {
                        try printNum(p.w, spec, v);
                        i = j;
                        continue;
                    }
                }
                try p.w.writeByte('%');
            },
        }
    }
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
    if (next0 < n0 or next1 < n1) try formatGroup(p, gf[2], .{ .file = 0, .beg = next0, .end = n0 }, .{ .file = 1, .beg = next1, .end = n1 });
}
