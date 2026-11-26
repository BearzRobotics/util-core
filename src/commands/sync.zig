// SPDX-License-Identifier: GPL-2.0-or-later
//! sync: thin wrapper over `util_core.sync` (decision 0004). Parses options,
//! applies GNU's option-combination rules and words the diagnostics.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const lib = @import("../lib/sync.zig");

const help_text = @embedFile("../help/sync.txt");

pub fn main(ctx: cli.Context) u8 {
    var data = false;
    var fs = false;
    var p = getopt.Parser.init(ctx, "df", &.{
        .{ .name = "data", .id = 'd' },
        .{ .name = "file-system", .id = 'f' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'd' => data = true,
            'f' => fs = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const files = p.operands.items;
    if (data and fs) {
        cli.warn(ctx, "cannot specify both --data and --file-system", .{});
        return 1;
    }
    if (data and files.len == 0) {
        cli.warn(ctx, "--data needs at least one argument", .{});
        return 1;
    }
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const mode: lib.Options.Mode = if (data) .data else if (fs) .fs else .file;
    const res = lib.run(env, .{ .mode = mode }, files, .{
        .context = @constCast(&ctx),
        .func = report,
    });
    return if (res.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: lib.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .open_failed => |e| cli.warn(ctx.*, "error opening {f}: {s}", .{ cli.quoteA(e.name), sys.errnoText(e.errno) }),
        .blocking_failed => |e| cli.warn(ctx.*, "couldn't reset non-blocking mode {f}: {s}", .{ cli.quoteA(e.name), sys.errnoText(e.errno) }),
        .sync_failed => |e| cli.warn(ctx.*, "error syncing {f}: {s}", .{ cli.quoteA(e.name), sys.errnoText(e.errno) }),
        .close_failed => |e| cli.warn(ctx.*, "failed to close {f}: {s}", .{ cli.quoteA(e.name), sys.errnoText(e.errno) }),
    }
}
