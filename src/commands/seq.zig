// SPDX-License-Identifier: GPL-2.0-or-later
//! seq: thin wrapper over `util_core.seq` (decision 0004). Parses arguments
//! the way GNU seq does and words the diagnostics; the sequence generation is
//! in src/lib/seq.zig (see there for the two evaluation paths).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const seq = @import("../lib/seq.zig");

const long_names = [_][]const u8{ "format", "separator", "equal-width", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var format: ?[]const u8 = null;
    var sep: []const u8 = "\n";
    var equal_width = false;
    var nums: std.ArrayList([]const u8) = .empty;
    defer nums.deinit(ctx.gpa);

    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-' or (std.ascii.isDigit(a[1]) or a[1] == '.')) {
            nums.append(ctx.gpa, a) catch return oom(ctx);
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
                0, 1 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                            return 1;
                        }
                        val = args[i];
                    }
                    if (k == 0) format = val else sep = val;
                },
                2 => equal_width = true,
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'w' => equal_width = true,
            'f', 's' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                if (a[j] == 'f') format = val else sep = val;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    if (format != null and equal_width) {
        cli.warn(ctx, "format string may not be specified when printing equal width strings\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (nums.items.len == 0) return usage(ctx, "missing operand", null);
    if (nums.items.len > 3) return usage(ctx, "extra operand", nums.items[3]);

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: seq.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = seq.run(env, .{
        .format = format,
        .separator = sep,
        .equal_width = equal_width,
    }, nums.items, &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
        error.OutOfMemory => {
            _ = cli.flushWriter(&stdout);
            return oom(ctx);
        },
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    return if (result.ok) 0 else 1;
}

fn report(context: ?*anyopaque, ev: seq.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .invalid_argument => |t| cli.warn(ctx.*, "invalid floating point argument: '{s}'\nTry '{s} --help' for more information.", .{ t, ctx.name }),
        .not_a_number => |t| cli.warn(ctx.*, "invalid 'not-a-number' argument: '{s}'\nTry '{s} --help' for more information.", .{ t, ctx.name }),
        .zero_increment => |t| cli.warn(ctx.*, "invalid Zero increment value: '{s}'\nTry '{s} --help' for more information.", .{ t, ctx.name }),
        .format_ends_in_percent => |f| cli.warn(ctx.*, "format '{s}' ends in %", .{f}),
        .format_too_many_directives => |f| cli.warn(ctx.*, "format '{s}' has too many % directives", .{f}),
        .format_no_directive => |f| cli.warn(ctx.*, "format '{s}' has no % directive", .{f}),
        .format_unknown_directive => |d| cli.warn(ctx.*, "format '{s}' has unknown %{c} directive", .{ d.format, d.conv }),
        .format_unsupported_directive => |d| cli.warn(ctx.*, "format '{s}': %{c} is not supported yet", .{ d.format, d.conv }),
    }
}

fn usage(ctx: cli.Context, what: []const u8, operand: ?[]const u8) u8 {
    if (operand) |o| {
        cli.warn(ctx, "{s} '{s}'\nTry '{s} --help' for more information.", .{ what, o, ctx.name });
    } else cli.warn(ctx, "{s}\nTry '{s} --help' for more information.", .{ what, ctx.name });
    return 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: seq [OPTION]... LAST\n" ++
        "  or:  seq [OPTION]... FIRST LAST\n" ++
        "  or:  seq [OPTION]... FIRST INCREMENT LAST\n" ++
        "Print numbers from FIRST to LAST, in steps of INCREMENT.\n\n" ++
        "  -f, --format=FORMAT      use printf style floating-point FORMAT\n" ++
        "  -s, --separator=STRING   use STRING to separate numbers (default: \\n)\n" ++
        "  -w, --equal-width        equalize width by padding with leading zeroes\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n\n" ++
        "If FIRST or INCREMENT is omitted, it defaults to 1.\n")) 0 else 1;
}
