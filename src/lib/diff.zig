// SPDX-License-Identifier: GPL-2.0-or-later
//! diff library (decision 0004): compare files and directories and write the
//! result in GNU diff's formats or as `--json` (decision 0003).
//! References: GNU diffutils manual "Comparing and Merging Files" (3.12);
//! POSIX.1-2024 diff. The line comparison engine is `diffcore.zig`.
//!
//! Two levels are exported. `compareData` takes two byte buffers and returns
//! a `Compared` (the edit script plus the line tables, no output at all);
//! `hunks` turns that into context-grouped `Hunk`s. `run` compares two
//! operands (files, standard input or directories) and writes the text.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const diffcore = @import("diffcore.zig");
const json = @import("../json.zig");
const posixre = @import("../posixre.zig");
const tz = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const fnmatch = @import("../fnmatch.zig");
const diffsbs = @import("diffsbs.zig");

pub const Env = common.Env;
pub const Lines = diffcore.Lines;
pub const Edit = diffcore.Edit;
pub const Flags = diffcore.Flags;

pub const Style = enum { normal, context, unified, ed, rcs, forward_ed, ifdef, side_by_side };

/// The seven line/group formats of `--line-format` and friends; null leaves a
/// slot at GNU's default for the style.
pub const Formats = struct {
    old_line: ?[]const u8 = null,
    new_line: ?[]const u8 = null,
    unchanged_line: ?[]const u8 = null,
    old_group: ?[]const u8 = null,
    new_group: ?[]const u8 = null,
    unchanged_group: ?[]const u8 = null,
    changed_group: ?[]const u8 = null,
};

pub const Palette = struct {
    /// SGR parameter strings, GNU defaults.
    add: []const u8 = "32",
    delete: []const u8 = "31",
    header: []const u8 = "1",
    hunk: []const u8 = "36",
    context: []const u8 = "",
    line_number: []const u8 = "",
};

pub const Options = struct {
    style: Style = .normal,
    /// Lines of context for the context and unified styles (-C, -U).
    context: usize = 3,
    flags: Flags = .{},
    /// -B
    ignore_blank_lines: bool = false,
    /// -I: a hunk whose changed lines all match one of these is ignored.
    ignore_matching: []const []const u8 = &.{},
    /// -a: treat binary files as text.
    text: bool = false,
    /// --strip-trailing-cr
    strip_trailing_cr: bool = false,
    /// -q
    brief: bool = false,
    /// -s
    report_identical: bool = false,
    /// -t
    expand_tabs: bool = false,
    /// -T
    initial_tab: bool = false,
    tab_size: usize = 8,
    suppress_blank_empty: bool = false,
    /// -W
    width: usize = 130,
    left_column: bool = false,
    suppress_common_lines: bool = false,
    /// -F REGEX, or -p (`show_c_function` supplies the default expression).
    function_regexp: ?[]const u8 = null,
    formats: Formats = .{},
    /// -D NAME builds the group formats from this name.
    ifdef_name: ?[]const u8 = null,
    recursive: bool = false,
    /// -N
    new_file: bool = false,
    unidirectional_new_file: bool = false,
    ignore_file_name_case: bool = false,
    /// -x
    exclude: []const []const u8 = &.{},
    /// -S
    starting_file: ?[]const u8 = null,
    no_dereference: bool = false,
    labels: [2]?[]const u8 = .{ null, null },
    /// --color
    color: bool = false,
    palette: Palette = .{},
    /// The option words shown in the "diff -r ..." line of a directory
    /// comparison (already quoted); the wrapper builds it.
    switch_string: []const u8 = "",
    /// Output the result as JSON.
    json: bool = false,
    /// -l: pass each file's output through the page formatter (`pr -h`).
    paginate: bool = false,
};

pub const Event = union(enum) {
    /// A file could not be opened, read or examined.
    file_error: struct { name: []const u8, err: anyerror },
    /// ed-style output needs a final newline: "NAME: No newline at end of file".
    no_newline: []const u8,
    /// A condition GNU reports and stops on ("-D option not supported with directories").
    fatal: []const u8,
};

pub const Observer = common.Observer(Event);

pub const LineKind = enum { context, removed, added };

pub const HunkLine = struct {
    kind: LineKind,
    /// The line without its newline.
    text: []const u8,
    /// The line is the last of its file and has no newline.
    no_newline: bool,
};

/// A group of changes with its context, as `diff -u` shows it. Numbers are
/// 1-based; when a count is 0 the start is the line before the range (as in
/// the `@@` header).
pub const Hunk = struct {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    lines: []HunkLine,
};

/// An edit with the -B / -I verdict: all changed lines ignorable.
pub const Item = struct {
    edit: Edit,
    ignore: bool = false,
};

/// The comparison of two byte buffers: line tables and edit script.
pub const Compared = struct {
    gpa: std.mem.Allocator,
    a: Lines,
    b: Lines,
    items: []Item,
    /// Buffers made by --strip-trailing-cr or by adding a final newline.
    owned: [2]?[]u8 = .{ null, null },

    pub fn deinit(c: *Compared) void {
        c.a.deinit(c.gpa);
        c.b.deinit(c.gpa);
        c.gpa.free(c.items);
        for (c.owned) |o| if (o) |m| c.gpa.free(m);
    }

    /// Some hunk is not ignorable.
    pub fn differs(c: *const Compared) bool {
        for (c.items) |it| if (!it.ignore) return true;
        return false;
    }
};

/// Compare two buffers. Borrowed `a` and `b` must outlive the result.
pub fn compareData(gpa: std.mem.Allocator, a_in: []const u8, b_in: []const u8, options: Options) !Compared {
    var a = a_in;
    var b = b_in;
    var owned: [2]?[]u8 = .{ null, null };
    errdefer for (owned) |o| if (o) |m| gpa.free(m);
    if (options.strip_trailing_cr) {
        owned[0] = try diffcore.stripCr(gpa, a);
        a = owned[0].?;
        owned[1] = try diffcore.stripCr(gpa, b);
        b = owned[1].?;
    }
    return finishCompare(gpa, a, b, owned, options, null);
}

fn contextFor(options: Options) usize {
    return switch (options.style) {
        .context, .unified => options.context,
        else => 0,
    };
}

fn finishCompare(gpa: std.mem.Allocator, a: []const u8, b: []const u8, owned: [2]?[]u8, options: Options, matchers: ?*Matchers) !Compared {
    const la = try diffcore.splitLines(gpa, a);
    errdefer la.deinit(gpa);
    const lb = try diffcore.splitLines(gpa, b);
    errdefer lb.deinit(gpa);
    var flags = options.flags;
    flags.horizon_lines = @max(flags.horizon_lines, contextFor(options));
    const edits = try diffcore.compare(gpa, la, lb, flags);
    defer gpa.free(edits);
    const items = try gpa.alloc(Item, edits.len);
    errdefer gpa.free(items);
    for (edits, items) |e, *it| it.* = .{ .edit = e };
    var c: Compared = .{ .gpa = gpa, .a = la, .b = lb, .items = items, .owned = owned };
    if (options.ignore_blank_lines or options.ignore_matching.len > 0) {
        var own: ?Matchers = null;
        defer if (own) |*m| m.deinit();
        var mp = matchers;
        if (mp == null) {
            own = try Matchers.init(gpa, options);
            mp = &own.?;
        }
        for (c.items) |*it| {
            var one = [1]Item{it.*};
            it.ignore = analyze(&c, options, mp.?, &one).changes == .unchanged;
        }
    }
    return c;
}

/// Compiled -I and -F expressions.
pub const Matchers = struct {
    gpa: std.mem.Allocator,
    ignore: std.ArrayList(posixre.Compiled) = .empty,
    finders: std.ArrayList(posixre.Finder) = .empty,
    function: ?posixre.Compiled = null,
    function_finder: ?posixre.Finder = null,

    pub fn init(gpa: std.mem.Allocator, options: Options) !Matchers {
        var m: Matchers = .{ .gpa = gpa };
        errdefer m.deinit();
        for (options.ignore_matching) |p| {
            var c = posixre.compile(gpa, p, false, false) catch return error.BadRegex;
            errdefer c.deinit(gpa);
            try m.ignore.append(gpa, c);
        }
        for (m.ignore.items) |*c| try m.finders.append(gpa, try posixre.Finder.init(gpa, c));
        if (options.function_regexp) |p| {
            m.function = posixre.compile(gpa, p, false, false) catch return error.BadRegex;
            m.function_finder = try posixre.Finder.init(gpa, &m.function.?);
        }
        return m;
    }

    pub fn deinit(m: *Matchers) void {
        for (m.finders.items) |*f| f.deinit();
        m.finders.deinit(m.gpa);
        for (m.ignore.items) |*c| c.deinit(m.gpa);
        m.ignore.deinit(m.gpa);
        if (m.function_finder) |*f| f.deinit();
        if (m.function) |*c| c.deinit(m.gpa);
    }

    fn ignores(m: *Matchers, text: []const u8) bool {
        for (m.finders.items) |*f| {
            if (f.find(text, 0) catch null) |_| return true;
        }
        return false;
    }

    fn isFunction(m: *Matchers, text: []const u8) bool {
        if (m.function_finder) |*f| return (f.find(text, 0) catch null) != null;
        return false;
    }
};

pub const Changes = enum(u2) { unchanged = 0, old = 1, new = 2, changed = 3 };

pub const Analysis = struct {
    changes: Changes,
    first0: isize,
    last0: isize,
    first1: isize,
    last1: isize,
};

fn isSpaceByte(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

fn lineTrivial(options: Options, m: *Matchers, text: []const u8) bool {
    if (options.ignore_blank_lines) {
        var t = text;
        if (options.flags.ignore_trailing_space or options.flags.ignore_space_change or options.flags.ignore_all_space) {
            while (t.len > 0 and isSpaceByte(t[t.len - 1])) t = t[0 .. t.len - 1];
        }
        if (t.len == 0) return true;
    }
    if (options.ignore_matching.len > 0 and m.ignores(text)) return true;
    return false;
}

pub fn analyze(c: *const Compared, options: Options, m: *Matchers, hunk: []const Item) Analysis {
    var trivial = options.ignore_blank_lines or options.ignore_matching.len > 0;
    var show_from: usize = 0;
    var show_to: usize = 0;
    const first = hunk[0].edit;
    var l0: isize = 0;
    var l1: isize = 0;
    for (hunk) |it| {
        const e = it.edit;
        l0 = @as(isize, @intCast(e.line0 + e.deleted)) - 1;
        l1 = @as(isize, @intCast(e.line1 + e.inserted)) - 1;
        show_from += e.deleted;
        show_to += e.inserted;
        var i = e.line0;
        while (trivial and i < e.line0 + e.deleted) : (i += 1) {
            if (!lineTrivial(options, m, c.a.body(i))) trivial = false;
        }
        i = e.line1;
        while (trivial and i < e.line1 + e.inserted) : (i += 1) {
            if (!lineTrivial(options, m, c.b.body(i))) trivial = false;
        }
    }
    const kind: Changes = if (trivial) .unchanged else @enumFromInt(@as(u2, if (show_from > 0) 1 else 0) | @as(u2, if (show_to > 0) 2 else 0));
    return .{ .changes = kind, .first0 = @intCast(first.line0), .last0 = l0, .first1 = @intCast(first.line1), .last1 = l1 };
}

/// Group the (not ignorable) changes with `context` lines around them into
/// hunks, the way `diff -u -U context` does.
pub fn hunks(gpa: std.mem.Allocator, c: *const Compared, context: usize) ![]Hunk {
    var out: std.ArrayList(Hunk) = .empty;
    errdefer {
        for (out.items) |h| gpa.free(h.lines);
        out.deinit(gpa);
    }
    var i: usize = 0;
    while (i < c.items.len) {
        const end = findHunk(c.items, i, context);
        const group = c.items[i .. end + 1];
        i = end + 1;
        var any = false;
        for (group) |g| if (!g.ignore) {
            any = true;
        };
        if (!any) continue;
        const first = group[0].edit;
        const lastE = group[group.len - 1].edit;
        const n0 = c.a.count();
        const n1 = c.b.count();
        const f0 = first.line0 -| context;
        const f1 = first.line1 -| context;
        const l0 = @min(lastE.line0 + lastE.deleted + context, n0); // exclusive
        const l1 = @min(lastE.line1 + lastE.inserted + context, n1);
        var lines: std.ArrayList(HunkLine) = .empty;
        errdefer lines.deinit(gpa);
        var p = f0;
        var q = f1;
        var gi: usize = 0;
        while (p < l0 or q < l1) {
            if (gi >= group.len or p < group[gi].edit.line0) {
                try lines.append(gpa, .{ .kind = .context, .text = c.a.body(p), .no_newline = !c.a.terminated(p) });
                p += 1;
                q += 1;
            } else {
                const e = group[gi].edit;
                var k: usize = 0;
                while (k < e.deleted) : (k += 1) {
                    try lines.append(gpa, .{ .kind = .removed, .text = c.a.body(p), .no_newline = !c.a.terminated(p) });
                    p += 1;
                }
                k = 0;
                while (k < e.inserted) : (k += 1) {
                    try lines.append(gpa, .{ .kind = .added, .text = c.b.body(q), .no_newline = !c.b.terminated(q) });
                    q += 1;
                }
                gi += 1;
            }
        }
        const oc = l0 - f0;
        const nc = l1 - f1;
        try out.append(gpa, .{
            .old_start = if (oc == 0) f0 else f0 + 1,
            .old_count = oc,
            .new_start = if (nc == 0) f1 else f1 + 1,
            .new_count = nc,
            .lines = try lines.toOwnedSlice(gpa),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeHunks(gpa: std.mem.Allocator, hs: []Hunk) void {
    for (hs) |h| gpa.free(h.lines);
    gpa.free(hs);
}

/// Index of the last item of the hunk that starts at `start`.
fn findHunk(items: []const Item, start: usize, context: usize) usize {
    const ctx_big = context > (std.math.maxInt(usize) - 1) / 2;
    const non_ignorable: usize = if (ctx_big) std.math.maxInt(usize) else 2 * context + 1;
    const ignorable: usize = context;
    var s = start;
    while (true) {
        const e = items[s].edit;
        const top0 = e.line0 + e.deleted;
        const prev = s;
        s += 1;
        if (s >= items.len) return prev;
        const thresh = if (items[s].ignore) ignorable else non_ignorable;
        if (items[s].edit.line0 - top0 >= thresh) return prev;
    }
}

// ---------------------------------------------------------------- printing

pub const FileTime = struct {
    sec: i64,
    nsec: u32,
};

pub const Printer = struct {
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    options: Options,
    c: *const Compared,
    m: *Matchers,
    names: [2][]const u8,
    times: [2]FileTime,
    zone: *const tz.Zone,
    /// "diff -r a b" line printed before the first output of a file in a directory comparison.
    header: ?[]const u8 = null,
    begun: bool = false,
    last_search: isize = 0,
    last_match: ?isize = null,
    /// Set when output was produced (a hunk, or the whole script).
    wrote_diff: bool = false,

    fn trans(i: isize) isize {
        return i + 1;
    }

    pub fn begin(p: *Printer) Io.Writer.Error!void {
        if (p.begun) return;
        p.begun = true;
        if (p.header) |h| {
            try p.w.writeAll(h);
            try p.w.writeByte('\n');
        }
        switch (p.options.style) {
            .context => try p.contextHeader(false),
            .unified => try p.contextHeader(true),
            else => {},
        }
    }

    fn contextLabel(p: *Printer, mark: []const u8, idx: usize, unidiff: bool) Io.Writer.Error!void {
        if (p.options.labels[idx]) |l| {
            try p.w.print("{s} {s}\n", .{ mark, l });
            return;
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(p.gpa);
        const t = p.times[idx];
        const tm = tz.localtime(p.zone, t.sec);
        strftime.format(&buf, p.gpa, if (unidiff) "%Y-%m-%d %H:%M:%S.%N %z" else "%a %b %e %T %Y", &tm, t.sec, t.nsec) catch return error.WriteFailed;
        try p.w.print("{s} {s}\t{s}\n", .{ mark, p.names[idx], buf.items });
    }

    fn contextHeader(p: *Printer, unidiff: bool) Io.Writer.Error!void {
        const color = p.options.color;
        if (color) try p.sgr(p.options.palette.header);
        try p.contextLabel(if (unidiff) "---" else "***", 0, unidiff);
        try p.contextLabel(if (unidiff) "+++" else "---", 1, unidiff);
        if (color) try p.reset();
    }

    fn sgr(p: *Printer, params: []const u8) Io.Writer.Error!void {
        if (params.len == 0) return;
        try p.w.print("\x1b[{s}m", .{params});
    }
    fn reset(p: *Printer) Io.Writer.Error!void {
        try p.w.writeAll("\x1b[m");
    }

    /// One line with its flag (GNU's print_1_line).
    fn printLine(p: *Printer, flag: []const u8, text: []const u8) Io.Writer.Error!void {
        const o = p.options;
        const blank = text.len == 1 and text[0] == '\n';
        if (flag.len > 0) {
            const omit = o.suppress_blank_empty and blank;
            if (!(omit and std.mem.eql(u8, flag, " "))) {
                try p.w.writeAll(flag);
                if (!omit) try p.w.writeByte(if (o.initial_tab) '\t' else ' ');
            }
        }
        try p.outputLine(text, if (flag.len > 0) flag else null);
        if ((flag.len > 0 or true) and (text.len == 0 or text[text.len - 1] != '\n') and flag.len > 0) {
            try p.w.writeAll("\n\\ No newline at end of file\n");
        }
    }

    fn flagWantsNote(flag: []const u8) bool {
        _ = flag;
        return true;
    }

    /// The text of a line, expanding tabs for -t (GNU's output_1_line). After
    /// a carriage return inside the line the flag is printed again when `flag`
    /// is given, so that tab stops keep lining up.
    pub fn outputLine(p: *Printer, text: []const u8, flag: ?[]const u8) Io.Writer.Error!void {
        const o = p.options;
        if (!o.expand_tabs) return p.w.writeAll(text);
        var col: usize = 0;
        for (text, 0..) |ch, idx| {
            switch (ch) {
                '\t' => {
                    const n = o.tab_size - col % o.tab_size;
                    try p.w.splatByteAll(' ', n);
                    col += n;
                },
                '\r' => {
                    try p.w.writeByte(ch);
                    if (flag) |f| {
                        if (idx + 1 < text.len and text[idx + 1] != '\n') {
                            try p.w.writeAll(f);
                            try p.w.writeByte(if (o.initial_tab) '\t' else ' ');
                        }
                    }
                    col = 0;
                },
                '\x08' => {
                    if (col > 0) {
                        col -= 1;
                        try p.w.writeByte(ch);
                    }
                },
                else => {
                    try p.w.writeByte(ch);
                    if (ch >= 32 and ch != 127) col += 1;
                },
            }
        }
    }

    fn numberRange(p: *Printer, sep: u8, first: isize, last: isize) Io.Writer.Error!void {
        const a = trans(first);
        const b = trans(last);
        if (b > a) try p.w.print("{d}{c}{d}", .{ a, sep, b }) else try p.w.print("{d}", .{b});
    }

    // normal ------------------------------------------------------------

    fn normalHunk(p: *Printer, hunk: []const Item) Io.Writer.Error!void {
        const an = analyze(p.c, p.options, p.m, hunk);
        if (an.changes == .unchanged) return;
        try p.begin();
        p.wrote_diff = true;
        try p.numberRange(',', an.first0, an.last0);
        try p.w.writeByte(switch (an.changes) {
            .old => 'd',
            .new => 'a',
            else => 'c',
        });
        try p.numberRange(',', an.first1, an.last1);
        try p.w.writeByte('\n');
        const color = p.options.color;
        if (@intFromEnum(an.changes) & 1 != 0) {
            var i: isize = an.first0;
            while (i <= an.last0) : (i += 1) {
                if (color) try p.sgr(p.options.palette.delete);
                try p.printLine("<", p.c.a.raw(@intCast(i)));
                if (color) try p.reset();
            }
        }
        if (an.changes == .changed) try p.w.writeAll("---\n");
        if (@intFromEnum(an.changes) & 2 != 0) {
            var i: isize = an.first1;
            while (i <= an.last1) : (i += 1) {
                if (color) try p.sgr(p.options.palette.add);
                try p.printLine(">", p.c.b.raw(@intCast(i)));
                if (color) try p.reset();
            }
        }
    }

    // context and unified ------------------------------------------------

    fn findFunction(p: *Printer, linenum: isize) ?isize {
        var i = linenum;
        const last = p.last_search;
        p.last_search = i;
        while (true) {
            i -= 1;
            if (last > i) break;
            const text = p.c.a.body(@intCast(i));
            if (p.m.isFunction(text)) {
                p.last_match = i;
                return i;
            }
        }
        return p.last_match;
    }

    fn functionText(p: *Printer, idx: isize) []const u8 {
        var t = p.c.a.body(@intCast(idx));
        while (t.len > 0 and isSpaceByte(t[t.len - 1])) t = t[0 .. t.len - 1];
        return t[0..@min(t.len, 40)];
    }

    const Bounds = struct { first0: isize, last0: isize, first1: isize, last1: isize };

    fn bounds(p: *Printer, an: Analysis) Bounds {
        const ctx: isize = @intCast(p.options.context);
        const n0: isize = @intCast(p.c.a.count());
        const n1: isize = @intCast(p.c.b.count());
        const first0 = @max(an.first0 - ctx, 0);
        const first1 = @max(an.first1 - ctx, 0);
        const last0 = if (an.last0 < n0 - ctx) an.last0 + ctx else n0 - 1;
        const last1 = if (an.last1 < n1 - ctx) an.last1 + ctx else n1 - 1;
        return .{ .first0 = first0, .last0 = last0, .first1 = first1, .last1 = last1 };
    }

    fn contextHunk(p: *Printer, hunk: []const Item) Io.Writer.Error!void {
        const an = analyze(p.c, p.options, p.m, hunk);
        if (an.changes == .unchanged) return;
        const b = p.bounds(an);
        const func: ?isize = if (p.options.function_regexp != null) p.findFunction(b.first0) else null;
        try p.begin();
        p.wrote_diff = true;
        const color = p.options.color;
        if (color) try p.sgr(p.options.palette.hunk);
        try p.w.writeAll("***************");
        if (func) |f| {
            try p.w.writeByte(' ');
            try p.w.writeAll(p.functionText(f));
        }
        try p.w.writeAll("\n*** ");
        try p.numberRange(',', b.first0, b.last0);
        try p.w.writeAll(" ****\n");
        if (color) try p.reset();
        const items = hunk;
        if (@intFromEnum(an.changes) & 1 != 0) {
            var k: usize = 0;
            var i = b.first0;
            while (i <= b.last0) : (i += 1) {
                while (k < items.len and @as(isize, @intCast(items[k].edit.line0 + items[k].edit.deleted)) <= i) k += 1;
                var prefix: []const u8 = " ";
                if (k < items.len and @as(isize, @intCast(items[k].edit.line0)) <= i) prefix = if (items[k].edit.inserted > 0) "!" else "-";
                try p.coloredLine(prefix, p.c.a.raw(@intCast(i)), prefix[0] != ' ', true);
            }
        }
        if (color) try p.sgr(p.options.palette.hunk);
        try p.w.writeAll("--- ");
        try p.numberRange(',', b.first1, b.last1);
        try p.w.writeAll(" ----\n");
        if (color) try p.reset();
        if (@intFromEnum(an.changes) & 2 != 0) {
            var k: usize = 0;
            var i = b.first1;
            while (i <= b.last1) : (i += 1) {
                while (k < items.len and @as(isize, @intCast(items[k].edit.line1 + items[k].edit.inserted)) <= i) k += 1;
                var prefix: []const u8 = " ";
                if (k < items.len and @as(isize, @intCast(items[k].edit.line1)) <= i) prefix = if (items[k].edit.deleted > 0) "!" else "+";
                try p.coloredLine(prefix, p.c.b.raw(@intCast(i)), prefix[0] != ' ', false);
            }
        }
    }

    fn coloredLine(p: *Printer, prefix: []const u8, text: []const u8, changed: bool, old_side: bool) Io.Writer.Error!void {
        if (p.options.color and changed) {
            try p.sgr(if (prefix[0] == '-' or (prefix[0] == '!' and old_side)) p.options.palette.delete else p.options.palette.add);
            try p.printLine(prefix, text);
            try p.reset();
        } else try p.printLine(prefix, text);
    }

    fn unifiedRange(p: *Printer, first: isize, last: isize) Io.Writer.Error!void {
        const a = trans(first);
        const b = trans(last);
        if (b <= a) {
            if (b < a) try p.w.print("{d},0", .{b}) else try p.w.print("{d}", .{b});
        } else try p.w.print("{d},{d}", .{ a, b - a + 1 });
    }

    fn unifiedHunk(p: *Printer, hunk: []const Item) Io.Writer.Error!void {
        const an = analyze(p.c, p.options, p.m, hunk);
        if (an.changes == .unchanged) return;
        const b = p.bounds(an);
        const func: ?isize = if (p.options.function_regexp != null) p.findFunction(b.first0) else null;
        try p.begin();
        p.wrote_diff = true;
        const o = p.options;
        const color = o.color;
        if (color) try p.sgr(o.palette.hunk);
        try p.w.writeAll("@@ -");
        try p.unifiedRange(b.first0, b.last0);
        try p.w.writeAll(" +");
        try p.unifiedRange(b.first1, b.last1);
        try p.w.writeAll(" @@");
        if (func) |f| {
            try p.w.writeByte(' ');
            try p.w.writeAll(p.functionText(f));
        }
        if (color) try p.reset();
        try p.w.writeByte('\n');

        var next: usize = 0;
        var i = b.first0;
        var j = b.first1;
        while (i <= b.last0 or j <= b.last1) {
            if (next >= hunk.len or i < @as(isize, @intCast(hunk[next].edit.line0))) {
                const text = p.c.a.raw(@intCast(i));
                i += 1;
                j += 1;
                const blank = text.len == 1 and text[0] == '\n';
                if (!(o.suppress_blank_empty and blank)) try p.w.writeByte(if (o.initial_tab) '\t' else ' ');
                try p.outputLine(text, null);
                try p.noteIfMissing(text);
            } else {
                const e = hunk[next].edit;
                var k = e.deleted;
                while (k > 0) : (k -= 1) {
                    const text = p.c.a.raw(@intCast(i));
                    i += 1;
                    if (color) try p.sgr(o.palette.delete);
                    try p.w.writeByte('-');
                    if (o.initial_tab and !(o.suppress_blank_empty and text.len == 1 and text[0] == '\n')) try p.w.writeByte('\t');
                    try p.outputLine(text, null);
                    if (color) try p.reset();
                    try p.noteIfMissing(text);
                }
                k = e.inserted;
                while (k > 0) : (k -= 1) {
                    const text = p.c.b.raw(@intCast(j));
                    j += 1;
                    if (color) try p.sgr(o.palette.add);
                    try p.w.writeByte('+');
                    if (o.initial_tab and !(o.suppress_blank_empty and text.len == 1 and text[0] == '\n')) try p.w.writeByte('\t');
                    try p.outputLine(text, null);
                    if (color) try p.reset();
                    try p.noteIfMissing(text);
                }
                next += 1;
            }
        }
    }

    fn noteIfMissing(p: *Printer, text: []const u8) Io.Writer.Error!void {
        if (text.len == 0 or text[text.len - 1] != '\n') try p.w.writeAll("\n\\ No newline at end of file\n");
    }

    // ed, rcs, forward ed ------------------------------------------------

    fn edHunk(p: *Printer, hunk: []const Item) Io.Writer.Error!void {
        const an = analyze(p.c, p.options, p.m, hunk);
        if (an.changes == .unchanged) return;
        try p.begin();
        p.wrote_diff = true;
        try p.numberRange(',', an.first0, an.last0);
        try p.w.writeByte(switch (an.changes) {
            .old => 'd',
            .new => 'a',
            else => 'c',
        });
        try p.w.writeByte('\n');
        if (an.changes != .old) {
            var insert_mode = true;
            var i = an.first1;
            while (i <= an.last1) : (i += 1) {
                if (!insert_mode) {
                    try p.w.writeAll("a\n");
                    insert_mode = true;
                }
                const text = p.c.b.raw(@intCast(i));
                if (text.len == 2 and text[0] == '.' and text[1] == '\n') {
                    try p.w.writeAll("..\n.\ns/.//\n");
                    insert_mode = false;
                } else try p.printLine("", text);
            }
            if (insert_mode) try p.w.writeAll(".\n");
        }
    }

    fn forwardEdHunk(p: *Printer, hunk: []const Item) Io.Writer.Error!void {
        const an = analyze(p.c, p.options, p.m, hunk);
        if (an.changes == .unchanged) return;
        try p.begin();
        p.wrote_diff = true;
        try p.w.writeByte(switch (an.changes) {
            .old => 'd',
            .new => 'a',
            else => 'c',
        });
        try p.numberRange(' ', an.first0, an.last0);
        try p.w.writeByte('\n');
        if (an.changes != .old) {
            var i = an.first1;
            while (i <= an.last1) : (i += 1) try p.printLine("", p.c.b.raw(@intCast(i)));
            try p.w.writeAll(".\n");
        }
    }

    fn rcsHunk(p: *Printer, hunk: []const Item) Io.Writer.Error!void {
        const an = analyze(p.c, p.options, p.m, hunk);
        if (an.changes == .unchanged) return;
        try p.begin();
        p.wrote_diff = true;
        if (@intFromEnum(an.changes) & 1 != 0) {
            try p.w.print("d{d} {d}\n", .{ trans(an.first0), an.last0 - an.first0 + 1 });
        }
        if (@intFromEnum(an.changes) & 2 != 0) {
            try p.w.print("a{d} {d}\n", .{ trans(an.last0), an.last1 - an.first1 + 1 });
            var i = an.first1;
            while (i <= an.last1) : (i += 1) try p.printLine("", p.c.b.raw(@intCast(i)));
        }
    }

    // driver -------------------------------------------------------------

    pub fn script(p: *Printer) !void {
        const items = p.c.items;
        switch (p.options.style) {
            .normal, .ed, .rcs, .forward_ed => {
                if (p.options.style == .ed) {
                    var k = items.len;
                    while (k > 0) {
                        k -= 1;
                        try p.edHunk(items[k .. k + 1]);
                    }
                } else for (0..items.len) |k| {
                    const one = items[k .. k + 1];
                    switch (p.options.style) {
                        .normal => try p.normalHunk(one),
                        .rcs => try p.rcsHunk(one),
                        else => try p.forwardEdHunk(one),
                    }
                }
            },
            .context, .unified => {
                var i: usize = 0;
                while (i < items.len) {
                    const end = findHunk(items, i, p.options.context);
                    const group = items[i .. end + 1];
                    i = end + 1;
                    if (p.options.style == .context) try p.contextHunk(group) else try p.unifiedHunk(group);
                }
            },
            .ifdef => try diffsbs.printIfdef(p, items),
            .side_by_side => try diffsbs.printSideBySide(p, items),
        }
    }
};

pub fn writeHunksJson(w: *Io.Writer, hs: []const Hunk) Io.Writer.Error!void {
    try w.writeByte('[');
    for (hs, 0..) |h, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"old_start\":{d},\"old_count\":{d},\"new_start\":{d},\"new_count\":{d},\"lines\":[", .{ h.old_start, h.old_count, h.new_start, h.new_count });
        for (h.lines, 0..) |l, k| {
            if (k > 0) try w.writeByte(',');
            try w.print("{{\"kind\":\"{s}\",\"text\":", .{@tagName(l.kind)});
            try json.writeString(w, l.text);
            try w.print(",\"no_newline\":{s}}}", .{if (l.no_newline) "true" else "false"});
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// Compare two operands (a path, or "-" for standard input) and write the
/// result. Returns GNU's exit status: 0 same, 1 different, 2 trouble.
pub const run = @import("diffrun.zig").run;
pub const max_input = @import("diffrun.zig").max_input;

test {
    _ = diffsbs;
    _ = @import("diffrun.zig");
}
