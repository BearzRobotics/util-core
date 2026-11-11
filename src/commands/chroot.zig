// SPDX-License-Identifier: GPL-2.0-or-later
//! chroot — run a command with a different root directory.
//! Reference: GNU coreutils manual "chroot invocation" (9.7).
//!
//! Needs CAP_SYS_CHROOT. --userspec and --groups are not supported (they exit
//! with status 125 and say so): they could not be verified without root.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const exec = @import("../exec.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const help_text = @embedFile("../help/chroot.txt");

pub fn main(ctx: cli.Context) u8 {
    var skip_chdir = false;
    var userspec: ?[]const u8 = null;
    var groups: ?[]const u8 = null;
    var p = getopt.Parser.init(ctx, "+", &.{
        .{ .name = "groups", .arg = .required, .id = 1100 },
        .{ .name = "userspec", .arg = .required, .id = 1101 },
        .{ .name = "skip-chdir", .id = 1102 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 125,
        .opt => |o| switch (o.id) {
            1100 => groups = o.arg,
            1101 => userspec = o.arg,
            1102 => skip_chdir = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 125,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 125,
            else => unreachable,
        },
    };
    const ops = p.operands.items;
    if (ops.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 125;
    }
    const newroot = ops[0];
    if (skip_chdir and !std.mem.eql(u8, newroot, "/")) {
        getopt.usageError(ctx, "option --skip-chdir only permitted if NEWROOT is old '/'", .{});
        return 125;
    }
    const z = ctx.gpa.dupeSentinel(u8, newroot, 0) catch return 125;
    defer ctx.gpa.free(z);
    if (sys.chroot(z)) |e| {
        cli.warn(ctx, "cannot change root directory to {f}: {s}", .{ cli.quoteA(newroot), sys.errnoText(e) });
        return 125;
    }
    if (!skip_chdir) {
        std.process.setCurrentPath(ctx.io, "/") catch {
            cli.warn(ctx, "cannot chdir to root directory", .{});
            return 125;
        };
    }
    if (userspec != null or groups != null) {
        cli.warn(ctx, "--userspec and --groups are not supported", .{});
        return 125;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    if (ops.len > 1) {
        for (ops[1..]) |a| argv.append(ctx.gpa, a) catch return 125;
    } else {
        const shell = cli.getenv(ctx, "SHELL");
        argv.append(ctx.gpa, if (shell != null and shell.?.len > 0) shell.? else "/bin/sh") catch return 125;
        argv.append(ctx.gpa, "-i") catch return 125;
    }
    return exec.execStyled(ctx, argv.items[0], argv.items, null, .run);
}
