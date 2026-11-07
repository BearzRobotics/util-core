//! groups — print the groups a user is in.
//! Reference: GNU coreutils manual "groups invocation" (9.7). Same data as
//! `id -Gn`; with user names each line is prefixed by `NAME : `.

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const userdb = @import("../userdb.zig");

pub fn main(ctx: cli.Context) u8 {
    var users: std.ArrayList([]const u8) = .empty;
    defer users.deinit(ctx.gpa);
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            users.append(ctx.gpa, a) catch return 1;
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
    var db = userdb.Db.load(ctx.gpa, ctx.io);
    defer db.deinit();
    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    if (users.items.len == 0) {
        const me = sys.identity();
        var gbuf: [1024]u32 = undefined;
        const sup = sys.supplementaryGroups(&gbuf);
        status = list(ctx, &out, &db, me.egid, sup, null);
    } else for (users.items) |name| {
        const u = db.userByName(name) orelse {
            out.flush();
            cli.warn(ctx, "{f}: no such user", .{cli.quoteC(name)});
            status = 1;
            continue;
        };
        const groups = db.groupsOf(ctx.gpa, u.name, u.gid) catch return 1;
        defer ctx.gpa.free(groups);
        if (list(ctx, &out, &db, u.gid, groups, name) != 0) status = 1;
    }
    out.flush();
    return if (out.failed) 1 else status;
}

fn list(ctx: cli.Context, out: *cli.Out, db: *const userdb.Db, primary: u32, groups: []const u32, prefix: ?[]const u8) u8 {
    var status: u8 = 0;
    if (prefix) |p| {
        out.write(p);
        out.write(" : ");
    }
    var first = true;
    var all: [1025]u32 = undefined;
    var n: usize = 0;
    all[n] = primary;
    n += 1;
    for (groups) |g| if (g != primary and n < all.len) {
        all[n] = g;
        n += 1;
    };
    for (all[0..n]) |g| {
        if (!first) out.writeByte(' ');
        first = false;
        if (db.groupByGid(g)) |gr| {
            out.write(gr.name);
        } else {
            out.flush();
            cli.warn(ctx, "cannot find name for group ID {d}", .{g});
            out.print("{d}", .{g});
            status = 1;
        }
    }
    out.writeByte('\n');
    return status;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: groups [OPTION]... [USERNAME]...\n" ++
        "Print group memberships for each USERNAME or, if no USERNAME is specified, for\n" ++
        "the current process (which may differ if the groups database has changed).\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
