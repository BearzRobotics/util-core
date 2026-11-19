// SPDX-License-Identifier: GPL-2.0-or-later
//! pathchk: thin wrapper over `util_core.pathchk` (decision 0004). Parses
//! options and words the diagnostics; the checks are in src/lib/pathchk.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const lib = @import("../lib/pathchk.zig");

const help_text = @embedFile("../help/pathchk.txt");

pub fn main(ctx: cli.Context) u8 {
    var opts: lib.Options = .{};
    var p = getopt.Parser.init(ctx, "pP", &.{
        .{ .name = "portability", .id = 1100 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'p' => opts.basic = true,
            'P' => opts.extra = true,
            1100 => {
                opts.basic = true;
                opts.extra = true;
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
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const res = lib.run(env, opts, names, .{ .context = @constCast(&ctx), .func = report });
    return if (res.invalid > 0) 1 else 0;
}

fn report(context: ?*anyopaque, ev: lib.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    const file = ev.file;
    switch (ev.problem) {
        .empty_name => cli.warn(ctx.*, "empty file name", .{}),
        .leading_hyphen => cli.warn(ctx.*, "leading '-' in a component of file name {f}", .{cli.quoteA(file)}),
        .non_portable_char => |c| {
            var buf: [8]u8 = undefined;
            const shown: []const u8 = switch (c) {
                '\'' => "\\'",
                '\\' => "\\\\",
                7 => "\\a",
                8 => "\\b",
                9 => "\\t",
                10 => "\\n",
                11 => "\\v",
                12 => "\\f",
                13 => "\\r",
                else => if (c < 0x20 or c >= 0x7f)
                    std.fmt.bufPrint(&buf, "\\{o:0>3}", .{c}) catch unreachable
                else
                    @as(*const [1]u8, &c),
            };
            cli.warn(ctx.*, "non-portable character '{s}' in file name {f}", .{ shown, cli.quoteA(file) });
        },
        .stat_failed => |err| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(file), sys.errnoText(err) }),
        .name_too_long => |l| cli.warn(ctx.*, "limit {d} exceeded by length {d} of file name {f}", .{ l.limit, l.length, cli.quoteA(file) }),
        .component_too_long => |l| cli.warn(ctx.*, "limit {d} exceeded by length {d} of file name component {f}", .{ l.limit, l.length, cli.quoteA(l.component) }),
    }
}
