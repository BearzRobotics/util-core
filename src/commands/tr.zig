// SPDX-License-Identifier: GPL-2.0-or-later
//! tr — translate, squeeze and/or delete characters.
//! References: GNU coreutils manual "tr invocation" (9.7); POSIX.1-2024 tr.
//!
//! Characters are bytes (the C locale), so classes, ranges and the
//! complement are defined over the 256 byte values in ascending order, like
//! `LC_ALL=C tr`. Multibyte locales and collation are not implemented.
//!
//! Operand strings are parsed into constructs: a byte, a range `a-z`, a class
//! `[:alpha:]`, an equivalence class `[=a=]` and, in string2 only, a repeat
//! `[c*n]`. Backslash escapes (\a \b \f \n \r \t \v \\ and 1-3 digit octal)
//! make the following character literal. Translation pads a short string2
//! with its last byte (GNU), or truncates string1 with -t.
//! Behaviour and diagnostics were checked against GNU tr 9.7.

const std = @import("std");
const cli = @import("../cli.zig");
const tr = @import("../lib/tr.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "complement", "delete", "squeeze-repeats", "truncate-set1", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var complement = false;
    var delete = false;
    var squeeze = false;
    var truncate = false;
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);

    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        // A lone "-" and anything not starting with '-' are operands. As in
        // GNU, so is everything after the first operand, or after "--":
        // STRING2 may start with '-'.
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
            only_operands = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => complement = true,
                    1 => delete = true,
                    2 => squeeze = true,
                    3 => truncate = true,
                    4 => return help(ctx),
                    else => return if (cli.printVersion(ctx)) 0 else 1,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'c', 'C' => complement = true,
            'd' => delete = true,
            's' => squeeze = true,
            't' => truncate = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    // Operand count rules (diagnostics as GNU).
    const n = operands.items.len;
    const try_line = "Try '{s} --help' for more information.";
    if (n == 0) {
        cli.warn(ctx, "missing operand\n" ++ try_line, .{ctx.name});
        return 1;
    }
    if (n > 2 or (delete and !squeeze and n > 1)) {
        const extra = operands.items[if (delete and !squeeze) 1 else 2];
        if (delete and !squeeze and n == 2) {
            cli.warn(ctx, "extra operand '{s}'\nOnly one string may be given when deleting without squeezing repeats.\n" ++ try_line, .{ extra, ctx.name });
        } else cli.warn(ctx, "extra operand '{s}'\n" ++ try_line, .{ extra, ctx.name });
        return 1;
    }
    if (n == 1 and !delete and !squeeze) {
        cli.warn(ctx, "missing operand after '{s}'\nTwo strings must be given when translating.\n" ++ try_line, .{ operands.items[0], ctx.name });
        return 1;
    }
    if (n == 1 and delete and squeeze) {
        cli.warn(ctx, "missing operand after '{s}'\nTwo strings must be given when both deleting and squeezing repeats.\n" ++ try_line, .{ operands.items[0], ctx.name });
        return 1;
    }
    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: tr.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    tr.run(env, .{
        .complement = complement,
        .delete = delete,
        .squeeze = squeeze,
        .truncate = truncate,
    }, operands.items[0], if (n == 2) operands.items[1] else null, .{ .name = "-", .source = .{ .file = Io.File.stdin() } }, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.InvalidSpec, error.ReadFailed => return 1,
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    return 0;
}

fn report(context: ?*anyopaque, ev: tr.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .trailing_backslash => cli.warn(ctx.*, "warning: an unescaped backslash at end of string is not portable", .{}),
        .ambiguous_octal => |d| cli.warn(ctx.*, "warning: the ambiguous octal escape \\{s} is being\n\tinterpreted as the 2-byte sequence \\0{c}{c}, {c}", .{ d[0..3], d[0], d[1], d[2] }),
        .reverse_range => |r| cli.warn(ctx.*, "range-endpoints of '{c}-{c}' are in reverse collating sequence order", .{ r.lo, r.hi }),
        .equiv_operand => |s| cli.warn(ctx.*, "{s}: equivalence class operand must be a single character", .{s}),
        .invalid_class => |s| cli.warn(ctx.*, "invalid character class '{s}'", .{s}),
        .invalid_repeat => |s| cli.warn(ctx.*, "invalid repeat count '{s}' in [c*n] construct", .{s}),
        .repeat_in_string1 => cli.warn(ctx.*, "the [c*] repeat construct may not appear in string1", .{}),
        .several_fills => cli.warn(ctx.*, "only one [c*] repeat construct may appear in string2", .{}),
        .equiv_in_string2 => cli.warn(ctx.*, "[=c=] expressions may not appear in string2 when translating", .{}),
        .string2_classes => cli.warn(ctx.*, "when translating, the only character classes that may appear in\nstring2 are 'upper' and 'lower'", .{}),
        .misaligned_case_class => cli.warn(ctx.*, "misaligned [:upper:] and/or [:lower:] construct", .{}),
        .string2_ends_with_class => cli.warn(ctx.*, "when translating with string1 longer than string2,\nthe latter string must not end with a character class", .{}),
        .empty_string2 => cli.warn(ctx.*, "when not truncating set1, string2 must be non-empty", .{}),
        .read_failed => |e| cli.warn(ctx.*, "read error: {s}", .{cli.errText(e)}),
    }
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tr [OPTION]... STRING1 [STRING2]\n" ++
        "Translate, squeeze, and/or delete characters from standard input,\n" ++
        "writing to standard output.\n\n" ++
        "  -c, -C, --complement    use the complement of STRING1\n" ++
        "  -d, --delete            delete characters in STRING1, do not translate\n" ++
        "  -s, --squeeze-repeats   replace each sequence of a repeated character\n" ++
        "                            that is listed in the last STRING, with a\n" ++
        "                            single occurrence of that character\n" ++
        "  -t, --truncate-set1     first truncate STRING1 to length of STRING2\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
