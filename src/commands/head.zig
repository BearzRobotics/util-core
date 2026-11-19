// SPDX-License-Identifier: GPL-2.0-or-later
//! head — output the first part of files.
//! References: GNU coreutils manual "head invocation" (9.7); POSIX.1-2024 head.
//!
//! POSIX: -n/-c with a positive count. GNU extensions implemented: size
//! suffixes, a leading '-' on the count (all but the last NUM), -q/-v/-z,
//! long options, and the obsolete `-NUM[bkm][cqv]` form when it is the first
//! argument. Files are streamed; "all but the last N" buffers the last N
//! items in memory (as GNU does for non-seekable input).

const std = @import("std");
const cli = @import("../cli.zig");
const count_arg = @import("../count_arg.zig");
const head = @import("../lib/head.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "bytes", "lines", "quiet", "silent", "verbose", "zero-terminated", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var cfg: head.Options = .{};
    var header: head.Header = .auto;
    var args = ctx.args;

    // Obsolete -NUM form: only as the first argument.
    if (args.len > 0 and isObsolete(args[0])) {
        if (!parseObsolete(ctx, args[0], &cfg, &header)) return 1;
        args = args[1..];
    }

    var i: usize = 0;
    var only_operands = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
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
                    if (!setCount(ctx, &cfg, k == 0, val)) return 1;
                },
                2, 3 => header = .never,
                4 => header = .always,
                5 => cfg.delimiter = 0,
                6 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'q' => header = .never,
            'v' => header = .always,
            'z' => cfg.delimiter = 0,
            'c', 'n' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                if (!setCount(ctx, &cfg, a[j] == 'c', val)) return 1;
                break;
            },
            '0'...'9' => {
                // GNU: digits are only valid in the obsolete first-argument form.
                cli.warn(ctx, "invalid trailing option -- {c}\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                return 1;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    var inputs: std.ArrayList(head.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        inputs.append(ctx.gpa, .{ .name = "-", .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (files.items) |path| {
        const in: head.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    cfg.header = header;
    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: head.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = head.run(env, cfg, inputs.items, &stdout.interface, .{
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

fn report(context: ?*anyopaque, ev: head.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    if (ev.stage == .open and ev.err == error.IsDir) {
        // GNU opens directories fine and fails on read.
        cli.warn(ctx.*, "error reading '{s}': Is a directory", .{ev.name});
    } else if (ev.stage == .open) {
        cli.warn(ctx.*, "cannot open '{s}' for reading: {s}", .{ ev.name, cli.errText(ev.err) });
    } else cli.warn(ctx.*, "error reading '{s}': {s}", .{ ev.name, cli.errText(ev.err) });
}

/// Obsolete `-NUM[bkm][cqv]`: '-' then at least one digit, then only letters
/// from b k m c l q v.
fn isObsolete(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-' or !std.ascii.isDigit(a[1])) return false;
    var i: usize = 1;
    while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
    for (a[i..]) |c| if (std.mem.indexOfScalar(u8, "bkmclqv", c) == null) return false;
    return true;
}

fn parseObsolete(ctx: cli.Context, a: []const u8, cfg: *head.Options, header: *head.Header) bool {
    var i: usize = 1;
    while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
    var digits_end = i;
    // A size letter directly after the digits belongs to the count.
    if (i < a.len and std.mem.indexOfScalar(u8, "bkm", a[i]) != null) digits_end = i + 1;
    const num = count_arg.parse(a[1..digits_end]) orelse {
        cli.warn(ctx, "invalid number of lines: '{s}'", .{a[1..digits_end]});
        return false;
    };
    cfg.count = num.value;
    cfg.skip_last = false;
    cfg.bytes = false;
    for (a[digits_end..]) |c| switch (c) {
        'c' => cfg.bytes = true,
        'l' => cfg.bytes = false,
        'q' => header.* = .never,
        'v' => header.* = .always,
        else => {},
    };
    return true;
}

fn setCount(ctx: cli.Context, cfg: *head.Options, bytes: bool, text: []const u8) bool {
    const c = count_arg.parse(text) orelse {
        cli.warn(ctx, "invalid number of {s}: '{s}'", .{ if (bytes) "bytes" else "lines", text });
        return false;
    };
    cfg.bytes = bytes;
    cfg.count = c.value;
    cfg.skip_last = c.sign == .minus;
    return true;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: head [OPTION]... [FILE]...\n" ++
        "Print the first 10 lines of each FILE to standard output.\n" ++
        "With more than one FILE, precede each with a header giving the file name.\n\n" ++
        "  -c, --bytes=[-]NUM       print the first NUM bytes of each file;\n" ++
        "                             with the leading '-', print all but the last\n" ++
        "                             NUM bytes of each file\n" ++
        "  -n, --lines=[-]NUM       print the first NUM lines instead of the first 10;\n" ++
        "                             with the leading '-', print all but the last\n" ++
        "                             NUM lines of each file\n" ++
        "  -q, --quiet, --silent    never print headers giving file names\n" ++
        "  -v, --verbose            always print headers giving file names\n" ++
        "  -z, --zero-terminated    line delimiter is NUL, not newline\n" ++
        "      --help               display this help and exit\n" ++
        "      --version            output version information and exit\n\n" ++
        "NUM may have a multiplier suffix: b 512, kB 1000, K 1024, MB 1000*1000,\n" ++
        "M 1024*1024, GB, G, T, P, E, Z, Y, R, Q.\n")) 0 else 1;
}

test "isObsolete" {
    try std.testing.expect(isObsolete("-5"));
    try std.testing.expect(isObsolete("-5q"));
    try std.testing.expect(isObsolete("-12kc"));
    try std.testing.expect(!isObsolete("-n"));
    try std.testing.expect(!isObsolete("-5x"));
    try std.testing.expect(!isObsolete("5"));
}
