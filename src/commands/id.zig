//! id — print real and effective user and group IDs.
//! Reference: GNU coreutils manual "id invocation" (9.7); POSIX.1-2024 id.
//! Names come from /etc/passwd and /etc/group only (no NSS). SELinux contexts
//! are not supported (-Z reports that, as GNU does on a kernel without it).

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const userdb = @import("../userdb.zig");

const long_names = [_][]const u8{ "context", "group", "groups", "name", "real", "user", "zero", "help", "version" };

const Config = struct {
    user: bool = false, // -u
    group: bool = false, // -g
    groups: bool = false, // -G
    name: bool = false, // -n
    real: bool = false, // -r
    zero: bool = false, // -z
    context: bool = false, // -Z
};

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
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
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            if (eq != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => cfg.context = true,
                1 => cfg.group = true,
                2 => cfg.groups = true,
                3 => cfg.name = true,
                4 => cfg.real = true,
                5 => cfg.user = true,
                6 => cfg.zero = true,
                7 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'a' => {},
            'Z' => cfg.context = true,
            'g' => cfg.group = true,
            'G' => cfg.groups = true,
            'n' => cfg.name = true,
            'r' => cfg.real = true,
            'u' => cfg.user = true,
            'z' => cfg.zero = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    const only_one = @as(u8, @intFromBool(cfg.user)) + @intFromBool(cfg.group) + @intFromBool(cfg.groups);
    if (only_one > 1) {
        cli.warn(ctx, "cannot print \"only\" of more than one choice", .{});
        return 1;
    }
    const default_format = only_one == 0 and !cfg.context;
    if (only_one == 0 and !cfg.context and (cfg.name or cfg.real)) {
        cli.warn(ctx, "printing only names or real IDs requires -u, -g, or -G", .{});
        return 1;
    }
    if (default_format and cfg.zero) {
        cli.warn(ctx, "option --zero not permitted in default format", .{});
        return 1;
    }
    if (cfg.context) {
        cli.warn(ctx, "--context (-Z) works only on an SELinux-enabled kernel", .{});
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
        if (!show(ctx, &out, &db, &cfg, null, me.uid, me.euid, me.gid, me.egid, sup, default_format)) status = 1;
    } else for (users.items) |name| {
        // A name wins over a number: "id 0" falls back to uid 0 only when no
        // user is called "0".
        var u = db.userByName(name);
        if (u == null) if (std.fmt.parseInt(u32, name, 10)) |n| {
            u = db.userByUid(n);
        } else |_| {};
        const found = u orelse {
            cli.warn(ctx, "{f}: no such user", .{cli.quoteC(name)});
            status = 1;
            continue;
        };
        const groups = db.groupsOf(ctx.gpa, found.name, found.gid) catch return 1;
        defer ctx.gpa.free(groups);
        if (!show(ctx, &out, &db, &cfg, found.name, found.uid, found.uid, found.gid, found.gid, groups, default_format)) status = 1;
    }
    out.flush();
    return if (out.failed) 1 else status;
}

fn userLabel(db: *const userdb.Db, uid: u32) ?[]const u8 {
    return if (db.userByUid(uid)) |u| u.name else null;
}

fn groupLabel(db: *const userdb.Db, gid: u32) ?[]const u8 {
    return if (db.groupByGid(gid)) |g| g.name else null;
}

fn printId(ctx: cli.Context, out: *cli.Out, id: u32, label: ?[]const u8, names: bool, what: []const u8) bool {
    if (names) {
        if (label) |l| {
            out.write(l);
            return true;
        }
        out.flush();
        cli.warn(ctx, "cannot find name for {s} ID {d}", .{ what, id });
        out.print("{d}", .{id});
        return false;
    }
    out.print("{d}", .{id});
    return true;
}

fn show(ctx: cli.Context, out: *cli.Out, db: *const userdb.Db, cfg: *const Config, arg_user: ?[]const u8, ruid: u32, euid: u32, rgid: u32, egid: u32, groups: []const u32, default_format: bool) bool {
    _ = arg_user;
    var ok = true;
    const term: u8 = if (cfg.zero) 0 else '\n';
    if (cfg.user) {
        const id = if (cfg.real) ruid else euid;
        ok = printId(ctx, out, id, userLabel(db, id), cfg.name, "user");
        out.writeByte(term);
        return ok;
    }
    if (cfg.group) {
        const id = if (cfg.real) rgid else egid;
        ok = printId(ctx, out, id, groupLabel(db, id), cfg.name, "group");
        out.writeByte(term);
        return ok;
    }
    if (cfg.groups) {
        // The primary group first, then the others without repeating it.
        const primary = if (cfg.real) rgid else egid;
        const sep: u8 = if (cfg.zero) 0 else ' ';
        if (!printId(ctx, out, primary, groupLabel(db, primary), cfg.name, "group")) ok = false;
        for (groups) |g| {
            if (g == primary) continue;
            out.writeByte(sep);
            if (!printId(ctx, out, g, groupLabel(db, g), cfg.name, "group")) ok = false;
        }
        out.writeByte(term);
        return ok;
    }
    std.debug.assert(default_format);
    out.print("uid={d}", .{ruid});
    if (userLabel(db, ruid)) |l| out.print("({s})", .{l});
    out.print(" gid={d}", .{rgid});
    if (groupLabel(db, rgid)) |l| out.print("({s})", .{l});
    if (euid != ruid) {
        out.print(" euid={d}", .{euid});
        if (userLabel(db, euid)) |l| out.print("({s})", .{l});
    }
    if (egid != rgid) {
        out.print(" egid={d}", .{egid});
        if (groupLabel(db, egid)) |l| out.print("({s})", .{l});
    }
    out.write(" groups=");
    // The effective group comes first, then the others without repeating it.
    out.print("{d}", .{egid});
    if (groupLabel(db, egid)) |l| out.print("({s})", .{l});
    for (groups) |g| {
        if (g == egid) continue;
        out.writeByte(',');
        out.print("{d}", .{g});
        if (groupLabel(db, g)) |l| out.print("({s})", .{l});
    }
    out.writeByte('\n');
    return ok;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: id [OPTION]... [USER]...\n" ++
        "Print user and group information for each specified USER,\n" ++
        "or (when USER omitted) for the current process.\n\n" ++
        "  -a             ignore, for compatibility with other versions\n" ++
        "  -Z, --context  print only the security context of the process\n" ++
        "  -g, --group    print only the effective group ID\n" ++
        "  -G, --groups   print all group IDs\n" ++
        "  -n, --name     print a name instead of a number, for -u,-g,-G\n" ++
        "  -r, --real     print the real ID instead of the effective ID, with -u,-g,-G\n" ++
        "  -u, --user     print only the effective user ID\n" ++
        "  -z, --zero     delimit entries with NUL characters, not whitespace;\n" ++
        "                   not permitted in default format\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n\n" ++
        "Without any OPTION, print some useful set of identified information.\n")) 0 else 1;
}
