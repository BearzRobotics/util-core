// SPDX-License-Identifier: GPL-2.0-or-later
//! comm — compare two sorted files line by line.
//! References: GNU coreutils manual "comm invocation" (9.7); POSIX.1-2024 comm.
//!
//! Lines are compared bytewise (C locale; LC_COLLATE is not consulted).
//! Order checking follows GNU: by default an out-of-order input is reported
//! (once per file) only when an unpairable line has been seen; --check-order
//! makes it fatal at once and --nocheck-order disables it. After a reported
//! disorder the exit status is 1 and "input is not in sorted order" is printed.

const std = @import("std");
const cli = @import("../cli.zig");
const comm = @import("../lib/comm.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "check-order", "nocheck-order", "output-delimiter", "total", "zero-terminated", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var suppress = [3]bool{ false, false, false };
    var check: comm.Check = .default;
    var delim: ?[]const u8 = null;
    var total = false;
    var term: u8 = '\n';
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
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
                0 => check = .enabled,
                1 => check = .disabled,
                2 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--output-delimiter' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        val = args[i];
                    }
                    if (delim) |d| if (!std.mem.eql(u8, d, val)) {
                        cli.warn(ctx, "multiple output delimiters specified", .{});
                        return 1;
                    };
                    delim = val;
                },
                3 => total = true,
                4 => term = 0,
                5 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            '1' => suppress[0] = true,
            '2' => suppress[1] = true,
            '3' => suppress[2] = true,
            'z' => term = 0,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    if (operands.items.len < 2) {
        if (operands.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        } else cli.warn(ctx, "missing operand after '{s}'\nTry '{s} --help' for more information.", .{ operands.items[0], ctx.name });
        return 1;
    }
    if (operands.items.len > 2) {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ operands.items[2], ctx.name });
        return 1;
    }
    var ins: [2]comm.Input = undefined;
    for (operands.items, 0..) |path, k| {
        ins[k] = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: comm.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = comm.run(env, .{
        .suppress = suppress,
        .check_order = check,
        .delimiter = delim orelse "\t",
        .total = total,
        .terminator = term,
    }, ins[0], ins[1], &stdout.interface, .{
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

fn report(context: ?*anyopaque, ev: comm.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev.kind) {
        .open_failed => cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err.?) }),
        .read_failed => cli.warn(ctx.*, "read error", .{}),
        .file_disorder => cli.warn(ctx.*, "file {d} is not in sorted order", .{ev.file}),
        .input_disorder => cli.warn(ctx.*, "input is not in sorted order", .{}),
    }
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: comm [OPTION]... FILE1 FILE2\n" ++
        "Compare sorted files FILE1 and FILE2 line by line.\n\n" ++
        "When FILE1 or FILE2 (not both) is -, read standard input.\n\n" ++
        "With no options, produce three-column output.  Column one contains\n" ++
        "lines unique to FILE1, column two contains lines unique to FILE2,\n" ++
        "and column three contains lines common to both files.\n\n" ++
        "  -1                      suppress column 1 (lines unique to FILE1)\n" ++
        "  -2                      suppress column 2 (lines unique to FILE2)\n" ++
        "  -3                      suppress column 3 (lines that appear in both files)\n\n" ++
        "      --check-order     check that the input is correctly sorted, even\n" ++
        "                          if all input lines are pairable\n" ++
        "      --nocheck-order   do not check that the input is correctly sorted\n" ++
        "      --output-delimiter=STR  separate columns with STR\n" ++
        "      --total           output a summary\n" ++
        "  -z, --zero-terminated    line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
