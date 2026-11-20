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
        try common(w, o, &c, p0, p1, l0, l1);
        p0 = l0;
        p1 = l1;
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

fn hdr(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, mark: []const u8, name: []const u8, start: usize, count: usize) !void {
    if (count == 0) return;
    if (count == 1) try buf.print(gpa, "{s} {s} {d}\n", .{ mark, name, start + 1 }) else try buf.print(gpa, "{s} {s} {d},{d}\n", .{ mark, name, start + 1, start + count });
}

/// Events of the interactive merge worth telling the user about (stderr).
pub const Event = union(enum) {
    /// An unknown command: GNU prints its command summary.
    help,
    /// The editor could not be run.
    editor_failed: []const u8,
    /// A line of the diff program's output that is not part of the protocol.
    bad_protocol: []const u8,
};

pub const Observer = @import("common.zig").Observer(Event);

pub const Editor = struct {
    context: ?*anyopaque = null,
    /// Run an editor on `text` (the initial content) and return the edited
    /// content, allocated with `gpa`; null if editing is not possible.
    func: ?*const fn (context: ?*anyopaque, gpa: std.mem.Allocator, text: []const u8) ?[]u8 = null,
};

/// A read position in an input file, counted in lines (GNU sdiff copies the
/// raw bytes of the files, so a last line without a newline stays without).
const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    /// The next `n` lines (fewer at the end of the data).
    fn take(c: *Cursor, n: usize) []const u8 {
        const start = c.pos;
        var left = n;
        while (left > 0 and c.pos < c.data.len) {
            if (std.mem.indexOfScalarPos(u8, c.data, c.pos, '\n')) |nl| {
                c.pos = nl + 1;
                left -= 1;
            } else {
                c.pos = c.data.len;
                break;
            }
        }
        return c.data[start..c.pos];
    }
};

const Outcome = enum { done, quit, failed };

/// The prompt and the commands applying to one group of differing lines.
const Session = struct {
    env: Env,
    names: [2][]const u8,
    screen: *Io.Writer,
    out: *Io.Writer,
    answers: *Io.Reader,
    editor: Editor,
    observer: Observer,
    /// Common lines are not shown (`-s`, toggled by the `s` and `v` commands).
    silent: bool,

    fn header(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, mark: []const u8, name: []const u8, start: usize, count: usize) !void {
        return hdr(buf, gpa, mark, name, start, count);
    }

    /// Ask until a command settles the group: `left` and `right` are the
    /// cursors in front of its lines (`llen` and `rlen` of them), `lline` and
    /// `rline` their 1-based numbers.
    fn command(s: *Session, left: *Cursor, right: *Cursor, lline: usize, llen: usize, rline: usize, rlen: usize) !Outcome {
        while (true) {
            try s.screen.writeAll("%");
            try s.screen.flush();
            const line = (s.answers.takeDelimiter('\n') catch return .quit) orelse return .quit;
            const terminated = s.answers.seek > 0 and s.answers.buffer[s.answers.seek - 1] == '\n';
            // GNU skips white space between the letters of a command.
            var cmd_buf: [3]u8 = undefined;
            var cmd_len: usize = 0;
            for (line) |ch| {
                if (ch == ' ' or (ch >= 9 and ch <= 13)) continue;
                if (cmd_len < cmd_buf.len) cmd_buf[cmd_len] = ch;
                cmd_len += 1;
            }
            if (!terminated) {
                // End of input inside a command line: GNU complains, then quits.
                if (cmd_len != 0) {
                    s.observer.emit(.help);
                    try s.screen.writeAll("%");
                    try s.screen.flush();
                }
                return .quit;
            }
            if (cmd_len == 0 or cmd_len > 2) {
                s.observer.emit(.help);
                continue;
            }
            const cmd = cmd_buf[0..cmd_len];
            if (cmd_len == 1 and (cmd[0] == 'l' or cmd[0] == '1')) {
                try s.out.writeAll(left.take(llen));
                _ = right.take(rlen);
                return .done;
            } else if (cmd_len == 1 and (cmd[0] == 'r' or cmd[0] == '2')) {
                try s.out.writeAll(right.take(rlen));
                _ = left.take(llen);
                return .done;
            } else if (cmd_len == 1 and cmd[0] == 'q') {
                return .quit;
            } else if (cmd_len == 1 and cmd[0] == 's') {
                s.silent = true;
            } else if (cmd_len == 1 and cmd[0] == 'v') {
                s.silent = false;
            } else if (cmd[0] == 'e' and (cmd_len == 1 or std.mem.indexOfScalar(u8, "lrbd12", cmd[1]) != null)) {
                const gpa = s.env.gpa;
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(gpa);
                const which: u8 = if (cmd_len == 2) cmd[1] else 'n';
                if (which == 'd') try header(&buf, gpa, "---", s.names[0], lline - 1, llen);
                if (which == 'l' or which == '1' or which == 'b' or which == 'd') try buf.appendSlice(gpa, left.take(llen)) else _ = left.take(llen);
                if (which == 'd') try header(&buf, gpa, "+++", s.names[1], rline - 1, rlen);
                if (which == 'r' or which == '2' or which == 'b' or which == 'd') try buf.appendSlice(gpa, right.take(rlen)) else _ = right.take(rlen);
                const f = s.editor.func orelse {
                    s.observer.emit(.{ .editor_failed = "no editor available" });
                    return .failed;
                };
                const edited = f(s.editor.context, gpa, buf.items) orelse return .failed;
                defer gpa.free(edited);
                try s.out.writeAll(edited);
                return .done;
            } else s.observer.emit(.help);
        }
    }
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
    var s: Session = .{ .env = env, .names = names, .screen = screen, .out = out, .answers = answers, .editor = editor, .observer = observer, .silent = o.suppress_common_lines };
    var left: Cursor = .{ .data = a };
    var right: Cursor = .{ .data = b };
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
        var so = o;
        so.suppress_common_lines = s.silent;
        if (l0 != p0 or l1 != p1) {
            try common(screen, so, &c, p0, p1, l0, l1);
            try out.writeAll(left.take(l0 - p0));
            _ = right.take(l1 - p1);
        }
        p0 = l0;
        p1 = l1;
        if (k >= c.items.len) break;
        differs = true;
        const e = c.items[k].edit;
        var i: usize = 0;
        while (i < e.deleted and i < e.inserted) : (i += 1) try diffsbs.row(screen, o, c.a.raw(e.line0 + i), '|', c.b.raw(e.line1 + i));
        var j = i;
        while (j < e.deleted) : (j += 1) try diffsbs.row(screen, o, c.a.raw(e.line0 + j), '<', null);
        j = i;
        while (j < e.inserted) : (j += 1) try diffsbs.row(screen, o, null, '>', c.b.raw(e.line1 + j));
        switch (try s.command(&left, &right, e.line0 + 1, e.deleted, e.line1 + 1, e.inserted)) {
            .done => {},
            .quit, .failed => {
                try out.flush();
                return 2;
            },
        }
        p0 = e.line0 + e.deleted;
        p1 = e.line1 + e.inserted;
    }
    try out.flush();
    return if (differs) 1 else 0;
}

fn parseCount(t: []const u8) ?usize {
    if (t.len == 0) return null;
    var v: usize = 0;
    for (t) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
        v = std.math.mul(usize, v, 10) catch return null;
        v = std.math.add(usize, v, ch - '0') catch return null;
    }
    return v;
}

/// The same merge driven by the output of a `--sdiff-merge-assist` diff
/// program (`protocol`): `iL,R` and `cL,R` lines, each followed by max(L,R)
/// rows of side-by-side text. Returns 0 when it ran to the end, 2 on a quit,
/// a failed editor or a malformed protocol (reported through `observer`).
pub fn interactExternal(env: Env, options: Options, names: [2][]const u8, a: []const u8, b: []const u8, protocol: []const u8, screen: *Io.Writer, out: *Io.Writer, answers: *Io.Reader, editor: Editor, observer: Observer) !u8 {
    var s: Session = .{ .env = env, .names = names, .screen = screen, .out = out, .answers = answers, .editor = editor, .observer = observer, .silent = options.diff.suppress_common_lines };
    var left: Cursor = .{ .data = a };
    var right: Cursor = .{ .data = b };
    var proto: Cursor = .{ .data = protocol };
    var lline: usize = 1;
    var rline: usize = 1;
    var status: u8 = 0;
    while (proto.pos < protocol.len) {
        const nl = std.mem.indexOfScalarPos(u8, protocol, proto.pos, '\n') orelse {
            observer.emit(.{ .bad_protocol = protocol[proto.pos..] });
            status = 2;
            break;
        };
        const line = protocol[proto.pos..nl];
        proto.pos = nl + 1;
        if (line.len > 0 and line[0] == ' ') {
            try screen.writeAll(line[1..]);
            try screen.writeByte('\n');
            continue;
        }
        const comma = std.mem.indexOfScalar(u8, line, ',');
        const llen = if (line.len > 1 and comma != null) parseCount(line[1..comma.?]) else null;
        const rlen = if (comma) |cm| parseCount(line[cm + 1 ..]) else null;
        if (line.len == 0 or llen == null or rlen == null or (line[0] != 'i' and line[0] != 'c')) {
            observer.emit(.{ .bad_protocol = line });
            status = 2;
            break;
        }
        const lenmax = @max(llen.?, rlen.?);
        const rows_text = proto.take(lenmax);
        if (line[0] == 'i') {
            if (!s.silent) try screen.writeAll(rows_text);
            try out.writeAll(left.take(llen.?));
            _ = right.take(rlen.?);
        } else {
            try screen.writeAll(rows_text);
            switch (try s.command(&left, &right, lline, llen.?, rline, rlen.?)) {
                .done => {},
                .quit, .failed => {
                    status = 2;
                    break;
                },
            }
        }
        lline += llen.?;
        rline += rlen.?;
    }
    try out.flush();
    return status;
}

fn common(w: *Io.Writer, o: diff.Options, c: *const diff.Compared, p0: usize, p1: usize, l0: usize, l1: usize) !void {
    if (o.suppress_common_lines) return;
    var a = p0;
    var b = p1;
    if (!o.left_column) {
        while (a != l0 and b != l1) {
            try diffsbs.row(w, o, c.a.raw(a), ' ', c.b.raw(b));
            a += 1;
            b += 1;
        }
        while (b != l1) : (b += 1) try diffsbs.row(w, o, null, ')', c.b.raw(b));
    }
    while (a != l0) : (a += 1) try diffsbs.row(w, o, c.a.raw(a), '(', null);
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
