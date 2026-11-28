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
const nice = @import("../lib/nice.zig");

const help_text = @embedFile("../help/nice.txt");

pub fn main(ctx: cli.Context) u8 {
    var adjustment: ?[]const u8 = null;
    var p = getopt.Parser.init(ctx, "+n:", &.{.{ .name = "adjustment", .arg = .required, .id = 'n' }});
    defer p.deinit();
    while (true) {
        // The obsolete "-N" / "-+N" / "--N" forms (adjustment N, N, -N) may
        // stand wherever an option may; getopt must not see them.
        if (p.sub == 0 and !p.ended and p.index < ctx.args.len) {
            if (nice.obsoleteAdjustment(ctx.args[p.index..])) |ob| {
                adjustment = ob.adjustment;
                p.index += 1;
                continue;
            }
        }
        switch (p.next()) {
            .done => break,
            .bad => return 125,
            .opt => |o| switch (o.id) {
                'n' => adjustment = o.arg,
                getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 125,
                getopt.version_id => return if (cli.printVersion(ctx)) 0 else 125,
                else => unreachable,
            },
        }
    }
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
    var delta: i64 = nice.default_adjustment;
    if (adjustment) |t| {
        delta = nice.parseAdjustment(t) catch {
            cli.warn(ctx, "invalid adjustment {f}", .{cli.quoteC(t)});
            return 125;
        };
    }
    // Changing the niceness is process-wide, so it happens here, not in the library.
    const target = nice.targetNice(sys.getNice(), delta);
    if (sys.setNice(target)) |e| {
        // The kernel clamps; EPERM/EACCES are only a warning, as in GNU.
        cli.warn(ctx, "cannot set niceness: {s}", .{sys.errnoText(e)});
        if (!nice.isOnlyWarning(e)) return 125;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    for (command) |c| argv.append(ctx.gpa, c) catch return 125;
    return exec.exec(ctx, command[0], argv.items, null);
}
