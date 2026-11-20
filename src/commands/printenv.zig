// SPDX-License-Identifier: GPL-2.0-or-later
//! printenv: thin wrapper over `util_core.printenv` (decision 0004).
//! Exit status: 0 all found, 1 some not found, 2 usage or write error (as the
//! GNU manual).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/printenv.zig");

const long_names = [_][]const u8{ "null", "help", "version", "json" };

pub fn main(ctx: cli.Context) u8 {
    var term: u8 = '\n';
    var as_json = false;
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => term = 0,
                    1 => return if (cli.writeStdout(ctx.io, "Usage: printenv [OPTION]... [VARIABLE]...\n" ++
                        "Print the values of the specified environment VARIABLE(s).\n" ++
                        "If no VARIABLE is specified, print name and value pairs for them all.\n\n" ++
                        "  -0, --null     end each output line with NUL, not newline\n" ++
                        "      --json     print the result as JSON (not in GNU)\n" ++
                        "      --help     display this help and exit\n" ++
                        "      --version  output version information and exit\n")) 0 else 2,
                    3 => as_json = true,
                    else => return if (cli.printVersion(ctx)) 0 else 2,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 2;
                },
            }
        } else for (a[1..]) |c| switch (c) {
            '0' => term = 0,
            else => {
                cli.invalidShort(ctx, c);
                return 2;
            },
        };
    }
    const names = ctx.args[i..];
    if (as_json and term == 0) {
        cli.warn(ctx, "--json cannot be combined with -0", .{});
        return 2;
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const res = lib.run(env, .{ .terminator = term, .json = as_json }, names, &stdout.interface) catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        return 2;
    };
    if (!cli.flushWriter(&stdout)) return 2;
    return if (res.missing > 0) 1 else 0;
}
