//! tty — print the file name of the terminal connected to standard input.
//! Reference: GNU coreutils manual "tty invocation" (9.7); POSIX.1-2024 tty.
//! Exit status 0 on a terminal, 1 when not, 2 for bad usage, 3 on a write error.

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "silent", "quiet", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var silent = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (std.mem.eql(u8, a, "--")) continue;
        if (a.len < 2 or a[0] != '-') {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
            return 2;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0, 1 => silent = true,
                    2 => return help(ctx),
                    else => return if (cli.printVersion(ctx)) 0 else 1,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 2;
                },
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            's' => silent = true,
            else => {
                cli.invalidShort(ctx, c);
                return 2;
            },
        };
    }
    const stdin = Io.File.stdin();
    const is_tty = stdin.isTty(ctx.io) catch false;
    if (!is_tty) {
        if (!silent) _ = cli.writeStdout(ctx.io, "not a tty\n");
        return 1;
    }
    if (silent) return 0;
    var buf: [4096]u8 = undefined;
    const n = Io.Dir.readLinkAbsolute(ctx.io, "/proc/self/fd/0", &buf) catch {
        _ = cli.writeStdout(ctx.io, "not a tty\n");
        return 1;
    };
    var out: [4200]u8 = undefined;
    const line = std.fmt.bufPrint(&out, "{s}\n", .{buf[0..n]}) catch return 3;
    return if (cli.writeStdout(ctx.io, line)) 0 else 3;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tty [OPTION]...\nPrint the file name of the terminal connected to standard input.\n\n  -s, --silent, --quiet   print nothing, only return an exit status\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
