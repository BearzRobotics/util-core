// SPDX-License-Identifier: GPL-2.0-or-later
//! pwd: thin wrapper over `util_core.pwd` (decision 0004).
//! References: GNU coreutils manual "pwd invocation" (9.7); POSIX.1-2024 pwd.
//!
//! Options -L / -P (last wins). POSIX defaults to -L; GNU's standalone pwd
//! defaults to -P unless POSIXLY_CORRECT is set. We follow GNU.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/pwd.zig");

const long_names = [_][]const u8{ "logical", "physical", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var logical = cli.getenv(ctx, "POSIXLY_CORRECT") != null;
    var i: usize = 0;
    var operands: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            operands += ctx.args.len - i - 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') {
            operands += 1;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => logical = true,
                    1 => logical = false,
                    2 => return help(ctx),
                    else => return if (cli.printVersion(ctx)) 0 else 1,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        } else for (a[1..]) |c| switch (c) {
            'L' => logical = true,
            'P' => logical = false,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (operands > 0) cli.warn(ctx, "ignoring non-option arguments", .{});

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    lib.run(env, .{ .logical = logical }, &stdout.interface) catch |e| switch (e) {
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
        else => {
            cli.warn(ctx, "cannot get current directory: {s}", .{cli.errText(e)});
            return 1;
        },
    };
    return if (cli.flushWriter(&stdout)) 0 else 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: pwd [OPTION]...\n" ++
        "Print the full filename of the current working directory.\n\n" ++
        "  -L, --logical   use PWD from environment, even if it contains symlinks\n" ++
        "  -P, --physical  avoid all symlinks (default unless POSIXLY_CORRECT is set)\n" ++
        "      --help      display this help and exit\n" ++
        "      --version   output version information and exit\n")) 0 else 1;
}
