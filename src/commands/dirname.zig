// SPDX-License-Identifier: GPL-2.0-or-later
//! dirname: thin wrapper over `util_core.dirname` (decision 0004).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/dirname.zig");

pub fn main(ctx: cli.Context) u8 {
    const args = ctx.args;
    if (cli.soleArg(args, "--help")) {
        return if (cli.writeStdout(ctx.io, "Usage: dirname [OPTION] NAME...\n" ++
            "Output each NAME with its last non-slash component and trailing slashes\n" ++
            "removed; if NAME contains no /'s, output '.'.\n\n" ++
            "  -z, --zero     end each output line with NUL, not newline\n")) 0 else 1;
    }
    if (cli.soleArg(args, "--version")) return if (cli.printVersion(ctx)) 0 else 1;

    var terminator: u8 = '\n';
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "-z") or std.mem.eql(u8, a, "--zero")) {
            terminator = 0;
        } else {
            cli.warn(ctx, "invalid option -- '{s}'\nTry '{s} --help' for more information.", .{ a[1..], ctx.name });
            return 1;
        }
    }
    const names = args[i..];
    if (names.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    lib.run(env, .{ .terminator = terminator }, names, &stdout.interface) catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        return 1;
    };
    return if (cli.flushWriter(&stdout)) 0 else 1;
}
