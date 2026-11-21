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
const Io = std.Io;
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const syntax = @import("../syntax/root.zig");
const cat = @import("../lib/cat.zig");

const Options = cat.Options;
const Style = cat.Style;

const When = cli.When;

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
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: cat.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = cat.run(env, lib_opts, lib_inputs.items, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return fail(ctx, "out of memory"),
        error.WriteFailed => {
            // `cli.finish` words the write error.
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: cat.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err) });
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
    if (opt.len >= 2 and opt[0] == '-' and opt[1] != '-') {
        cli.invalidShort(ctx, opt[1]);
    } else cli.warn(ctx, "unrecognized option '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}
