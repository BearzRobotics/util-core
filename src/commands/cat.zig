//! cat — concatenate files to standard output. Reference: GNU coreutils cat(1),
//! POSIX cat, and bat(1) for the terminal view (SPEC §8.2).
//!
//! Two output paths share one binary:
//!   * GNU path: used when stdout is not a terminal, or when any GNU formatting
//!     option (-A -b -e -E -n -s -t -T -v) is given. Byte-for-byte GNU behaviour.
//!   * bat view: used when stdout is a terminal (or --decorations=always) and no
//!     GNU formatting option was given. Header, grid and line numbers, styled
//!     by --style / --plain. Syntax highlighting, paging and git markers are
//!     not implemented yet.
//!
//! With no formatting option the input is copied in large chunks without
//! inspection. With any of -A -b -e -E -n -s -t -T -v each byte goes through a
//! small state machine whose state (line start, line number, blank-line run)
//! persists across files, because GNU cat treats the inputs as one stream.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const syntax = @import("../syntax/root.zig");

const Options = struct {
    number: bool = false, // -n
    number_nonblank: bool = false, // -b (wins over -n)
    show_ends: bool = false, // -E
    show_tabs: bool = false, // -T
    show_nonprinting: bool = false, // -v
    squeeze_blank: bool = false, // -s

    /// Any GNU formatting option forces the GNU path, even on a terminal.
    fn gnuFormatting(o: Options) bool {
        return !o.plain();
    }

    fn plain(o: Options) bool {
        return !(o.number or o.number_nonblank or o.show_ends or o.show_tabs or
            o.show_nonprinting or o.squeeze_blank);
    }
};

const Formatter = struct {
    opts: Options,
    out: *cli.Out,
    at_line_start: bool = true,
    prev_line_blank: bool = false,
    line_no: u64 = 0,

    fn feed(f: *Formatter, bytes: []const u8) void {
        for (bytes) |c| {
            if (f.at_line_start) {
                if (c == '\n') {
                    if (f.opts.squeeze_blank and f.prev_line_blank) continue;
                    f.prev_line_blank = true;
                    if (f.opts.number and !f.opts.number_nonblank) f.numberLine();
                    if (f.opts.show_ends) f.out.writeByte('$');
                    f.out.writeByte('\n');
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
            } else f.byte(c);
        }
    }

    fn numberLine(f: *Formatter) void {
        f.line_no += 1;
        f.out.print("{d: >6}\t", .{f.line_no});
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
const Style = struct {
    header: bool = true, // File: <name>
    size: bool = true, // Size: <n>
    grid: bool = true,
    numbers: bool = true,

    const plain: Style = .{ .header = false, .size = false, .grid = false, .numbers = false };

    fn none(s: Style) bool {
        return !(s.header or s.size or s.grid or s.numbers);
    }

    /// Parse a comma-separated bat --style list. Later items add to earlier
    /// ones, except "plain"/"full"/"auto", which replace the set.
    fn parse(list: []const u8) ?Style {
        var st: Style = .{};
        var it = std.mem.splitScalar(u8, list, ',');
        var first = true;
        while (it.next()) |item| {
            if (std.mem.eql(u8, item, "full") or std.mem.eql(u8, item, "auto")) {
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
                } else return null;
            }
            first = false;
        }
        return st;
    }
};

const When = cli.When;

fn parseWhen(v: []const u8) ?When {
    return When.parse(v);
}

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
    style: Style,
    /// Color escapes allowed (syntax colors, gray gutter).
    color: bool,
    /// Non-color styles allowed (bold, faint). Independent of NO_COLOR.
    styled: bool = false,
    width: usize,
    out: *cli.Out,
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
        if (v.active) |*a| {
            if (a.line.items.len > 0 and !a.overflow) v.renderLine(a);
            v.finish();
            a.deinit();
            v.active = null;
        } else v.finish();
    }

    fn begin(v: *BatView, name: []const u8, size: ?u64) void {
        v.name = name;
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

    fn sidebar(v: *const BatView) usize {
        return if (v.style.numbers) sidebar_width else 0;
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
        if (v.style.numbers) {
            v.out.write("     "); // sidebar_width spaces
        }
        if (v.style.grid and v.style.numbers) {
            v.paintDim();
            v.out.write("│ ");
            v.paintReset();
        } else if (v.style.grid) {
            // header and grid without numbers: no divider, text starts at column 0
        }
        v.out.write(label);
        v.paintBold();
        v.out.write(text);
        v.paintReset();
        v.out.write(suffix);
        v.out.writeByte('\n');
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
        if (!v.style.numbers and !v.style.grid) return;
        v.paintDim();
        if (v.style.numbers) v.out.print("{d: >4} ", .{v.line_no});
        if (v.style.grid and v.style.numbers) v.out.write("│ ");
        v.paintReset();
    }

    /// Write text, expanding tabs.
    fn writeText(v: *BatView, text: []const u8) void {
        for (text) |c| {
            if (c == '\t') {
                const n = tab_width - v.col % tab_width;
                for (0..n) |_| v.out.writeByte(' ');
                v.col += n;
            } else {
                v.out.writeByte(c);
                v.col += 1;
            }
        }
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
                '\t' => {
                    const n = tab_width - v.col % tab_width;
                    for (0..n) |_| v.out.writeByte(' ');
                    v.col += n;
                },
                else => {
                    v.out.writeByte(c);
                    v.col += 1;
                },
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
fn humanSize(buf: []u8, n: u64) []const u8 {
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

/// Terminal width in columns, or 80 when it cannot be determined.
fn terminalWidth() usize {
    return sys.terminalColumns() orelse 80;
}

pub fn main(ctx: cli.Context) u8 {
    var opts: Options = .{};
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);

    var style: Style = .{};
    var color: When = .auto;
    var decorations: When = .auto;
    var language: ?[]const u8 = null;
    var list_languages = false;
    var syntax_dirs: std.ArrayList([]const u8) = .empty;
    defer syntax_dirs.deinit(ctx.gpa);

    var only_operands = false;
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return fail(ctx, "out of memory");
        } else if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            if (std.mem.eql(u8, a, "--help")) return help(ctx);
            if (std.mem.eql(u8, a, "--version")) return if (cli.printVersion(ctx)) 0 else 1;
            if (std.mem.eql(u8, a, "--show-all")) {
                opts.show_nonprinting = true;
                opts.show_ends = true;
                opts.show_tabs = true;
            } else if (std.mem.eql(u8, a, "--number-nonblank")) {
                opts.number_nonblank = true;
            } else if (std.mem.eql(u8, a, "--show-ends")) {
                opts.show_ends = true;
            } else if (std.mem.eql(u8, a, "--number")) {
                opts.number = true;
            } else if (std.mem.eql(u8, a, "--squeeze-blank")) {
                opts.squeeze_blank = true;
            } else if (std.mem.eql(u8, a, "--show-tabs")) {
                opts.show_tabs = true;
            } else if (std.mem.eql(u8, a, "--show-nonprinting")) {
                opts.show_nonprinting = true;
            } else if (std.mem.eql(u8, a, "--plain")) {
                style = Style.plain;
            } else if (valueOf(ctx.args, &i, "--style")) |v| {
                style = Style.parse(v) orelse return badValue(ctx, "--style", v);
            } else if (valueOf(ctx.args, &i, "--color")) |v| {
                color = parseWhen(v) orelse return badValue(ctx, "--color", v);
            } else if (valueOf(ctx.args, &i, "--decorations")) |v| {
                decorations = parseWhen(v) orelse return badValue(ctx, "--decorations", v);
            } else if (valueOf(ctx.args, &i, "--language")) |v| {
                language = v;
            } else if (valueOf(ctx.args, &i, "--syntax-dir")) |v| {
                syntax_dirs.append(ctx.gpa, v) catch return fail(ctx, "out of memory");
            } else if (std.mem.eql(u8, a, "--list-languages")) {
                list_languages = true;
            } else return badOption(ctx, a);
        } else {
            var j: usize = 1;
            while (j < a.len) : (j += 1) switch (a[j]) {
                'A' => {
                    opts.show_nonprinting = true;
                    opts.show_ends = true;
                    opts.show_tabs = true;
                },
                'b' => opts.number_nonblank = true,
                'e' => {
                    opts.show_nonprinting = true;
                    opts.show_ends = true;
                },
                'E' => opts.show_ends = true,
                'n' => opts.number = true,
                's' => opts.squeeze_blank = true,
                't' => {
                    opts.show_nonprinting = true;
                    opts.show_tabs = true;
                },
                'T' => opts.show_tabs = true,
                'p' => style = Style.plain,
                'l' => {
                    // -lNAME or -l NAME; the rest of the cluster is the value.
                    if (j + 1 < a.len) {
                        language = a[j + 1 ..];
                    } else if (i + 1 < ctx.args.len) {
                        i += 1;
                        language = ctx.args[i];
                    } else return badOption(ctx, a);
                    j = a.len;
                },
                'u' => {}, // unbuffered: output is already written promptly enough; ignored as in GNU
                'v' => opts.show_nonprinting = true,
                else => return badOption(ctx, a),
            };
        }
    }

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;

    const tty = Io.File.stdout().isTty(ctx.io) catch false;
    const decorated = !opts.gnuFormatting() and switch (decorations) {
        .always => true,
        .never => false,
        .auto => tty,
    };
    const color_on = cli.colorEnabled(ctx, color, tty);
    const styled_on = cli.styleEnabled(ctx, color, tty);

    // Grammars are loaded only when a highlighted bat view is possible.
    var session: syntax.session.Session = syntax.session.Session.init(ctx.gpa);
    defer session.deinit();
    var have_session = false;
    var forced: ?*syntax.definition.Syntax = null;
    if ((decorated and color_on) or list_languages) {
        loadGrammars(ctx, &session, syntax_dirs.items);
        have_session = true;
        if (session.failed > 0)
            cli.warn(ctx, "{d} syntax file(s) could not be loaded", .{session.failed});
    }
    if (list_languages) return listLanguages(ctx, &session);
    if (language) |name| if (have_session) {
        forced = session.byUserName(name) orelse {
            cli.warn(ctx, "unknown language '{s}' (see --list-languages)", .{name});
            return 1;
        };
    };

    // Plain style with nothing to highlight is just the raw bytes.
    const highlight_possible = have_session and session.reg.syntaxes.items.len > 0;
    const bat_view = decorated and (!style.none() or (color_on and highlight_possible));

    var out = cli.Out.init(ctx.io);
    var fmt: Formatter = .{ .opts = opts, .out = &out };
    var view: BatView = .{
        .style = style,
        .color = color_on,
        .styled = styled_on,
        .width = if (bat_view) terminalWidth() else 80,
        .out = &out,
        .session = if (have_session) &session else null,
    };
    var status: u8 = 0;
    var buf: [64 * 1024]u8 = undefined;

    for (inputs) |path| {
        const file = cli.openInput(ctx.io, path) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);

        if (bat_view) view.begin(path, fileSize(ctx, file));
        defer if (bat_view) view.endFile();
        var first_chunk = true;

        while (true) {
            const n = cli.readChunk(ctx.io, file, &buf) catch |e| {
                cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
                status = 1;
                break;
            };
            if (n == 0) break;
            if (bat_view) {
                if (first_chunk and view.session != null and color_on) {
                    first_chunk = false;
                    const nl = std.mem.indexOfScalar(u8, buf[0..n], '\n');
                    const first_line = buf[0..if (nl) |k| k + 1 else n];
                    if (forced orelse session.reg.detect(path, first_line)) |syn| {
                        view.attach(ctx.gpa, syn) catch return fail(ctx, "out of memory");
                    }
                }
                view.feed(buf[0..n]);
            } else if (opts.plain()) {
                out.write(buf[0..n]);
            } else fmt.feed(buf[0..n]);
            if (out.failed) return 1;
        }
    }
    out.flush();
    return if (out.failed) 1 else status;
}

/// Load grammars from --syntax-dir directories and the user config directory
/// ($XDG_CONFIG_HOME/cat/syntaxes or ~/.config/cat/syntaxes).
fn loadGrammars(ctx: cli.Context, session: *syntax.session.Session, extra_dirs: []const []const u8) void {
    for (extra_dirs) |d| _ = session.loadDir(ctx.io, d) catch {};
    const dir: ?[]u8 = if (cli.getenv(ctx, "XDG_CONFIG_HOME")) |x|
        std.Io.Dir.path.join(ctx.gpa, &.{ x, "cat", "syntaxes" }) catch null
    else if (cli.getenv(ctx, "HOME")) |h|
        std.Io.Dir.path.join(ctx.gpa, &.{ h, ".config", "cat", "syntaxes" }) catch null
    else
        null;
    if (dir) |d| {
        defer ctx.gpa.free(d);
        _ = session.loadDir(ctx.io, d) catch {};
    }
}

fn listLanguages(ctx: cli.Context, session: *syntax.session.Session) u8 {
    var out = cli.Out.init(ctx.io);
    for (session.reg.syntaxes.items) |syn| {
        out.write(syn.name);
        out.write("\t");
        for (syn.extensions, 0..) |e, k| {
            if (k > 0) out.writeByte(',');
            out.write(e);
        }
        out.writeByte('\n');
    }
    out.flush();
    return if (out.failed) 1 else 0;
}

/// Size of a regular file, or null (pipes, terminals, errors).
fn fileSize(ctx: cli.Context, file: Io.File) ?u64 {
    const st = file.stat(ctx.io) catch return null;
    return if (st.kind == .file) st.size else null;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: cat [OPTION]... [FILE]...\n" ++
        "Concatenate FILE(s) to standard output. With no FILE, or when FILE is -,\n" ++
        "read standard input.\n\n" ++
        "  -A, --show-all           equivalent to -vET\n" ++
        "  -b, --number-nonblank    number nonempty output lines, overrides -n\n" ++
        "  -e                       equivalent to -vE\n" ++
        "  -E, --show-ends          display $ at end of each line\n" ++
        "  -n, --number             number all output lines\n" ++
        "  -s, --squeeze-blank      suppress repeated empty output lines\n" ++
        "  -t                       equivalent to -vT\n" ++
        "  -T, --show-tabs          display TAB characters as ^I\n" ++
        "  -u                       (ignored)\n" ++
        "  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB\n\n" ++
        "bat-style view (default on a terminal unless a GNU option above is used):\n" ++
        "  -p, --plain              no header, grid or line numbers\n" ++
        "      --style=LIST         comma list of: full, plain, header, grid, numbers\n" ++
        "      --color=WHEN         auto, always or never\n" ++
        "      --decorations=WHEN   auto, always or never (always forces the view in pipes)\n" ++
        "  -l, --language=NAME      highlight as NAME (language, scope or extension)\n" ++
        "      --syntax-dir=DIR     also load .sublime-syntax grammars from DIR\n" ++
        "      --list-languages     list loaded grammars\n\n" ++
        "Grammars are read from --syntax-dir and ~/.config/cat/syntaxes. Highlighting\n" ++
        "is used only in the bat view with color on; no grammars are bundled yet.\n")) 0 else 1;
}

fn fail(ctx: cli.Context, msg: []const u8) u8 {
    cli.warn(ctx, "{s}", .{msg});
    return 1;
}

/// If args[i.*] is `--name=VALUE`, or `--name` followed by a value argument,
/// return the value (advancing `i` past a separate value).
fn valueOf(args: []const [:0]const u8, i: *usize, name: []const u8) ?[]const u8 {
    const a: []const u8 = args[i.*];
    if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=') return a[name.len + 1 ..];
    if (std.mem.eql(u8, a, name) and i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

fn badValue(ctx: cli.Context, opt: []const u8, value: []const u8) u8 {
    cli.warn(ctx, "invalid argument '{s}' for '{s}'", .{ value, opt });
    return 1;
}

fn badOption(ctx: cli.Context, opt: []const u8) u8 {
    cli.warn(ctx, "invalid option '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}

test "formatter: -n -E -s" {
    var out = cli.Out.init(undefined);
    // Capture by inspecting the buffer instead of flushing.
    var f: Formatter = .{ .opts = .{ .number = true, .show_ends = true, .squeeze_blank = true }, .out = &out };
    f.feed("a\n\n\nb");
    try std.testing.expectEqualStrings("     1\ta$\n     2\t$\n     3\tb", out.buf[0..out.len]);
}

test "formatter: -v notation" {
    var out = cli.Out.init(undefined);
    var f: Formatter = .{ .opts = .{ .show_nonprinting = true, .show_tabs = true }, .out = &out };
    f.feed("\x01\t\x7f\x80\xff");
    try std.testing.expectEqualStrings("^A^I^?M-^@M-^?", out.buf[0..out.len]);
}

test "bat view: full style, as bat 0.26.1 prints it" {
    var out = cli.Out.init(undefined);
    var v: BatView = .{ .style = .{}, .color = false, .width = 12, .out = &out };
    v.begin("f.txt", 5);
    v.feed("a\tb\nc");
    v.finish();
    try std.testing.expectEqualStrings(
        "─────┬──────\n" ++
            "     │ File: f.txt\n" ++
            "     │ Size: 5 B\n" ++
            "─────┼──────\n" ++
            "   1 │ a   b\n" ++
            "   2 │ c\n" ++
            "─────┴──────\n",
        out.buf[0..out.len],
    );
}

test "bat view: empty file shows <EMPTY> only with a header" {
    var out = cli.Out.init(undefined);
    var v: BatView = .{ .style = .{}, .color = false, .width = 12, .out = &out };
    v.begin("e", 0);
    v.finish();
    try std.testing.expectEqualStrings(
        "─────┬──────\n" ++
            "     │ File: e   <EMPTY>\n" ++
            "     │ Size: 0 B\n" ++
            "─────┴──────\n",
        out.buf[0..out.len],
    );

    out.len = 0;
    var g: BatView = .{ .style = Style.parse("numbers,grid").?, .color = false, .width = 12, .out = &out };
    g.begin("e", 0);
    g.finish();
    try std.testing.expectEqual(@as(usize, 0), out.len);
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
