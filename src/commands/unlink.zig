//! unlink — remove a file by calling unlink(2).
//! Reference: GNU coreutils manual "unlink invocation" (9.7).

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
    if (files.items.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (files.items.len > 1) {
        cli.warn(ctx, "extra operand {f}\nTry '{s} --help' for more information.", .{ cli.quoteA(files.items[1]), ctx.name });
        return 1;
    }
    Io.Dir.cwd().deleteFile(ctx.io, files.items[0]) catch |e| {
        cli.warn(ctx, "cannot unlink {f}: {s}", .{ cli.quoteA(files.items[0]), cli.errText(e) });
        return 1;
    };
    return 0;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: unlink FILE\n  or:  unlink OPTION\nCall the unlink function to remove the specified FILE.\n\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
