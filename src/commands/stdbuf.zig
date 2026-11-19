// SPDX-License-Identifier: GPL-2.0-or-later
//! stdbuf — run a command with modified buffering of its standard streams.
//! Reference: GNU coreutils manual "stdbuf invocation" (9.7).
//!
//! The environment preparation (_STDBUF_I/O/E, LD_PRELOAD with libstdbuf.so)
//! is in src/lib/stdbuf.zig; replacing the process stays here.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const exec = @import("../exec.zig");
const stdbuf = @import("../lib/stdbuf.zig");

const help_text = @embedFile("../help/stdbuf.txt");

pub fn main(ctx: cli.Context) u8 {
    var modes: stdbuf.Modes = .{};
    var p = getopt.Parser.init(ctx, "+i:o:e:", &.{
        .{ .name = "input", .arg = .required, .id = 'i' },
        .{ .name = "output", .arg = .required, .id = 'o' },
        .{ .name = "error", .arg = .required, .id = 'e' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 125,
        .opt => |o| switch (o.id) {
            'i', 'o', 'e' => {
                const stream: stdbuf.Stream = if (o.id == 'i') .input else if (o.id == 'o') .output else .@"error";
                const m = o.arg.?;
                const mode = stdbuf.parseMode(stream, m) catch |e| {
                    switch (e) {
                        error.LineBufferedInput => getopt.usageError(ctx, "line buffering stdin is meaningless", .{}),
                        error.InvalidMode => cli.warn(ctx, "invalid mode {f}", .{cli.quoteC(m)}),
                        error.ValueTooLarge => cli.warn(ctx, "invalid mode {f}: Value too large for defined data type", .{cli.quoteC(m)}),
                    }
                    return 125;
                };
                switch (stream) {
                    .input => modes.input = mode,
                    .output => modes.output = mode,
                    .@"error" => modes.@"error" = mode,
                }
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 125,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 125,
            else => unreachable,
        },
    };
    const command = p.operands.items;
    if (command.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 125;
    }
    if (!modes.any()) {
        getopt.usageError(ctx, "you must specify a buffering mode option", .{});
        return 125;
    }

    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = stdbuf.findLibrary(ctx.io) orelse {
        cli.warn(ctx, "failed to find libstdbuf.so", .{});
        return 125;
    };
    const env = stdbuf.environment(a, ctx.environ, modes, lib) catch return 125;

    var argv: std.ArrayList([]const u8) = .empty;
    for (command) |c| argv.append(a, c) catch return 125;
    return exec.execStyled(ctx, command[0], argv.items, &env, .run);
}
