// SPDX-License-Identifier: GPL-2.0-or-later
//! diff3: thin wrapper over `util_core.diff3` (decision 0004).
//! References: GNU diffutils manual "Comparing Three Files" (3.12).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const diff3 = @import("../lib/diff3.zig");

const help_text = @embedFile("../help/diff3.txt");

const O = struct {
    const diff_program = 1100;
    const strip_cr = 1101;
    const json = 1200;
};

fn usage(ctx: cli.Context, comptime fmt: []const u8, args: anytype) u8 {
    cli.warn(ctx, fmt, args);
    cli.warn(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 2;
}

fn readAll(ctx: cli.Context, path: []const u8) ![]u8 {
    const gpa = ctx.gpa;
    const is_stdin = std.mem.eql(u8, path, "-");
    const f = if (is_stdin) Io.File.stdin() else try Io.Dir.cwd().openFile(ctx.io, path, .{});
    defer if (!is_stdin) f.close(ctx.io);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var b: [65536]u8 = undefined;
    while (true) {
        const n = try cli.readChunk(ctx.io, f, &b);
        if (n == 0) break;
        if (list.items.len + n > (1 << 30)) return error.FileTooBig;
        try list.appendSlice(gpa, b[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var o: diff3.Options = .{};
    var text = false;
    var strip_cr = false;
    var merge = false;
    var as_json = false;
    var letter: ?u8 = null; // e E x X 3 A
    var write_quit = false;
    var nlabels: usize = 0;
    var labels: [3][]const u8 = .{ "", "", "" };
    var incompatible = false;
    var parser = getopt.Parser.init(ctx, "aeEimvx3ATXL:A", &.{
        .{ .name = "show-all", .id = 'A' },
        .{ .name = "ed", .id = 'e' },
        .{ .name = "show-overlap", .id = 'E' },
        .{ .name = "easy-only", .id = '3' },
        .{ .name = "overlap-only", .id = 'x' },
        .{ .name = "merge", .id = 'm' },
        .{ .name = "text", .id = 'a' },
        .{ .name = "initial-tab", .id = 'T' },
        .{ .name = "label", .arg = .required, .id = 'L' },
        .{ .name = "diff-program", .arg = .required, .id = O.diff_program },
        .{ .name = "strip-trailing-cr", .id = O.strip_cr },
        .{ .name = "json", .id = O.json },
    });
    parser.ext_min = 1100;
    parser.try_prefix = true;
    defer parser.deinit();
    while (true) {
        const item = parser.next();
        switch (item) {
            .done => break,
            .bad => return 2,
            .opt => {},
        }
        const a = item.opt;
        switch (a.id) {
            'e', 'E', 'x', 'X', '3', 'A' => {
                if (letter != null and letter.? != a.id) incompatible = true;
                letter = @intCast(a.id);
            },
            'i' => write_quit = true,
            'm' => merge = true,
            'a' => text = true,
            'T' => o.initial_tab = true,
            'L' => {
                if (nlabels >= 3) return usage(ctx, "too many file label options", .{});
                labels[nlabels] = a.arg.?;
                nlabels += 1;
            },
            O.diff_program => {
                if (!std.mem.eql(u8, a.arg.?, "diff")) {
                    cli.warn(ctx, "subsidiary program '{s}' is not supported; the built-in comparison is always used", .{a.arg.?});
                    return 2;
                }
            },
            O.strip_cr => strip_cr = true,
            O.json => as_json = true,
            'v', getopt.version_id => return if (cli.printVersion(ctx)) 0 else 2,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 2,
            else => unreachable,
        }
    }
    if (incompatible or (merge and write_quit) or (nlabels != 0 and nlabels != 3)) return usage(ctx, "incompatible options", .{});
    const ops = parser.operands.items;
    if (ops.len < 3) {
        const last: []const u8 = if (ctx.args.len > 0) ctx.args[ctx.args.len - 1] else ctx.name;
        return usage(ctx, "missing operand after '{s}'", .{last});
    }
    if (ops.len > 3) return usage(ctx, "extra operand '{s}'", .{ops[3]});
    if (as_json and (letter != null or merge or write_quit or o.initial_tab)) return usage(ctx, "option --json is incompatible with output style options", .{});
    for (0..3) |i| o.labels[i] = if (nlabels == 3) labels[i] else ops[i];
    if (letter) |l| switch (l) {
        'e' => {},
        '3' => o.select = .easy_only,
        'x', 'X' => o.select = .overlap_only,
        'E' => o.bracket = true,
        'A' => {
            o.bracket = true;
            o.show_all = true;
        },
        else => unreachable,
    } else if (merge) {
        o.bracket = true;
        o.show_all = true;
    }
    o.write_quit = write_quit;

    var data: [3][]u8 = .{ &.{}, &.{}, &.{} };
    defer for (data) |m| gpa.free(m);
    var stdin_count: usize = 0;
    for (ops) |p| {
        if (std.mem.eql(u8, p, "-")) stdin_count += 1;
    }
    if (stdin_count > 1) return usage(ctx, "incompatible options", .{});
    for (0..3) |i| {
        data[i] = readAll(ctx, ops[i]) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ ops[i], cli.errText(e) });
            return 2;
        };
    }
    if (!text) for (0..3) |i| {
        if (std.mem.indexOfScalar(u8, data[i][0..@min(data[i].len, 4096)], 0) != null) {
            cli.warn(ctx, "diff failed: Binary files {s} and {s} differ", .{ ops[0], ops[2] });
            return 2;
        }
    };

    var res = diff3.merge3(gpa, data[0], data[1], data[2], .{ .strip_trailing_cr = strip_cr }) catch {
        cli.warn(ctx, "memory exhausted", .{});
        return 2;
    };
    defer res.deinit();
    var buf: [16384]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    var status: u8 = 0;
    if (merge or letter != null) {
        if (diff3.hasConflicts(&res, o)) status = 1;
    }
    const r: anyerror!void = if (as_json)
        diff3.writeJson(gpa, w, &res, .{ ops[0], ops[1], ops[2] })
    else if (merge)
        diff3.writeMerge(w, &res, o)
    else if (letter != null)
        diff3.writeEd(w, &res, o)
    else
        diff3.writeNormal(w, &res, o);
    r catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        cli.writeErrorWarn(ctx);
        return 2;
    };
    w.flush() catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        cli.writeErrorWarn(ctx);
        return 2;
    };
    return status;
}
