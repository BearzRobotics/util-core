// SPDX-License-Identifier: GPL-2.0-or-later
//! mknod — make block or character special files, or named pipes.
//! Reference: GNU coreutils manual "mknod invocation" (9.7); POSIX.1-2024
//! does not specify mknod. Block and character devices need privilege.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const mknod = @import("../lib/mknod.zig");

const help_text = @embedFile("../help/mknod.txt");

pub fn main(ctx: cli.Context) u8 {
    var mode_text: ?[]const u8 = null;
    var p = getopt.Parser.init(ctx, "m:Z", &.{
        .{ .name = "mode", .arg = .required, .id = 'm' },
        .{ .name = "context", .arg = .optional, .id = 'Z' },
    });
    defer p.deinit();
    var context_warned = false;
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'm' => mode_text = o.arg,
            'Z' => if (o.arg != null and !context_warned) {
                context_warned = true;
                cli.warn(ctx, "warning: ignoring --context; it requires an SELinux/SMACK-enabled kernel", .{});
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const ops = p.operands.items;
    const umask = sys.umask();
    const final = mknod.resolveMode(mode_text, umask) catch |e| {
        switch (e) {
            error.InvalidMode => cli.warn(ctx, "invalid mode", .{}),
            error.NotPermissionBits => cli.warn(ctx, "mode must specify only file permission bits", .{}),
        }
        return 1;
    };
    if (ops.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 1;
    }
    if (ops.len == 1) {
        getopt.usageError(ctx, "missing operand after {f}", .{cli.quoteC(ops[0])});
        return 1;
    }
    const name = ops[0];
    const type_text = ops[1];
    // GNU looks only at the first character of TYPE, and checks the operand
    // count before it complains about an unknown type.
    const kind = mknod.kindOf(type_text);
    const is_fifo = kind == .fifo;
    var rest = ops[2..];
    var dev: u64 = 0;
    if (is_fifo and rest.len > 0) {
        // GNU adds the explanation only when exactly MAJOR and MINOR were given.
        if (rest.len == 2)
            getopt.usageError(ctx, "extra operand {f}\nFifos do not have major and minor device numbers.", .{cli.quoteC(rest[0])})
        else
            getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(rest[0])});
        return 1;
    }
    if (!is_fifo) {
        if (rest.len == 0) {
            getopt.usageError(ctx, "missing operand after {f}\nSpecial files require major and minor device numbers.", .{cli.quoteC(type_text)});
            return 1;
        }
        if (rest.len == 1) {
            getopt.usageError(ctx, "missing operand after {f}", .{cli.quoteC(rest[0])});
            return 1;
        }
        if (rest.len > 2) {
            getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(rest[2])});
            return 1;
        }
    }
    const node_kind = kind orelse {
        getopt.usageError(ctx, "invalid device type {f}", .{cli.quoteC(type_text)});
        return 1;
    };
    if (!is_fifo) {
        const major = mknod.parseNumber(rest[0]) orelse {
            cli.warn(ctx, "invalid major device number {f}", .{cli.quoteC(rest[0])});
            return 1;
        };
        const minor = mknod.parseNumber(rest[1]) orelse {
            cli.warn(ctx, "invalid minor device number {f}", .{cli.quoteC(rest[1])});
            return 1;
        };
        dev = mknod.makedev(major, minor);
        if (dev == mknod.no_device) {
            cli.warn(ctx, "invalid device {s} {s}", .{ rest[0], rest[1] });
            return 1;
        }
        rest = rest[2..];
    }
    const env: mknod.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const failure = mknod.run(env, name, .{ .kind = node_kind, .dev = dev, .mode = final }) catch return 1;
    if (failure) |fl| switch (fl) {
        .create => |e| {
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), sys.errnoText(e) });
            return 1;
        },
        .permissions => |e| {
            cli.warn(ctx, "cannot set permissions of {f}: {s}", .{ cli.quoteA(name), sys.errnoText(e) });
            return 1;
        },
    };
    return 0;
}
