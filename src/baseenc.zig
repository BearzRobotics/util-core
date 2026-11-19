// SPDX-License-Identifier: GPL-2.0-or-later
//! Shared argument parsing and diagnostics for base64, base32 and basenc: thin
//! wrapper over `util_core.baseenc` (decision 0004). The encodings and the
//! streaming encoder/decoder are in src/lib/baseenc.zig.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const lib = @import("lib/baseenc.zig");

pub const Kind = lib.Kind;

// -------------------------------------------------------------- front end

const long_names = [_][]const u8{ "decode", "ignore-garbage", "wrap", "help", "version", "base64", "base64url", "base32", "base32hex", "base16", "base2msbf", "base2lsbf", "z85" };

/// `fixed` is the encoding of base64/base32; basenc passes null and takes it
/// from an option.
pub fn main(ctx: cli.Context, fixed: ?Kind) u8 {
    var kind: ?Kind = fixed;
    var decode = false;
    var ignore = false;
    var wrap: usize = 76;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    const is_basenc = fixed == null;

    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
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
            if (k >= 5 and !is_basenc) {
                cli.badLong(ctx, a, .none);
                return 1;
            }
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (k == 2 and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--wrap' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                    return 1;
                }
                value = ctx.args[i];
            } else if (k != 2 and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => decode = true,
                1 => ignore = true,
                2 => wrap = parseWrap(ctx, value.?) orelse return 1,
                3 => return help(ctx, is_basenc),
                4 => return if (cli.printVersion(ctx)) 0 else 1,
                5 => kind = .base64,
                6 => kind = .base64url,
                7 => kind = .base32,
                8 => kind = .base32hex,
                9 => kind = .base16,
                10 => kind = .base2msbf,
                11 => kind = .base2lsbf,
                else => kind = .z85,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'd' => decode = true,
            'i' => ignore = true,
            'w' => {
                var value: []const u8 = a[j + 1 ..];
                if (value.len == 0) {
                    i += 1;
                    if (i >= ctx.args.len) {
                        cli.warn(ctx, "option requires an argument -- 'w'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    value = ctx.args[i];
                }
                wrap = parseWrap(ctx, value) orelse return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }
    const k = kind orelse {
        cli.warn(ctx, "missing encoding type\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    };
    if (files.items.len > 1) {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ files.items[1], ctx.name });
        return 1;
    }
    const name: []const u8 = if (files.items.len == 1) files.items[0] else "-";
    const input: lib.Input = if (std.mem.eql(u8, name, "-"))
        .{ .name = name, .source = .{ .file = Io.File.stdin() } }
    else
        .{ .name = name, .source = .{ .path = name } };

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = lib.run(env, .{ .kind = k, .decode = decode, .ignore_garbage = ignore, .wrap = wrap }, input, &stdout.interface) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    switch (result) {
        .ok => {},
        .open_failed => |e| {
            // GNU opens a directory fine and reports the failed read.
            if (e == error.IsDir) cli.warn(ctx, "read error: Is a directory", .{}) else cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
            return 1;
        },
        .read_failed => |e| {
            _ = cli.flushWriter(&stdout);
            cli.warn(ctx, "read error: {s}", .{cli.errText(e)});
            return 1;
        },
        .invalid_input => {
            _ = cli.flushWriter(&stdout);
            cli.warn(ctx, "invalid input", .{});
            return 1;
        },
        .bad_length => {
            _ = cli.flushWriter(&stdout);
            cli.warn(ctx, "invalid input (length must be multiple of 4 characters)", .{});
            return 1;
        },
    }
    if (!cli.flushWriter(&stdout)) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return 0;
}

fn parseWrap(ctx: cli.Context, text: []const u8) ?usize {
    return std.fmt.parseInt(usize, text, 10) catch {
        cli.warn(ctx, "invalid wrap size: '{s}'", .{text});
        return null;
    };
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context, basenc: bool) u8 {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Usage: {s} [OPTION]... [FILE]\n" ++
        "Encode or decode FILE, or standard input, to standard output.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "{s}" ++
        "  -d, --decode          decode data\n" ++
        "  -i, --ignore-garbage  when decoding, ignore non-alphabet characters\n" ++
        "  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).\n" ++
        "                          Use 0 to disable line wrapping\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n", .{
        ctx.name,
        if (basenc) "      --base64 --base64url --base32 --base32hex --base16\n      --base2msbf --base2lsbf --z85   select the encoding\n" else "",
    }) catch return 1;
    return if (cli.writeStdout(ctx.io, text)) 0 else 1;
}
