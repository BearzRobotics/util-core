// SPDX-License-Identifier: GPL-2.0-or-later
//! touch: thin wrapper over `util_core.touch` (decision 0004). Parses the
//! arguments, resolves -d/-t/-r into concrete times (GNU date parser,
//! src/datetime.zig) and words the diagnostics; the library applies the times.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const datetime = @import("../datetime.zig");
const Io = std.Io;

const help_text = @embedFile("../help/touch.txt");

const touch = @import("../lib/touch.zig");
const ch_atime = touch.ch_atime;
const ch_mtime = touch.ch_mtime;

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var change_times: u8 = 0;
    var no_create = false;
    var no_deref = false;
    var flex_date: ?[]const u8 = null;
    var ref_file: ?[]const u8 = null;
    var t_arg: ?[]const u8 = null;
    var newtime: [2]sys.TimeSpec = .{ .{}, .{} };
    var date_set = false;
    var amtime_now = false;

    var tz_env: ?[]const u8 = null;
    if (ctx.environ) |m| tz_env = m.get("TZ");
    var zone = tzmod.load(gpa, ctx.io, tz_env);
    defer zone.deinit();

    var p = getopt.Parser.init(ctx, "acd:fhmr:t:", &.{
        .{ .name = "time", .arg = .required, .id = 1100 },
        .{ .name = "no-create", .id = 'c' },
        .{ .name = "date", .arg = .required, .id = 'd' },
        .{ .name = "reference", .arg = .required, .id = 'r' },
        .{ .name = "no-dereference", .id = 'h' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'a' => change_times |= ch_atime,
            'c' => no_create = true,
            'd' => flex_date = o.arg,
            'f' => {},
            'h' => no_deref = true,
            'm' => change_times |= ch_mtime,
            'r' => ref_file = o.arg,
            't' => t_arg = o.arg,
            1100 => {
                const names = [_][]const u8{ "atime", "access", "use", "mtime", "modify" };
                const v = o.arg.?;
                var found: ?usize = null;
                var amb = false;
                for (names, 0..) |n, i| {
                    if (std.mem.eql(u8, n, v)) {
                        found = i;
                        amb = false;
                        break;
                    }
                    if (std.mem.startsWith(u8, n, v)) {
                        // "a" is ambiguous only between different meanings
                        if (found != null and ((found.? < 3) != (i < 3))) amb = true;
                        if (found == null) found = i;
                    }
                }
                if (found == null or amb) {
                    cli.warn(ctx, "{s} argument {f} for '--time'\nValid arguments are:\n  - 'atime', 'access', 'use'\n  - 'mtime', 'modify'\nTry '{s} --help' for more information.", .{ if (amb) "ambiguous" else "invalid", cli.quoteC(v), ctx.name });
                    return 1;
                }
                change_times |= if (found.? < 3) ch_atime else ch_mtime;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };

    const ts_now = Io.Timestamp.now(ctx.io, .real);
    const now: datetime.Timespec = .{ .sec = @intCast(@divFloor(ts_now.nanoseconds, std.time.ns_per_s)), .nsec = @intCast(@mod(ts_now.nanoseconds, std.time.ns_per_s)) };
    const cur_year = tzmod.localtime(&zone, now.sec).year;

    if (t_arg) |ta| {
        const t = datetime.posixTime(&zone, ta, true, cur_year) orelse {
            cli.warn(ctx, "invalid date format {f}", .{cli.quoteC(ta)});
            return 1;
        };
        newtime = .{ .{ .sec = t, .nsec = 0 }, .{ .sec = t, .nsec = 0 } };
        date_set = true;
    }
    if (change_times == 0) change_times = ch_atime | ch_mtime;
    if (date_set and (ref_file != null or flex_date != null)) {
        getopt.usageError(ctx, "cannot specify times from more than one source", .{});
        return 1;
    }

    const dateRelative = struct {
        fn f(c: cli.Context, g: std.mem.Allocator, z: *const tzmod.Zone, text: []const u8, base: datetime.Timespec) ?datetime.Timespec {
            return datetime.parse(g, c.io, text, base, z);
        }
    }.f;

    if (ref_file) |rf| {
        var err: std.os.linux.E = .SUCCESS;
        const st = sys.fileStat(rf, !no_deref, &err) orelse {
            cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteA(rf), sys.errnoText(err) });
            return 1;
        };
        newtime[0] = .{ .sec = st.atime_s, .nsec = st.atime_ns };
        newtime[1] = .{ .sec = st.mtime_s, .nsec = st.mtime_ns };
        date_set = true;
        if (flex_date) |fd| {
            if (change_times & ch_atime != 0) {
                const r = dateRelative(ctx, gpa, &zone, fd, .{ .sec = newtime[0].sec, .nsec = @intCast(newtime[0].nsec) }) orelse {
                    cli.warn(ctx, "invalid date format {f}", .{cli.quoteC(fd)});
                    return 1;
                };
                newtime[0] = .{ .sec = r.sec, .nsec = r.nsec };
            }
            if (change_times & ch_mtime != 0) {
                const r = dateRelative(ctx, gpa, &zone, fd, .{ .sec = newtime[1].sec, .nsec = @intCast(newtime[1].nsec) }) orelse {
                    cli.warn(ctx, "invalid date format {f}", .{cli.quoteC(fd)});
                    return 1;
                };
                newtime[1] = .{ .sec = r.sec, .nsec = r.nsec };
            }
        }
    } else if (flex_date) |fd| {
        const r = dateRelative(ctx, gpa, &zone, fd, now) orelse {
            cli.warn(ctx, "invalid date format {f}", .{cli.quoteC(fd)});
            return 1;
        };
        newtime = .{ .{ .sec = r.sec, .nsec = r.nsec }, .{ .sec = r.sec, .nsec = r.nsec } };
        date_set = true;
        // "-d now" without -a/-m behaves as if -d were absent.
        if (change_times == (ch_atime | ch_mtime) and r.sec == now.sec and r.nsec == now.nsec) {
            const notnow: datetime.Timespec = .{ .sec = now.sec ^ 1, .nsec = now.nsec };
            if (dateRelative(ctx, gpa, &zone, fd, notnow)) |r1| {
                if (r1.sec == notnow.sec and r1.nsec == notnow.nsec) date_set = false;
            }
        }
    }
    if (!date_set) {
        if (change_times == (ch_atime | ch_mtime)) {
            amtime_now = true;
        } else {
            newtime[0].nsec = sys.TimeSpec.now_ns;
            newtime[1].nsec = sys.TimeSpec.now_ns;
        }
    }

    const files = p.operands.items;
    if (files.len == 0) {
        getopt.usageError(ctx, "missing file operand", .{});
        return 1;
    }
    const env: touch.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    const ok = touch.run(env, .{
        .change_times = change_times,
        .no_create = no_create,
        .no_deref = no_deref,
        .times = newtime,
        .now = amtime_now,
    }, files, .{ .context = @constCast(&ctx), .func = report });
    return if (ok) 0 else 1;
}

fn report(context: ?*anyopaque, ev: touch.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .cannot_touch => |f| cli.warn(ctx.*, "cannot touch {f}: {s}", .{ cli.quoteA(f.path), sys.errnoText(f.errno) }),
        .set_times_failed => |f| cli.warn(ctx.*, "setting times of {f}: {s}", .{ cli.quoteA(f.path), sys.errnoText(f.errno) }),
    }
}
