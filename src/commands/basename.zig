// SPDX-License-Identifier: GPL-2.0-or-later
//! basename: thin wrapper over `util_core.basename` (decision 0004). Parses
//! arguments the way GNU basename does; the stripping is in
//! src/lib/basename.zig.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const lib = @import("../lib/basename.zig");

pub fn main(ctx: cli.Context) u8 {
    const args = ctx.args;
    if (cli.soleArg(args, "--help")) {
        return if (cli.writeStdout(ctx.io, "Usage: basename NAME [SUFFIX]\n" ++
            "  or:  basename OPTION... NAME...\n" ++
            "Print NAME with any leading directory components removed.\n\n" ++
            "  -a, --multiple       support multiple arguments\n" ++
            "  -s, --suffix=SUFFIX  remove a trailing SUFFIX; implies -a\n" ++
            "  -z, --zero           end each output line with NUL, not newline\n")) 0 else 1;
    }
    if (cli.soleArg(args, "--version")) return if (cli.printVersion(ctx)) 0 else 1;

    var multiple = false;
    var suffix: ?[]const u8 = null;
    var terminator: u8 = '\n';

    // Option parsing (GNU getopt_long style, with permutation of operands).
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    var only_operands = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
        } else if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
        } else if (std.mem.eql(u8, a, "--multiple")) {
            multiple = true;
        } else if (std.mem.eql(u8, a, "--zero")) {
            terminator = 0;
        } else if (std.mem.eql(u8, a, "--suffix")) {
            i += 1;
            if (i == args.len) return missingArg(ctx, "--suffix");
            suffix = args[i];
            multiple = true;
        } else if (std.mem.startsWith(u8, a, "--suffix=")) {
            suffix = a["--suffix=".len..];
            multiple = true;
        } else if (a[1] != '-') {
            // Cluster of short options.
            var j: usize = 1;
            while (j < a.len) : (j += 1) switch (a[j]) {
                'a' => multiple = true,
                'z' => terminator = 0,
                's' => {
                    multiple = true;
                    if (j + 1 < a.len) {
                        suffix = a[j + 1 ..];
                    } else {
                        i += 1;
                        if (i == args.len) return missingArg(ctx, "-s");
                        suffix = args[i];
                    }
                    break;
                },
                else => return badOption(ctx, a[j .. j + 1]),
            };
        } else return badOption(ctx, a);
    }

    var names = operands.items;
    if (names.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (!multiple) {
        if (names.len > 2) {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ names[2], ctx.name });
            return 1;
        }
        if (names.len == 2) {
            suffix = names[1];
            names = names[0..1];
        }
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    lib.run(env, .{ .suffix = suffix, .terminator = terminator }, names, &stdout.interface) catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        return 1;
    };
    return if (cli.flushWriter(&stdout)) 0 else 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn missingArg(ctx: cli.Context, opt: []const u8) u8 {
    cli.warn(ctx, "option '{s}' requires an argument\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}

fn badOption(ctx: cli.Context, opt: []const u8) u8 {
    cli.warn(ctx, "invalid option -- '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}
