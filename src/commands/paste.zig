// SPDX-License-Identifier: GPL-2.0-or-later
//! paste — merge corresponding lines of files.
//! References: GNU coreutils manual "paste invocation" (9.7); POSIX.1-2024
//! paste.
//!
//! Parallel mode joins line N of every file with the delimiters in -d (used
//! circularly, restarting for each output line); -s joins all lines of each
//! file. An exhausted file behaves like empty lines. Every `-` operand reads
//! successive lines from the one shared standard input. With no operand GNU
//! reads standard input (POSIX requires at least one).

const std = @import("std");
const cli = @import("../cli.zig");
const paste = @import("../lib/paste.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "serial", "delimiters", "zero-terminated", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var serial = false;
    var delim_text: []const u8 = "\t";
    var term: u8 = '\n';
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            switch (k) {
                0 => serial = true,
                1 => {
                    if (eq) |e| {
                        delim_text = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--delimiters' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        delim_text = args[i];
                    }
                },
                2 => term = 0,
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            's' => serial = true,
            'z' => term = 0,
            'd' => {
                if (j + 1 < a.len) {
                    delim_text = a[j + 1 ..];
                } else {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 'd'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    delim_text = args[i];
                }
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    var inputs: std.ArrayList(paste.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        inputs.append(ctx.gpa, .{ .name = "-", .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (files.items) |path| {
        const in: paste.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: paste.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = paste.run(env, .{ .serial = serial, .delimiters = delim_text, .terminator = term }, inputs.items, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.UnescapedBackslash => {
            cli.warn(ctx, "delimiter list ends with an unescaped backslash: {s}", .{delim_text});
            return 1;
        },
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: paste.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err) });
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: paste [OPTION]... [FILE]...\n" ++
        "Write lines consisting of the sequentially corresponding lines from\n" ++
        "each FILE, separated by TABs, to standard output.\n\n" ++
        "  -d, --delimiters=LIST   reuse characters from LIST instead of TABs\n" ++
        "  -s, --serial            paste one file at a time instead of in parallel\n" ++
        "  -z, --zero-terminated   line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
