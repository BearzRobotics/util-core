// SPDX-License-Identifier: GPL-2.0-or-later
//! sleep: thin wrapper over `util_core.sleep` (decision 0004). Sums the
//! operands (GNU extension: NUMBER[smhd]) and waits through the library.

const std = @import("std");
const cli = @import("../cli.zig");
const lib = @import("../lib/sleep.zig");

pub const parseInterval = lib.parseInterval;

pub fn main(ctx: cli.Context) u8 {
    var i: usize = 0;
    var total: f64 = 0;
    var operands: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            // Everything after "--" is an operand.
            for (ctx.args[i + 1 ..]) |op| {
                total += lib.parseInterval(op) orelse return invalid(ctx, op);
                operands += 1;
            }
            break;
        }
        if (std.mem.eql(u8, a, "--help")) return help(ctx);
        if (std.mem.eql(u8, a, "--version")) return if (cli.printVersion(ctx)) 0 else 1;
        if (a.len >= 2 and a[0] == '-' and !isNumberStart(a[1])) {
            if (a[1] == '-') {
                cli.badLong(ctx, a, .none);
            } else cli.invalidShort(ctx, a[1]);
            return 1;
        }
        total += lib.parseInterval(a) orelse return invalid(ctx, a);
        operands += 1;
    }
    if (operands == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    lib.run(env, .{ .seconds = total }) catch return 1;
    return 0;
}

fn isNumberStart(c: u8) bool {
    return std.ascii.isDigit(c) or c == '.';
}

fn invalid(ctx: cli.Context, text: []const u8) u8 {
    cli.warn(ctx, "invalid time interval '{s}'\nTry '{s} --help' for more information.", .{ text, ctx.name });
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: sleep NUMBER[SUFFIX]...\n" ++
        "  or:  sleep OPTION\n" ++
        "Pause for NUMBER seconds.  SUFFIX may be 's' for seconds (the default),\n" ++
        "'m' for minutes, 'h' for hours or 'd' for days.  NUMBER need not be an\n" ++
        "integer.  Given two or more arguments, pause for the amount of time\n" ++
        "specified by the sum of their values.\n\n" ++
        "      --help     display this help and exit\n" ++
        "      --version  output version information and exit\n")) 0 else 1;
}
