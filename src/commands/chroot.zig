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
const chroot = @import("../lib/chroot.zig");

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
    const opts: chroot.Options = .{ .newroot = newroot, .skip_chdir = skip_chdir, .userspec = userspec, .groups = groups };
    if (chroot.check(opts)) |problem| switch (problem) {
        .skip_chdir_needs_root => {
            getopt.usageError(ctx, "option --skip-chdir only permitted if NEWROOT is old '/'", .{});
            return 125;
        },
    };
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
    if (chroot.unsupported(opts)) {
        cli.warn(ctx, "--userspec and --groups are not supported", .{});
        return 125;
    }
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const argv = chroot.commandLine(arena.allocator(), ops[1..], cli.getenv(ctx, "SHELL")) catch return 125;
    return exec.execStyled(ctx, argv[0], argv, null, .run);
}
