// SPDX-License-Identifier: GPL-2.0-or-later
//! nice — run a program with a modified scheduling priority.
//! Reference: GNU coreutils manual "nice invocation" (9.7); POSIX.1-2024 nice.
//!
//! With no COMMAND, print the current niceness. A failure to change the
//! priority because of permissions is a warning; the command still runs.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const exec = @import("../exec.zig");
const sys = @import("../sys.zig");

const help_text = @embedFile("../help/nice.txt");

pub fn main(ctx: cli.Context) u8 {
    var adjustment: ?[]const u8 = null;
    // Obsolete "-N" / "--N" forms (adjustment N / -N) are recognised only as
    // the first argument, before getopt sees them.
    var args = ctx.args;
    if (args.len > 0) {
        const a: []const u8 = args[0];
        if (a.len >= 2 and a[0] == '-' and std.ascii.isDigit(a[1])) {
            adjustment = a[1..];
            args = args[1..];
        } else if (a.len >= 3 and a[0] == '-' and a[1] == '-' and std.ascii.isDigit(a[2])) {
            adjustment = a[1..];
            args = args[1..];
        }
    }
    var c2 = ctx;
    c2.args = args;
    var p = getopt.Parser.init(c2, "+n:", &.{.{ .name = "adjustment", .arg = .required, .id = 'n' }});
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 125,
        .opt => |o| switch (o.id) {
            'n' => adjustment = o.arg,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 125,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 125,
            else => unreachable,
        },
    };
    const command = p.operands.items;
    if (command.len == 0) {
        if (adjustment != null) {
            getopt.usageError(ctx, "a command must be given with an adjustment", .{});
            return 125;
        }
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}\n", .{sys.getNice()}) catch unreachable;
        return if (cli.writeStdout(ctx.io, s)) 0 else 125;
    }
    var delta: i64 = 10;
    if (adjustment) |t| {
        delta = std.fmt.parseInt(i64, if (t.len > 0 and t[0] == '+') t[1..] else t, 10) catch |e| switch (e) {
            error.Overflow => if (t.len > 0 and t[0] == '-') std.math.minInt(i32) else std.math.maxInt(i32),
            else => {
                cli.warn(ctx, "invalid adjustment {f}", .{cli.quoteC(t)});
                return 125;
            },
        };
    }
    const target: i32 = @intCast(std.math.clamp(@as(i64, sys.getNice()) + delta, -20, 19));
    if (sys.setNice(target)) |e| {
        // The kernel clamps; EPERM/EACCES are only a warning, as in GNU.
        cli.warn(ctx, "cannot set niceness: {s}", .{sys.errnoText(e)});
        if (e != .PERM and e != .ACCES) return 125;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    for (command) |c| argv.append(ctx.gpa, c) catch return 125;
    return exec.exec(ctx, command[0], argv.items, null);
}
