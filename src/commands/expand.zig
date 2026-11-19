// SPDX-License-Identifier: GPL-2.0-or-later
//! expand — convert tabs to spaces.
//! References: GNU coreutils manual "expand invocation" (9.7); POSIX.1-2024
//! expand. Tab list syntax lives in src/tabs.zig.
//!
//! Columns count bytes (C locale); a backspace decrements the column (not
//! below 0). A tab beyond the last stop of a multi-stop list becomes one
//! space. -i converts only the tabs before the first non-blank of a line.

const std = @import("std");
const cli = @import("../cli.zig");
const tabs = @import("../tabs.zig");
const lib = @import("../lib/expand.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "initial", "tabs", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var initial_only = false;
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
                0 => initial_only = true,
                1 => {
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
                    addTabText(ctx, &tab_text, val) catch return oom(ctx);
                },
                2 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        // Obsolete -N[,N...]: digits and commas only.
        if (std.mem.indexOfNone(u8, a[1..], "0123456789,") == null) {
            addTabText(ctx, &tab_text, a[1..]) catch return oom(ctx);
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'i' => initial_only = true,
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
                addTabText(ctx, &tab_text, val) catch return oom(ctx);
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const stops = parseTabs(ctx, arena_state.allocator(), tab_text.items) orelse return 1;

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
    const result = lib.run(env, .{ .stops = stops, .initial_only = initial_only }, inputs.items, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
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

fn addTabText(ctx: cli.Context, list: *std.ArrayList(u8), text: []const u8) !void {
    if (list.items.len > 0) try list.append(ctx.gpa, ',');
    try list.appendSlice(ctx.gpa, text);
}

/// Parse the accumulated tab list, printing GNU's diagnostics on failure.
pub fn parseTabs(ctx: cli.Context, arena: std.mem.Allocator, text: []const u8) ?tabs.Stops {
    var err: tabs.ParseError = .zero;
    return tabs.parse(arena, text, &err) orelse {
        switch (err) {
            .zero => cli.warn(ctx, "tab size cannot be 0", .{}),
            .not_ascending => cli.warn(ctx, "tab sizes must be ascending", .{}),
            .invalid_chars => |s| cli.warn(ctx, "tab size contains invalid character(s): {f}", .{quote(s)}),
            .slash_not_last => cli.warn(ctx, "'/' specifier only allowed with the last value", .{}),
            .plus_not_last => cli.warn(ctx, "'+' specifier only allowed with the last value", .{}),
            .slash_not_at_start => |s| cli.warn(ctx, "'/' specifier not at start of number: {f}", .{quote(s)}),
            .plus_not_at_start => |s| cli.warn(ctx, "'+' specifier not at start of number: {f}", .{quote(s)}),
            .too_large => |s| cli.warn(ctx, "tab stop is too large {f}", .{quote(s)}),
            .oom => cli.warn(ctx, "out of memory", .{}),
        }
        return null;
    };
}

/// GNU quotes diagnostics' operands with 'single quotes'.
fn quote(s: []const u8) Quoted {
    return .{ .s = s };
}

const Quoted = struct {
    s: []const u8,
    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('\'');
        try w.writeAll(q.s);
        try w.writeByte('\'');
    }
};

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: expand [OPTION]... [FILE]...\n" ++
        "Convert tabs in each FILE to spaces, writing to standard output.\n\n" ++
        "  -i, --initial    do not convert tabs after non blanks\n" ++
        "  -t, --tabs=N     have tabs N characters apart, not 8\n" ++
        "  -t, --tabs=LIST  use comma separated list of tab positions.\n" ++
        "                     The last specified position can be prefixed with '/'\n" ++
        "                     to specify a tab size to use after the last\n" ++
        "                     explicitly specified tab stop.  Also a prefix of '+'\n" ++
        "                     can be used to align remaining tab stops relative to\n" ++
        "                     the last specified tab stop instead of the first column\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
