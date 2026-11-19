// SPDX-License-Identifier: GPL-2.0-or-later
//! rmdir: thin wrapper over `util_core.rmdir` (decision 0004). Parses
//! arguments the way GNU rmdir does and words the diagnostics.

const std = @import("std");
const cli = @import("../cli.zig");
const rmdir = @import("../lib/rmdir.zig");

const long_names = [_][]const u8{ "ignore-fail-on-non-empty", "parents", "verbose", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var ignore_nonempty = false;
    var parents = false;
    var verbose = false;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(ctx.gpa);
    const args = ctx.args;
    var only_operands = false;
    for (args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            dirs.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => ignore_nonempty = true,
                    1 => parents = true,
                    2 => verbose = true,
                    3 => return help(ctx),
                    else => return if (cli.printVersion(ctx)) 0 else 1,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'p' => parents = true,
            'v' => verbose = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (dirs.items.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    const env: rmdir.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const ok = rmdir.run(env, .{ .parents = parents, .ignore_fail_on_non_empty = ignore_nonempty }, dirs.items, .{
        .context = @constCast(&ctx),
        .func = if (verbose) reportVerbose else report,
    });
    return if (ok) 0 else 1;
}

fn report(context: ?*anyopaque, ev: rmdir.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .removing => {},
        .failed => |f| cli.warn(ctx.*, "failed to remove {s}'{s}': {s}", .{ if (f.is_parent) "directory " else "", f.path, errMessage(f.err) }),
    }
}

fn reportVerbose(context: ?*anyopaque, ev: rmdir.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    if (ev == .removing) cli.say(ctx.*, "removing directory, '{s}'", .{ev.removing});
    report(context, ev);
}

fn errMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.BadPathName, error.InvalidUtf8, error.InvalidWtf8 => "Invalid argument",
        else => cli.errText(e),
    };
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: rmdir [OPTION]... DIRECTORY...\n" ++
        "Remove the DIRECTORY(ies), if they are empty.\n\n" ++
        "      --ignore-fail-on-non-empty\n" ++
        "                    ignore each failure to remove a non-empty directory\n" ++
        "  -p, --parents     remove DIRECTORY and its ancestors; e.g., 'rmdir -p a/b'\n" ++
        "                      is similar to 'rmdir a/b a'\n" ++
        "  -v, --verbose     output a diagnostic for every directory processed\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
