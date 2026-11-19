// SPDX-License-Identifier: GPL-2.0-or-later
//! uniq — report or filter out repeated adjacent lines.
//! References: GNU coreutils manual "uniq invocation" (9.7); POSIX.1-2024 uniq.
//!
//! Comparison key of a line: skip -f fields (each field is blanks followed by
//! non-blanks), then -s characters, then keep at most -w characters; -i folds
//! ASCII case. Characters are bytes (C locale). The traditional `-N` form
//! means -f N; `+N` is not accepted (it is a file name, as in GNU's default).
//! The last line is always written with a terminator.

const std = @import("std");
const cli = @import("../cli.zig");
const uniq = @import("../lib/uniq.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "count", "repeated", "all-repeated", "group", "unique", "ignore-case", "skip-fields", "skip-chars", "check-chars", "zero-terminated", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var cfg: uniq.Options = .{};
    var group_method: ?uniq.Delimit = null;
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    var pending_digits: ?usize = null; // traditional -N
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
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
                0 => cfg.count = true,
                1 => {
                    cfg.output_unique = false;
                },
                2 => {
                    cfg.all_repeated = true;
                    cfg.output_unique = false;
                    cfg.method = .none;
                    if (eq) |e| cfg.method = parseMethod(ctx, a[e + 1 ..], "all-repeated", &.{ .none, .prepend, .separate }) orelse return 1;
                },
                3 => {
                    cfg.group = true;
                    group_method = .separate;
                    if (eq) |e| group_method = parseMethod(ctx, a[e + 1 ..], "group", &.{ .prepend, .append, .separate, .both }) orelse return 1;
                },
                4 => cfg.output_first_repeated = false,
                5 => cfg.ignore_case = true,
                6, 7, 8 => {
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
                    if (!setNum(ctx, &cfg, k, val)) return 1;
                },
                9 => cfg.term = 0,
                10 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'c' => cfg.count = true,
            'd' => cfg.output_unique = false,
            'D' => {
                cfg.all_repeated = true;
                cfg.output_unique = false;
            },
            'u' => cfg.output_first_repeated = false,
            'i' => cfg.ignore_case = true,
            'z' => cfg.term = 0,
            '0'...'9' => {
                // Traditional -N: digits accumulate into one number.
                const d: usize = a[j] - '0';
                pending_digits = (pending_digits orelse 0) *| 10 +| d;
                cfg.skip_fields = pending_digits.?;
            },
            'f', 's', 'w' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                const k: usize = switch (a[j]) {
                    'f' => 6,
                    's' => 7,
                    else => 8,
                };
                if (!setNum(ctx, &cfg, k, val)) return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    if (cfg.group) {
        if (cfg.count or !cfg.output_unique or !cfg.output_first_repeated or cfg.all_repeated) {
            cli.warn(ctx, "--group is mutually exclusive with -c/-d/-D/-u\nTry '{s} --help' for more information.", .{ctx.name});
            return 1;
        }
        cfg.method = group_method.?;
    }
    if (cfg.count and cfg.all_repeated) {
        cli.warn(ctx, "printing all duplicated lines and repeat counts is meaningless\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (operands.items.len > 2) {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ operands.items[2], ctx.name });
        return 1;
    }

    const in_path: []const u8 = if (operands.items.len > 0) operands.items[0] else "-";
    const input = cli.openInput(ctx.io, in_path) catch |e| {
        cli.warn(ctx, "{s}: {s}", .{ in_path, cli.errText(e) });
        return 1;
    };
    defer cli.closeInput(ctx.io, input);

    var out_file: ?Io.File = null;
    if (operands.items.len > 1 and !std.mem.eql(u8, operands.items[1], "-")) {
        out_file = Io.Dir.cwd().createFile(ctx.io, operands.items[1], .{}) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ operands.items[1], cli.errText(e) });
            return 1;
        };
    }
    defer if (out_file) |f| f.close(ctx.io);
    var buf: [8192]u8 = undefined;
    var dest = (out_file orelse Io.File.stdout()).writerStreaming(ctx.io, &buf);

    const env: uniq.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = uniq.run(env, cfg, .{ .name = in_path, .source = .{ .file = input } }, &dest.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            // Only a failure on standard output is recorded for `finish`.
            if (out_file == null) cli.noteStdoutFailure(cli.errText(dest.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
        else => {
            cli.warn(ctx, "{s}: {s}", .{ in_path, cli.errText(e) });
            return 1;
        },
    };
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: uniq.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.warn(ctx.*, "read error: {s}", .{cli.errText(ev.err)});
}

fn parseMethod(ctx: cli.Context, text: []const u8, option: []const u8, comptime allowed: []const uniq.Delimit) ?uniq.Delimit {
    inline for (allowed) |m| {
        if (std.mem.eql(u8, text, @tagName(m))) return m;
    }
    // GNU accepts unambiguous abbreviations.
    var found: ?uniq.Delimit = null;
    var ambiguous = false;
    inline for (allowed) |m| {
        if (text.len > 0 and std.mem.startsWith(u8, @tagName(m), text)) {
            if (found != null) ambiguous = true;
            found = m;
        }
    }
    if (found != null and !ambiguous) return found;
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    inline for (allowed) |m| {
        const piece = std.fmt.bufPrint(buf[n..], "\n  - '{s}'", .{@tagName(m)}) catch "";
        n += piece.len;
    }
    const list = buf[0..n];
    cli.warn(ctx, "invalid argument '{s}' for '--{s}'\nValid arguments are:{s}\nTry '{s} --help' for more information.", .{ text, option, list, ctx.name });
    return null;
}

fn setNum(ctx: cli.Context, cfg: *uniq.Options, which: usize, val: []const u8) bool {
    var v: usize = 0;
    var ok = val.len > 0;
    for (val) |c| {
        if (!std.ascii.isDigit(c)) {
            ok = false;
            break;
        }
        v = v *| 10 +| (c - '0');
    }
    if (!ok) {
        const what = switch (which) {
            6 => "invalid number of fields to skip",
            7 => "invalid number of bytes to skip",
            else => "invalid number of bytes to compare",
        };
        cli.warn(ctx, "{s}: {s}", .{ val, what });
        return false;
    }
    switch (which) {
        6 => cfg.skip_fields = v,
        7 => cfg.skip_chars = v,
        else => cfg.check_chars = v,
    }
    return true;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: uniq [OPTION]... [INPUT [OUTPUT]]\n" ++
        "Filter adjacent matching lines from INPUT (or standard input),\n" ++
        "writing to OUTPUT (or standard output).\n\n" ++
        "  -c, --count           prefix lines by the number of occurrences\n" ++
        "  -d, --repeated        only print duplicate lines, one for each group\n" ++
        "  -D                    print all duplicate lines\n" ++
        "      --all-repeated[=METHOD]  like -D, but allow separating groups\n" ++
        "                                 with an empty line;\n" ++
        "                                 METHOD={none(default),prepend,separate}\n" ++
        "  -f, --skip-fields=N   avoid comparing the first N fields\n" ++
        "      --group[=METHOD]  show all items, separating groups with an empty line;\n" ++
        "                          METHOD={separate(default),prepend,append,both}\n" ++
        "  -i, --ignore-case     ignore differences in case when comparing\n" ++
        "  -s, --skip-chars=N    avoid comparing the first N characters\n" ++
        "  -u, --unique          only print unique lines\n" ++
        "  -z, --zero-terminated     line delimiter is NUL, not newline\n" ++
        "  -w, --check-chars=N   compare no more than N characters in lines\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
