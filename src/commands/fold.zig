// SPDX-License-Identifier: GPL-2.0-or-later
//! fold — wrap input lines to fit a given width.
//! References: GNU coreutils manual "fold invocation" (9.7); POSIX.1-2024 fold.
//!
//! Columns follow POSIX: a tab advances to the next multiple of 8, backspace
//! decrements (never below 0), carriage return resets to 0; with -b every
//! byte is one column. Characters are bytes (C locale); wide and multibyte
//! characters are not interpreted. -s breaks after the last blank (space or
//! tab) in the pending segment when there is one.

const std = @import("std");
const cli = @import("../cli.zig");
const fold = @import("../lib/fold.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "bytes", "spaces", "width", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var bytes_mode = false;
    var spaces = false;
    var width: usize = 80;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    var width_digits: ?usize = null; // obsolete -N
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
                0 => bytes_mode = true,
                1 => spaces = true,
                2 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--width' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        val = args[i];
                    }
                    width = parseWidth(ctx, val) orelse return 1;
                },
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'b' => bytes_mode = true,
            's' => spaces = true,
            '0'...'9' => {
                width_digits = (width_digits orelse 0) *| 10 +| (a[j] - '0');
                width = width_digits.?;
                if (width == 0) {
                    cli.warn(ctx, "invalid number of columns: '0': Numerical result out of range", .{});
                    return 1;
                }
            },
            'w' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 'w'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    val = args[i];
                }
                width = parseWidth(ctx, val) orelse return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    var inputs: std.ArrayList(fold.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        inputs.append(ctx.gpa, .{ .name = "-", .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (files.items) |path| {
        const in: fold.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: fold.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = fold.run(env, .{ .width = width, .bytes = bytes_mode, .spaces = spaces }, inputs.items, &stdout.interface, .{
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

fn report(context: ?*anyopaque, ev: fold.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev.stage) {
        .open => cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err.?) }),
        .read => cli.warn(ctx.*, "{s}: read error", .{ev.name}),
    }
}

fn parseWidth(ctx: cli.Context, text: []const u8) ?usize {
    var v: usize = 0;
    var ok = text.len > 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) {
            ok = false;
            break;
        }
        v = v *| 10 +| (c - '0');
    }
    if (!ok) {
        cli.warn(ctx, "invalid number of columns: '{s}'", .{text});
        return null;
    }
    if (v == 0) {
        cli.warn(ctx, "invalid number of columns: '{s}': Numerical result out of range", .{text});
        return null;
    }
    return v;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: fold [OPTION]... [FILE]...\n" ++
        "Wrap input lines in each FILE, writing to standard output.\n\n" ++
        "  -b, --bytes         count bytes rather than columns\n" ++
        "  -s, --spaces        break at spaces\n" ++
        "  -w, --width=WIDTH   use WIDTH columns instead of 80\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}

