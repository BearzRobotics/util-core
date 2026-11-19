// SPDX-License-Identifier: GPL-2.0-or-later
//! tac — concatenate and print files in reverse.
//! Reference: GNU coreutils manual "tac invocation" (9.7). POSIX does not
//! specify tac.
//!
//! Each file is read completely into memory, split into records, and the
//! records are written last to first. Options: -b (separator attached before
//! the record), -s SEP (record separator; empty means NUL). Not implemented:
//! -r (regular-expression separator) is rejected with an error.

const std = @import("std");
const cli = @import("../cli.zig");
const tac = @import("../lib/tac.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "before", "regex", "separator", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var before = false;
    var sep: []const u8 = "\n";
    const args = ctx.args;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
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
                0 => before = true,
                1 => return regexUnsupported(ctx),
                2 => {
                    if (eq) |e| {
                        sep = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--separator' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        sep = args[i];
                    }
                },
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'b' => before = true,
            'r' => return regexUnsupported(ctx),
            's' => {
                if (j + 1 < a.len) {
                    sep = a[j + 1 ..];
                } else {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 's'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    sep = args[i];
                }
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    var inputs: std.ArrayList(tac.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        inputs.append(ctx.gpa, .{ .name = "-", .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (files.items) |path| {
        const in: tac.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: tac.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = tac.run(env, .{ .before = before, .separator = sep }, inputs.items, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: tac.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev.stage) {
        .open => cli.warn(ctx.*, "failed to open '{s}' for reading: {s}", .{ ev.name, cli.errText(ev.err) }),
        .read => cli.warn(ctx.*, "{s}: read error: {s}", .{ ev.name, cli.errText(ev.err) }),
    }
}

fn regexUnsupported(ctx: cli.Context) u8 {
    cli.warn(ctx, "option -r/--regex is not supported yet", .{});
    return 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tac [OPTION]... [FILE]...\n" ++
        "Write each FILE to standard output, last line first.\n\n" ++
        "  -b, --before             attach the separator before instead of after\n" ++
        "  -r, --regex              interpret the separator as a regular expression\n" ++
        "  -s, --separator=STRING   use STRING as the separator instead of newline\n" ++
        "      --help               display this help and exit\n" ++
        "      --version            output version information and exit\n")) 0 else 1;
}
