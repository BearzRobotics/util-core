// SPDX-License-Identifier: GPL-2.0-or-later
//! The model of a `less`-style pager: a text that can still grow, the
//! scroll position, line wrapping, search, and drawing a frame. It serves the
//! `less` command and the paging of `cat`, so a long file scrolls on every
//! platform without a separate download.
//!
//! Decision 0004: this module is logic only. It never reads a terminal, never
//! spawns a thread and never writes anywhere but the writer it is given.
//! `src/pager_ui.zig` puts the terminal in raw mode, feeds bytes to the
//! `KeyParser`, calls `append` as data arrives and `render` after each change.
//!
//! The text is appended while the user scrolls (`append`), so a pipe can be
//! read and paged at the same time. Lines are wrapped to the terminal width
//! (or chopped with `Options.chop`), tabs expand to 8 columns, escape
//! sequences of colour (`raw`) cost no width.
//!
//! Keys: space f ^F PgDn page down; b ^B PgUp page up; d ^D / u ^U half page;
//! j e ^N Enter Down / k y ^P Up one row; g < Home top; G > End bottom;
//! / ? search forward / backward; n N repeat; F follow (^X ^C end it);
//! = position; r R ^L redraw; h help line; q Q ^C quit.

const std = @import("std");
const Io = std.Io;

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    page_up,
    page_down,
    half_up,
    half_down,
    home,
    end,
    enter,
    escape,
    backspace,
    redraw,
    interrupt,
};

/// Turns terminal bytes into keys, understanding the common escape sequences
/// (`ESC [ A`, `ESC O A`, `ESC [ 5 ~`, ...).
pub const KeyParser = struct {
    state: enum { ground, esc, csi } = .ground,
    num: u16 = 0,

    pub fn feed(p: *KeyParser, b: u8) ?Key {
        switch (p.state) {
            .ground => switch (b) {
                0x1b => {
                    p.state = .esc;
                    return null;
                },
                0x03 => return .interrupt,
                0x02 => return .page_up,
                0x04 => return .half_down,
                0x06 => return .page_down,
                0x0c => return .redraw,
                0x0e => return .down,
                0x10 => return .up,
                0x15 => return .half_up,
                0x0a, 0x0d => return .enter,
                0x08, 0x7f => return .backspace,
                else => return .{ .char = b },
            },
            .esc => {
                if (b == '[' or b == 'O') {
                    p.state = .csi;
                    p.num = 0;
                    return null;
                }
                // A lone ESC (the byte after it is dropped).
                p.state = .ground;
                return .escape;
            },
            .csi => {
                if (b >= '0' and b <= '9') {
                    p.num = p.num *| 10 +| (b - '0');
                    return null;
                }
                if (b == ';') {
                    p.num = 0;
                    return null;
                }
                p.state = .ground;
                return switch (b) {
                    'A' => .up,
                    'B' => .down,
                    'H' => .home,
                    'F' => .end,
                    '~' => switch (p.num) {
                        1, 7 => .home,
                        4, 8 => .end,
                        5 => .page_up,
                        6 => .page_down,
                        else => null,
                    },
                    else => null,
                };
            },
        }
    }
};

pub const Action = enum { none, redraw, quit };

pub const Case = enum { sensitive, smart, ignore };

pub const Options = struct {
    /// Cut long lines at the terminal edge instead of wrapping (less -S).
    chop: bool = false,
    /// Pass colour escape sequences through (less -R); otherwise control
    /// characters are shown as ^X.
    raw: bool = false,
    /// Number the lines (less -N).
    numbers: bool = false,
    /// less -i is `smart`, -I `ignore`.
    case: Case = .sensitive,
};

const tab_stop = 8;
const number_cols = 7; // "%6d "

const Pos = struct { line: usize, sub: usize };

pub const Pager = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    text: std.ArrayList(u8) = .empty,
    /// Offset of the start of each line in `text`.
    starts: std.ArrayList(usize) = .empty,
    /// Cached count of screen rows per line; 0 = not computed.
    rowc: std.ArrayList(u32) = .empty,
    at_line_start: bool = true,
    rows: usize,
    cols: usize,
    top: usize = 0,
    sub: usize = 0,
    /// All the input has arrived.
    eof: bool = false,
    /// Follow mode: new data is read as it comes, and the view moves with it
    /// while it is at the bottom. The keys keep working.
    follow: bool = false,
    /// The input is a file that may still grow after `finish`.
    growing: bool = false,
    mode: enum { browse, input } = .browse,
    forward: bool = true,
    input: std.ArrayList(u8) = .empty,
    pattern: std.ArrayList(u8) = .empty,
    message: []const u8 = "",
    msg_buf: [96]u8 = undefined,
    name: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, opts: Options, rows: usize, cols: usize) Pager {
        return .{ .gpa = gpa, .opts = opts, .rows = @max(rows, 2), .cols = @max(cols, 1) };
    }

    pub fn deinit(p: *Pager) void {
        p.text.deinit(p.gpa);
        p.starts.deinit(p.gpa);
        p.rowc.deinit(p.gpa);
        p.input.deinit(p.gpa);
        p.pattern.deinit(p.gpa);
    }

    pub fn lineCount(p: *const Pager) usize {
        return p.starts.items.len;
    }

    /// Add more input. Returns true when the visible screen or the status may
    /// have changed (so the caller should redraw).
    pub fn append(p: *Pager, bytes: []const u8) !bool {
        if (bytes.len == 0) return false;
        const was_full = p.screenFull();
        // Only a view that is at the end moves with the data.
        const pinned = p.follow and p.atBottom();
        const base = p.text.items.len;
        try p.text.appendSlice(p.gpa, bytes);
        // The line that was still open grows.
        if (p.rowc.items.len > 0 and !p.at_line_start) p.rowc.items[p.rowc.items.len - 1] = 0;
        for (bytes, 0..) |c, k| {
            if (p.at_line_start) {
                try p.starts.append(p.gpa, base + k);
                try p.rowc.append(p.gpa, 0);
                p.at_line_start = false;
            }
            if (c == '\n') p.at_line_start = true;
        }
        if (pinned) {
            p.toBottom();
            return true;
        }
        return !was_full;
    }

    /// The input has ended.
    pub fn finish(p: *Pager) void {
        p.eof = true;
        if (!p.growing) p.follow = false;
    }

    fn textCols(p: *const Pager) usize {
        const used: usize = if (p.opts.numbers) number_cols else 0;
        return if (p.cols > used) p.cols - used else 1;
    }

    fn body(p: *const Pager) usize {
        return p.rows - 1;
    }

    /// Line `i` without its newline.
    pub fn line(p: *const Pager, i: usize) []const u8 {
        const a = p.starts.items[i];
        var b = if (i + 1 < p.starts.items.len) p.starts.items[i + 1] else p.text.items.len;
        if (b > a and p.text.items[b - 1] == '\n') b -= 1;
        if (b > a and p.text.items[b - 1] == '\r') b -= 1;
        return p.text.items[a..b];
    }

    /// Display width of one byte at column `col` (0 for the continuation
    /// bytes of a UTF-8 character).
    fn byteWidth(_: *const Pager, b: u8, col: usize) usize {
        if (b == '\t') return tab_stop - col % tab_stop;
        if (b >= 0x80) return if (b >= 0xc0) 1 else 0;
        if (b < 0x20 or b == 0x7f) return 2; // ^X
        return 1;
    }

    /// Length in bytes of an escape sequence at the start of `s` (0 if none).
    fn escLen(s: []const u8) usize {
        if (s.len < 2 or s[0] != 0x1b or s[1] != '[') return 0;
        var k: usize = 2;
        while (k < s.len and !(s[k] >= 0x40 and s[k] <= 0x7e)) k += 1;
        return if (k < s.len) k + 1 else s.len;
    }

    /// Byte offset where the screen row that starts at `start` ends.
    fn rowEnd(p: *const Pager, ln: []const u8, start: usize) usize {
        const width = p.textCols();
        var i = start;
        var col: usize = 0;
        while (i < ln.len) {
            if (p.opts.raw) {
                const e = escLen(ln[i..]);
                if (e > 0) {
                    i += e;
                    continue;
                }
            }
            const w = p.byteWidth(ln[i], col);
            if (col + w > width and col > 0) break;
            col += w;
            i += 1;
        }
        return i;
    }

    fn rowsOf(p: *Pager, i: usize) usize {
        if (p.opts.chop) return 1;
        if (p.rowc.items[i] != 0) return p.rowc.items[i];
        const ln = p.line(i);
        var n: usize = 1;
        var at: usize = 0;
        while (true) {
            const e = p.rowEnd(ln, at);
            if (e >= ln.len) break;
            at = e;
            n += 1;
        }
        p.rowc.items[i] = @intCast(n);
        return n;
    }

    fn stepDown(p: *Pager, pos: *Pos) bool {
        if (pos.sub + 1 < p.rowsOf(pos.line)) {
            pos.sub += 1;
            return true;
        }
        if (pos.line + 1 < p.lineCount()) {
            pos.line += 1;
            pos.sub = 0;
            return true;
        }
        return false;
    }

    fn stepUp(p: *Pager, pos: *Pos) bool {
        if (pos.sub > 0) {
            pos.sub -= 1;
            return true;
        }
        if (pos.line > 0) {
            pos.line -= 1;
            pos.sub = p.rowsOf(pos.line) - 1;
            return true;
        }
        return false;
    }

    /// The topmost position that still shows the last row at the bottom.
    fn bottomPos(p: *Pager) Pos {
        if (p.lineCount() == 0) return .{ .line = 0, .sub = 0 };
        var pos: Pos = .{ .line = p.lineCount() - 1, .sub = p.rowsOf(p.lineCount() - 1) - 1 };
        var k: usize = 1;
        while (k < p.body()) : (k += 1) {
            if (!p.stepUp(&pos)) break;
        }
        return pos;
    }

    fn toBottom(p: *Pager) void {
        const b = p.bottomPos();
        p.top = b.line;
        p.sub = b.sub;
    }

    fn atBottom(p: *Pager) bool {
        const b = p.bottomPos();
        return p.top > b.line or (p.top == b.line and p.sub >= b.sub);
    }

    /// The text fills the screen already.
    fn screenFull(p: *Pager) bool {
        var pos: Pos = .{ .line = p.top, .sub = p.sub };
        if (p.lineCount() == 0) return false;
        var k: usize = 1;
        while (k < p.body()) : (k += 1) {
            if (!p.stepDown(&pos)) return false;
        }
        return true;
    }

    /// The whole text fits on one screen: no pager is needed (less -F).
    pub fn fits(p: *Pager) bool {
        var total: usize = 0;
        for (0..p.lineCount()) |i| {
            total += p.rowsOf(i);
            if (total > p.rows) return false;
        }
        return true;
    }

    pub fn resize(p: *Pager, rows: usize, cols: usize) void {
        const nr = @max(rows, 2);
        const nc = @max(cols, 1);
        if (nr == p.rows and nc == p.cols) return;
        p.rows = nr;
        if (nc != p.cols) {
            p.cols = nc;
            @memset(p.rowc.items, 0);
            p.sub = 0;
        }
        if (p.atBottom()) p.toBottom();
    }

    fn scrollRows(p: *Pager, delta: isize) void {
        var pos: Pos = .{ .line = p.top, .sub = p.sub };
        const limit = p.bottomPos();
        var n: usize = @abs(delta);
        if (delta > 0) {
            while (n > 0) : (n -= 1) {
                if (pos.line > limit.line or (pos.line == limit.line and pos.sub >= limit.sub)) break;
                if (!p.stepDown(&pos)) break;
            }
        } else {
            while (n > 0) : (n -= 1) {
                if (!p.stepUp(&pos)) break;
            }
        }
        p.top = pos.line;
        p.sub = pos.sub;
    }

    pub fn key(p: *Pager, k: Key) Action {
        p.message = "";
        if (p.mode == .input) return p.inputKey(k);
        // ^C and ^X end following; every other key does what it always does.
        if (p.follow and (k == .interrupt or (k == .char and k.char == 0x18))) {
            p.follow = false;
            return .redraw;
        }
        const page: isize = @intCast(p.body());
        const half: isize = @intCast(@max(p.body() / 2, 1));
        switch (k) {
            .interrupt => return .quit,
            .char => |c| switch (c) {
                'q', 'Q' => return .quit,
                ' ', 'f' => p.scrollRows(page),
                'b' => p.scrollRows(-page),
                'd' => p.scrollRows(half),
                'u' => p.scrollRows(-half),
                'j', 'e' => p.scrollRows(1),
                'k', 'y' => p.scrollRows(-1),
                'g', '<' => {
                    p.top = 0;
                    p.sub = 0;
                },
                'G', '>' => p.toBottom(),
                'F' => {
                    p.follow = true;
                    p.toBottom();
                },
                '/', '?' => {
                    p.mode = .input;
                    p.forward = c == '/';
                    p.input.clearRetainingCapacity();
                },
                'n' => p.findNext(p.forward),
                'N' => p.findNext(!p.forward),
                '=' => p.message = std.fmt.bufPrint(&p.msg_buf, "{s}line {d}/{d}{s}", .{
                    if (p.name.len > 0 and p.name.len < 40) p.name else "",
                    p.top + 1,
                    p.lineCount(),
                    if (p.eof) "" else "+",
                }) catch "",
                'r', 'R' => {},
                'h', 'H' => p.message = "q quit  space/b page  d/u half  j/k row  g/G ends  / ? search  n/N next  F follow",
                else => return .none,
            },
            .page_down => p.scrollRows(page),
            .page_up => p.scrollRows(-page),
            .half_down => p.scrollRows(half),
            .half_up => p.scrollRows(-half),
            .down, .enter => p.scrollRows(1),
            .up => p.scrollRows(-1),
            .home => {
                p.top = 0;
                p.sub = 0;
            },
            .end => p.toBottom(),
            .redraw => {},
            .escape, .backspace => return .none,
        }
        return .redraw;
    }

    fn inputKey(p: *Pager, k: Key) Action {
        switch (k) {
            .interrupt, .escape => p.mode = .browse,
            .enter => {
                p.mode = .browse;
                if (p.input.items.len > 0) {
                    p.pattern.clearRetainingCapacity();
                    p.pattern.appendSlice(p.gpa, p.input.items) catch {};
                }
                p.findNext(p.forward);
            },
            .backspace => {
                if (p.input.items.len == 0) p.mode = .browse else _ = p.input.pop();
            },
            .char => |c| if (c >= 0x20) p.input.append(p.gpa, c) catch {},
            else => {},
        }
        return .redraw;
    }

    fn ignoreCase(p: *const Pager) bool {
        return switch (p.opts.case) {
            .sensitive => false,
            .ignore => true,
            .smart => for (p.pattern.items) |c| {
                if (std.ascii.isUpper(c)) break false;
            } else true,
        };
    }

    /// Does line `i`, with escape sequences removed, contain the pattern?
    fn lineMatches(p: *const Pager, i: usize) bool {
        var buf: [4096]u8 = undefined;
        const raw = p.line(i);
        var n: usize = 0;
        var k: usize = 0;
        while (k < raw.len and n < buf.len) {
            const e = escLen(raw[k..]);
            if (e > 0) {
                k += e;
                continue;
            }
            buf[n] = raw[k];
            n += 1;
            k += 1;
        }
        const hay = buf[0..n];
        if (p.ignoreCase()) return std.ascii.findIgnoreCase(hay, p.pattern.items) != null;
        return std.mem.indexOf(u8, hay, p.pattern.items) != null;
    }

    fn findNext(p: *Pager, forward: bool) void {
        if (p.pattern.items.len == 0) {
            p.message = "No previous search pattern";
            return;
        }
        const n = p.lineCount();
        if (n == 0) return;
        var i = p.top;
        var step: usize = 0;
        while (step + 1 < n) : (step += 1) {
            if (forward) {
                i += 1;
                if (i >= n) break; // no wrap: the end of the data
            } else {
                if (i == 0) break;
                i -= 1;
            }
            if (p.lineMatches(i)) {
                p.top = i;
                p.sub = 0;
                if (p.top > p.bottomPos().line) p.toBottom();
                return;
            }
        }
        p.message = "Pattern not found";
    }

    /// The control sequences that are in effect at byte `upto` of `ln`
    /// (colours set earlier in the line), to restore on a wrapped row.
    fn activeStyle(ln: []const u8, upto: usize, buf: []u8) []const u8 {
        var len: usize = 0;
        var i: usize = 0;
        while (i < upto) {
            const e = escLen(ln[i..upto]);
            if (e == 0) {
                i += 1;
                continue;
            }
            const seq = ln[i .. i + e];
            i += e;
            if (seq[seq.len - 1] != 'm') continue;
            if (seq.len <= 4 and (seq.len == 3 or seq[2] == '0')) {
                len = 0; // ESC[m or ESC[0m resets
                continue;
            }
            if (len + seq.len <= buf.len) {
                @memcpy(buf[len .. len + seq.len], seq);
                len += seq.len;
            }
        }
        return buf[0..len];
    }

    /// Write bytes [start, end) of `ln` as one screen row: tabs expanded,
    /// control characters as ^X unless `raw`, clipped at the row width.
    fn emitRow(p: *const Pager, w: *Io.Writer, ln: []const u8, start: usize, end: usize) Io.Writer.Error!void {
        const width = p.textCols();
        var col: usize = 0;
        var i = start;
        while (i < end) {
            if (p.opts.raw) {
                const e = escLen(ln[i..end]);
                if (e > 0) {
                    try w.writeAll(ln[i .. i + e]);
                    i += e;
                    continue;
                }
            }
            const b = ln[i];
            const cw = p.byteWidth(b, col);
            if (col + cw > width and cw > 0) {
                if (p.opts.chop) break; // clipped
            }
            if (b == '\t') {
                try w.splatByteAll(' ', cw);
            } else if (b < 0x20 or b == 0x7f) {
                try w.writeByte('^');
                try w.writeByte(if (b == 0x7f) '?' else b + '@');
            } else try w.writeByte(b);
            col += cw;
            i += 1;
        }
    }

    /// Write all the lines to a screen that is not being paged (less -F):
    /// each as `render` would show it, one after another, with no cursor
    /// positioning and the terminal left to wrap them.
    pub fn print(p: *const Pager, w: *Io.Writer) Io.Writer.Error!void {
        for (0..p.lineCount()) |i| {
            const ln = p.line(i);
            if (p.opts.numbers) try w.print("\x1b[90m{d: >6} \x1b[0m", .{i + 1});
            try p.emitRow(w, ln, 0, ln.len);
            if (p.opts.raw and std.mem.indexOfScalar(u8, ln, 0x1b) != null) try w.writeAll("\x1b[0m");
            // The last line may still be without its newline.
            if (i + 1 < p.lineCount() or p.at_line_start) try w.writeByte('\n');
        }
    }

    /// Draw the whole frame at the top of the screen: the visible rows and
    /// the status row.
    pub fn render(p: *Pager, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("\x1b[H");
        var pos: Pos = .{ .line = p.top, .sub = p.sub };
        var have = p.lineCount() > 0;
        for (0..p.body()) |_| {
            // Clear the row before drawing it: line wrapping is off, so after
            // a full row the cursor is still on the last column, and clearing
            // then would erase the character there.
            try w.writeAll("\x1b[K");
            if (have) {
                const ln = p.line(pos.line);
                // Where does this screen row start and end inside the line?
                var start: usize = 0;
                var k: usize = 0;
                while (k < pos.sub and !p.opts.chop) : (k += 1) start = p.rowEnd(ln, start);
                const end = if (p.opts.chop) ln.len else p.rowEnd(ln, start);
                if (p.opts.numbers) {
                    if (pos.sub == 0) try w.print("\x1b[90m{d: >6} \x1b[0m", .{pos.line + 1}) else try w.splatByteAll(' ', number_cols);
                }
                if (start > 0 and p.opts.raw) {
                    var sb: [256]u8 = undefined;
                    try w.writeAll(activeStyle(ln, start, &sb));
                }
                try p.emitRow(w, ln, start, end);
                try w.writeAll("\x1b[0m");
                have = p.stepDown(&pos);
            } else try w.writeAll("~");
            try w.writeAll("\r\n");
        }
        try w.writeAll("\x1b[K");
        if (p.mode == .input) {
            try w.writeByte(if (p.forward) '/' else '?');
            try w.writeAll(p.input.items);
        } else if (p.message.len > 0) {
            try w.print("\x1b[7m{s}\x1b[0m", .{p.message});
        } else if (p.follow) {
            try w.writeAll(if (p.atBottom())
                "\x1b[7mWaiting for data... (^X or ^C to stop)\x1b[0m"
            else
                "\x1b[7mFollowing (G: go to the end, ^X or ^C: stop)\x1b[0m");
        } else if (p.eof and p.atBottom()) {
            try w.writeAll("\x1b[7m(END)\x1b[0m");
        } else try w.writeByte(':');
    }

    /// Switch to the alternate screen with line wrapping off.
    pub fn enter(w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("\x1b[?1049h\x1b[?7l\x1b[2J");
    }

    /// Back to the normal screen.
    pub fn leave(w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("\x1b[?7h\x1b[?1049l");
    }
};

test "key parser: sequences and plain keys" {
    var p: KeyParser = .{};
    try std.testing.expectEqual(@as(?Key, .{ .char = 'q' }), p.feed('q'));
    try std.testing.expectEqual(@as(?Key, null), p.feed(0x1b));
    try std.testing.expectEqual(@as(?Key, null), p.feed('['));
    try std.testing.expectEqual(@as(?Key, .up), p.feed('A'));
    try std.testing.expectEqual(@as(?Key, null), p.feed(0x1b));
    try std.testing.expectEqual(@as(?Key, null), p.feed('['));
    try std.testing.expectEqual(@as(?Key, null), p.feed('6'));
    try std.testing.expectEqual(@as(?Key, .page_down), p.feed('~'));
    try std.testing.expectEqual(@as(?Key, .interrupt), p.feed(3));
}

fn feedLines(p: *Pager, n: usize) !void {
    for (0..n) |i| {
        var b: [32]u8 = undefined;
        _ = try p.append(try std.fmt.bufPrint(&b, "line {d}\n", .{i}));
    }
}

test "pager: scrolling, ends and fits" {
    const gpa = std.testing.allocator;
    var p = Pager.init(gpa, .{}, 11, 80); // 10 body rows
    defer p.deinit();
    try feedLines(&p, 100);
    p.finish();
    try std.testing.expectEqual(@as(usize, 100), p.lineCount());
    try std.testing.expect(!p.fits());
    try std.testing.expectEqual(Action.redraw, p.key(.{ .char = ' ' }));
    try std.testing.expectEqual(@as(usize, 10), p.top);
    _ = p.key(.{ .char = 'j' });
    try std.testing.expectEqual(@as(usize, 11), p.top);
    _ = p.key(.{ .char = 'b' });
    try std.testing.expectEqual(@as(usize, 1), p.top);
    _ = p.key(.{ .char = 'G' });
    try std.testing.expectEqual(@as(usize, 90), p.top);
    _ = p.key(.{ .char = 'j' }); // stays at the end
    try std.testing.expectEqual(@as(usize, 90), p.top);
    _ = p.key(.{ .char = 'g' });
    try std.testing.expectEqual(@as(usize, 0), p.top);
    try std.testing.expectEqual(Action.quit, p.key(.{ .char = 'q' }));

    var q = Pager.init(gpa, .{}, 11, 80);
    defer q.deinit();
    try feedLines(&q, 5);
    try std.testing.expect(q.fits());
}

test "pager: a row that fills the window is not cleared after it is drawn" {
    const gpa = std.testing.allocator;
    for ([_]bool{ false, true }) |chop| {
        var p = Pager.init(gpa, .{ .chop = chop }, 4, 10);
        defer p.deinit();
        _ = try p.append("abcdefghiZ\n");
        p.finish();
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try p.render(&aw.writer);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[KabcdefghiZ\x1b[0m\r\n") != null);
    }
}

test "pager: long lines wrap into rows and scroll by row" {
    const gpa = std.testing.allocator;
    var p = Pager.init(gpa, .{}, 4, 10); // 3 body rows, 10 columns
    defer p.deinit();
    _ = try p.append("aaaaaaaaaabbbbbbbbbbcc\nsecond\nthird\nfourth\n");
    p.finish();
    try std.testing.expectEqual(@as(usize, 3), p.rowsOf(0)); // 22 bytes in 10 columns
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try p.render(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "aaaaaaaaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "bbbbbbbbbb") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "second") == null);
    _ = p.key(.down);
    try std.testing.expectEqual(@as(usize, 1), p.sub);
    _ = p.key(.{ .char = 'G' });
    aw.clearRetainingCapacity();
    try p.render(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "fourth") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "(END)") != null);
}

test "pager: chop clips at the width" {
    const gpa = std.testing.allocator;
    var p = Pager.init(gpa, .{ .chop = true }, 3, 5);
    defer p.deinit();
    _ = try p.append("0123456789\nxy\n");
    p.finish();
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try p.render(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "01234\x1b") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "56789") == null);
}

test "pager: colour escapes cost no width and are restored on wrapped rows" {
    const gpa = std.testing.allocator;
    var p = Pager.init(gpa, .{ .raw = true }, 4, 6);
    defer p.deinit();
    _ = try p.append("\x1b[31mabcdefghij\x1b[0m\n");
    p.finish();
    try std.testing.expectEqual(@as(usize, 2), p.rowsOf(0));
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try p.render(&aw.writer);
    // The second row starts with the colour again.
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[31mghij") != null);
}

test "pager: growing input and follow" {
    const gpa = std.testing.allocator;
    var p = Pager.init(gpa, .{}, 4, 80);
    defer p.deinit();
    try std.testing.expect(try p.append("one\n"));
    try std.testing.expect(try p.append("two\n")); // screen not full yet: redraw
    _ = try p.append("three\nfour\nfive\n");
    try std.testing.expect(!(try p.append("six\n"))); // full and not following: no redraw
    _ = p.key(.{ .char = 'F' });
    try std.testing.expect(p.follow);
    try std.testing.expect(try p.append("seven\n"));
    try std.testing.expectEqual(@as(usize, 4), p.top); // 7 lines, 3 body rows
    // Scrolling back keeps following, and the view stays where it was put.
    _ = p.key(.up);
    try std.testing.expect(p.follow);
    try std.testing.expectEqual(@as(usize, 3), p.top);
    try std.testing.expect(!(try p.append("eight\n")));
    try std.testing.expectEqual(@as(usize, 3), p.top);
    // Back at the end, the view moves with the data again.
    _ = p.key(.{ .char = 'G' });
    try std.testing.expect(try p.append("nine\n"));
    try std.testing.expectEqual(@as(usize, 6), p.top);
    // A growing file is still followed at its present end; a stream is not.
    p.growing = true;
    p.finish();
    try std.testing.expect(p.follow);
    try std.testing.expectEqual(Action.redraw, p.key(.interrupt)); // ends following only
    try std.testing.expect(!p.follow);
    _ = p.key(.{ .char = 'F' });
    _ = p.key(.{ .char = 0x18 }); // ^X
    try std.testing.expect(!p.follow);
    _ = p.key(.{ .char = 'F' });
    try std.testing.expectEqual(Action.quit, p.key(.{ .char = 'q' }));
    p.follow = false;
    p.growing = false;
    // A partial line keeps growing in place.
    _ = try p.append("par");
    _ = try p.append("tial\n");
    try std.testing.expectEqual(@as(usize, 10), p.lineCount());
    try std.testing.expectEqualStrings("partial", p.line(9));
}

test "pager: search ignores escape sequences, smart case, no wrap" {
    const gpa = std.testing.allocator;
    var p = Pager.init(gpa, .{ .case = .smart, .raw = true }, 3, 80); // 2 body rows
    defer p.deinit();
    _ = try p.append("alpha\n\x1b[31mbe\x1b[0mta\nGamma\nalpha again\n");
    p.finish();
    _ = p.key(.{ .char = '/' });
    for ("beta") |c| _ = p.key(.{ .char = c });
    _ = p.key(.enter);
    try std.testing.expectEqual(@as(usize, 1), p.top);
    _ = p.key(.{ .char = '/' });
    for ("gamma") |c| _ = p.key(.{ .char = c }); // lower case: ignores case
    _ = p.key(.enter);
    try std.testing.expectEqual(@as(usize, 2), p.top);
    _ = p.key(.{ .char = '/' });
    for ("zzz") |c| _ = p.key(.{ .char = c });
    _ = p.key(.enter);
    try std.testing.expectEqualStrings("Pattern not found", p.message);
}

test "pager: printing without paging filters like a drawn row" {
    const gpa = std.testing.allocator;
    var p = Pager.init(gpa, .{}, 10, 80);
    defer p.deinit();
    _ = try p.append("a\x1b]0;t\x07\rb\r\n\x1b[2Jend");
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try p.print(&aw.writer);
    try std.testing.expectEqualStrings("a^[]0;t^G^Mb\n^[[2Jend", aw.written());
}

test "pager: control characters are shown as ^X without raw" {
    const gpa = std.testing.allocator;
    var p = Pager.init(gpa, .{}, 3, 80);
    defer p.deinit();
    _ = try p.append("a\x1bb\tc\n");
    p.finish();
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try p.render(&aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "a^[b ") != null);
}
