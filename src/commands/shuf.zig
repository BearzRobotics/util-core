// SPDX-License-Identifier: GPL-2.0-or-later
//! shuf: thin wrapper over `util_core.shuf` (decision 0004). Parses arguments
//! the way GNU shuf does and words the diagnostics; the permutation logic and
//! the gnulib-compatible random draws are in src/lib/shuf.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const shuf = @import("../lib/shuf.zig");
const Io = std.Io;

const help_text = @embedFile("../help/shuf.txt");

fn parseU64(text: []const u8) error{ Invalid, Overflow }!u64 {
    if (text.len == 0 or !std.ascii.isDigit(text[0])) {
        if (text.len > 0 and text[0] == '+' and text.len > 1) {} else return error.Invalid;
    }
    return std.fmt.parseInt(u64, text, 10) catch |e| switch (e) {
        error.Overflow => error.Overflow,
        else => error.Invalid,
    };
}

pub fn main(ctx: cli.Context) u8 {
    var echo = false;
    var repeat = false;
    var eol: u8 = '\n';
    var input_range: ?[2]u64 = null;
    var head_lines: u64 = std.math.maxInt(u64);
    var outfile: ?[]const u8 = null;
    var random_source: ?[]const u8 = null;
    var range_text: []const u8 = "";

    var p = getopt.Parser.init(ctx, "ei:n:o:rz", &.{
        .{ .name = "echo", .id = 'e' },
        .{ .name = "input-range", .arg = .required, .id = 'i' },
        .{ .name = "head-count", .arg = .required, .id = 'n' },
        .{ .name = "output", .arg = .required, .id = 'o' },
        .{ .name = "random-source", .arg = .required, .id = 1100 },
        .{ .name = "repeat", .id = 'r' },
        .{ .name = "zero-terminated", .id = 'z' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'e' => echo = true,
            'r' => repeat = true,
            'z' => eol = 0,
            'i' => {
                if (input_range != null) {
                    cli.warn(ctx, "multiple -i options specified", .{});
                    return 1;
                }
                const a = o.arg.?;
                range_text = a;
                const dash = std.mem.indexOfScalar(u8, a, '-');
                var ok = dash != null;
                var overflow = false;
                var lo: u64 = 0;
                var hi: u64 = 0;
                if (dash) |d| {
                    lo = parseU64(a[0..d]) catch |e| blk: {
                        ok = false;
                        overflow = e == error.Overflow;
                        break :blk 0;
                    };
                    hi = parseU64(a[d + 1 ..]) catch |e| blk: {
                        ok = false;
                        overflow = overflow or e == error.Overflow;
                        break :blk 0;
                    };
                }
                const n = hi -% lo +% 1;
                if (!ok or (lo <= hi) == (n == 0)) {
                    cli.warn(ctx, "invalid input range: {f}{s}", .{ cli.quoteC(a), if (overflow) ": Value too large for defined data type" else "" });
                    return 1;
                }
                input_range = .{ lo, hi };
            },
            'n' => {
                const v = parseU64(o.arg.?) catch |e| {
                    if (e == error.Overflow) continue;
                    cli.warn(ctx, "invalid line count: {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                };
                head_lines = @min(head_lines, v);
            },
            'o' => {
                if (outfile != null and !std.mem.eql(u8, outfile.?, o.arg.?)) {
                    cli.warn(ctx, "multiple output files specified", .{});
                    return 1;
                }
                outfile = o.arg;
            },
            1100 => {
                if (random_source != null and !std.mem.eql(u8, random_source.?, o.arg.?)) {
                    cli.warn(ctx, "multiple random sources specified", .{});
                    return 1;
                }
                random_source = o.arg;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const operands = p.operands.items;
    if (echo and input_range != null) {
        getopt.usageError(ctx, "cannot combine -e and -i options", .{});
        return 1;
    }
    if (if (input_range != null) operands.len > 0 else (!echo and operands.len > 1)) {
        const idx: usize = if (input_range != null) 0 else 1;
        getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(operands[idx])});
        return 1;
    }


    var opts: shuf.Options = .{
        .source = undefined,
        .repeat = repeat,
        .eol = eol,
        .head_lines = head_lines,
        .output_path = outfile,
        .random_source = random_source,
    };
    if (echo) {
        opts.source = .{ .echo = operands };
    } else if (input_range) |r| {
        opts.source = .{ .range = r };
    } else {
        const name: []const u8 = if (operands.len == 1) operands[0] else "-";
        opts.source = .{ .file = if (std.mem.eql(u8, name, "-"))
            .{ .name = name, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = name, .source = .{ .path = name } } };
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: shuf.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    shuf.run(env, opts, &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
        error.Failed, error.OutOfMemory => return 1,
        error.WriteFailed => {
            if (outfile == null) cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    return 0;
}

fn report(context: ?*anyopaque, ev: shuf.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .open_input => |e| {
            // GNU opens a directory fine and fails on the first read.
            if (e.err == error.IsDir) cli.warn(ctx.*, "read error: Is a directory", .{}) else cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) });
        },
        .read_input => cli.warn(ctx.*, "read error", .{}),
        .no_lines_to_repeat => cli.warn(ctx.*, "no lines to repeat", .{}),
        .open_random => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .random_read_error => |n| cli.warn(ctx.*, "{f}: read error", .{cli.quoteC(n)}),
        .random_eof => |n| cli.warn(ctx.*, "{f}: end of file", .{cli.quoteC(n)}),
        .open_output => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
    }
}
