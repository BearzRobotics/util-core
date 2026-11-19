// SPDX-License-Identifier: GPL-2.0-or-later
//! yes: thin wrapper over `util_core.yes` (decision 0004). Parses arguments
//! the way GNU yes does; the line building and the output loop are in
//! src/lib/yes.zig.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/yes.zig");

pub fn main(ctx: cli.Context) u8 {
    var args = ctx.args;

    if (cli.soleArg(args, "--help")) {
        return if (cli.writeStdout(ctx.io, "Usage: yes [STRING]...\n" ++
            "  or:  yes OPTION\n" ++
            "Repeatedly output a line with all specified STRING(s), or 'y'.\n\n" ++
            "      --help     display this help and exit\n" ++
            "      --version  output version information and exit\n")) 0 else 1;
    }
    if (cli.soleArg(args, "--version")) return if (cli.printVersion(ctx)) 0 else 1;

    // "--" ends option parsing; any other leading "-x" is an unknown option.
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) {
        args = args[1..];
    } else if (args.len > 0 and args[0].len > 1 and args[0][0] == '-') {
        cli.warn(ctx, "invalid option -- '{c}'\nTry '{s} --help' for more information.", .{ args[0][1], ctx.name });
        return 1;
    }

    // Unbuffered: the library hands over large chunks, one write each.
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &.{});
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    lib.run(env, .{ .strings = args }, &stdout.interface) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    return 0;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}
