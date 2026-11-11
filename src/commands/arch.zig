// SPDX-License-Identifier: GPL-2.0-or-later
//! arch — print the machine hardware name (same as uname -m).
//! Reference: GNU coreutils manual "arch invocation" (9.7).

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");

pub fn main(ctx: cli.Context) u8 {
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (std.mem.eql(u8, a, "--help")) return help(ctx);
        if (std.mem.eql(u8, a, "--version")) return if (cli.printVersion(ctx)) 0 else 1;
        if (std.mem.startsWith(u8, a, "--") and a.len > 2) {
            const m = cli.matchLong(a[2..], &.{ "help", "version" });
            switch (m) {
                .found => |k| return if (k == 0) help(ctx) else if (cli.printVersion(ctx)) 0 else 1,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        }
        if (a.len > 1 and a[0] == '-' and !std.mem.eql(u8, a, "--")) {
            cli.invalidShort(ctx, a[1]);
            return 1;
        }
        if (!std.mem.eql(u8, a, "--")) {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
            return 1;
        }
    }
    const u = sys.uname();
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{u.machine()}) catch return 1;
    return if (cli.writeStdout(ctx.io, line)) 0 else 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: arch [OPTION]...\nPrint machine architecture.\n\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
