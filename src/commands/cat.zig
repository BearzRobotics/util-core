// SPDX-License-Identifier: GPL-2.0-or-later
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
const builtin = @import("builtin");
const timing = @import("../lib/time.zig");
const Io = std.Io;
const cli = @import("../cli.zig");
const fu = @import("../lib/fu_common.zig");
const sys = @import("../sys.zig");
const syntax = @import("../syntax/root.zig");
const cat = @import("../lib/cat.zig");
const pager_ui = @import("../pager_ui.zig");
const termcolors = @import("../termcolors.zig");

const Options = cat.Options;
const Style = cat.Style;

const When = cli.When;

/// Set in the environment of the pager cat starts. A cat found with it set was
/// reached through that pager (`PAGER` names a script that runs cat, say), so
/// starting a pager again could repeat without end.
const in_pager_variable = "UTIL_CORE_CAT_PAGER";

fn parseWhen(v: []const u8) ?When {
    return When.parse(v);
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
    var paging: When = .auto;
    var pager_cmd: ?[]const u8 = null;
    var language: ?[]const u8 = null;
    var list_languages = false;
    var list_themes = false;
    var theme_name: ?[]const u8 = null;
    var theme_dark: ?[]const u8 = null;
    var theme_light: ?[]const u8 = null;
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
            } else if (std.mem.eql(u8, a, "--no-paging")) {
                paging = .never;
            } else if (valueOf(ctx.args, &i, "--paging")) |v| {
                paging = parseWhen(v) orelse return badValue(ctx, "--paging", v);
            } else if (valueOf(ctx.args, &i, "--pager")) |v| {
                pager_cmd = v;
            } else if (valueOf(ctx.args, &i, "--decorations")) |v| {
                decorations = parseWhen(v) orelse return badValue(ctx, "--decorations", v);
            } else if (valueOf(ctx.args, &i, "--language")) |v| {
                language = v;
            } else if (valueOf(ctx.args, &i, "--syntax-dir")) |v| {
                syntax_dirs.append(ctx.gpa, v) catch return fail(ctx, "out of memory");
            } else if (valueOf(ctx.args, &i, "--theme")) |v| {
                theme_name = v;
            } else if (valueOf(ctx.args, &i, "--theme-dark")) |v| {
                theme_dark = v;
            } else if (valueOf(ctx.args, &i, "--theme-light")) |v| {
                theme_light = v;
            } else if (std.mem.eql(u8, a, "--list-themes")) {
                list_themes = true;
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
                'P' => paging = .never,
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
    const in_pager = cli.getenv(ctx, in_pager_variable) != null;
    if (in_pager) paging = .never;
    // As part of the pager, the stream from the first cat is passed on as it
    // is, not decorated a second time.
    const passing_on = in_pager and inputs.len == 1 and std.mem.eql(u8, inputs[0], "-") and
        !(Io.File.stdin().isTty(ctx.io) catch false);
    // Reading a terminal, cat is just cat: what is typed comes straight back,
    // and nothing else may read the keyboard.
    const from_terminal = for (inputs) |path| {
        if (isTerminal(ctx, path)) break true;
    } else false;
    if (from_terminal) paging = .never;
    const decorated = !opts.gnuFormatting() and switch (decorations) {
        .always => true,
        .never => false,
        .auto => tty and !passing_on and !from_terminal,
    };
    // On a Windows console escapes work only after enabling VT processing; if
    // that fails, treat the console as one that cannot show them.
    const ansi_ok = !tty or sys.enableAnsiOutput();
    const color_on = ansi_ok and cli.colorEnabled(ctx, color, tty);
    const styled_on = ansi_ok and cli.styleEnabled(ctx, color, tty);

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
    if (list_themes) return listThemes(ctx);
    // Colors for the highlighted view: the theme, at the terminal's color depth.
    if (have_session and color_on and decorated) {
        if (!selectTheme(ctx, &session, theme_name, theme_dark, theme_light, tty)) return 1;
    }
    if (language) |name| if (have_session) {
        forced = session.byUserName(name) orelse {
            cli.warn(ctx, "unknown language '{s}' (see --list-languages)", .{name});
            return 1;
        };
    };

    // Plain style with nothing to highlight is just the raw bytes.
    const highlight_possible = have_session and session.reg.syntaxes.items.len > 0;
    const bat_view = decorated and (!style.none() or (color_on and highlight_possible));

    var lib_opts = opts;
    if (bat_view) lib_opts.view = .{
        .style = style,
        .color = color_on,
        .styled = styled_on,
        .width = terminalWidth(),
        .session = if (have_session) &session else null,
        .forced = forced,
    };

    var lib_inputs: std.ArrayList(cat.Input) = .empty;
    defer lib_inputs.deinit(ctx.gpa);
    for (inputs) |path| {
        const in: cat.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        lib_inputs.append(ctx.gpa, in) catch return fail(ctx, "out of memory");
    }

    var buf: [8192]u8 = undefined;
    // bat pages a terminal view: `less -FRX` quits at once when it fits on one screen.
    const want_pager = switch (paging) {
        .never => false,
        .auto => bat_view and tty,
        .always => tty,
    };
    // A pager given by --pager, $BAT_PAGER or $PAGER runs as a process; with
    // none configured, the built-in one (the same as `less`) takes over and
    // scrolls while cat is still writing.
    const choice: Pager.Choice = if (want_pager) Pager.start(ctx, pager_cmd) else .off;
    var pager: ?Pager = if (choice == .process) choice.process else null;
    defer if (pager) |*p| {
        _ = p.finish(ctx);
    };
    var ui: ?*pager_ui.Ui = if (choice == .built_in)
        pager_ui.Ui.start(ctx.gpa, ctx.io, .{ .raw = true }, "", true)
    else
        null;
    // Short output is cat's bytes themselves.
    if (ui) |u| u.verbatim = true;
    var sink_buf: [16384]u8 = undefined;
    var stdout = (if (pager) |p| p.stdin else Io.File.stdout()).writerStreaming(ctx.io, &buf);
    const sink: *Io.Writer = if (ui) |u| u.sink(&sink_buf) else &stdout.interface;
    const env: cat.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = cat.run(env, lib_opts, lib_inputs.items, sink, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return fail(ctx, "out of memory"),
        error.WriteFailed => {
            // The user left the pager before the end: not an error, unless
            // it is the pager that failed.
            if (pager) |*running| {
                const status = pagerStatus(ctx, running);
                pager = null;
                return status;
            }
            // `cli.finish` words the write error.
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    if (ui) |u| {
        sink.flush() catch {};
        _ = u.finish(true);
        u.deinit();
        ui = null;
    }
    if (pager) |*running| {
        stdout.interface.flush() catch {};
        const status = pagerStatus(ctx, running);
        pager = null;
        if (status != 0) return status;
    }
    return if (result.failed) 1 else 0;
}

/// Wait for the pager. One that fails may have shown nothing, so say so.
fn pagerStatus(ctx: cli.Context, pager: *Pager) u8 {
    const failure = pager.finish(ctx) orelse return 0;
    cli.warn(ctx, "the pager failed (status {d}); --paging=never shows the text without it", .{failure});
    return 1;
}

/// Whether the operand `path` reads a terminal.
fn isTerminal(ctx: cli.Context, path: []const u8) bool {
    if (std.mem.eql(u8, path, "-")) return Io.File.stdin().isTty(ctx.io) catch false;
    // Only a character device can be one (/dev/tty, /dev/stdin).
    var e: std.os.linux.E = .SUCCESS;
    const st = sys.fileStat(path, true, &e) orelse return false;
    if (st.mode & 0o170000 != 0o020000) return false;
    const fd = sys.openFd(path, sys.O.RDONLY | sys.O.NOCTTY | sys.O.NONBLOCK, 0, &e) orelse return false;
    defer _ = sys.closeFd(fd);
    return (Io.File{ .handle = fd, .flags = .{ .nonblocking = true } }).isTty(ctx.io) catch false;
}

/// A pager process fed through a pipe. Started only for a terminal view and only
/// when one is configured; if it cannot be started the built-in pager is used.
const Pager = struct {
    child: std.process.Child,
    stdin: Io.File,

    const Choice = union(enum) {
        /// Write straight to the terminal.
        off,
        /// None is configured (or it cannot be started).
        built_in,
        process: Pager,
    };

    /// --pager, $BAT_PAGER, then $PAGER. `less` without arguments gets
    /// `-FRX` (quit if one screen, pass colors, keep the screen) as in bat.
    /// A pager that is just `cat` is the usual way to ask for no paging.
    fn start(ctx: cli.Context, given: ?[]const u8) Choice {
        const cmd = given orelse cli.getenv(ctx, "BAT_PAGER") orelse cli.getenv(ctx, "PAGER") orelse return .built_in;
        var arena_state: std.heap.ArenaAllocator = .init(ctx.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // Quoted as for a shell. A backslash is part of a Windows path.
        const line = if (builtin.os.tag == .windows)
            std.mem.replaceOwned(u8, arena, cmd, "\\", "\\\\") catch return .off
        else
            cmd;
        const words = timing.splitCommand(arena, line) catch |e| switch (e) {
            error.OutOfMemory => return .off,
            error.UnterminatedQuote => {
                cli.warn(ctx, "the pager command has an unterminated quote; not paging", .{});
                return .off;
            },
        };
        if (words.len == 0) return .built_in;
        var argv = std.mem.concat(arena, []const u8, &.{ words, &.{"-FRX"} }) catch return .off;
        var n: usize = words.len;
        const base = std.Io.Dir.path.basename(argv[0]);
        if (n == 1 and (std.mem.eql(u8, base, "cat") or std.ascii.eqlIgnoreCase(base, "cat.exe"))) return .off;
        if (n == 1 and (std.mem.eql(u8, base, "less") or std.mem.eql(u8, base, "less.exe"))) {
            n = 2; // the "-FRX" appended above
        }
        var environ: ?std.process.Environ.Map = null;
        defer if (environ) |*m| m.deinit();
        if (ctx.environ) |inherited| {
            // Without the mark the pager must not be started.
            environ = inherited.clone(ctx.gpa) catch return .off;
            environ.?.put(in_pager_variable, "1") catch return .off;
        }
        const child = std.process.spawn(ctx.io, .{
            .argv = argv[0..n],
            .stdin = .pipe,
            .environ_map = if (environ) |*m| m else null,
        }) catch return .built_in;
        const f = child.stdin orelse return .built_in;
        // Ctrl-C belongs to the pager while it runs (it uses it for searches).
        _ = sys.setSignal(sys.signo.INT, .ignore);
        // And a pager that goes away must not take cat with it unreported.
        sys.ignoreSignal(.pipe);
        return .{ .process = .{ .child = child, .stdin = f } };
    }

    /// Close the pipe and wait until the user leaves the pager. Returns its
    /// exit status when that reports a failure.
    fn finish(p: *Pager, ctx: cli.Context) ?u8 {
        p.stdin.close(ctx.io);
        p.child.stdin = null;
        const term = p.child.wait(ctx.io) catch return null;
        return switch (term) {
            .exited => |code| if (code == 0) null else code,
            else => null,
        };
    }
};

fn report(context: ?*anyopaque, ev: cat.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    var name = cli.quote(ev.name);
    const env: cat.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    name.utf8 = fu.localeIsUtf8(env);
    cli.warn(ctx.*, "{f}: {s}", .{ name, cli.errText(ev.err) });
}

/// A directory under the user's cat configuration ($XDG_CONFIG_HOME/cat or
/// ~/.config/cat, and %APPDATA%\cat on Windows). Caller frees.
fn configDir(ctx: cli.Context, sub: []const u8) ?[]u8 {
    if (absoluteDir(ctx, "XDG_CONFIG_HOME")) |x| return std.Io.Dir.path.join(ctx.gpa, &.{ x, "cat", sub }) catch null;
    if (absoluteDir(ctx, "HOME")) |h| return std.Io.Dir.path.join(ctx.gpa, &.{ h, ".config", "cat", sub }) catch null;
    if (absoluteDir(ctx, "APPDATA")) |a| return std.Io.Dir.path.join(ctx.gpa, &.{ a, "cat", sub }) catch null;
    return null;
}

/// The directory a variable names, when it names one from the root. As the XDG
/// specification asks, an empty or relative value does not count: it would
/// take grammars and themes from wherever the user happens to be.
fn absoluteDir(ctx: cli.Context, name: []const u8) ?[]const u8 {
    const value = cli.getenv(ctx, name) orelse return null;
    return if (std.Io.Dir.path.isAbsolute(value)) value else null;
}

/// Pick the theme: --theme, else $BAT_THEME, else `auto` (a light or dark
/// theme by the terminal background, only when the terminal shows more than
/// the 16 palette colors; otherwise the palette-following `ansi`). False
/// (after a message) when the named theme does not exist.
fn selectTheme(ctx: cli.Context, session: *syntax.session.Session, given: ?[]const u8, dark: ?[]const u8, light: ?[]const u8, tty: bool) bool {
    const requested = given orelse cli.getenv(ctx, "BAT_THEME") orelse "auto";
    const depth = termcolors.depth(ctx);
    var name = requested;
    const is_auto = std.ascii.eqlIgnoreCase(requested, "auto");
    if (is_auto or std.ascii.eqlIgnoreCase(requested, "dark") or std.ascii.eqlIgnoreCase(requested, "light")) {
        if (is_auto and depth == .ansi16) {
            session.theme.use(ctx.gpa, &syntax.theme.default_rules, false, depth);
            return true;
        }
        const look: termcolors.Appearance = if (is_auto)
            termcolors.appearance(ctx, tty)
        else if (std.ascii.eqlIgnoreCase(requested, "light")) .light else .dark;
        name = switch (look) {
            .light => light orelse cli.getenv(ctx, "BAT_THEME_LIGHT") orelse "day",
            .dark => dark orelse cli.getenv(ctx, "BAT_THEME_DARK") orelse "night",
        };
    }
    if (syntax.theme.findBuiltin(name)) |b| {
        session.theme.use(ctx.gpa, b.rules, false, depth);
        return true;
    }
    if (loadUserTheme(ctx, name)) |rules| {
        session.theme.use(ctx.gpa, rules, true, depth);
        return true;
    }
    cli.warn(ctx, "unknown theme '{s}' (see --list-themes)", .{name});
    return false;
}

fn loadUserTheme(ctx: cli.Context, name: []const u8) ?[]syntax.theme.Rule {
    if (std.mem.indexOfAny(u8, name, "/\\") != null or name.len == 0) return null;
    const dir = configDir(ctx, "themes") orelse return null;
    defer ctx.gpa.free(dir);
    const file = std.fmt.allocPrint(ctx.gpa, "{s}.theme", .{name}) catch return null;
    defer ctx.gpa.free(file);
    const full = std.Io.Dir.path.join(ctx.gpa, &.{ dir, file }) catch return null;
    defer ctx.gpa.free(full);
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, full, ctx.gpa, .limited(1 << 20)) catch return null;
    defer ctx.gpa.free(text);
    const parsed = syntax.theme.parse(ctx.gpa, text) catch return null;
    if (parsed == null) cli.warn(ctx, "{f}: malformed theme file", .{cli.quote(full)});
    return parsed;
}

fn listThemes(ctx: cli.Context) u8 {
    var out = cli.Out.init(ctx.io);
    for (syntax.theme.builtin_themes) |t| {
        out.write(t.name);
        out.write(if (std.mem.eql(u8, t.name, "ansi")) "\tfollows the terminal palette\n" else if (t.light) "\tlight\n" else "\tdark\n");
    }
    if (configDir(ctx, "themes")) |dir| {
        defer ctx.gpa.free(dir);
        if (Io.Dir.cwd().openDir(ctx.io, dir, .{ .iterate = true })) |d_const| {
            var d = d_const;
            defer d.close(ctx.io);
            var it = d.iterate();
            while (it.next(ctx.io) catch null) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".theme")) continue;
                out.write(entry.name[0 .. entry.name.len - ".theme".len]);
                out.write("\tuser theme\n");
            }
        } else |_| {}
    }
    out.flush();
    return if (out.failed) 1 else 0;
}

/// Load grammars from --syntax-dir directories and the user config directory
/// ($XDG_CONFIG_HOME/cat/syntaxes or ~/.config/cat/syntaxes).
fn loadGrammars(ctx: cli.Context, session: *syntax.session.Session, extra_dirs: []const []const u8) void {
    for (extra_dirs) |d| _ = session.loadDir(ctx.io, d) catch {};
    const dir: ?[]u8 = configDir(ctx, "syntaxes");
    if (dir) |d| {
        defer ctx.gpa.free(d);
        _ = session.loadDir(ctx.io, d) catch {};
    }
    // Built-in grammars last: the user's own are found first.
    _ = session.loadBuiltin() catch {};
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
        "      --style=LIST         comma list of: full, plain, header, grid, numbers, changes\n" ++
        "      --color=WHEN         auto, always or never\n" ++
        "      --decorations=WHEN   auto, always or never (always forces the view in pipes)\n" ++
        "      --paging=WHEN        auto (terminal view), always or never; pages through\n" ++
        "                           $BAT_PAGER, $PAGER or `less -FRX`; with none set, the\n" ++
        "                           built-in pager (see less --help) scrolls while cat writes\n" ++
        "  -P, --no-paging          same as --paging=never\n" ++
        "      --pager=CMD          the pager command (just cat: no paging)\n" ++
        "  -l, --language=NAME      highlight as NAME (language, scope or extension)\n" ++
        "      --syntax-dir=DIR     also load .sublime-syntax grammars from DIR\n" ++
        "      --list-languages     list loaded grammars\n" ++
        "      --theme=NAME         color theme: auto (default), dark, light, or a name from\n" ++
        "                           --list-themes ($BAT_THEME); auto asks the terminal whether\n" ++
        "                           its background is dark or light\n" ++
        "      --theme-dark=NAME    theme used when the background is dark (default night)\n" ++
        "      --theme-light=NAME   theme used when it is light (default day)\n" ++
        "      --list-themes        list the themes\n\n" ++
        "Grammars are read from --syntax-dir and ~/.config/cat/syntaxes (about 70 are\n" ++
        "built in); themes from ~/.config/cat/themes/NAME.theme. Highlighting is used\n" ++
        "only in the bat view with color on.\n")) 0 else 1;
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
    if (opt.len >= 2 and opt[0] == '-' and opt[1] != '-') {
        cli.invalidShort(ctx, opt[1]);
    } else cli.warn(ctx, "unrecognized option '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}
