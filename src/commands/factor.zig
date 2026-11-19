// SPDX-License-Identifier: GPL-2.0-or-later
//! factor: thin wrapper over `util_core.factor` (decision 0004). Parses
//! arguments the way GNU factor does and words the diagnostics; the number
//! parsing and factoring are in src/lib/factor.zig.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const factor = @import("../lib/factor.zig");

const long_names = [_][]const u8{ "exponents", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var exponents = false;
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-' or (a.len >= 2 and std.ascii.isDigit(a[1]) and false)) {
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
            switch (m) {
                .found => |k| {
                    if (eq != null) {
                        cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                        return 1;
                    }
                    switch (k) {
                        0 => exponents = true,
                        1 => return help(ctx),
                        else => return if (cli.printVersion(ctx)) 0 else 1,
                    }
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        } else for (a[1..]) |c| switch (c) {
            'h' => exponents = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: factor.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const options: factor.Options = .{ .exponents = exponents };
    const observer: factor.Observer = .{ .context = @constCast(&ctx), .func = report };
    const result = if (operands.items.len > 0)
        factor.run(env, options, operands.items, &stdout.interface, observer)
    else blk: {
        var rbuf: [64 * 1024]u8 = undefined;
        var stdin = Io.File.stdin().readerStreaming(ctx.io, &rbuf);
        break :blk factor.runReader(env, options, &stdin.interface, &stdout.interface, observer) catch |e| {
            if (e == error.ReadFailed) {
                cli.warn(ctx, "read error: {s}", .{cli.errText(stdin.err orelse error.ReadFailed)});
                return 1;
            }
            break :blk e;
        };
    };
    const r = result catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.ReadFailed => unreachable,
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    return if (r.ok) 0 else 1;
}

fn report(context: ?*anyopaque, ev: factor.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .invalid_number => |t| cli.warn(ctx.*, "{f} is not a valid positive integer", .{cli.quoteC(t)}),
        .too_hard => |h| cli.warn(ctx.*, "{s}: too hard to factor (no elliptic-curve method; gave up after {d} rho steps)", .{ h.number, h.steps }),
        .out_of_memory => cli.warn(ctx.*, "memory exhausted", .{}),
    }
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: factor [OPTION] [NUMBER]...\n" ++
        "Print the prime factors of each specified integer NUMBER.  If none\n" ++
        "are specified on the command line, read them from standard input.\n\n" ++
        "  -h, --exponents   print repeated factors in form p^e unless e is 1\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
