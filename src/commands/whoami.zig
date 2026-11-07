//! whoami — print the user name of the effective user ID.
//! Reference: GNU coreutils manual "whoami invocation" (9.7).

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const userdb = @import("../userdb.zig");

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
    var db = userdb.Db.load(ctx.gpa, ctx.io);
    defer db.deinit();
    const id = sys.identity();
    const u = db.userByUid(id.euid) orelse {
        cli.warn(ctx, "cannot find name for user ID {d}", .{id.euid});
        return 1;
    };
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{u.name}) catch return 1;
    return if (cli.writeStdout(ctx.io, line)) 0 else 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: whoami [OPTION]...\nPrint the user name associated with the current effective user ID.\nSame as id -un.\n\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
