// SPDX-License-Identifier: GPL-2.0-or-later
//! logname: thin wrapper over `util_core.logname` (decision 0004).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/logname.zig");

pub fn main(ctx: cli.Context) u8 {
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (std.mem.eql(u8, a, "--help")) return help(ctx);
        if (std.mem.eql(u8, a, "--version")) return if (cli.printVersion(ctx)) 0 else 1;
        if (std.mem.eql(u8, a, "--")) continue;
        if (a.len > 1 and a[0] == '-') {
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
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
        return 1;
    }
    var buf: [512]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const res = lib.run(env, .{}, &stdout.interface) catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        return 1;
    };
    if (res == .no_login_name) {
        cli.warn(ctx, "no login name", .{});
        return 1;
    }
    return if (cli.flushWriter(&stdout)) 0 else 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: logname [OPTION]\nPrint the user's login name.\n\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
