// SPDX-License-Identifier: GPL-2.0-or-later
//! mkfifo — make named pipes.
//! Reference: GNU coreutils manual "mkfifo invocation" (9.7); POSIX.1-2024 mkfifo.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const mkfifo = @import("../lib/mkfifo.zig");

const help_text = @embedFile("../help/mkfifo.txt");

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
    const names = p.operands.items;
    if (names.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 1;
    }
    const umask = sys.umask();
    const final = mkfifo.resolveMode(mode_text, umask) catch |e| {
        switch (e) {
            error.InvalidMode => cli.warn(ctx, "invalid mode", .{}),
            error.NotPermissionBits => cli.warn(ctx, "mode must specify only file permission bits", .{}),
        }
        return 1;
    };
    const env: mkfifo.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const ok = mkfifo.run(env, final, names, .{ .context = @constCast(&ctx), .func = report }) catch return 1;
    return if (ok) 0 else 1;
}

fn report(context: ?*anyopaque, ev: mkfifo.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev.failure) {
        .create => |e| cli.warn(ctx.*, "cannot create fifo {f}: {s}", .{ cli.quoteA(ev.name), sys.errnoText(e) }),
        .permissions => |e| cli.warn(ctx.*, "cannot set permissions of {f}: {s}", .{ cli.quoteA(ev.name), cli.errText(e) }),
    }
}
