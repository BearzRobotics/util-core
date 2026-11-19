// SPDX-License-Identifier: GPL-2.0-or-later
//! sum: thin wrapper over `util_core.sum` (decision 0004); the checksums are
//! in src/lib/sum.zig. Checksum and block count (BSD or System V algorithm).
//! Reference: GNU coreutils manual "sum invocation" (9.7).
//!
//! Output: "SUM BLOCKS [NAME]". The BSD form (default, -r) writes the 16-bit
//! checksum with five digits and the block count (1024-byte blocks) right
//! aligned in five columns; the System V form (-s) uses plain numbers and
//! 512-byte blocks. A name is printed when at least one file operand is given.

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;
const lib = @import("../lib/sum.zig");

const long_names = [_][]const u8{ "sysv", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var sysv = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
        } else if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
        } else if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            switch (m) {
                .found => |k| {
                    if (eq != null) {
                        cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                        return 1;
                    }
                    switch (k) {
                        0 => sysv = true,
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
            'r' => sysv = false,
            's' => sysv = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    var inputs: std.ArrayList(lib.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        inputs.append(ctx.gpa, .{ .name = null, .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
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
    var sink: Sink = .{ .ctx = &ctx, .fw = &stdout };
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = lib.run(env, .{ .sysv = sysv }, inputs.items, &stdout.interface, .{ .context = &sink, .func = report }) catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        cli.writeErrorWarn(ctx);
        return 1;
    };
    if (!cli.flushWriter(&stdout)) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return if (result.failed) 1 else 0;
}

const Sink = struct { ctx: *const cli.Context, fw: *Io.File.Writer };

fn report(context: ?*anyopaque, ev: lib.Event) void {
    const sink: *Sink = @ptrCast(@alignCast(context.?));
    sink.fw.interface.flush() catch {};
    cli.warn(sink.ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err) });
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: sum [OPTION]... [FILE]...\n" ++
        "Print or check BSD (16-bit) checksums.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "  -r              use BSD sum algorithm (the default), use 1K blocks\n" ++
        "  -s, --sysv      use System V sum algorithm, use 512 bytes blocks\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
