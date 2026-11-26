// SPDX-License-Identifier: GPL-2.0-or-later
//! locate: thin wrapper over `util_core.locate` (decision 0004). Parses the
//! options as GNU locate does and words the database diagnostics; the
//! database decoding, matching and reports are in src/lib/locate.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const locate = @import("../lib/locate.zig");
const fu = @import("../lib/fu_common.zig");
const Io = std.Io;

/// These commands have always used the general-purpose allocator without
/// leak checking (their results live until exit).

pub const default_db = locate.default_db;

fn q(_: cli.Context, text: []const u8) cli.QuotedC {
    return cli.quoteC(text);
}

fn usageText(ctx: cli.Context) []const u8 {
    _ = ctx;
    return
    \\Usage: %s [-d path | --database=path] [-e | -E | --[non-]existing]
    \\      [-i | --ignore-case] [-w | --wholename] [-b | --basename]
    \\      [--limit=N | -l N] [-S | --statistics] [-0 | --null] [-c | --count]
    \\      [-P | -H | --nofollow] [-L | --follow] [-m | --mmap] [-s | --stdio]
    \\      [-A | --all] [-p | --print] [-r | --regex] [--regextype=TYPE]
    \\      [--max-database-age D] [--version] [--help]
    \\      pattern...
    \\Please see also the documentation at https://www.gnu.org/software/findutils/.
    \\You can report (and track progress on fixing) bugs in the "%s"
    \\program via the GNU findutils bug-reporting page at
    \\https://savannah.gnu.org/bugs/?group=findutils or, if
    \\you have no web access, by sending email to <bug-findutils@gnu.org>.
    \\
    ;
}

fn report(context: ?*anyopaque, ev: locate.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .open_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ q(ctx.*, e.name), e.text }),
        .stat_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ q(ctx.*, e.name), e.text }),
        .stdin_twice => cli.warn(ctx.*, "warning: the locate database can only be read from stdin once.", .{}),
        .database_old => |e| cli.warn(ctx.*, "warning: database {f} is more than {d} days old (actual age is {d:.1} days)", .{ q(ctx.*, e.name), e.max_days, e.age_days }),
        .unsupported_slocate_level => |e| cli.warn(ctx.*, "{f} is an slocate database of unsupported security level {d}; skipping it.", .{ q(ctx.*, e.name), e.level }),
        .slocate_non_existing_unsupported => cli.warn(ctx.*, "You specified the -E option, but that option cannot be used with slocate-format databases with a non-zero security level.  No results will be generated for this database.\n", .{}),
        .slocate_existing_forced => |n| cli.warn(ctx.*, "{f} is an slocate database.  Turning on the '-e' option.", .{q(ctx.*, n)}),
        .old_format_too_short => |n| cli.warn(ctx.*, "Old-format locate database {f} is too short to be valid", .{q(ctx.*, n)}),
        .old_format => |n| cli.warn(ctx.*, "old-format locate database {f} is not supported", .{q(ctx.*, n)}),
        .corrupt => |n| cli.warn(ctx.*, "locate database {f} is corrupt or invalid", .{q(ctx.*, n)}),
        .bad_regex => |t| cli.warn(ctx.*, "{s}", .{t}),
    }
}

pub fn main(ctx: cli.Context) u8 {
    var o: locate.Options = .{ .follow = true };
    var print_flag = false;
    var limit_set = false;
    var p = getopt.Parser.init(ctx, "Abcd:eEil:prsm0SwHPL", &.{
        .{ .name = "database", .arg = .required, .id = 'd' },
        .{ .name = "existing", .id = 'e' },
        .{ .name = "non-existing", .id = 'E' },
        .{ .name = "ignore-case", .id = 'i' },
        .{ .name = "all", .id = 'A' },
        .{ .name = "null", .id = '0' },
        .{ .name = "count", .id = 'c' },
        .{ .name = "wholename", .id = 'w' },
        .{ .name = "wholepath", .id = 'w' },
        .{ .name = "basename", .id = 'b' },
        .{ .name = "print", .id = 'p' },
        .{ .name = "stdio", .id = 's' },
        .{ .name = "mmap", .id = 'm' },
        .{ .name = "limit", .arg = .required, .id = 'l' },
        .{ .name = "regex", .id = 'r' },
        .{ .name = "regextype", .arg = .required, .id = 2000 },
        .{ .name = "statistics", .id = 'S' },
        .{ .name = "follow", .id = 'L' },
        .{ .name = "nofollow", .id = 'P' },
        .{ .name = "max-database-age", .arg = .required, .id = 2001 },
    });
    defer p.deinit();
    o.database_path = cli.getenv(ctx, "LOCATE_PATH");
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |opt| switch (opt.id) {
            '0' => {
                o.separator = 0;
            },
            'A' => o.match_all = true,
            'b' => o.basename_only = true,
            'c' => o.count_only = true,
            'd' => o.database_path = opt.arg.?,
            'e' => o.check = .existing,
            'E' => o.check = .non_existing,
            'i' => o.ignore_case = true,
            'p' => print_flag = true,
            'w' => o.basename_only = false,
            'r' => o.use_regex = true,
            'S' => o.statistics = true,
            'L' => o.follow = true,
            'P', 'H' => o.follow = false,
            's', 'm' => {},
            'l' => {
                const a = opt.arg.?;
                var dend: usize = 0;
                while (dend < a.len and std.ascii.isDigit(a[dend])) dend += 1;
                if (dend == 0) {
                    if (opt.is_long) cli.warn(ctx, "invalid --limit argument {f}", .{q(ctx, a)}) else cli.warn(ctx, "invalid -l argument {f}", .{q(ctx, a)});
                    return 1;
                }
                const v = std.fmt.parseInt(u64, a[0..dend], 10) catch {
                    if (opt.is_long) cli.warn(ctx, "--limit argument {f} too large", .{q(ctx, a)}) else cli.warn(ctx, "-l argument {f} too large", .{q(ctx, a)});
                    return 1;
                };
                o.limit = v;
                limit_set = true;
            },
            2000 => {
                o.regex_syntax = fu.RegexSyntax.parse(opt.arg.?) orelse {
                    cli.warn(ctx, "Unknown regular expression type {f}; valid types are 'findutils-default', 'ed', 'emacs', 'gnu-awk', 'grep', 'posix-awk', 'awk', 'posix-basic', 'posix-egrep', 'egrep', 'posix-extended', 'posix-minimal-basic', 'sed'.", .{q(ctx, opt.arg.?)});
                    return 1;
                };
            },
            2001 => {
                const a = opt.arg.?;
                if (a.len == 0) {
                    cli.warn(ctx, "The argument for option --max-database-age must not be empty", .{});
                    return 1;
                }
                o.max_age_days = std.fmt.parseInt(u64, a, 10) catch {
                    cli.warn(ctx, "Invalid argument {f} for option --max-database-age", .{q(ctx, a)});
                    return 1;
                };
            },
            getopt.help_id => {
                const t = usageText(ctx);
                const a1 = std.mem.replaceOwned(u8, ctx.gpa, t, "%s", ctx.name) catch return 1;
                defer ctx.gpa.free(a1);
                return if (cli.writeStdout(ctx.io, a1)) 0 else 1;
            },
            getopt.version_id => {
                const v =
                    \\locate (GNU findutils) 4.10.0
                    \\Copyright (C) 2024 Free Software Foundation, Inc.
                    \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
                    \\This is free software: you are free to change and redistribute it.
                    \\There is NO WARRANTY, to the extent permitted by law.
                    \\
                    \\Written by Eric B. Decker, James Youngman, and Kevin Dalley.
                    \\
                ;
                return if (cli.writeStdout(ctx.io, v)) 0 else 1;
            },
            else => return 1,
        },
    };
    const patterns = p.operands.items;
    o.print = print_flag or (!o.count_only and !o.statistics);
    if (o.statistics) {
        if (patterns.len == 0) o.limit = null;
    } else if (!o.count_only and patterns.len == 0) {
        cli.warn(ctx, "pattern argument expected", .{});
        cli.warn(ctx, "Try '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    o.stdin = Io.File.stdin();
    o.terminal = Io.File.stdout().isTty(ctx.io) catch false;

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: locate.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    o.utf8 = fu.localeIsUtf8(env);
    const result = locate.run(env, o, patterns, &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
        error.OutOfMemory => {
            cli.warn(ctx, "memory exhausted", .{});
            return 1;
        },
        error.Fatal => return 1,
    };
    if (result.write_failed) cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
    return result.exit_status;
}
