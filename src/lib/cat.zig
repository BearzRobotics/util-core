// SPDX-License-Identifier: GPL-2.0-or-later
//! cat library (decision 0004): concatenate inputs to a writer. References:
//! GNU coreutils cat(1), POSIX cat, and bat(1) for the terminal view.
//!
//! Two output paths:
//!   * GNU path (the default, `Options.view == null`): byte-for-byte GNU
//!     behaviour. With no formatting option the input is copied in large
//!     chunks without inspection. With any of show_ends, number,
//!     number_nonblank, show_tabs, show_nonprinting or squeeze_blank each
//!     byte goes through a small state machine whose state (line start, line
//!     number, blank-line run) persists across inputs, because GNU cat treats
//!     the inputs as one stream.
//!   * bat view (`Options.view != null`): a documented extension (decision
//!     0005): header, grid and line numbers per `View.style`, optional syntax
//!     highlighting through a grammar `Session`. The host decides when to use
//!     it (the cat command: stdout is a terminal and no GNU formatting option
//!     was given); the library never inspects the terminal or the environment.

const std = @import("std");
const quote = @import("../quote.zig");
const Io = std.Io;
const common = @import("common.zig");
const stickyout = @import("stickyout.zig");
const syntax = @import("../syntax/root.zig");
const gitchanges = @import("gitchanges.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Options = struct {
    number: bool = false, // -n
    number_nonblank: bool = false, // -b (wins over -n)
    show_ends: bool = false, // -E
    show_tabs: bool = false, // -T
    show_nonprinting: bool = false, // -v
    squeeze_blank: bool = false, // -s
    /// Terminal view (an extension, decision 0005); null: GNU output.
    view: ?View = null,

    /// Any GNU formatting option forces the GNU path, even on a terminal.
    pub fn gnuFormatting(o: Options) bool {
        return !o.plain();
    }

    pub fn plain(o: Options) bool {
        return !(o.number or o.number_nonblank or o.show_ends or o.show_tabs or
            o.show_nonprinting or o.squeeze_blank);
    }
};

const Formatter = struct {
    opts: Options,
    out: *stickyout.Out,
    at_line_start: bool = true,
    prev_line_blank: bool = false,
    line_no: u64 = 0,
    /// -E shows a carriage return that directly precedes a newline as "^M".
    /// A '\r' at the end of a chunk is held back until the next byte (which
    /// may be in the next chunk or the next file) says which it is.
    pending_cr: bool = false,

    /// Call after the last input: a held-back '\r' was not followed by '\n'.
    fn finish(f: *Formatter) void {
        if (f.pending_cr) f.out.writeByte('\r');
        f.pending_cr = false;
    }

    /// Resolve a held-back '\r' given the next byte.
    fn resolveCr(f: *Formatter, next: u8) void {
        f.pending_cr = false;
        if (next == '\n') f.out.write("^M") else f.out.writeByte('\r');
    }

    fn feed(f: *Formatter, bytes: []const u8) void {
        // -v and -T rewrite bytes inside lines, so they need the byte loop;
        // everything else only treats '\n' specially and can copy whole runs.
        if (f.opts.show_nonprinting or f.opts.show_tabs) return f.feedBytes(bytes);
        var i: usize = 0;
        while (i < bytes.len) {
            if (f.pending_cr) f.resolveCr(bytes[i]);
            if (f.at_line_start) {
                if (bytes[i] == '\n') {
                    i += 1;
                    f.blankLine();
                    continue;
                }
                f.prev_line_blank = false;
                if (f.opts.number or f.opts.number_nonblank) f.numberLine();
                f.at_line_start = false;
            }
            const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n');
            var end = nl orelse bytes.len;
            const cr = f.opts.show_ends and end > i and bytes[end - 1] == '\r';
            if (cr) end -= 1;
            f.out.write(bytes[i..end]);
            if (cr) {
                if (nl != null) f.out.write("^M") else f.pending_cr = true;
                end += 1;
            }
            i = end;
            if (i < bytes.len) {
                if (f.opts.show_ends) f.out.writeByte('$');
                f.out.writeByte('\n');
                f.at_line_start = true;
                i += 1;
            }
        }
    }

    /// An empty line (a '\n' at the start of a line), honouring -s, -n and -E.
    fn blankLine(f: *Formatter) void {
        if (f.opts.squeeze_blank and f.prev_line_blank) return;
        f.prev_line_blank = true;
        if (f.opts.number and !f.opts.number_nonblank) f.numberLine();
        if (f.opts.show_ends) f.out.writeByte('$');
        f.out.writeByte('\n');
    }

    fn feedBytes(f: *Formatter, bytes: []const u8) void {
        for (bytes) |c| {
            if (f.pending_cr) f.resolveCr(c);
            if (f.at_line_start) {
                if (c == '\n') {
                    f.blankLine();
                    continue;
                }
                f.prev_line_blank = false;
                if (f.opts.number or f.opts.number_nonblank) f.numberLine();
                f.at_line_start = false;
            }
            if (c == '\n') {
                if (f.opts.show_ends) f.out.writeByte('$');
                f.out.writeByte('\n');
                f.at_line_start = true;
            } else if (c == '\r' and f.opts.show_ends and !f.opts.show_nonprinting) {
                f.pending_cr = true;
            } else f.byte(c);
        }
    }

    /// "%6d\t" without the format machinery.
    fn numberLine(f: *Formatter) void {
        f.line_no += 1;
        var buf: [32]u8 = undefined;
        var i: usize = buf.len;
        i -= 1;
        buf[i] = '\t';
        var n = f.line_no;
        var digits: usize = 0;
        while (true) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
            digits += 1;
            if (n == 0) break;
        }
        while (digits < 6) : (digits += 1) {
            i -= 1;
            buf[i] = ' ';
        }
        f.out.write(buf[i..]);
    }

    fn byte(f: *Formatter, c: u8) void {
        if (c == '\t') {
            if (f.opts.show_tabs) f.out.write("^I") else f.out.writeByte('\t');
        } else if (!f.opts.show_nonprinting) {
            f.out.writeByte(c);
        } else if (c >= 128) {
            f.out.write("M-");
            f.control(c - 128);
        } else f.control(c);
    }

    /// Caret notation for control characters; printable bytes pass through.
    fn control(f: *Formatter, c: u8) void {
        if (c < 32) {
            f.out.writeByte('^');
            f.out.writeByte(c + 64);
        } else if (c == 127) {
            f.out.write("^?");
        } else f.out.writeByte(c);
    }
};

/// Which bat decorations to draw (bat --style components that are implemented).
pub const Style = struct {
    header: bool = true, // File: <name>
    size: bool = false, // Size: <n>; bat's default style has none, `full` does
    grid: bool = true,
    numbers: bool = true,
    changes: bool = true, // git markers in the gutter

    pub const full: Style = .{ .size = true };

    pub const plain: Style = .{ .header = false, .size = false, .grid = false, .numbers = false, .changes = false };

    pub fn none(s: Style) bool {
        return !(s.header or s.size or s.grid or s.numbers or s.changes);
    }

    /// Parse a comma-separated bat --style list. Later items add to earlier
    /// ones, except "plain"/"full"/"auto", which replace the set.
    pub fn parse(list: []const u8) ?Style {
        var st: Style = .{};
        var it = std.mem.splitScalar(u8, list, ',');
        var first = true;
        while (it.next()) |item| {
            if (std.mem.eql(u8, item, "full")) {
                st = full;
            } else if (std.mem.eql(u8, item, "auto")) {
                st = .{};
            } else if (std.mem.eql(u8, item, "plain")) {
                st = plain;
            } else {
                if (first) st = plain;
                if (std.mem.eql(u8, item, "header") or std.mem.eql(u8, item, "header-filename")) {
                    st.header = true;
                } else if (std.mem.eql(u8, item, "header-filesize")) {
                    st.size = true;
                } else if (std.mem.eql(u8, item, "grid")) {
                    st.grid = true;
                } else if (std.mem.eql(u8, item, "numbers")) {
                    st.numbers = true;
                } else if (std.mem.eql(u8, item, "changes")) {
                    st.changes = true;
                } else return null;
            }
            first = false;
        }
        return st;
    }
};

const sidebar_width = 5; // 4-digit number + " " (as bat)
const gray = "\x1b[90m"; // color: secondary text
const faint = "\x1b[2m"; // style: secondary text when color is off
const bold = "\x1b[1m";
const reset = "\x1b[0m";
const tab_width = 4; // bat expands tabs to 4 columns by default

/// Longest line (bytes) that is syntax-highlighted. Longer lines are written
/// unhighlighted so memory stays bounded; highlighting resumes on the next line.
const max_highlight_line = 1 << 20;

/// Per-file highlighting state: the grammar's context stack plus the line
/// being collected.
const ActiveHighlight = struct {
    gpa: std.mem.Allocator,
    hl: syntax.engine.Highlighter,
    st: syntax.engine.State,
    line: std.ArrayList(u8) = .empty,
    overflow: bool = false,

    fn deinit(a: *ActiveHighlight) void {
        a.line.deinit(a.gpa);
        a.st.deinit(a.gpa);
        a.hl.deinit();
    }
};

/// bat-style view of one file at a time. Line numbers restart per file, and
/// the header/grid are emitted lazily so an empty file prints nothing.
const BatView = struct {
    gpa: std.mem.Allocator,
    style: Style,
    /// Color escapes allowed (syntax colors, gray gutter).
    color: bool,
    /// Non-color styles allowed (bold, faint). Independent of NO_COLOR.
    styled: bool = false,
    width: usize,
    out: *stickyout.Out,
    name: []const u8 = "",
    line_no: u64 = 0,
    col: usize = 0,
    at_line_start: bool = true,
    started: bool = false,
    session: ?*syntax.session.Session = null,
    active: ?ActiveHighlight = null,
    /// Size of the current input in bytes; null for pipes and terminals.
    size: ?u64 = null,
    /// A previous file produced output (for the blank line between headers).
    printed_any: bool = false,
    /// Git change marks of the current file; the marker column exists only
    /// when this is set.
    changes: ?gitchanges.Changes = null,

    /// Highlight the current file with `syn`. Needs v.session.
    fn attach(v: *BatView, gpa: std.mem.Allocator, syn: *syntax.definition.Syntax) !void {
        const sess = v.session.?;
        v.active = .{
            .gpa = gpa,
            .hl = syntax.engine.Highlighter.init(&sess.reg),
            .st = try syntax.engine.State.init(gpa, syn),
        };
    }

    /// End of a file: flush pending output and drop highlighting state.
    fn endFile(v: *BatView) void {
        defer if (v.changes) |*c| {
            c.deinit(v.gpa);
            v.changes = null;
        };
        if (v.active) |*a| {
            if (a.line.items.len > 0 and !a.overflow) v.renderLine(a);
            v.finish();
            a.deinit();
            v.active = null;
        } else v.finish();
    }

    fn begin(v: *BatView, name: []const u8, size: ?u64, changes: ?gitchanges.Changes) void {
        v.name = name;
        v.changes = changes;
        v.size = size;
        v.line_no = 0;
        v.col = 0;
        v.at_line_start = true;
        v.started = false;
    }

    /// Gutter and rules: gray with color, faint with only styles, else plain.
    fn paintDim(v: *BatView) void {
        if (v.color) v.out.write(gray) else if (v.styled) v.out.write(faint);
    }

    fn paintBold(v: *BatView) void {
        if (v.styled) v.out.write(bold);
    }

    fn paintReset(v: *BatView) void {
        if (v.color or v.styled) v.out.write(reset);
    }

    /// Width of the line-number and marker columns together.
    fn sidebar(v: *const BatView) usize {
        const nums: usize = if (v.style.numbers) sidebar_width else 0;
        const marks: usize = if (v.changes != null) 2 else 0;
        return nums + marks;
    }

    fn hasSidebar(v: *const BatView) bool {
        return v.sidebar() != 0;
    }

    fn spaces(v: *BatView, n: usize) void {
        for (0..n) |_| v.out.writeByte(' ');
    }

    /// Horizontal rule; `joint` is drawn above the sidebar/content divider.
    fn rule(v: *BatView, joint: []const u8) void {
        v.paintDim();
        const sb = v.sidebar();
        const w = @max(v.width, sb + 3);
        for (0..w) |i| {
            if (sb != 0 and i == sb) v.out.write(joint) else v.out.write("─");
        }
        v.paintReset();
        v.out.writeByte('\n');
    }

    /// One header line: the gutter, the divider when there is a grid, then text.
    fn headerLine(v: *BatView, label: []const u8, text: []const u8, suffix: []const u8) void {
        v.spaces(v.sidebar());
        if (v.style.grid and v.hasSidebar()) {
            v.paintDim();
            v.out.write("│ ");
            v.paintReset();
        } else if (v.style.grid) {
            // header and grid without numbers: no divider, text starts at column 0
        }
        v.col = 0;
        v.out.write(label);
        v.col = label.len;
        v.paintBold();
        // The text can be a file name: what a terminal would act on is shown.
        var shown: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&shown);
        w.print("{f}", .{quote.Visible{ .name = text }}) catch {};
        for (w.buffered()) |c| v.putByte(c);
        v.paintReset();
        v.out.write(suffix);
        v.out.writeByte('\n');
        v.col = 0;
    }

    /// Header and top rule, printed lazily so unused inputs print nothing.
    /// `empty` marks a zero-byte input: bat shows it as `<EMPTY>` with no
    /// separator rule.
    fn start(v: *BatView, empty: bool) void {
        v.started = true;
        const has_header = v.style.header or v.style.size;
        if (v.printed_any and has_header and !v.style.grid) v.out.writeByte('\n');
        v.printed_any = true;
        if (v.style.grid) v.rule("┬");
        if (v.style.header) {
            const stdin = std.mem.eql(u8, v.name, "-");
            v.headerLine(if (stdin) "" else "File: ", if (stdin) "STDIN" else v.name, if (empty) "   <EMPTY>" else "");
        }
        if (v.style.size) {
            var buf: [32]u8 = undefined;
            v.headerLine("Size: ", if (v.size) |n| humanSize(&buf, n) else "-", "");
        }
        if (has_header and v.style.grid and !empty) v.rule("┼");
    }

    fn linePrefix(v: *BatView) void {
        v.line_no += 1;
        if (!v.hasSidebar() and !v.style.grid) return;
        v.paintDim();
        if (v.style.numbers) v.out.print("{d: >4} ", .{v.line_no});
        v.paintReset();
        if (v.changes) |*c| {
            if (c.at(v.line_no)) |m| {
                if (v.color) v.out.write(switch (m) {
                    .added => "\x1b[32m",
                    .modified => "\x1b[33m",
                    .removed_above, .removed_below => "\x1b[31m",
                });
                v.out.write(m.char());
                if (v.color) v.out.write(reset);
            } else v.out.writeByte(' ');
            v.out.writeByte(' ');
        }
        if (v.style.grid and v.hasSidebar()) {
            v.paintDim();
            v.out.write("│ ");
            v.paintReset();
        }
    }

    /// Columns available for text next to the gutter (at least 1).
    fn textWidth(v: *const BatView) usize {
        const gutter = v.sidebar() + (if (v.style.grid and v.hasSidebar()) @as(usize, 2) else 0);
        return @max(v.width, gutter + 1) - gutter;
    }

    /// Continuation row of a wrapped line: blank sidebar, divider, no number.
    fn wrapBreak(v: *BatView) void {
        v.out.writeByte('\n');
        if (v.hasSidebar()) {
            v.paintDim();
            v.spaces(v.sidebar());
            if (v.style.grid) v.out.write("│ ");
            v.paintReset();
        }
        v.col = 0;
    }

    /// Write one byte at the current column, wrapping at the text width.
    /// Tabs expand to the next 4-column stop. Bytes count as columns
    /// (decision: UTF-8 aware counting is a known gap).
    fn putByte(v: *BatView, c: u8) void {
        const tw = v.textWidth();
        if (c == '\t') {
            const n = tab_width - v.col % tab_width;
            for (0..n) |_| {
                if (v.col >= tw) v.wrapBreak();
                v.out.writeByte(' ');
                v.col += 1;
            }
        } else {
            if (v.col >= tw) v.wrapBreak();
            v.out.writeByte(c);
            v.col += 1;
        }
    }

    /// Write text, expanding tabs and wrapping.
    fn writeText(v: *BatView, text: []const u8) void {
        for (text) |c| v.putByte(c);
    }

    const Sink = struct {
        v: *BatView,
        line: []const u8,

        pub fn token(s: *Sink, a: usize, b: usize, scopes: []const syntax.definition.ScopeId) void {
            var text = s.line[a..b];
            if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
            if (text.len == 0) return;
            const sess = s.v.session.?;
            const color = sess.theme.colorFor(sess.gpa, &sess.reg, scopes) catch null;
            if (color) |c| s.v.out.write(c);
            s.v.writeText(text);
            if (color != null) s.v.out.write(reset);
        }
    };

    /// Highlight and print the collected line (which ends with '\n').
    fn renderLine(v: *BatView, a: *ActiveHighlight) void {
        if (a.line.items.len == 0 or a.line.items[a.line.items.len - 1] != '\n') {
            a.line.append(a.gpa, '\n') catch return;
        }
        if (!v.started) v.start(false);
        v.linePrefix();
        v.col = 0;
        var sink: Sink = .{ .v = v, .line = a.line.items };
        a.hl.highlightLine(&a.st, a.line.items, &sink) catch {
            // Out of memory while highlighting: print the line as it is.
            v.writeText(a.line.items[0 .. a.line.items.len - 1]);
        };
        v.out.writeByte('\n');
        v.at_line_start = true;
        v.col = 0;
        a.line.clearRetainingCapacity();
    }

    /// Collect bytes into lines and render each complete line.
    fn feedHighlighted(v: *BatView, a: *ActiveHighlight, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const part = if (nl) |n| rest[0..n] else rest;

            if (a.overflow) {
                v.writeText(part);
            } else if (a.line.items.len + part.len > max_highlight_line) {
                // Too long to highlight: print what we have and the rest raw.
                if (!v.started) v.start(false);
                if (a.line.items.len == 0 or v.at_line_start) {
                    v.linePrefix();
                    v.at_line_start = false;
                    v.col = 0;
                }
                v.writeText(a.line.items);
                a.line.clearRetainingCapacity();
                a.overflow = true;
                v.writeText(part);
            } else {
                a.line.appendSlice(a.gpa, part) catch return;
            }

            if (nl) |n| {
                if (a.overflow) {
                    v.out.writeByte('\n');
                    v.at_line_start = true;
                    v.col = 0;
                    a.overflow = false;
                } else {
                    a.line.append(a.gpa, '\n') catch return;
                    v.renderLine(a);
                }
                rest = rest[n + 1 ..];
            } else break;
        }
    }

    fn feed(v: *BatView, bytes: []const u8) void {
        if (v.active) |*a| return v.feedHighlighted(a, bytes);
        for (bytes) |c| {
            if (!v.started) v.start(false);
            if (v.at_line_start) {
                v.linePrefix();
                v.at_line_start = false;
            }
            switch (c) {
                '\n' => {
                    v.out.writeByte('\n');
                    v.at_line_start = true;
                    v.col = 0;
                },
                else => v.putByte(c),
            }
        }
    }

    /// End of one file: terminate an unfinished last line and close the grid.
    fn finish(v: *BatView) void {
        if (!v.started) {
            // Only a zero-byte input reaches here with nothing printed.
            if (v.size != null and v.size.? == 0 and (v.style.header or v.style.size)) v.start(true) else return;
        }
        if (!v.at_line_start) v.out.writeByte('\n');
        if (v.style.grid) v.rule("┴");
    }
};

/// bat's size text: bytes below 1000, then decimal KB / MB / GB with one
/// decimal. The switch to MB only after 2^20 bytes is copied from observing
/// bat 0.26.1 (1048576 prints as "1048.6 KB"); other boundaries are inferred.
pub fn humanSize(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    const text = if (n < 1000)
        std.fmt.bufPrint(buf, "{d} B", .{n})
    else if (n <= 1 << 20)
        std.fmt.bufPrint(buf, "{d:.1} KB", .{f / 1e3})
    else if (n <= 1 << 30)
        std.fmt.bufPrint(buf, "{d:.1} MB", .{f / 1e6})
    else
        std.fmt.bufPrint(buf, "{d:.1} GB", .{f / 1e9});
    return text catch "?";
}

/// The bat-style presentation extension (decision 0005). Never used unless
/// the host sets `Options.view`.
pub const View = struct {
    style: Style = .{},
    /// Color escapes allowed (syntax colors, gray gutter).
    color: bool = false,
    /// Non-color styles allowed (bold, faint).
    styled: bool = false,
    /// Terminal width in columns, for the horizontal rules.
    width: usize = 80,
    /// Loaded grammars; null: no highlighting.
    session: ?*syntax.session.Session = null,
    /// Highlight every input with this grammar instead of detecting one.
    forced: ?*syntax.definition.Syntax = null,
};

/// A problem with one input; the run continues with the next one.
pub const Event = struct {
    name: []const u8,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    var out = stickyout.Out.init(writer);
    var fmt: Formatter = .{ .opts = options, .out = &out };
    const bat_view = options.view != null;
    var view: BatView = if (options.view) |v| .{
        .gpa = env.gpa,
        .style = v.style,
        .color = v.color,
        .styled = v.styled,
        .width = v.width,
        .out = &out,
        .session = v.session,
    } else .{ .gpa = env.gpa, .style = .{}, .color = false, .width = 80, .out = &out };
    const color_on = view.color;
    const forced: ?*syntax.definition.Syntax = if (options.view) |v| v.forced else null;
    var result: Result = .{};
    var buf: [64 * 1024]u8 = undefined;

    for (inputs) |in| {
        const path = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            observer.emit(.{ .name = path, .err = e });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        const file = opened.file;

        const marks: ?gitchanges.Changes = if (bat_view and view.style.changes and in.source == .path) gitchanges.load(env, path) else null;
        if (bat_view) view.begin(path, fileSize(env, file), marks);
        defer if (bat_view) view.endFile();
        var first_chunk = true;

        while (true) {
            const n = common.readChunk(env.io, file, &buf) catch |e| {
                observer.emit(.{ .name = path, .err = e });
                result.failed = true;
                break;
            };
            if (n == 0) break;
            if (bat_view) {
                if (first_chunk and view.session != null and color_on) {
                    first_chunk = false;
                    const nl = std.mem.indexOfScalar(u8, buf[0..n], '\n');
                    const first_line = buf[0..if (nl) |k| k + 1 else n];
                    if (forced orelse view.session.?.reg.detect(path, first_line)) |syn| {
                        try view.attach(env.gpa, syn);
                    }
                }
                view.feed(buf[0..n]);
            } else if (options.plain()) {
                out.write(buf[0..n]);
            } else fmt.feed(buf[0..n]);
            // As in GNU, what has been read is written before waiting for
            // more: the input may be someone typing.
            out.flush();
            if (out.failed) return error.WriteFailed;
        }
    }
    fmt.finish();
    try out.finish();
    return result;
}

/// Size of a regular file, or null (pipes, terminals, errors).
fn fileSize(env: Env, file: Io.File) ?u64 {
    const st = file.stat(env.io) catch return null;
    return if (st.kind == .file) st.size else null;
}

fn testOut(aw: *Io.Writer.Allocating) stickyout.Out {
    return stickyout.Out.init(&aw.writer);
}

test "formatter: -n -E -s" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var out = testOut(&aw);
    var f: Formatter = .{ .opts = .{ .number = true, .show_ends = true, .squeeze_blank = true }, .out = &out };
    f.feed("a\n\n\nb");
    try std.testing.expectEqualStrings("     1\ta$\n     2\t$\n     3\tb", aw.written());
}

test "formatter: -v notation" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var out = testOut(&aw);
    var f: Formatter = .{ .opts = .{ .show_nonprinting = true, .show_tabs = true }, .out = &out };
    f.feed("\x01\t\x7f\x80\xff");
    try std.testing.expectEqualStrings("^A^I^?M-^@M-^?", aw.written());
}

test "bat view: full style, as bat 0.26.1 prints it" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var out = testOut(&aw);
    var v: BatView = .{ .gpa = std.testing.allocator, .style = Style.full, .color = false, .width = 20, .out = &out };
    v.begin("f.txt", 5, null);
    v.feed("a\tb\nc");
    v.finish();
    try std.testing.expectEqualStrings(
        "─────┬──────────────\n" ++
            "     │ File: f.txt\n" ++
            "     │ Size: 5 B\n" ++
            "─────┼──────────────\n" ++
            "   1 │ a   b\n" ++
            "   2 │ c\n" ++
            "─────┴──────────────\n",
        aw.written(),
    );
}

test "bat view: empty file shows <EMPTY> only with a header" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var out = testOut(&aw);
    var v: BatView = .{ .gpa = std.testing.allocator, .style = Style.full, .color = false, .width = 20, .out = &out };
    v.begin("e", 0, null);
    v.finish();
    try std.testing.expectEqualStrings(
        "─────┬──────────────\n" ++
            "     │ File: e   <EMPTY>\n" ++
            "     │ Size: 0 B\n" ++
            "─────┴──────────────\n",
        aw.written(),
    );

    aw.clearRetainingCapacity();
    var g: BatView = .{ .gpa = std.testing.allocator, .style = Style.parse("numbers,grid").?, .color = false, .width = 20, .out = &out };
    g.begin("e", 0, null);
    g.finish();
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "bat view: long lines wrap under a blank gutter" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var out = testOut(&aw);
    var v: BatView = .{ .gpa = std.testing.allocator, .style = .{}, .color = false, .width = 12, .out = &out };
    v.begin("f", 10, null);
    v.feed("abcdefghij\n");
    v.finish();
    try std.testing.expectEqualStrings(
        "─────┬──────\n" ++
            "     │ File: \n" ++
            "     │ f\n" ++
            "─────┼──────\n" ++
            "   1 │ abcde\n" ++
            "     │ fghij\n" ++
            "─────┴──────\n",
        aw.written(),
    );
}

test "human sizes follow bat" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("10 B", humanSize(&buf, 10));
    try std.testing.expectEqualStrings("1.0 KB", humanSize(&buf, 1023));
    try std.testing.expectEqualStrings("10.2 KB", humanSize(&buf, 10240));
    try std.testing.expectEqualStrings("1048.6 KB", humanSize(&buf, 1048576));
    try std.testing.expectEqualStrings("2.0 MB", humanSize(&buf, 2000000));
}

test "style list parsing" {
    try std.testing.expect(Style.parse("plain").?.none());
    const s = Style.parse("numbers").?;
    try std.testing.expect(s.numbers and !s.grid and !s.header and !s.size);
    try std.testing.expect(Style.parse("bogus") == null);
}
