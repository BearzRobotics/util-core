// SPDX-License-Identifier: GPL-2.0-or-later
//! fmt: thin wrapper over `util_core.fmt` (decision 0004). Parses arguments
//! the way GNU fmt does and words the diagnostics; the paragraph-filling
//! algorithm is in src/lib/fmt.zig.

const std = @import("std");
const numparse = @import("../numparse.zig");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const fmt = @import("../lib/fmt.zig");
const Io = std.Io;

const help_text = @embedFile("../help/fmt.txt");

const WidthError = error{ invalid, range };

fn parseWidth(text: []const u8, max: u64) WidthError!u64 {
    if (text.len > 0 and text[0] == '-') return error.invalid;
    const v = numparse.parseInt(u64, text, 10) catch |e| return if (e == error.Overflow) error.range else error.invalid;
    if (v > max) return error.range;
    return v;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var width_opt: ?[]const u8 = null;
    var goal_opt: ?[]const u8 = null;
    var args = ctx.args;
    if (args.len > 0 and args[0].len >= 2 and args[0][0] == '-' and std.ascii.isDigit(args[0][1])) {
        width_opt = args[0][1..];
        args = args[1..];
    }
    var c2 = ctx;
    c2.args = args;

    var opts: fmt.Options = .{};
    var prefix_arg: ?[]const u8 = null;

    var p = getopt.Parser.init(c2, "0123456789cstuw:p:g:", &.{
        .{ .name = "crown-margin", .id = 'c' },
        .{ .name = "prefix", .arg = .required, .id = 'p' },
        .{ .name = "split-only", .id = 's' },
        .{ .name = "tagged-paragraph", .id = 't' },
        .{ .name = "uniform-spacing", .id = 'u' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "goal", .arg = .required, .id = 'g' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'c' => opts.crown = true,
            's' => opts.split = true,
            't' => opts.tagged = true,
            'u' => opts.uniform = true,
            'w' => width_opt = o.arg,
            'g' => goal_opt = o.arg,
            'p' => prefix_arg = o.arg,
            '0'...'9' => {
                cli.warn(ctx, "invalid option -- {c}; -WIDTH is recognized only when it is the first\noption; use -w N instead\nTry '{s} --help' for more information.", .{ @as(u8, @intCast(o.id)), ctx.name });
                return 1;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (prefix_arg) |pa| opts.prefix = pa;
    if (width_opt) |w| {
        opts.max_width = @intCast(parseWidth(w, fmt.max_width_limit) catch |e| {
            cli.warn(ctx, "invalid width: {f}{s}", .{ cli.quoteC(w), if (e == error.range) ": Numerical result out of range" else "" });
            return 1;
        });
    }
    if (goal_opt) |g| {
        opts.goal_width = @intCast(parseWidth(g, @intCast(opts.max_width)) catch |e| {
            cli.warn(ctx, "invalid width: {f}{s}", .{ cli.quoteC(g), if (e == error.range) ": Value too large for defined data type" else "" });
            return 1;
        });
        if (width_opt == null) opts.max_width = opts.goal_width.? + 10;
    }

    var names: []const []const u8 = p.operands.items;
    const dash = [_][]const u8{"-"};
    if (names.len == 0) names = &dash;
    var inputs: std.ArrayList(fmt.Input) = .empty;
    defer inputs.deinit(gpa);
    for (names) |name| {
        const in: fmt.Input = if (std.mem.eql(u8, name, "-"))
            .{ .name = name, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = name, .source = .{ .path = name } };
        inputs.append(gpa, in) catch return 1;
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: fmt.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    const result = fmt.run(env, opts, inputs.items, &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
        error.OutOfMemory => return 1,
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    if (!cli.flushWriter(&stdout)) return 1;
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: fmt.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .open_failed => |e| cli.warn(ctx.*, "cannot open {f} for reading: {s}", .{ cli.quoteA(e.name), cli.errText(e.err) }),
        .read_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
    }
}
