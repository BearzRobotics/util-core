// SPDX-License-Identifier: GPL-2.0-or-later
//! users: thin wrapper over `util_core.users` (decision 0004).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/users.zig");

pub fn main(ctx: cli.Context) u8 {
    var file_arg: ?[]const u8 = null;
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            if (file_arg != null) {
                cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
                return 1;
            }
            file_arg = a;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &.{ "help", "version" });
            switch (m) {
                .found => |k| return if (k == 0) help(ctx) else if (cli.printVersion(ctx)) 0 else 1,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        }
        cli.invalidShort(ctx, a[1]);
        return 1;
    }
    var opts: lib.Options = .{};
    if (file_arg) |p| opts.path = p;

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    lib.run(env, opts, &stdout.interface) catch |e| switch (e) {
        error.OutOfMemory => return 1,
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    return if (cli.flushWriter(&stdout)) 0 else 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: users [OPTION]... [FILE]\n" ++
        "Output who is currently logged in according to FILE.\n" ++
        "If FILE is not specified, use /var/run/utmp.  /var/log/wtmp as FILE is common.\n\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
