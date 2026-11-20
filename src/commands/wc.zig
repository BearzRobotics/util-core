// SPDX-License-Identifier: GPL-2.0-or-later
//! wc: thin wrapper over `util_core.wc` (decision 0004). Parses arguments the
//! way GNU wc does and words the diagnostics; the counting and the report are
//! in src/lib/wc.zig.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const wc = @import("../lib/wc.zig");

pub fn main(ctx: cli.Context) u8 {
    var show: wc.Show = .{};
    var any = false;
    var as_json = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);

    var only_operands = false;
    for (ctx.args) |a| {
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
        } else if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            if (std.mem.eql(u8, a, "--help")) return help(ctx);
            if (std.mem.eql(u8, a, "--version")) return if (cli.printVersion(ctx)) 0 else 1;
            if (std.mem.eql(u8, a, "--json")) {
                as_json = true;
                continue;
            }
            if (std.mem.eql(u8, a, "--lines")) {
                show.lines = true;
            } else if (std.mem.eql(u8, a, "--words")) {
                show.words = true;
            } else if (std.mem.eql(u8, a, "--chars")) {
                show.chars = true;
            } else if (std.mem.eql(u8, a, "--bytes")) {
                show.bytes = true;
            } else if (std.mem.eql(u8, a, "--max-line-length")) {
                show.max_line = true;
            } else if (std.mem.startsWith(u8, a, "--files0-from") or std.mem.startsWith(u8, a, "--total")) {
                cli.warn(ctx, "option '{s}' is not supported yet", .{a});
                return 1;
            } else return badOption(ctx, a);
            any = true;
        } else {
            for (a[1..]) |c| switch (c) {
                'l' => show.lines = true,
                'w' => show.words = true,
                'm' => show.chars = true,
                'c' => show.bytes = true,
                'L' => show.max_line = true,
                else => return badOption(ctx, a),
            };
            any = true;
        }
    }
    if (!any) show = .{ .lines = true, .words = true, .bytes = true };

    var inputs: std.ArrayList(wc.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        inputs.append(ctx.gpa, .{ .name = null, .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (files.items) |path| {
        const in: wc.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: wc.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = wc.run(env, .{ .show = show, .json = as_json }, inputs.items, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    if (!cli.flushWriter(&stdout)) return 1;
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: wc.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err) });
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: wc [OPTION]... [FILE]...\n" ++
        "Print newline, word, and byte counts for each FILE, and a total line if\n" ++
        "more than one FILE is specified. With no FILE, or when FILE is -, read\n" ++
        "standard input.\n\n" ++
        "  -c, --bytes            print the byte counts\n" ++
        "  -m, --chars            print the character counts\n" ++
        "  -l, --lines            print the newline counts\n" ++
        "  -L, --max-line-length  print the maximum display width\n" ++
        "  -w, --words            print the word counts\n" ++
        "      --json             print one JSON object per input (not in GNU)\n")) 0 else 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn badOption(ctx: cli.Context, opt: []const u8) u8 {
    if (opt.len >= 2 and opt[0] == '-' and opt[1] != '-') {
        cli.invalidShort(ctx, opt[1]);
    } else cli.warn(ctx, "unrecognized option '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}
