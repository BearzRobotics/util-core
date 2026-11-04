//! yes — repeatedly output a line. Reference: GNU coreutils yes(1).
//!
//! The output line (arguments joined by single spaces plus newline, default
//! "y\n") is replicated into a fixed 8 KiB buffer so each write is a large
//! syscall instead of one per line. Memory use is constant regardless of
//! argument size, unless a single line exceeds the buffer, in which case the
//! line is written directly.

const std = @import("std");
const cli = @import("../cli.zig");

const buffer_size = 8192;

pub fn main(ctx: cli.Context) u8 {
    var args = ctx.args;

    if (cli.soleArg(args, "--help")) {
        return if (cli.writeStdout(ctx.io, "Usage: yes [STRING]...\n" ++
            "  or:  yes OPTION\n" ++
            "Repeatedly output a line with all specified STRING(s), or 'y'.\n\n" ++
            "      --help     display this help and exit\n" ++
            "      --version  output version information and exit\n")) 0 else 1;
    }
    if (cli.soleArg(args, "--version")) return if (cli.printVersion(ctx)) 0 else 1;

    // "--" ends option parsing; any other leading "-x" is an unknown option.
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) {
        args = args[1..];
    } else if (args.len > 0 and args[0].len > 1 and args[0][0] == '-') {
        cli.warn(ctx, "invalid option -- '{c}'\nTry '{s} --help' for more information.", .{ args[0][1], ctx.name });
        return 1;
    }

    // Build one line, overflow-checked, in gpa memory.
    var line_len: usize = 0;
    if (args.len == 0) {
        line_len = 2;
    } else {
        for (args) |a| {
            line_len = std.math.add(usize, line_len, a.len + 1) catch return oom(ctx);
        }
    }
    const line = ctx.gpa.alloc(u8, line_len) catch return oom(ctx);
    defer ctx.gpa.free(line);
    if (args.len == 0) {
        line[0] = 'y';
        line[1] = '\n';
    } else {
        var at: usize = 0;
        for (args, 0..) |a, i| {
            @memcpy(line[at..][0..a.len], a);
            at += a.len;
            line[at] = if (i + 1 == args.len) '\n' else ' ';
            at += 1;
        }
    }

    // Replicate the line into a buffer (whole copies only).
    var buf: [buffer_size]u8 = undefined;
    const out: []const u8 = if (line.len > buf.len / 2) line else blk: {
        var filled: usize = 0;
        while (filled + line.len <= buf.len) : (filled += line.len) {
            @memcpy(buf[filled..][0..line.len], line);
        }
        break :blk buf[0..filled];
    };

    // Runs until the write fails (typically EPIPE when the reader exits).
    while (true) {
        if (!cli.writeStdout(ctx.io, out)) return 1;
    }
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}
