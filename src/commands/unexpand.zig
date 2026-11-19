// SPDX-License-Identifier: GPL-2.0-or-later
//! unexpand — convert spaces to tabs.
//! References: GNU coreutils manual "unexpand invocation" (9.7); POSIX.1-2024
//! unexpand. Tab list syntax lives in src/tabs.zig.
//!
//! Model (checked against GNU by differential and randomised tests): runs of
//! blanks are held back; when the column reaches a tab stop they are replaced
//! by one TAB. A single space that reaches a stop after some non-blank text
//! stays a space if the next character is not a blank (a TAB would not save
//! anything); if the run continues it becomes part of the TAB. Held blanks
//! that do not reach a stop are written unchanged. Without -a only the
//! blanks before the first non-blank of a line are considered; -t implies -a
//! unless --first-only is given. Columns count bytes (C locale).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const tabs = @import("../tabs.zig");
const expand = @import("expand.zig");
const lib = @import("../lib/unexpand.zig");

const long_names = [_][]const u8{ "all", "first-only", "tabs", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var all = false;
    var first_only = false;
    var tab_text: std.ArrayList(u8) = .empty;
    defer tab_text.deinit(ctx.gpa);
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            switch (k) {
                0 => all = true,
                1 => first_only = true,
                2 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--tabs' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        val = args[i];
                    }
                    addTabs(ctx, &tab_text, val, &all) catch return oom(ctx);
                },
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        // Obsolete -N[,N...]: tab list that does not imply -a.
        if (std.mem.indexOfNone(u8, a[1..], "0123456789,") == null) {
            if (tab_text.items.len > 0) tab_text.append(ctx.gpa, ',') catch return oom(ctx);
            tab_text.appendSlice(ctx.gpa, a[1..]) catch return oom(ctx);
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'a' => all = true,
            't' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 't'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    val = args[i];
                }
                addTabs(ctx, &tab_text, val, &all) catch return oom(ctx);
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }
    if (first_only) all = false;

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const stops = expand.parseTabs(ctx, arena_state.allocator(), tab_text.items) orelse return 1;

    var inputs: std.ArrayList(lib.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        inputs.append(ctx.gpa, .{ .name = "-", .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (files.items) |path| {
        const in: lib.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = lib.run(env, .{ .stops = stops, .all = all }, inputs.items, &stdout.interface, .{
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
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: lib.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err) });
}

fn addTabs(ctx: cli.Context, list: *std.ArrayList(u8), text: []const u8, all: *bool) !void {
    if (list.items.len > 0) try list.append(ctx.gpa, ',');
    try list.appendSlice(ctx.gpa, text);
    all.* = true; // -t implies -a
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: unexpand [OPTION]... [FILE]...\n" ++
        "Convert blanks in each FILE to tabs, writing to standard output.\n\n" ++
        "  -a, --all        convert all blanks, instead of just initial blanks\n" ++
        "      --first-only  convert only leading sequences of blanks (overrides -a)\n" ++
        "  -t, --tabs=N     have tabs N characters apart instead of 8 (enables -a)\n" ++
        "  -t, --tabs=LIST  use comma separated list of tab positions.\n" ++
        "                     The last specified position can be prefixed with '/'\n" ++
        "                     to specify a tab size to use after the last\n" ++
        "                     explicitly specified tab stop.  Also a prefix of '+'\n" ++
        "                     can be used to align remaining tab stops relative to\n" ++
        "                     the last specified tab stop instead of the first column\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
