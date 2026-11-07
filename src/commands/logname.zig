//! logname — print the user's login name.
//! Reference: GNU coreutils manual "logname invocation" (9.7); POSIX.1-2024
//! logname. glibc's getlogin() first consults /proc/self/loginuid; the utmp
//! fallback is not implemented, so a session known only to utmp reports
//! "no login name".

const std = @import("std");
const cli = @import("../cli.zig");
const userdb = @import("../userdb.zig");
const Io = std.Io;

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
    const name = loginName(ctx) orelse {
        cli.warn(ctx, "no login name", .{});
        return 1;
    };
    defer ctx.gpa.free(name);
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{name}) catch return 1;
    return if (cli.writeStdout(ctx.io, line)) 0 else 1;
}

fn loginName(ctx: cli.Context) ?[]u8 {
    const f = Io.Dir.cwd().openFile(ctx.io, "/proc/self/loginuid", .{}) catch return null;
    defer f.close(ctx.io);
    var buf: [32]u8 = undefined;
    const n = cli.readChunk(ctx.io, f, &buf) catch return null;
    const uid = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..n], " \n\x00"), 10) catch return null;
    if (uid == std.math.maxInt(u32)) return null; // (uid_t)-1: no login session
    var db = userdb.Db.load(ctx.gpa, ctx.io);
    defer db.deinit();
    const u = db.userByUid(uid) orelse return null;
    return ctx.gpa.dupe(u8, u.name) catch null;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: logname [OPTION]\nPrint the user's login name.\n\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
