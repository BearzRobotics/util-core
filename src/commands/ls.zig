// SPDX-License-Identifier: GPL-2.0-or-later
//! ls, dir and vdir — list directory contents.
//! Thin wrapper over `util_core.ls` (decision 0004): GNU's option parsing, the
//! defaults that depend on the terminal and on environment variables, the
//! --time-style validation and the wording of diagnostics are here; the
//! listing itself (sorting, quoting, colours, columns, the long format, --json)
//! is in src/lib/ls.zig. dir and vdir (src/commands/dir.zig, vdir.zig) call
//! `run` with their own mode.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "ls invocation"
//! (9.7), POSIX.1-2024 ls, and GNU coreutils 9.6 src/ls.c.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const quotearg = @import("../quotearg.zig");
const human = @import("../human.zig");
const argmatch = @import("../argmatch.zig");
const ls = @import("../lib/ls.zig");
const Io = std.Io;

const help_ls = @embedFile("../help/ls.txt");
const help_dir = @embedFile("../help/dir.txt");
const help_vdir = @embedFile("../help/vdir.txt");

pub const Mode = enum { ls, multi_col, long };

const Format = ls.Format;
const IndicatorStyle = ls.IndicatorStyle;
const SortType = ls.SortType;
const MIN_COLUMN_WIDTH = 3;

/// Words the library's events as GNU does.
const Report = struct {
    ctx: cli.Context,

    fn report(context: ?*anyopaque, ev: ls.Event) void {
        const self: *Report = @ptrCast(@alignCast(context.?));
        const ctx = self.ctx;
        switch (ev) {
            .failure => |f| {
                const msg: []const u8 = switch (f.kind) {
                    .canonicalize => "error canonicalizing",
                    .cannot_access => "cannot access",
                    .cannot_read_link => "cannot read symbolic link",
                    .cannot_open_dir => "cannot open directory",
                    .cannot_determine_dev_ino => "cannot determine device and inode of",
                    .reading_directory => "reading directory",
                };
                const text = switch (f.reason) {
                    .errno => |e| sys.errnoText(e),
                    .err => |e| cli.errText(e),
                };
                cli.warn(ctx, "{s} {f}: {s}", .{ msg, cli.quoteA(f.name), text });
            },
            .already_listed => |name| cli.warn(ctx, "{f}: not listing already-listed directory", .{cli.quote(name)}),
            .unrecognized_prefix => |lab| cli.warn(ctx, "unrecognized prefix: {f}", .{cli.quoteC(&lab)}),
            .unparsable_ls_colors => cli.warn(ctx, "unparsable value for LS_COLORS environment variable", .{}),
        }
    }
};

const Opt = struct {
    const author = 1100;
    const block_size = 1101;
    const color = 1102;
    const deref_cl_symlink_to_dir = 1103;
    const file_type = 1104;
    const format = 1105;
    const full_time = 1106;
    const group_dirs_first = 1107;
    const hide = 1108;
    const hyperlink = 1109;
    const indicator_style = 1110;
    const quoting_style = 1111;
    const show_control_chars = 1112;
    const si = 1113;
    const sort = 1114;
    const time = 1115;
    const time_style = 1116;
    const zero = 1117;
    const json = 1118;
    const classify = 'F';
};

const when_table = [_]argmatch.Entry{
    .{ .name = "always", .value = 1 }, .{ .name = "yes", .value = 1 },    .{ .name = "force", .value = 1 },
    .{ .name = "never", .value = 0 },  .{ .name = "no", .value = 0 },     .{ .name = "none", .value = 0 },
    .{ .name = "auto", .value = 2 },   .{ .name = "tty", .value = 2 },    .{ .name = "if-tty", .value = 2 },
};

const format_table = [_]argmatch.Entry{
    .{ .name = "verbose", .value = 0 },       .{ .name = "long", .value = 0 },
    .{ .name = "commas", .value = 4 },        .{ .name = "horizontal", .value = 3 },
    .{ .name = "across", .value = 3 },        .{ .name = "vertical", .value = 2 },
    .{ .name = "single-column", .value = 1 },
};

const sort_table = [_]argmatch.Entry{
    .{ .name = "none", .value = 6 },      .{ .name = "size", .value = 3 },    .{ .name = "time", .value = 5 },
    .{ .name = "version", .value = 4 },   .{ .name = "extension", .value = 1 }, .{ .name = "name", .value = 0 },
    .{ .name = "width", .value = 2 },
};

const time_table = [_]argmatch.Entry{
    .{ .name = "atime", .value = 2 },        .{ .name = "access", .value = 2 },       .{ .name = "use", .value = 2 },
    .{ .name = "ctime", .value = 1 },        .{ .name = "status", .value = 1 },
    .{ .name = "mtime", .value = 0 },        .{ .name = "modification", .value = 0 },
    .{ .name = "birth", .value = 3 },        .{ .name = "creation", .value = 3 },
};

const indicator_table = [_]argmatch.Entry{
    .{ .name = "none", .value = 0 },      .{ .name = "slash", .value = 1 },
    .{ .name = "file-type", .value = 2 }, .{ .name = "classify", .value = 3 },
};

const quoting_table = blk: {
    var t: [quotearg.style_names.len]argmatch.Entry = undefined;
    for (quotearg.style_names, 0..) |n, i| t[i] = .{ .name = n, .value = i };
    break :blk t;
};

const time_style_table = [_]argmatch.Entry{
    .{ .name = "full-iso", .value = 0 }, .{ .name = "long-iso", .value = 1 },
    .{ .name = "iso", .value = 2 },      .{ .name = "locale", .value = 3 },
};

fn xargmatch(ctx: cli.Context, arg: []const u8, context: []const u8, table: []const argmatch.Entry) ?u32 {
    const r = argmatch.match(arg, table);
    switch (r) {
        .ok => |v| return v,
        else => {
            argmatch.die(ctx, arg, context, table, r);
            return null;
        },
    }
}

fn decodeLineLength(spec: []const u8) ?usize {
    const p = human.strtoumax(spec, "");
    switch (p.err) {
        .ok => return if (p.value <= std.math.maxInt(isize)) @intCast(p.value) else 0,
        .overflow => return 0,
        else => return null,
    }
}

fn xstrtolFatal(ctx: cli.Context, e: human.StrtolError, option: []const u8, arg: []const u8) void {
    switch (e) {
        .invalid => cli.warn(ctx, "invalid {s} argument {f}", .{ option, cli.quoteC(arg) }),
        .invalid_suffix_char, .invalid_suffix_char_with_overflow => cli.warn(ctx, "invalid suffix in {s} argument {f}", .{ option, cli.quoteC(arg) }),
        .overflow => cli.warn(ctx, "{s} argument {f} too large", .{ option, cli.quoteC(arg) }),
        .ok => {},
    }
}

fn realMain(ctx: cli.Context, mode: Mode) u8 {
    var opts: ls.Options = .{ .output_block_size = 0 };
    var ignore_list: std.ArrayList([]const u8) = .empty;
    defer ignore_list.deinit(ctx.gpa);
    var hide_list: std.ArrayList([]const u8) = .empty;
    defer hide_list.deinit(ctx.gpa);
    const stdout_tty = Io.File.stdout().isTty(ctx.io) catch false;

    var time_style_option: ?[]const u8 = null;
    var kibibytes_specified = false;
    var format_opt: i32 = -1;
    var hide_control_chars_opt: i32 = -1;
    var quoting_style_opt: i32 = -1;
    var sort_opt: i32 = -1;
    var tabsize_opt: i64 = -1;
    var width_opt: i64 = -1;

    var p = getopt.Parser.init(ctx, "abcdfghiklmnopqrstuvw:xABCDFGHI:LNQRST:UXZ1", &.{
        .{ .name = "all", .id = 'a' },
        .{ .name = "escape", .id = 'b' },
        .{ .name = "directory", .id = 'd' },
        .{ .name = "dired", .id = 'D' },
        .{ .name = "full-time", .id = Opt.full_time },
        .{ .name = "group-directories-first", .id = Opt.group_dirs_first },
        .{ .name = "human-readable", .id = 'h' },
        .{ .name = "inode", .id = 'i' },
        .{ .name = "kibibytes", .id = 'k' },
        .{ .name = "numeric-uid-gid", .id = 'n' },
        .{ .name = "no-group", .id = 'G' },
        .{ .name = "hide-control-chars", .id = 'q' },
        .{ .name = "reverse", .id = 'r' },
        .{ .name = "size", .id = 's' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "almost-all", .id = 'A' },
        .{ .name = "ignore-backups", .id = 'B' },
        .{ .name = "classify", .arg = .optional, .id = 'F' },
        .{ .name = "file-type", .id = Opt.file_type },
        .{ .name = "si", .id = Opt.si },
        .{ .name = "dereference-command-line", .id = 'H' },
        .{ .name = "dereference-command-line-symlink-to-dir", .id = Opt.deref_cl_symlink_to_dir },
        .{ .name = "hide", .arg = .required, .id = Opt.hide },
        .{ .name = "ignore", .arg = .required, .id = 'I' },
        .{ .name = "indicator-style", .arg = .required, .id = Opt.indicator_style },
        .{ .name = "dereference", .id = 'L' },
        .{ .name = "literal", .id = 'N' },
        .{ .name = "quote-name", .id = 'Q' },
        .{ .name = "quoting-style", .arg = .required, .id = Opt.quoting_style },
        .{ .name = "recursive", .id = 'R' },
        .{ .name = "format", .arg = .required, .id = Opt.format },
        .{ .name = "show-control-chars", .id = Opt.show_control_chars },
        .{ .name = "sort", .arg = .required, .id = Opt.sort },
        .{ .name = "tabsize", .arg = .required, .id = 'T' },
        .{ .name = "time", .arg = .required, .id = Opt.time },
        .{ .name = "time-style", .arg = .required, .id = Opt.time_style },
        .{ .name = "zero", .id = Opt.zero },
        .{ .name = "json", .id = Opt.json },
        .{ .name = "color", .arg = .optional, .id = Opt.color },
        .{ .name = "hyperlink", .arg = .optional, .id = Opt.hyperlink },
        .{ .name = "block-size", .arg = .required, .id = Opt.block_size },
        .{ .name = "context", .id = 'Z' },
        .{ .name = "author", .id = Opt.author },
    });
    defer p.deinit();

    while (true) switch (p.next()) {
        .done => break,
        .bad => return 2,
        .opt => |o| switch (o.id) {
            'a' => opts.ignore_mode = .minimal,
            'b' => quoting_style_opt = @intFromEnum(quotearg.Style.escape),
            'c' => {
                opts.time_type = .ctime;
                opts.explicit_time = true;
            },
            'd' => opts.immediate_dirs = true,
            'f' => {
                opts.ignore_mode = .minimal;
                sort_opt = @intFromEnum(SortType.none);
            },
            Opt.file_type => opts.indicator_style = .file_type,
            'g' => {
                format_opt = @intFromEnum(Format.long);
                opts.print_owner = false;
            },
            'h' => {
                opts.file_human_output_opts = human.autoscale | human.si | human.base_1024;
                opts.human_output_opts = opts.file_human_output_opts;
                opts.file_output_block_size = 1;
                opts.output_block_size = 1;
            },
            'i' => opts.print_inode = true,
            'k' => kibibytes_specified = true,
            'l' => format_opt = @intFromEnum(Format.long),
            'm' => format_opt = @intFromEnum(Format.with_commas),
            'n' => {
                opts.numeric_ids = true;
                format_opt = @intFromEnum(Format.long);
            },
            'o' => {
                format_opt = @intFromEnum(Format.long);
                opts.print_group = false;
            },
            'p' => opts.indicator_style = .slash,
            'q' => hide_control_chars_opt = 1,
            'r' => opts.sort_reverse = true,
            's' => opts.print_block_size = true,
            't' => sort_opt = @intFromEnum(SortType.time),
            'u' => {
                opts.time_type = .atime;
                opts.explicit_time = true;
            },
            'v' => sort_opt = @intFromEnum(SortType.version),
            'w' => {
                const v = decodeLineLength(o.arg.?) orelse {
                    cli.warn(ctx, "invalid line width: {f}", .{cli.quoteC(o.arg.?)});
                    return 2;
                };
                width_opt = @intCast(v);
            },
            'x' => format_opt = @intFromEnum(Format.horizontal),
            'A' => opts.ignore_mode = .dot_and_dotdot,
            'B' => {
                ignore_list.append(ctx.gpa, "*~") catch {};
                ignore_list.append(ctx.gpa, ".*~") catch {};
            },
            'C' => format_opt = @intFromEnum(Format.many_per_line),
            'D' => {
                format_opt = @intFromEnum(Format.long);
                opts.print_hyperlink = false;
                opts.dired = true;
            },
            'F' => {
                const v: u32 = if (o.arg) |a| (xargmatch(ctx, a, "--classify", &when_table) orelse return 1) else 1;
                if (v == 1 or (v == 2 and stdout_tty)) opts.indicator_style = .classify;
            },
            'G' => opts.print_group = false,
            'H' => opts.dereference = .command_line_args,
            Opt.deref_cl_symlink_to_dir => opts.dereference = .command_line_symlink_to_dir,
            'I' => ignore_list.append(ctx.gpa, o.arg.?) catch {},
            'L' => opts.dereference = .always,
            'N' => quoting_style_opt = @intFromEnum(quotearg.Style.literal),
            'Q' => quoting_style_opt = @intFromEnum(quotearg.Style.c),
            'R' => opts.recursive = true,
            'S' => sort_opt = @intFromEnum(SortType.size),
            'T' => {
                const arg = o.arg.?;
                const r = human.strtoumax(arg, "");
                switch (r.err) {
                    .ok => tabsize_opt = @intCast(@min(r.value, std.math.maxInt(i64))),
                    .overflow => {
                        cli.warn(ctx, "invalid tab size: {f}: Value too large for defined data type", .{cli.quoteC(arg)});
                        return 2;
                    },
                    else => {
                        cli.warn(ctx, "invalid tab size: {f}", .{cli.quoteC(arg)});
                        return 2;
                    },
                }
            },
            'U' => sort_opt = @intFromEnum(SortType.none),
            'X' => sort_opt = @intFromEnum(SortType.extension),
            '1' => if (format_opt != @intFromEnum(Format.long)) {
                format_opt = @intFromEnum(Format.one_per_line);
            },
            Opt.author => opts.print_author = true,
            Opt.json => opts.json = true,
            Opt.hide => hide_list.append(ctx.gpa, o.arg.?) catch {},
            Opt.sort => sort_opt = @intCast(xargmatch(ctx, o.arg.?, "--sort", &sort_table) orelse return 1),
            Opt.group_dirs_first => opts.directories_first = true,
            Opt.time => {
                opts.time_type = @enumFromInt(xargmatch(ctx, o.arg.?, "--time", &time_table) orelse return 1);
                opts.explicit_time = true;
            },
            Opt.format => format_opt = @intCast(xargmatch(ctx, o.arg.?, "--format", &format_table) orelse return 1),
            Opt.full_time => {
                format_opt = @intFromEnum(Format.long);
                time_style_option = "full-iso";
            },
            Opt.color => {
                const v: u32 = if (o.arg) |a| (xargmatch(ctx, a, "--color", &when_table) orelse return 1) else 1;
                opts.print_with_color = v == 1 or (v == 2 and stdout_tty);
            },
            Opt.hyperlink => {
                const v: u32 = if (o.arg) |a| (xargmatch(ctx, a, "--hyperlink", &when_table) orelse return 1) else 1;
                opts.print_hyperlink = v == 1 or (v == 2 and stdout_tty);
            },
            Opt.indicator_style => opts.indicator_style = @enumFromInt(xargmatch(ctx, o.arg.?, "--indicator-style", &indicator_table) orelse return 1),
            Opt.quoting_style => quoting_style_opt = @intCast(xargmatch(ctx, o.arg.?, "--quoting-style", &quoting_table) orelse return 1),
            Opt.time_style => time_style_option = o.arg.?,
            Opt.show_control_chars => hide_control_chars_opt = 0,
            Opt.block_size => {
                const arg = o.arg.?;
                const bs = human.options(arg, null, false);
                if (bs.err != .ok) {
                    xstrtolFatal(ctx, bs.err, "--block-size", arg);
                    return 2;
                }
                opts.human_output_opts = bs.opts;
                opts.output_block_size = bs.size;
                opts.file_human_output_opts = bs.opts;
                opts.file_output_block_size = bs.size;
            },
            Opt.si => {
                opts.file_human_output_opts = human.autoscale | human.si;
                opts.human_output_opts = opts.file_human_output_opts;
                opts.file_output_block_size = 1;
                opts.output_block_size = 1;
            },
            'Z' => opts.print_scontext = true,
            Opt.zero => {
                opts.eolbyte = 0;
                hide_control_chars_opt = 0;
                if (format_opt != @intFromEnum(Format.long)) format_opt = @intFromEnum(Format.one_per_line);
                opts.print_with_color = false;
                quoting_style_opt = @intFromEnum(quotearg.Style.literal);
            },
            getopt.help_id => {
                const ok = switch (mode) {
                    .ls => cli.writeStdout(ctx.io, help_ls ++ "\n"),
                    .multi_col => cli.writeStdout(ctx.io, help_dir ++ "\n"),
                    .long => cli.writeStdout(ctx.io, help_vdir ++ "\n"),
                };
                return if (ok) 0 else 2;
            },
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 2,
            else => unreachable,
        },
    };

    if (opts.output_block_size == 0) {
        const ls_bs = cli.getenv(ctx, "LS_BLOCK_SIZE");
        const env_bs = ls_bs orelse (cli.getenv(ctx, "BLOCK_SIZE") orelse cli.getenv(ctx, "BLOCKSIZE"));
        const posix = cli.getenv(ctx, "POSIXLY_CORRECT") != null;
        const bs = human.options(ls_bs, env_bs, posix);
        opts.human_output_opts = bs.opts;
        opts.output_block_size = bs.size;
        if (ls_bs != null or cli.getenv(ctx, "BLOCK_SIZE") != null) {
            opts.file_human_output_opts = opts.human_output_opts;
            opts.file_output_block_size = opts.output_block_size;
        }
        if (kibibytes_specified) {
            opts.human_output_opts = 0;
            opts.output_block_size = 1024;
        }
    }

    opts.format = if (format_opt >= 0) @enumFromInt(format_opt) else switch (mode) {
        .ls => if (stdout_tty) Format.many_per_line else Format.one_per_line,
        .multi_col => Format.many_per_line,
        .long => Format.long,
    };

    var linelen: i64 = width_opt;
    if (opts.format == .many_per_line or opts.format == .horizontal or opts.format == .with_commas or opts.print_with_color) {
        if (linelen < 0) {
            if (stdout_tty) {
                if (sys.terminalColumns()) |c| {
                    if (c > 0) linelen = @intCast(c);
                }
            }
        }
        if (linelen < 0) {
            if (cli.getenv(ctx, "COLUMNS")) |c| {
                if (c.len > 0) {
                    if (decodeLineLength(c)) |v| {
                        linelen = @intCast(v);
                    } else {
                        cli.warn(ctx, "ignoring invalid width in environment variable COLUMNS: {f}", .{cli.quoteC(c)});
                    }
                }
            }
        }
    }
    opts.line_length = if (linelen < 0) 80 else @intCast(linelen);
    if (opts.format == .many_per_line or opts.format == .horizontal or opts.format == .with_commas) {
        if (tabsize_opt >= 0) {
            opts.tabsize = @intCast(tabsize_opt);
        } else {
            opts.tabsize = 8;
            if (cli.getenv(ctx, "TABSIZE")) |t| {
                const r = human.strtoumax(t, "");
                if (r.err == .ok) {
                    opts.tabsize = @intCast(r.value);
                } else {
                    cli.warn(ctx, "ignoring invalid tab size in environment variable TABSIZE: {f}", .{cli.quoteC(t)});
                }
            }
        }
    }

    opts.qmark_funny_chars = if (hide_control_chars_opt < 0) (mode == .ls and stdout_tty) else hide_control_chars_opt != 0;

    var qs: i32 = quoting_style_opt;
    if (qs < 0) {
        if (cli.getenv(ctx, "QUOTING_STYLE")) |q| {
            switch (argmatch.match(q, &quoting_table)) {
                .ok => |v| qs = @intCast(v),
                else => cli.warn(ctx, "ignoring invalid value of environment variable QUOTING_STYLE: {f}", .{cli.quoteC(q)}),
            }
        }
    }
    if (qs < 0) {
        qs = if (mode == .ls)
            (if (stdout_tty) @intFromEnum(quotearg.Style.shell_escape) else -1)
        else
            @intFromEnum(quotearg.Style.escape);
    }
    if (qs >= 0) opts.filename_style = quotearg.style_values[@intCast(qs)];
    if (sort_opt >= 0) opts.sort_type = @enumFromInt(sort_opt);
    // Settings derived from the others (also what --json overrides).
    opts.normalize();
    if (opts.eolbyte < @intFromBool(opts.dired)) {
        cli.warn(ctx, "--dired and --zero are incompatible", .{});
        return 2;
    }


    if (opts.format == .long) {
        var style: []const u8 = time_style_option orelse (cli.getenv(ctx, "TIME_STYLE") orelse "locale");
        var posix_skipped = false;
        while (std.mem.startsWith(u8, style, "posix-")) {
            // hard_locale is false in the C locale: the style is ignored.
            posix_skipped = true;
            break;
        }
        if (!posix_skipped) {
            if (style.len > 0 and style[0] == '+') {
                const p0 = style[1..];
                if (std.mem.indexOfScalar(u8, p0, '\n')) |nl| {
                    const rest = p0[nl + 1 ..];
                    if (std.mem.indexOfScalar(u8, rest, '\n') != null) {
                        cli.warn(ctx, "invalid time style format {f}", .{cli.quoteC(p0)});
                        return 2;
                    }
                    opts.long_time_format = .{ p0[0..nl], rest };
                } else opts.long_time_format = .{ p0, p0 };
            } else {
                const r = argmatch.match(style, &time_style_table);
                switch (r) {
                    .ok => |v| switch (v) {
                        0 => opts.long_time_format = .{ "%Y-%m-%d %H:%M:%S.%N %z", "%Y-%m-%d %H:%M:%S.%N %z" },
                        1 => opts.long_time_format = .{ "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M" },
                        2 => opts.long_time_format = .{ "%Y-%m-%d ", "%m-%d %H:%M" },
                        else => {},
                    },
                    else => {
                        const q = quotearg.quoteAlloc(ctx.gpa, style, .locale, null) catch return 2;
                        defer ctx.gpa.free(q);
                        cli.warn(ctx, "{s} argument {s} for 'time style'\nValid arguments are:\n  - [posix-]full-iso\n  - [posix-]long-iso\n  - [posix-]iso\n  - [posix-]locale\n  - +FORMAT (e.g., +%H:%M) for a 'date'-style format\nTry '{s} --help' for more information.", .{ if (r == .ambiguous) "ambiguous" else "invalid", q, ctx.name });
                        return 2;
                    },
                }
            }
        }
        style = style;
    }

    opts.ignore_patterns = ignore_list.items;
    opts.hide_patterns = hide_list.items;

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    var rep: Report = .{ .ctx = ctx };
    const env: ls.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = ls.run(env, opts, p.operands.items, &stdout.interface, .{ .context = &rep, .func = Report.report });
    const rc = result.exit_status;
    if (!cli.flushWriter(&stdout) or result.write_failed) {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        if (rc == 0) {
            cli.writeErrorWarn(ctx);
            return 2;
        }
    }
    return rc;
}

pub fn main(ctx: cli.Context) u8 {
    return run(ctx, .ls);
}

pub fn run(ctx: cli.Context, mode: Mode) u8 {
    return realMain(ctx, mode);
}
