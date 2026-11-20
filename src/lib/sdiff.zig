// SPDX-License-Identifier: GPL-2.0-or-later
//! sdiff library (decision 0004): side-by-side comparison of two files, and
//! the interactive merge of `sdiff -o`.
//! References: GNU diffutils manual "Interactive Merging with sdiff" (3.12).
//!
//! The layout is `diffsbs.row`, shared with `diff -y`; `rows` returns the
//! aligned rows as data. `list` writes the GNU text, `interact` runs the
//! merge: answers come from a caller-supplied reader, so tests (and other
//! programs) can script it without a terminal.

const std = @import("std");
const Io = std.Io;
const diff = @import("diff.zig");
const diffsbs = @import("diffsbs.zig");
const json = @import("../json.zig");

pub const Env = diff.Env;

pub const Marker = enum {
    equal,
    changed,
    left_only,
    right_only,
};

/// One aligned row. `left` and `right` are the lines without newline.
pub const Row = struct {
    marker: Marker,
    left: ?[]const u8,
    right: ?[]const u8,
    /// 1-based line numbers, 0 when the side has no line.
    left_no: usize,
    right_no: usize,
};

pub const Options = struct {
    /// Comparison and layout options; `style` is forced to side-by-side.
    diff: diff.Options = .{},
};

fn trivial(c: *const diff.Compared, o: diff.Options, m: *diff.Matchers, it: diff.Item) bool {
    var one = [1]diff.Item{it};
    return diff.analyze(c, o, m, &one).changes == .unchanged;
}

/// The aligned rows of two buffers, in order. The caller frees the slice; the
/// row text borrows `a` and `b` (or the CR-stripped copies when requested, in
/// which case `rowsFromCompared` is the one to use).
pub fn rows(gpa: std.mem.Allocator, text: std.mem.Allocator, a: []const u8, b: []const u8, options: Options) ![]Row {
    var c = try diff.compareData(gpa, a, b, options.diff);
    defer c.deinit();
    // The row text is copied into `text` (use an arena) so that the result
    // does not depend on `c`.
    var m = try diff.Matchers.init(gpa, options.diff);
    defer m.deinit();
    var out: std.ArrayList(Row) = .empty;
    errdefer out.deinit(gpa);
    var p0: usize = 0;
    var p1: usize = 0;
    var k: usize = 0;
    while (k <= c.items.len) : (k += 1) {
        var l0: usize = c.a.count();
        var l1: usize = c.b.count();
        var hunk: ?diff.Item = null;
        if (k < c.items.len and !trivial(&c, options.diff, &m, c.items[k])) {
            hunk = c.items[k];
            l0 = hunk.?.edit.line0;
            l1 = hunk.?.edit.line1;
        } else if (k < c.items.len) continue;
        while (p0 < l0 and p1 < l1) : ({
            p0 += 1;
            p1 += 1;
        }) try out.append(gpa, .{ .marker = .equal, .left = c.a.body(p0), .right = c.b.body(p1), .left_no = p0 + 1, .right_no = p1 + 1 });
        while (p1 < l1) : (p1 += 1) try out.append(gpa, .{ .marker = .right_only, .left = null, .right = c.b.body(p1), .left_no = 0, .right_no = p1 + 1 });
        while (p0 < l0) : (p0 += 1) try out.append(gpa, .{ .marker = .left_only, .left = c.a.body(p0), .right = null, .left_no = p0 + 1, .right_no = 0 });
        if (hunk) |h| {
            const e = h.edit;
            var i: usize = 0;
            while (i < e.deleted and i < e.inserted) : (i += 1) {
                try out.append(gpa, .{ .marker = .changed, .left = c.a.body(e.line0 + i), .right = c.b.body(e.line1 + i), .left_no = e.line0 + i + 1, .right_no = e.line1 + i + 1 });
            }
            var j = i;
            while (j < e.deleted) : (j += 1) try out.append(gpa, .{ .marker = .left_only, .left = c.a.body(e.line0 + j), .right = null, .left_no = e.line0 + j + 1, .right_no = 0 });
            j = i;
            while (j < e.inserted) : (j += 1) try out.append(gpa, .{ .marker = .right_only, .left = null, .right = c.b.body(e.line1 + j), .left_no = 0, .right_no = e.line1 + j + 1 });
            p0 = e.line0 + e.deleted;
            p1 = e.line1 + e.inserted;
        }
    }
    // Copy the text out of `c` (which is freed on return).
    for (out.items) |*r| {
        if (r.left) |t| r.left = try text.dupe(u8, t);
        if (r.right) |t| r.right = try text.dupe(u8, t);
    }
    return out.toOwnedSlice(gpa);
}

/// Write the side-by-side text (what `sdiff FILE1 FILE2` prints).
pub fn list(env: Env, options: Options, a: []const u8, b: []const u8, w: *Io.Writer) !bool {
    var o = options.diff;
    o.style = .side_by_side;
    var c = try diff.compareData(env.gpa, a, b, o);
    defer c.deinit();
    var m = try diff.Matchers.init(env.gpa, o);
    defer m.deinit();
    var p0: usize = 0;
    var p1: usize = 0;
    var differs = false;
    var k: usize = 0;
    while (k <= c.items.len) : (k += 1) {
        var l0: usize = c.a.count();
        var l1: usize = c.b.count();
        if (k < c.items.len) {
            if (trivial(&c, o, &m, c.items[k])) continue;
            l0 = c.items[k].edit.line0;
            l1 = c.items[k].edit.line1;
        }
        try common(w, o, &c, &p0, &p1, l0, l1, null);
        if (k < c.items.len) {
            differs = true;
            const e = c.items[k].edit;
            var i: usize = 0;
            while (i < e.deleted and i < e.inserted) : (i += 1) try diffsbs.row(w, o, c.a.raw(e.line0 + i), '|', c.b.raw(e.line1 + i));
            var j = i;
            while (j < e.deleted) : (j += 1) try diffsbs.row(w, o, c.a.raw(e.line0 + j), '<', null);
            j = i;
            while (j < e.inserted) : (j += 1) try diffsbs.row(w, o, null, '>', c.b.raw(e.line1 + j));
            p0 = e.line0 + e.deleted;
            p1 = e.line1 + e.inserted;
        }
    }
    return differs;
}

fn common(w: *Io.Writer, o: diff.Options, c: *const diff.Compared, p0: *usize, p1: *usize, l0: usize, l1: usize, out: ?*Io.Writer) !void {
    var a = p0.*;
    var b = p1.*;
    while (a != l0 and b != l1) {
        if (!o.suppress_common_lines) {
            if (o.left_column) try diffsbs.row(w, o, c.a.raw(a), '(', null) else try diffsbs.row(w, o, c.a.raw(a), ' ', c.b.raw(b));
        }
        if (out) |ow| try writeLine(ow, c.a.raw(a));
        a += 1;
        b += 1;
    }
    while (b != l1) : (b += 1) {
        if (!o.suppress_common_lines) try diffsbs.row(w, o, null, ')', c.b.raw(b));
    }
    while (a != l0) : (a += 1) {
        if (!o.suppress_common_lines) try diffsbs.row(w, o, c.a.raw(a), '(', null);
        if (out) |ow| try writeLine(ow, c.a.raw(a));
    }
    p0.* = l0;
    p1.* = l1;
}

fn writeLine(w: *Io.Writer, raw: []const u8) Io.Writer.Error!void {
    try w.writeAll(raw);
    if (raw.len == 0 or raw[raw.len - 1] != '\n') try w.writeByte('\n');
}

fn hdr(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, mark: []const u8, name: []const u8, start: usize, count: usize) !void {
    if (count <= 1) try buf.print(gpa, "{s} {s} {d}\n", .{ mark, name, start + 1 }) else try buf.print(gpa, "{s} {s} {d},{d}\n", .{ mark, name, start + 1, start + count });
}

/// Events of the interactive merge worth telling the user about (stderr).
pub const Event = union(enum) {
    /// An unknown command: GNU prints its command summary.
    help,
    /// The editor could not be run.
    editor_failed: []const u8,
};

pub const Observer = @import("common.zig").Observer(Event);

pub const Editor = struct {
    context: ?*anyopaque = null,
    /// Run an editor on `text` (the initial content) and return the edited
    /// content, allocated with `gpa`; null if editing is not possible.
    func: ?*const fn (context: ?*anyopaque, gpa: std.mem.Allocator, text: []const u8) ?[]u8 = null,
};

/// Interactive merge (`sdiff -o`). Rows go to `screen`, the result to `out`,
/// answers come from `answers`. Returns GNU's status: 0 identical, 1 merged,
/// 2 quit early or end of input.
pub fn interact(env: Env, options: Options, names: [2][]const u8, a: []const u8, b: []const u8, screen: *Io.Writer, out: *Io.Writer, answers: *Io.Reader, editor: Editor, observer: Observer) !u8 {
    var o = options.diff;
    o.style = .side_by_side;
    var c = try diff.compareData(env.gpa, a, b, o);
    defer c.deinit();
    var m = try diff.Matchers.init(env.gpa, o);
    defer m.deinit();
    var p0: usize = 0;
    var p1: usize = 0;
    var silent = false;
    var differs = false;
    var k: usize = 0;
    while (k <= c.items.len) : (k += 1) {
        var l0: usize = c.a.count();
        var l1: usize = c.b.count();
        if (k < c.items.len) {
            if (trivial(&c, o, &m, c.items[k])) continue;
            l0 = c.items[k].edit.line0;
            l1 = c.items[k].edit.line1;
        }
        var so = o;
        so.suppress_common_lines = o.suppress_common_lines or silent;
        try common(screen, so, &c, &p0, &p1, l0, l1, out);
        if (k >= c.items.len) break;
        differs = true;
        const e = c.items[k].edit;
        var i: usize = 0;
        while (i < e.deleted and i < e.inserted) : (i += 1) try diffsbs.row(screen, o, c.a.raw(e.line0 + i), '|', c.b.raw(e.line1 + i));
        var j = i;
        while (j < e.deleted) : (j += 1) try diffsbs.row(screen, o, c.a.raw(e.line0 + j), '<', null);
        j = i;
        while (j < e.inserted) : (j += 1) try diffsbs.row(screen, o, null, '>', c.b.raw(e.line1 + j));
        // Prompt until a command settles the hunk.
        while (true) {
            try screen.writeAll("%");
            try screen.flush();
            const line = (answers.takeDelimiter('\n') catch return 2) orelse return 2;
            const cmd = std.mem.trim(u8, line, " \t\r");
            if (cmd.len == 0) {
                observer.emit(.help);
                continue;
            }
            const left_lines = struct {
                fn put(w: *Io.Writer, lines: diff.Lines, start: usize, n: usize) !void {
                    var q: usize = 0;
                    while (q < n) : (q += 1) try writeLine(w, lines.raw(start + q));
                }
            };
            if (std.mem.eql(u8, cmd, "l") or std.mem.eql(u8, cmd, "1")) {
                try left_lines.put(out, c.a, e.line0, e.deleted);
                break;
            } else if (std.mem.eql(u8, cmd, "r") or std.mem.eql(u8, cmd, "2")) {
                try left_lines.put(out, c.b, e.line1, e.inserted);
                break;
            } else if (std.mem.eql(u8, cmd, "q")) {
                return 2;
            } else if (std.mem.eql(u8, cmd, "s")) {
                silent = true;
            } else if (std.mem.eql(u8, cmd, "v")) {
                silent = false;
            } else if (cmd[0] == 'e' and cmd.len <= 2 and (cmd.len == 1 or std.mem.indexOfScalar(u8, "lrbd12", cmd[1]) != null)) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(env.gpa);
                const which: u8 = if (cmd.len == 2) cmd[1] else 'n';
                const want_left = which == 'l' or which == '1' or which == 'b' or which == 'd';
                const want_right = which == 'r' or which == '2' or which == 'b' or which == 'd';
                if (which == 'd') try hdr(&buf, env.gpa, "---", names[0], e.line0, e.deleted);
                if (want_left) {
                    var q: usize = 0;
                    while (q < e.deleted) : (q += 1) {
                        try buf.appendSlice(env.gpa, c.a.raw(e.line0 + q));
                        if (!c.a.terminated(e.line0 + q)) try buf.append(env.gpa, '\n');
                    }
                }
                if (which == 'd') try hdr(&buf, env.gpa, "+++", names[1], e.line1, e.inserted);
                if (want_right) {
                    var q: usize = 0;
                    while (q < e.inserted) : (q += 1) {
                        try buf.appendSlice(env.gpa, c.b.raw(e.line1 + q));
                        if (!c.b.terminated(e.line1 + q)) try buf.append(env.gpa, '\n');
                    }
                }
                const f = editor.func orelse {
                    observer.emit(.{ .editor_failed = "no editor available" });
                    continue;
                };
                const edited = f(editor.context, env.gpa, buf.items) orelse {
                    observer.emit(.{ .editor_failed = "editor failed" });
                    continue;
                };
                defer env.gpa.free(edited);
                try out.writeAll(edited);
                break;
            } else {
                observer.emit(.help);
            }
        }
        p0 = e.line0 + e.deleted;
        p1 = e.line1 + e.inserted;
    }
    try out.flush();
    return if (differs) 1 else 0;
}

/// The side-by-side result as JSON: the aligned rows.
pub fn writeJson(gpa: std.mem.Allocator, w: *Io.Writer, names: [2][]const u8, a: []const u8, b: []const u8, options: Options) !bool {
    var o = options.diff;
    o.style = .side_by_side;
    var c = try diff.compareData(gpa, a, b, o);
    defer c.deinit();
    var m = try diff.Matchers.init(gpa, o);
    defer m.deinit();
    try w.writeAll("{\"files\":[");
    try json.writeString(w, names[0]);
    try w.writeByte(',');
    try json.writeString(w, names[1]);
    try w.writeAll("],\"rows\":[");
    var first = true;
    var differs = false;
    var p0: usize = 0;
    var p1: usize = 0;
    var k: usize = 0;
    const R = struct {
        fn row(w2: *Io.Writer, first_p: *bool, marker: []const u8, left: ?[]const u8, right: ?[]const u8, ln: usize, rn: usize) !void {
            if (!first_p.*) try w2.writeByte(',');
            first_p.* = false;
            try w2.print("{{\"marker\":\"{s}\",\"left_line\":", .{marker});
            if (left != null) try w2.print("{d}", .{ln}) else try w2.writeAll("null");
            try w2.writeAll(",\"left\":");
            try json.writeOptString(w2, left);
            try w2.writeAll(",\"right_line\":");
            if (right != null) try w2.print("{d}", .{rn}) else try w2.writeAll("null");
            try w2.writeAll(",\"right\":");
            try json.writeOptString(w2, right);
            try w2.writeByte('}');
        }
    };
    while (k <= c.items.len) : (k += 1) {
        var l0: usize = c.a.count();
        var l1: usize = c.b.count();
        if (k < c.items.len) {
            if (trivial(&c, o, &m, c.items[k])) continue;
            l0 = c.items[k].edit.line0;
            l1 = c.items[k].edit.line1;
        }
        while (p0 < l0 and p1 < l1) : ({
            p0 += 1;
            p1 += 1;
        }) try R.row(w, &first, "equal", c.a.body(p0), c.b.body(p1), p0 + 1, p1 + 1);
        while (p1 < l1) : (p1 += 1) try R.row(w, &first, "right_only", null, c.b.body(p1), 0, p1 + 1);
        while (p0 < l0) : (p0 += 1) try R.row(w, &first, "left_only", c.a.body(p0), null, p0 + 1, 0);
        if (k < c.items.len) {
            differs = true;
            const e = c.items[k].edit;
            var i: usize = 0;
            while (i < e.deleted and i < e.inserted) : (i += 1) try R.row(w, &first, "changed", c.a.body(e.line0 + i), c.b.body(e.line1 + i), e.line0 + i + 1, e.line1 + i + 1);
            var j = i;
            while (j < e.deleted) : (j += 1) try R.row(w, &first, "left_only", c.a.body(e.line0 + j), null, e.line0 + j + 1, 0);
            j = i;
            while (j < e.inserted) : (j += 1) try R.row(w, &first, "right_only", null, c.b.body(e.line1 + j), 0, e.line1 + j + 1);
            p0 = e.line0 + e.deleted;
            p1 = e.line1 + e.inserted;
        }
    }
    try w.writeAll("]}\n");
    return differs;
}
