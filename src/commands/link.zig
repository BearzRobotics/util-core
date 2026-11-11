// SPDX-License-Identifier: GPL-2.0-or-later
//! link — create a hard link by calling link(2).
//! Reference: GNU coreutils manual "link invocation" (9.7).

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

pub fn main(ctx: cli.Context) u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return 1;
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
    if (files.items.len < 2) {
        if (files.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        } else cli.warn(ctx, "missing operand after {f}\nTry '{s} --help' for more information.", .{ cli.quoteA(files.items[0]), ctx.name });
        return 1;
    }
    if (files.items.len > 2) {
        cli.warn(ctx, "extra operand {f}\nTry '{s} --help' for more information.", .{ cli.quoteA(files.items[2]), ctx.name });
        return 1;
    }
    const cwd = Io.Dir.cwd();
    cwd.hardLink(files.items[0], cwd, files.items[1], ctx.io, .{}) catch |e| {
        cli.warn(ctx, "cannot create link {f} to {f}: {s}", .{ cli.quoteA(files.items[1]), cli.quoteA(files.items[0]), cli.errText(e) });
        return 1;
    };
    return 0;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: link FILE1 FILE2\n  or:  link OPTION\nCall the link function to create a link named FILE2 to an existing FILE1.\n\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
