// SPDX-License-Identifier: GPL-2.0-or-later
//! stat — display file or file system status.
//! Thin wrapper over `util_core.stat` (decision 0004): GNU's option parsing,
//! the diagnostics' wording and the exit status are here; the format engine,
//! the default/terse formats and the --json output are in src/lib/stat.zig.
//! Reference: GNU coreutils manual "stat invocation" (9.7).

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const stat = @import("../lib/stat.zig");
const Io = std.Io;

const help_text = @embedFile("../help/stat.txt");

/// Words the library's events as GNU does. Failures to examine a file flush
/// the output so far first, like GNU's buffered stdout does not (it is
/// line-ordered by the diagnostics below).
const Report = struct {
    ctx: cli.Context,
    out: *Io.Writer,

    fn report(context: ?*anyopaque, ev: stat.Event) void {
        const self: *Report = @ptrCast(@alignCast(context.?));
        const ctx = self.ctx;
        if (ev.isStatFailure()) self.out.flush() catch {};
        switch (ev) {
            .stdin_in_fs_mode => |name| cli.warn(ctx, "using {f} to denote standard input does not work in file system mode", .{cli.quoteA(name)}),
            .cannot_statfs => |e| cli.warn(ctx, "cannot read file system information for {f}: {s}", .{ cli.quoteA(e.name), sys.errnoText(e.errno) }),
            .cannot_stat_stdin => cli.warn(ctx, "cannot stat standard input", .{}),
            .cannot_stat => |e| cli.warn(ctx, "cannot statx {f}: {s}", .{ cli.quoteA(e.name), sys.errnoText(e.errno) }),
            .cannot_read_link => |e| cli.warn(ctx, "cannot read symbolic link {f}: {s}", .{ cli.quoteA(e.name), cli.errText(e.err) }),
            .cannot_get_context => |e| cli.warn(ctx, "failed to get security context of {f}: {s}", .{ cli.quoteA(e.name), sys.errnoText(e.errno) }),
            .cannot_canonicalize => |name| cli.warn(ctx, "failed to canonicalize {f}: No such file or directory", .{cli.quoteA(name)}),
            .out_of_memory => cli.warn(ctx, "memory exhausted", .{}),
            .unrecognized_escape => |c| cli.warn(ctx, "warning: unrecognized escape '\\{c}'", .{c}),
            .backslash_at_end => cli.warn(ctx, "warning: backslash at end of format", .{}),
            .invalid_directive => |text| cli.warn(ctx, "{f}: invalid directive", .{cli.quoteC(text)}),
        }
    }
};

pub fn main(ctx: cli.Context) u8 {
    var fs_mode = false;
    var terse = false;
    var format: ?[]const u8 = null;
    var printf_mode = false;
    var follow = false;
    var as_json = false;

    var p = getopt.Parser.init(ctx, "c:fLt", &.{
        .{ .name = "dereference", .id = 'L' },
        .{ .name = "file-system", .id = 'f' },
        .{ .name = "format", .arg = .required, .id = 'c' },
        .{ .name = "printf", .arg = .required, .id = 1100 },
        .{ .name = "terse", .id = 't' },
        .{ .name = "cached", .arg = .required, .id = 1101 },
        .{ .name = "json", .id = 1102 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            1100 => {
                format = o.arg;
                printf_mode = true;
            },
            'c' => {
                format = o.arg;
                printf_mode = false;
            },
            'L' => follow = true,
            'f' => fs_mode = true,
            't' => terse = true,
            1102 => as_json = true,
            1101 => {
                const names = [_][]const u8{ "default", "never", "always" };
                var found = false;
                for (names) |n| if (std.mem.startsWith(u8, n, o.arg.?)) {
                    found = true;
                };
                if (!found) {
                    cli.warn(ctx, "invalid argument {f} for '--cached'\nValid arguments are:\n  - 'default'\n  - 'never'\n  - 'always'\nTry '{s} --help' for more information.", .{ cli.quoteC(o.arg.?), ctx.name });
                    return 1;
                }
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (as_json and (format != null or terse)) {
        cli.warn(ctx, "--json cannot be combined with --format, --printf or --terse", .{});
        return 1;
    }
    // %N quotes with shell-escape-always only when the user gave a format.
    var quoting: []const u8 = "literal";
    const quote_always = format != null and std.mem.indexOf(u8, format.?, "%N") != null;
    if (quote_always) {
        quoting = "shell-escape-always";
        if (cli.getenv(ctx, "QUOTING_STYLE")) |qs| {
            var ok_style = false;
            for (stat.quoting_styles) |v| if (std.mem.eql(u8, v, qs)) {
                ok_style = true;
            };
            if (ok_style) {
                quoting = qs;
            } else {
                cli.warn(ctx, "ignoring invalid value of environment variable QUOTING_STYLE: {f}", .{cli.quoteC(qs)});
            }
        }
    }
    const files = p.operands.items;
    if (files.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 1;
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    var rep: Report = .{ .ctx = ctx, .out = &stdout.interface };
    const env: stat.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = stat.run(env, .{
        .fs_mode = fs_mode,
        .follow = follow,
        .terse = terse,
        .format = format,
        .printf_mode = printf_mode,
        .json = as_json,
        .quoting = quoting,
    }, files, &stdout.interface, .{ .context = &rep, .func = Report.report }) catch |e| switch (e) {
        error.OutOfMemory => return 1,
        // GNU: the directive diagnostic was printed; the output so far stays.
        error.InvalidDirective => {
            _ = cli.flushWriter(&stdout);
            return 1;
        },
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    if (!cli.flushWriter(&stdout)) return 1;
    return if (result.failed) 1 else 0;
}
