// SPDX-License-Identifier: GPL-2.0-or-later
//! diff3 library (decision 0004): three-way comparison of MYFILE, OLDFILE and
//! YOURFILE and the ways GNU diff3 reports it.
//! References: GNU diffutils manual "Comparing Three Files" and "Merging"
//! (3.12). The two comparisons (OLDFILE with each of the others) come from
//! `diffcore`; blocks that touch in OLDFILE are merged into one, as in GNU.
//!
//! `merge3` returns the data (`Block`s with a `Kind` and, per file, a line
//! range). `writeNormal`, `writeEd` and `writeMerge` are the text forms and
//! `writeJson` the `--json` form.

const std = @import("std");
const Io = std.Io;
const diffcore = @import("diffcore.zig");
const json = @import("../json.zig");

pub const Lines = diffcore.Lines;

/// Which files a block differs in.
pub const Kind = enum {
    /// Same in all three (only produced by `withUnchanged`).
    unchanged,
    /// Only MYFILE differs from the other two.
    only_first,
    /// Only OLDFILE differs (MYFILE and YOURFILE agree).
    only_second,
    /// Only YOURFILE differs.
    only_third,
    /// All three differ: a conflict.
    overlap,
};

pub const Range = struct {
    /// 0-based index of the first line.
    start: usize,
    count: usize,
};

pub const Block = struct {
    kind: Kind,
    /// Ranges in MYFILE, OLDFILE and YOURFILE.
    ranges: [3]Range,
};

/// A source of the two comparisons other than the built-in engine (an
/// external `--diff-program`): `func(context, gpa, pair)` returns the edits of
/// OLDFILE against MYFILE (pair 0) or against YOURFILE (pair 1).
pub const External = struct {
    context: ?*anyopaque = null,
    func: *const fn (context: ?*anyopaque, gpa: std.mem.Allocator, pair: u1) anyerror![]diffcore.Edit,
};

pub const Flags = struct {
    strip_trailing_cr: bool = false,
    /// Compare with the middle file (ed scripts and merges) instead of the
    /// third (the default report), as GNU does.
    common_middle: bool = false,
    external: ?External = null,
};

pub const ParseError = error{ OutOfMemory, IncompleteLastLine, BadControl, BadLeadingChars, BadSeparator };

fn skipBlanks(t: []const u8, i: usize) usize {
    var k = i;
    while (k < t.len and (t[k] == ' ' or t[k] == '\t')) k += 1;
    return k;
}

fn readNum(t: []const u8, i: *usize) ?usize {
    if (i.* >= t.len or !std.ascii.isDigit(t[i.*])) return null;
    var v: usize = 0;
    while (i.* < t.len and std.ascii.isDigit(t[i.*])) : (i.* += 1) v = v *| 10 +| (t[i.*] - '0');
    return v;
}

/// Parse a diff in the normal format (what `--diff-program` prints) into
/// edits of its first file against its second. `bad_line` receives the
/// offending control line for `error.BadControl`.
pub fn parseNormalDiff(gpa: std.mem.Allocator, text: []const u8, bad_line: *[]const u8) ParseError![]diffcore.Edit {
    var edits: std.ArrayList(diffcore.Edit) = .empty;
    errdefer edits.deinit(gpa);
    if (text.len > 0 and text[text.len - 1] != '\n') return error.IncompleteLastLine;
    var pos: usize = 0;
    while (pos < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..eol];
        bad_line.* = line;
        var i: usize = skipBlanks(line, 0);
        const a0 = readNum(line, &i) orelse return error.BadControl;
        var a1 = a0;
        i = skipBlanks(line, i);
        if (i < line.len and line[i] == ',') {
            i += 1;
            a1 = readNum(line, &i) orelse return error.BadControl;
        }
        i = skipBlanks(line, i);
        const kind: u8 = if (i < line.len) line[i] else 0;
        if (kind != 'a' and kind != 'c' and kind != 'd') return error.BadControl;
        i += 1;
        i = skipBlanks(line, i);
        const b0 = readNum(line, &i) orelse return error.BadControl;
        var b1 = b0;
        i = skipBlanks(line, i);
        if (i < line.len and line[i] == ',') {
            i += 1;
            b1 = readNum(line, &i) orelse return error.BadControl;
            i = skipBlanks(line, i);
        }
        if (i != line.len) return error.BadControl;
        pos = eol + 1;
        const del: usize = if (kind == 'a') 0 else (if (a1 >= a0) a1 - a0 + 1 else 0);
        const ins: usize = if (kind == 'd') 0 else (if (b1 >= b0) b1 - b0 + 1 else 0);
        // Skip the text lines (and any "\ No newline" notes).
        var k: usize = 0;
        while (k < del) : (k += 1) pos = try skipDiffLine(text, pos, '<');
        if (kind == 'c') {
            if (!std.mem.startsWith(u8, text[pos..], "---\n")) return error.BadSeparator;
            pos += 4;
        }
        k = 0;
        while (k < ins) : (k += 1) pos = try skipDiffLine(text, pos, '>');
        const line0: usize = if (kind == 'a') a0 else a0 -| 1;
        const line1: usize = if (kind == 'd') b0 else b0 -| 1;
        try edits.append(gpa, .{ .line0 = line0, .line1 = line1, .deleted = del, .inserted = ins });
    }
    return edits.toOwnedSlice(gpa);
}

fn skipDiffLine(text: []const u8, pos: usize, lead: u8) ParseError!usize {
    if (pos + 1 >= text.len or text[pos] != lead or text[pos + 1] != ' ') return error.BadLeadingChars;
    var p = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse return error.IncompleteLastLine;
    p += 1;
    if (p < text.len and text[p] == '\\') {
        p = (std.mem.indexOfScalarPos(u8, text, p, '\n') orelse return error.IncompleteLastLine) + 1;
    }
    return p;
}

/// Whether `edits` stay inside sequences of `n0` and `n1` lines and ascend
/// (what the merge needs to be memory safe with an arbitrary program).
fn editsFit(edits: []const diffcore.Edit, n0: usize, n1: usize) bool {
    var p0: usize = 0;
    var p1: usize = 0;
    for (edits) |e| {
        if (e.line0 < p0 or e.line1 < p1) return false;
        if (e.line0 + e.deleted > n0 or e.line1 + e.inserted > n1) return false;
        p0 = e.line0 + e.deleted;
        p1 = e.line1 + e.inserted;
    }
    return true;
}

pub const Result = struct {
    gpa: std.mem.Allocator,
    lines: [3]Lines,
    blocks: []Block,
    owned: [3]?[]u8 = .{ null, null, null },
    /// How many of the two comparisons (OLDFILE with MYFILE, with YOURFILE)
    /// involve a last line without a newline; GNU warns once for each when it
    /// writes an ed script.
    missing_newline: u8 = 0,

    pub fn deinit(r: *Result) void {
        for (r.lines) |l| l.deinit(r.gpa);
        r.gpa.free(r.blocks);
        for (r.owned) |o| if (o) |m| r.gpa.free(m);
    }

    /// Blocks and the unchanged stretches between them, in file order.
    pub fn withUnchanged(r: *const Result, gpa: std.mem.Allocator) ![]Block {
        var out: std.ArrayList(Block) = .empty;
        errdefer out.deinit(gpa);
        var pos = [3]usize{ 0, 0, 0 };
        for (r.blocks) |b| {
            const gap = b.ranges[1].start - pos[1];
            if (gap > 0) try out.append(gpa, .{ .kind = .unchanged, .ranges = .{
                .{ .start = pos[0], .count = gap },
                .{ .start = pos[1], .count = gap },
                .{ .start = pos[2], .count = gap },
            } });
            try out.append(gpa, b);
            for (0..3) |f| pos[f] = b.ranges[f].start + b.ranges[f].count;
        }
        const rest = r.lines[1].count() - pos[1];
        if (rest > 0) try out.append(gpa, .{ .kind = .unchanged, .ranges = .{
            .{ .start = pos[0], .count = rest },
            .{ .start = pos[1], .count = rest },
            .{ .start = pos[2], .count = rest },
        } });
        return out.toOwnedSlice(gpa);
    }
};

const Region = struct { lo: usize, hi_excl: usize, a: bool, b: bool, a_delta: isize, b_delta: isize };

/// Compare the three buffers. They are borrowed and must outlive the result
/// (unless `strip_trailing_cr` is set, which copies).
pub fn merge3(gpa: std.mem.Allocator, mine: []const u8, older: []const u8, yours: []const u8, flags: Flags) !Result {
    var data = [3][]const u8{ mine, older, yours };
    var owned: [3]?[]u8 = .{ null, null, null };
    errdefer for (owned) |o| if (o) |m| gpa.free(m);
    if (flags.strip_trailing_cr) {
        for (0..3) |i| {
            owned[i] = try diffcore.stripCr(gpa, data[i]);
            data[i] = owned[i].?;
        }
    }
    var ls: [3]Lines = undefined;
    var made: usize = 0;
    errdefer for (ls[0..made]) |l| l.deinit(gpa);
    for (0..3) |i| {
        ls[i] = try diffcore.splitLines(gpa, data[i]);
        made += 1;
    }
    // GNU diff3 compares each of two files with a common file: the third
    // for the default report, the middle one for ed scripts and merges. The
    // comparison runs from the other file to the common one (thread 1 first).
    const c: usize = if (flags.common_middle) 1 else 2;
    const others: [2]usize = if (flags.common_middle) .{ 0, 2 } else .{ 0, 1 };
    var raw: [2][]diffcore.Edit = .{ &.{}, &.{} };
    defer for (raw) |r| gpa.free(r);
    var tn: usize = 2;
    while (tn > 0) {
        tn -= 1;
        raw[tn] = if (flags.external) |x| try x.func(x.context, gpa, @intCast(tn)) else try diffcore.compare(gpa, ls[others[tn]], ls[c], .{ .horizon_lines = 100 });
        if (flags.external != null and !editsFit(raw[tn], ls[others[tn]].count(), ls[c].count())) return error.InvalidEdits;
    }
    // Changes in terms of the common file: `cs`/`cc` its range, `os`/`oc` the other file's.
    const Chg = struct { cs: usize, cc: usize, os: usize, oc: usize };
    var th: [2][]Chg = .{ &.{}, &.{} };
    defer for (th) |r| gpa.free(r);
    for (0..2) |k| {
        th[k] = try gpa.alloc(Chg, raw[k].len);
        for (raw[k], th[k]) |e, *ch| ch.* = .{ .cs = e.line1, .cc = e.inserted, .os = e.line0, .oc = e.deleted };
    }
    const odd = [3]Kind{ .only_first, .only_second, .only_third };

    var blocks: std.ArrayList(Block) = .empty;
    errdefer blocks.deinit(gpa);
    var idx: [2]usize = .{ 0, 0 };
    var delta: [2]isize = .{ 0, 0 }; // lines the other file is ahead of the common file
    while (idx[0] < th[0].len or idx[1] < th[1].len) {
        // Start with the earlier block.
        const take0 = idx[1] >= th[1].len or (idx[0] < th[0].len and th[0][idx[0]].cs <= th[1][idx[1]].cs);
        const first = if (take0) th[0][idx[0]] else th[1][idx[1]];
        const lo = first.cs;
        var hi = first.cs + first.cc; // exclusive end in the common file
        var has: [2]bool = .{ false, false };
        var dd: [2]isize = .{ 0, 0 };
        // Absorb every block of either thread that touches [lo, hi].
        var changed = true;
        while (changed) {
            changed = false;
            for (0..2) |k| {
                if (idx[k] < th[k].len and th[k][idx[k]].cs <= hi) {
                    const e = th[k][idx[k]];
                    hi = @max(hi, e.cs + e.cc);
                    dd[k] += @as(isize, @intCast(e.oc)) - @as(isize, @intCast(e.cc));
                    has[k] = true;
                    idx[k] += 1;
                    changed = true;
                }
            }
        }
        var rs: [2]usize = undefined;
        var rc: [2]usize = undefined;
        for (0..2) |k| {
            rs[k] = @intCast(@as(isize, @intCast(lo)) + delta[k]);
            rc[k] = @intCast(@as(isize, @intCast(hi - lo)) + dd[k]);
            delta[k] += dd[k];
        }
        var kind: Kind = undefined;
        if (has[0] and !has[1]) kind = odd[others[0]] else if (has[1] and !has[0]) kind = odd[others[1]] else {
            var same = rc[0] == rc[1];
            if (same) {
                var k: usize = 0;
                while (k < rc[0]) : (k += 1) {
                    if (!std.mem.eql(u8, ls[others[0]].raw(rs[0] + k), ls[others[1]].raw(rs[1] + k))) {
                        same = false;
                        break;
                    }
                }
            }
            kind = if (same) odd[c] else .overlap;
        }
        var ranges: [3]Range = undefined;
        ranges[c] = .{ .start = lo, .count = hi - lo };
        ranges[others[0]] = .{ .start = rs[0], .count = rc[0] };
        ranges[others[1]] = .{ .start = rs[1], .count = rc[1] };
        try blocks.append(gpa, .{ .kind = kind, .ranges = ranges });
    }
    // One note per "\ No newline" marker the comparison programs would print.
    var missing: u8 = 0;
    for (0..2) |k| {
        const n_oth = ls[others[k]].count();
        const n_com = ls[c].count();
        for (raw[k]) |e| {
            if (e.deleted > 0 and e.line0 + e.deleted == n_oth and !ls[others[k]].terminated(n_oth - 1)) missing += 1;
            if (e.inserted > 0 and e.line1 + e.inserted == n_com and !ls[c].terminated(n_com - 1)) missing += 1;
        }
    }
    return .{ .gpa = gpa, .lines = ls, .blocks = try blocks.toOwnedSlice(gpa), .owned = owned, .missing_newline = missing };
}

pub const Options = struct {
    /// -T
    initial_tab: bool = false,
    /// -L labels for the three files (defaults: the file names).
    labels: [3][]const u8 = .{ "", "", "" },
    /// ed script and merge selection.
    select: Select = .all,
    /// -E, -X, -A: bracket conflicts; `show_all` (-A) also shows OLDFILE.
    bracket: bool = false,
    show_all: bool = false,
    /// -i: append "w" and "q".
    write_quit: bool = false,
};

/// Which changes an ed script or merge incorporates.
pub const Select = enum {
    /// -e: changes from OLDFILE to YOURFILE, overlapping ones included.
    all,
    /// -3: only the non-overlapping ones.
    easy_only,
    /// -x: only the overlapping ones.
    overlap_only,
};

fn writeLinePrefixed(w: *Io.Writer, prefix: []const u8, text: []const u8) Io.Writer.Error!void {
    try w.writeAll(prefix);
    try w.writeAll(text);
    if (text.len == 0 or text[text.len - 1] != '\n') try w.writeAll("\n\\ No newline at end of file\n");
}

fn rangeHeader(w: *Io.Writer, r: Range) Io.Writer.Error!void {
    if (r.count == 0) try w.print("{d}a", .{r.start}) else if (r.count == 1) try w.print("{d}c", .{r.start + 1}) else try w.print("{d},{d}c", .{ r.start + 1, r.start + r.count });
}

/// The default report: one stanza per block.
pub fn writeNormal(w: *Io.Writer, r: *const Result, o: Options) Io.Writer.Error!void {
    const prefix: []const u8 = if (o.initial_tab) "\t" else "  ";
    for (r.blocks) |b| {
        try w.writeAll("====");
        switch (b.kind) {
            .only_first => try w.writeByte('1'),
            .only_second => try w.writeByte('2'),
            .only_third => try w.writeByte('3'),
            else => {},
        }
        try w.writeByte('\n');
        const order: [3]usize = if (b.kind == .only_second) .{ 0, 2, 1 } else .{ 0, 1, 2 };
        const skip: usize = switch (b.kind) {
            .only_first => 1,
            .only_second => 0,
            .only_third => 0,
            else => 3,
        };
        for (order) |f| {
            try w.print("{d}:", .{f + 1});
            try rangeHeader(w, b.ranges[f]);
            try w.writeByte('\n');
            if (f == skip) continue;
            var k: usize = 0;
            while (k < b.ranges[f].count) : (k += 1) try writeLinePrefixed(w, prefix, r.lines[f].raw(b.ranges[f].start + k));
        }
    }
}

const Action = enum { none, use_yours, bracket, bracket_old };

fn actionFor(b: Block, o: Options) Action {
    switch (b.kind) {
        .overlap => {
            if (o.select == .easy_only) return .none;
            if (o.bracket) return if (o.show_all) .bracket_old else .bracket;
            return .use_yours;
        },
        .only_third => return if (o.select == .overlap_only) .none else .use_yours,
        .only_second => return if (o.show_all and o.bracket) .bracket_old else .none,
        else => return .none,
    }
}

/// Whether the script or merge contains a conflict marker.
pub fn hasConflicts(r: *const Result, o: Options) bool {
    for (r.blocks) |b| {
        const a = actionFor(b, o);
        if (a == .bracket or a == .bracket_old) return true;
    }
    return false;
}

fn edAddr(w: *Io.Writer, lo: usize, count: usize) Io.Writer.Error!void {
    if (count <= 1) try w.print("{d}", .{lo + 1}) else try w.print("{d},{d}", .{ lo + 1, lo + count });
}

fn edText(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try w.writeAll(text);
    if (text.len == 0 or text[text.len - 1] != '\n') try w.writeByte('\n');
}

/// Text appended or changed by an ed command. A line that starts with a dot
/// gets a second one (a lone dot would end the input) and a closing
/// `s/^\.//` command removes them again.
const Ins = struct {
    /// Number the next inserted line gets once the command has run.
    next: usize,
    /// The number of the first line inserted, markers aside.
    first: ?usize = null,
    dotted: bool = false,

    fn line(s: *Ins, w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
        if (s.first == null) s.first = s.next;
        if (text.len > 0 and text[0] == '.') {
            try w.writeByte('.');
            s.dotted = true;
        }
        try edText(w, text);
        s.next += 1;
    }

    fn marker(s: *Ins, w: *Io.Writer, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        try w.print(fmt ++ "\n", args);
        s.next += 1;
    }

    fn finish(s: *Ins, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(".\n");
        if (s.dotted) {
            const f = s.first.?;
            const last = s.next - 1;
            if (f == last) try w.print("{d}s/^\\.//\n", .{f}) else try w.print("{d},{d}s/^\\.//\n", .{ f, last });
        }
    }
};

/// An ed script that turns MYFILE into the merged result.
pub fn writeEd(w: *Io.Writer, r: *const Result, o: Options) Io.Writer.Error!void {
    var k = r.blocks.len;
    while (k > 0) {
        k -= 1;
        const b = r.blocks[k];
        const m = b.ranges[0];
        const old = b.ranges[1];
        const y = b.ranges[2];
        switch (actionFor(b, o)) {
            .none => {},
            .use_yours => {
                if (m.count == 0) {
                    try w.print("{d}a\n", .{m.start});
                } else {
                    try edAddr(w, m.start, m.count);
                    try w.writeByte(if (y.count == 0) 'd' else 'c');
                    try w.writeByte('\n');
                }
                if (y.count > 0) {
                    var ins: Ins = .{ .next = m.start + 1 };
                    var i: usize = 0;
                    while (i < y.count) : (i += 1) try ins.line(w, r.lines[2].raw(y.start + i));
                    try ins.finish(w);
                }
            },
            .bracket, .bracket_old => |a| {
                const with_old = a == .bracket_old;
                const second = b.kind == .only_second;
                // After the block: the closing part.
                try w.print("{d}a\n", .{m.start + m.count});
                var ins: Ins = .{ .next = m.start + m.count + 1 };
                if (second) {
                    try ins.marker(w, ">>>>>>> {s}", .{o.labels[2]});
                } else {
                    if (with_old) {
                        // GNU numbers the following lines as if this section were absent.
                        const keep = ins.next;
                        try ins.marker(w, "||||||| {s}", .{o.labels[1]});
                        var i: usize = 0;
                        while (i < old.count) : (i += 1) try ins.line(w, r.lines[1].raw(old.start + i));
                        ins.next = keep;
                    }
                    try ins.marker(w, "=======", .{});
                    var i: usize = 0;
                    while (i < y.count) : (i += 1) try ins.line(w, r.lines[2].raw(y.start + i));
                    try ins.marker(w, ">>>>>>> {s}", .{o.labels[2]});
                    // For a conflict GNU unescapes from after the first
                    // marker, as many lines as the old and the new text and
                    // one more take, whether or not the old text is shown.
                    ins.first = m.start + m.count + 2;
                    ins.next = ins.first.? + old.count + y.count + 1;
                }
                try ins.finish(w);
                // Before the block: the opening part.
                try w.print("{d}a\n", .{m.start});
                var ins2: Ins = .{ .next = m.start + 1 };
                if (second) {
                    try ins2.marker(w, "<<<<<<< {s}", .{o.labels[1]});
                    var i: usize = 0;
                    while (i < old.count) : (i += 1) try ins2.line(w, r.lines[1].raw(old.start + i));
                    try ins2.marker(w, "=======", .{});
                    // Here GNU unescapes the old lines alone.
                    ins2.first = m.start + 2;
                    ins2.next = ins2.first.? + old.count;
                } else try ins2.marker(w, "<<<<<<< {s}", .{o.labels[0]});
                try ins2.finish(w);
            },
        }
    }
    if (o.write_quit) try w.writeAll("w\nq\n");
}

/// The merged file itself (-m). Lines are written as they are, so a last
/// line without a newline stays without one.
pub fn writeMerge(w: *Io.Writer, r: *const Result, o: Options) Io.Writer.Error!void {
    var pos: usize = 0; // next line of MYFILE
    for (r.blocks) |b| {
        const m = b.ranges[0];
        var i = pos;
        while (i < m.start) : (i += 1) try w.writeAll(r.lines[0].raw(i));
        pos = m.start + m.count;
        const old = b.ranges[1];
        const y = b.ranges[2];
        switch (actionFor(b, o)) {
            .none => {
                i = 0;
                while (i < m.count) : (i += 1) try w.writeAll(r.lines[0].raw(m.start + i));
            },
            .use_yours => {
                i = 0;
                while (i < y.count) : (i += 1) try w.writeAll(r.lines[2].raw(y.start + i));
            },
            .bracket, .bracket_old => |a| {
                const second = b.kind == .only_second;
                if (second) {
                    try w.print("<<<<<<< {s}\n", .{o.labels[1]});
                    i = 0;
                    while (i < old.count) : (i += 1) try w.writeAll(r.lines[1].raw(old.start + i));
                    try w.writeAll("=======\n");
                    i = 0;
                    while (i < m.count) : (i += 1) try w.writeAll(r.lines[0].raw(m.start + i));
                } else {
                    try w.print("<<<<<<< {s}\n", .{o.labels[0]});
                    i = 0;
                    while (i < m.count) : (i += 1) try w.writeAll(r.lines[0].raw(m.start + i));
                    if (a == .bracket_old) {
                        try w.print("||||||| {s}\n", .{o.labels[1]});
                        i = 0;
                        while (i < old.count) : (i += 1) try w.writeAll(r.lines[1].raw(old.start + i));
                    }
                    try w.writeAll("=======\n");
                    i = 0;
                    while (i < y.count) : (i += 1) try w.writeAll(r.lines[2].raw(y.start + i));
                }
                try w.print(">>>>>>> {s}\n", .{o.labels[2]});
            },
        }
    }
    var i = pos;
    while (i < r.lines[0].count()) : (i += 1) try w.writeAll(r.lines[0].raw(i));
}

/// The comparison as one JSON object: the three file names and the list of
/// blocks (including the unchanged stretches) with each side's range and text.
pub fn writeJson(gpa: std.mem.Allocator, w: *Io.Writer, r: *const Result, names: [3][]const u8) !void {
    const all = try r.withUnchanged(gpa);
    defer gpa.free(all);
    var conflicts: usize = 0;
    for (r.blocks) |b| {
        if (b.kind == .overlap) conflicts += 1;
    }
    try w.writeAll("{\"files\":[");
    for (names, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try json.writeString(w, n);
    }
    try w.print("],\"conflicts\":{d},\"blocks\":[", .{conflicts});
    for (all, 0..) |b, i| {
        if (i > 0) try w.writeByte(',');
        const kind = switch (b.kind) {
            .unchanged => "unchanged",
            .only_first => "only-first",
            .only_second => "only-second",
            .only_third => "only-third",
            .overlap => "overlap",
        };
        try w.print("{{\"kind\":\"{s}\",\"sides\":[", .{kind});
        for (0..3) |f| {
            if (f > 0) try w.writeByte(',');
            const rg = b.ranges[f];
            try w.print("{{\"start\":{d},\"count\":{d},\"lines\":[", .{ rg.start + 1, rg.count });
            var k: usize = 0;
            while (k < rg.count) : (k += 1) {
                if (k > 0) try w.writeByte(',');
                try json.writeString(w, r.lines[f].body(rg.start + k));
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}\n");
}

test "non-overlapping changes give separate blocks" {
    const t = std.testing;
    var r = try merge3(t.allocator, "a\nM\nc\nd\ne\n", "a\nb\nc\nd\ne\n", "a\nb\nc\nY\ne\n", .{});
    defer r.deinit();
    try t.expectEqual(@as(usize, 2), r.blocks.len);
    try t.expectEqual(Kind.only_first, r.blocks[0].kind);
    try t.expectEqual(Kind.only_third, r.blocks[1].kind);
}

test "same change on both sides is only_second" {
    const t = std.testing;
    var r = try merge3(t.allocator, "a\nZ\n", "a\nb\n", "a\nZ\n", .{});
    defer r.deinit();
    try t.expectEqual(@as(usize, 1), r.blocks.len);
    try t.expectEqual(Kind.only_second, r.blocks[0].kind);
}

test "conflict" {
    const t = std.testing;
    var r = try merge3(t.allocator, "a\nM\n", "a\nb\n", "a\nQ\n", .{});
    defer r.deinit();
    try t.expectEqual(Kind.overlap, r.blocks[0].kind);
}
