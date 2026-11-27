// SPDX-License-Identifier: GPL-2.0-or-later
//! nproc: thin wrapper over `util_core.nproc` (decision 0004).

const std = @import("std");
const numparse = @import("../numparse.zig");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/nproc.zig");

const long_names = [_][]const u8{ "all", "ignore", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var opts: lib.Options = .{};
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) continue;
        if (a.len < 2 or a[0] != '-') {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
            return 1;
        }
        if (a[1] != '-') {
            cli.invalidShort(ctx, a[1]);
            return 1;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
        const k = switch (m) {
            .found => |k| k,
            else => {
                cli.badLong(ctx, a, m);
                return 1;
            },
        };
        switch (k) {
            0 => opts.all = true,
            1 => {
                var v: []const u8 = undefined;
                if (eq) |e| {
                    v = a[e + 1 ..];
                } else {
                    i += 1;
                    if (i >= ctx.args.len) {
                        cli.warn(ctx, "option '--ignore' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    v = ctx.args[i];
                }
                opts.ignore = numparse.parseInt(usize, v, 10) catch {
                    cli.warn(ctx, "invalid number: {f}", .{cli.quoteC(v)});
                    return 1;
                };
            },
            2 => return help(ctx),
            else => return if (cli.printVersion(ctx)) 0 else 1,
        }
    }
    var buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    lib.run(env, opts, &stdout.interface) catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        return 1;
    };
    return if (cli.flushWriter(&stdout)) 0 else 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: nproc [OPTION]...\nPrint the number of processing units available to the current process,\nwhich may be less than the number of online processors\n\n      --all      print the number of installed processors\n      --ignore=N  if possible, exclude N processing units\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
