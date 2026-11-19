// SPDX-License-Identifier: GPL-2.0-or-later
//! tsort — topological sort.
//! References: GNU coreutils manual "tsort invocation" (9.7); POSIX.1-2024
//! tsort.
//!
//! Input is pairs of whitespace-separated strings meaning "first before
//! second"; equal strings only register the item. Output order reproduces
//! GNU: nodes with no predecessors seed a first-in-first-out queue in byte
//! order; finishing a node releases its successors in reverse order of
//! insertion. Cycles: when the queue empties with nodes left, a cycle is
//! reported ("input contains a loop:" then one node per line), its closing
//! edge is dropped, and sorting resumes; the exit status is then 1.
//!
//! Known deviation: GNU's choice of *which* cycle to report and where to
//! start it follows its internal tree walk. This implementation models that
//! walk (and agrees with GNU on most small graphs, always on acyclic input)
//! but cannot guarantee identical diagnostics for every cyclic graph.
//! -w (POSIX.1-2024) makes the exit status the number of cycles found (at most
//! 125); GNU 9.7 does not have -w.

const std = @import("std");
const cli = @import("../cli.zig");
const tsort = @import("../lib/tsort.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var count_cycles = false;
    var path: ?[]const u8 = null;
    var only_operands = false;
    var extra: ?[]const u8 = null;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            if (path == null) path = a else if (extra == null) extra = a;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| if (k == 0) return help(ctx) else return if (cli.printVersion(ctx)) 0 else 1,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        }
        for (a[1..]) |c| switch (c) {
            'w' => count_cycles = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (extra) |e| {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ e, ctx.name });
        return 1;
    }
    const name = path orelse "-";

    const input: tsort.Input = if (std.mem.eql(u8, name, "-"))
        .{ .name = name, .source = .{ .file = Io.File.stdin() } }
    else
        .{ .name = name, .source = .{ .path = name } };

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: tsort.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = tsort.run(env, .{}, input, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    if (result.failed) return 1;
    if (result.cycles > 0) return if (count_cycles) @intCast(@min(result.cycles, 125)) else 1;
    return 0;
}

fn report(context: ?*anyopaque, ev: tsort.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev.kind) {
        .open_failed => if (ev.err.? == error.IsDir) {
            cli.warn(ctx.*, "{s}: read error: Is a directory", .{ev.name});
        } else cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err.?) }),
        .read_failed => cli.warn(ctx.*, "{s}: read error: {s}", .{ ev.name, cli.errText(ev.err.?) }),
        .odd_tokens => cli.warn(ctx.*, "{s}: input contains an odd number of tokens", .{ev.name}),
        .loop => cli.warn(ctx.*, "{s}: input contains a loop:", .{ev.name}),
        .loop_node => cli.warn(ctx.*, "{s}", .{ev.name}),
    }
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tsort [OPTION] [FILE]\n" ++
        "Write totally ordered list consistent with the partial ordering in FILE.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "  -w                count cycles in the exit status (POSIX)\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
