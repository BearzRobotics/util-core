//! comm — compare two sorted files line by line.
//! References: GNU coreutils manual "comm invocation" (9.7); POSIX.1-2024 comm.
//!
//! Lines are compared bytewise (C locale; LC_COLLATE is not consulted).
//! Order checking follows GNU: by default an out-of-order input is reported
//! (once per file) only when an unpairable line has been seen; --check-order
//! makes it fatal at once and --nocheck-order disables it. After a reported
//! disorder the exit status is 1 and "input is not in sorted order" is printed.

const std = @import("std");
const cli = @import("../cli.zig");
const lines = @import("../lines.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "check-order", "nocheck-order", "output-delimiter", "total", "zero-terminated", "help", "version" };

const Check = enum { default, enabled, disabled };

const Side = struct {
    reader: lines.LineReader,
    cur: std.ArrayList(u8) = .empty,
    prev: std.ArrayList(u8) = .empty,
    present: bool = false,
    warned: bool = false,
    file: Io.File,
    is_stdin: bool,
};

pub fn main(ctx: cli.Context) u8 {
    var suppress = [3]bool{ false, false, false };
    var check: Check = .default;
    var delim: ?[]const u8 = null;
    var total = false;
    var term: u8 = '\n';
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
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
                0 => check = .enabled,
                1 => check = .disabled,
                2 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--output-delimiter' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        val = args[i];
                    }
                    if (delim) |d| if (!std.mem.eql(u8, d, val)) {
                        cli.warn(ctx, "multiple output delimiters specified", .{});
                        return 1;
                    };
                    delim = val;
                },
                3 => total = true,
                4 => term = 0,
                5 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            '1' => suppress[0] = true,
            '2' => suppress[1] = true,
            '3' => suppress[2] = true,
            'z' => term = 0,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    if (operands.items.len < 2) {
        if (operands.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        } else cli.warn(ctx, "missing operand after '{s}'\nTry '{s} --help' for more information.", .{ operands.items[0], ctx.name });
        return 1;
    }
    if (operands.items.len > 2) {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ operands.items[2], ctx.name });
        return 1;
    }
    // An empty --output-delimiter means NUL (GNU).
    const sep: []const u8 = if (delim) |d| (if (d.len == 0) "\x00" else d) else "\t";

    var sides: [2]Side = undefined;
    var opened: usize = 0;
    defer for (sides[0..opened]) |*s| {
        s.cur.deinit(ctx.gpa);
        s.prev.deinit(ctx.gpa);
        s.reader.deinit();
        if (!s.is_stdin) s.file.close(ctx.io);
    };
    for (operands.items, 0..) |path, k| {
        const file = cli.openInput(ctx.io, path) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            return 1;
        };
        const is_stdin = std.mem.eql(u8, path, "-");
        sides[k] = .{ .reader = lines.LineReader.init(ctx.gpa, ctx.io, file, term), .file = file, .is_stdin = is_stdin };
        opened = k + 1;
    }

    var out = cli.Out.init(ctx.io);
    const status = compare(ctx, &out, &sides, suppress, check, sep, total, term);
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return status;
}

fn advance(ctx: cli.Context, s: *Side) !void {
    std.mem.swap(std.ArrayList(u8), &s.prev, &s.cur);
    s.cur.clearRetainingCapacity();
    if (try s.reader.next()) |l| {
        try s.cur.appendSlice(ctx.gpa, l.text);
        s.present = true;
    } else s.present = false;
}

fn compare(ctx: cli.Context, out: *cli.Out, sides: *[2]Side, suppress: [3]bool, check: Check, sep: []const u8, total: bool, term: u8) u8 {
    var counts = [3]u64{ 0, 0, 0 };
    var seen_unpairable = false;
    var disorder = false;
    // Prime both sides; the first line of each file is never order-checked.
    for (sides) |*s| advance(ctx, s) catch return readFail(ctx, out);

    while (sides[0].present or sides[1].present) {
        const order: i32 = if (!sides[0].present) 1 else if (!sides[1].present) -1 else switch (std.mem.order(u8, sides[0].cur.items, sides[1].cur.items)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
        if (order == 0) {
            counts[2] += 1;
            if (!suppress[2]) emit(out, 2, sides[0].cur.items, suppress, sep, term);
        } else if (order < 0) {
            seen_unpairable = true;
            counts[0] += 1;
            if (!suppress[0]) emit(out, 0, sides[0].cur.items, suppress, sep, term);
        } else {
            seen_unpairable = true;
            counts[1] += 1;
            if (!suppress[1]) emit(out, 1, sides[1].cur.items, suppress, sep, term);
        }
        const checking = check == .enabled or (check == .default and seen_unpairable);
        for (sides, 0..) |*s, k| {
            const move = if (k == 0) order <= 0 else order >= 0;
            if (!move) continue;
            advance(ctx, s) catch return readFail(ctx, out);
            if (checking and s.present and !s.warned and std.mem.order(u8, s.prev.items, s.cur.items) == .gt) {
                out.flush();
                cli.warn(ctx, "file {d} is not in sorted order", .{k + 1});
                s.warned = true;
                disorder = true;
                if (check == .enabled) return 1;
            }
        }
    }
    if (total) {
        var b: [64]u8 = undefined;
        for (counts, 0..) |c, k| {
            const t = std.fmt.bufPrint(&b, "{d}", .{c}) catch unreachable;
            out.write(t);
            _ = k;
            out.write(sep);
        }
        out.write("total");
        out.writeByte(term);
    }
    if (disorder) {
        out.flush();
        cli.warn(ctx, "input is not in sorted order", .{});
        return 1;
    }
    return 0;
}

/// Write one output line in column `col` (0, 1 or 2).
fn emit(out: *cli.Out, col: usize, line: []const u8, suppress: [3]bool, sep: []const u8, term: u8) void {
    var lead: usize = 0;
    if (col >= 1 and !suppress[0]) lead += 1;
    if (col >= 2 and !suppress[1]) lead += 1;
    while (lead > 0) : (lead -= 1) out.write(sep);
    out.write(line);
    out.writeByte(term);
}

fn readFail(ctx: cli.Context, out: *cli.Out) u8 {
    out.flush();
    cli.warn(ctx, "read error", .{});
    return 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: comm [OPTION]... FILE1 FILE2\n" ++
        "Compare sorted files FILE1 and FILE2 line by line.\n\n" ++
        "When FILE1 or FILE2 (not both) is -, read standard input.\n\n" ++
        "With no options, produce three-column output.  Column one contains\n" ++
        "lines unique to FILE1, column two contains lines unique to FILE2,\n" ++
        "and column three contains lines common to both files.\n\n" ++
        "  -1                      suppress column 1 (lines unique to FILE1)\n" ++
        "  -2                      suppress column 2 (lines unique to FILE2)\n" ++
        "  -3                      suppress column 3 (lines that appear in both files)\n\n" ++
        "      --check-order     check that the input is correctly sorted, even\n" ++
        "                          if all input lines are pairable\n" ++
        "      --nocheck-order   do not check that the input is correctly sorted\n" ++
        "      --output-delimiter=STR  separate columns with STR\n" ++
        "      --total           output a summary\n" ++
        "  -z, --zero-terminated    line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
