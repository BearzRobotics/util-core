// SPDX-License-Identifier: GPL-2.0-or-later
//! echo: thin wrapper over `util_core.echo` (decision 0004).
//!
//! Options -n, -e, -E are recognised only as leading arguments made solely of
//! those letters (e.g. "-neE"); anything else is printed literally. --help and
//! --version are recognised only as the sole argument.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/echo.zig");

pub fn main(ctx: cli.Context) u8 {
    var args = ctx.args;
    if (cli.soleArg(args, "--help")) {
        return if (cli.writeStdout(ctx.io, "Usage: echo [SHORT-OPTION]... [STRING]...\n" ++
            "Echo the STRING(s) to standard output.\n\n" ++
            "  -n     do not output the trailing newline\n" ++
            "  -e     enable interpretation of backslash escapes\n" ++
            "  -E     disable interpretation of backslash escapes (default)\n")) 0 else 1;
    }
    if (cli.soleArg(args, "--version")) return if (cli.printVersion(ctx)) 0 else 1;

    var opts: lib.Options = .{};
    while (args.len > 0 and isOptionGroup(args[0])) : (args = args[1..]) {
        for (args[0][1..]) |c| switch (c) {
            'n' => opts.newline = false,
            'e' => opts.escapes = true,
            'E' => opts.escapes = false,
            else => unreachable,
        };
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    lib.run(env, opts, args, &stdout.interface) catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        return 1;
    };
    return if (cli.flushWriter(&stdout)) 0 else 1;
}

/// "-" followed by one or more of n/e/E and nothing else.
fn isOptionGroup(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-') return false;
    for (a[1..]) |c| if (c != 'n' and c != 'e' and c != 'E') return false;
    return true;
}
