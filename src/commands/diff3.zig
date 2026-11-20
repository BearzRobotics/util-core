// SPDX-License-Identifier: GPL-2.0-or-later
//! diff3: thin wrapper over `util_core.diff3` (decision 0004).
//! References: GNU diffutils manual "Comparing Three Files" (3.12).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const diff3 = @import("../lib/diff3.zig");
const diffcore = @import("../lib/diffcore.zig");
const subprog = @import("../lib/subprog.zig");

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

/// An external `--diff-program` comparison: the program is run as GNU diff3
/// runs it and its normal-format output is read back as edits.
const Ext = struct {
    ctx: cli.Context,
    program: []const u8,
    text: bool,
    strip_cr: bool,
    common_middle: bool,
    /// Paths handed to the program for MYFILE, OLDFILE, YOURFILE.
    paths: [3][]const u8,
    /// Set when the comparison failed; the message has been printed.
    failed: bool = false,

    fn run(context: ?*anyopaque, gpa: std.mem.Allocator, pair: u1) anyerror![]diffcore.Edit {
        const x: *Ext = @ptrCast(@alignCast(context.?));
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, x.program);
        if (x.text) try argv.append(gpa, "-a");
        if (x.strip_cr) try argv.append(gpa, "--strip-trailing-cr");
        const common: usize = if (x.common_middle) 1 else 2;
        const other: usize = if (x.common_middle) (if (pair == 0) 0 else 2) else pair;
        try argv.appendSlice(gpa, &.{ "--horizon-lines=100", "---no-directory", "--", x.paths[other], x.paths[common] });
        const env: subprog.Env = .{ .io = x.ctx.io, .gpa = gpa, .environ = x.ctx.environ };
        const res = try subprog.capture(env, argv.items);
        defer gpa.free(res.output);
        if (res.output.len > 0 and res.output[res.output.len - 1] != '\n') {
            cli.warn(x.ctx, "invalid diff format; incomplete last line", .{});
            x.failed = true;
            return error.SubsidiaryFailed;
        }
        if (res.status >= 2) {
            var b: [512]u8 = undefined;
            cli.warn(x.ctx, "{s}", .{subprog.describe(&b, x.program, res.status)});
            x.failed = true;
            return error.SubsidiaryFailed;
        }
        var bad: []const u8 = "";
        return diff3.parseNormalDiff(gpa, res.output, &bad) catch |e| {
            x.failed = true;
            switch (e) {
                error.OutOfMemory => return e,
                error.BadControl => cli.warn(x.ctx, "diff failed: {s}", .{bad}),
                error.BadSeparator => cli.warn(x.ctx, "invalid diff format; invalid change separator", .{}),
                error.BadLeadingChars => cli.warn(x.ctx, "invalid diff format; incorrect leading line chars", .{}),
                error.IncompleteLastLine => cli.warn(x.ctx, "invalid diff format; incomplete last line", .{}),
            }
            return error.SubsidiaryFailed;
        };
    }
};

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
    var program: []const u8 = "diff";
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
                program = a.arg.?;
            },
            O.strip_cr => strip_cr = true,
            O.json => as_json = true,
            'v', getopt.version_id => return if (cli.printVersion(ctx)) 0 else 2,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 2,
            else => unreachable,
        }
    }
    const brackets = merge or (letter != null and (letter.? == 'E' or letter.? == 'A'));
    if (incompatible or (merge and write_quit) or (nlabels != 0 and !brackets)) return usage(ctx, "incompatible options", .{});
    const ops = parser.operands.items;
    if (ops.len < 3) {
        const last: []const u8 = if (ctx.args.len > 0) ctx.args[ctx.args.len - 1] else ctx.name;
        return usage(ctx, "missing operand after '{s}'", .{last});
    }
    if (ops.len > 3) return usage(ctx, "extra operand '{s}'", .{ops[3]});
    if (as_json and (letter != null or merge or write_quit or o.initial_tab)) return usage(ctx, "option --json is incompatible with output style options", .{});
    for (0..3) |i| o.labels[i] = if (i < nlabels) labels[i] else ops[i];
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
            cli.writeStderr(ctx, "diff: {s}: {s}", .{ ops[i], cli.errText(e) });
            cli.warn(ctx, "subsidiary program 'diff' failed (exit status 2)", .{});
            return 2;
        };
    }
    const external = !std.mem.eql(u8, program, "diff");
    if (external and as_json) return usage(ctx, "option --json is incompatible with --diff-program", .{});
    if (!text and !external) {
        // GNU diff3 compares the second and third files first, then the first and third;
        // the first of those that is binary and differs is named.
        const pairs = if (letter != null or merge) [2][2]usize{ .{ 2, 1 }, .{ 0, 1 } } else [2][2]usize{ .{ 1, 2 }, .{ 0, 2 } };
        for (pairs) |pr| {
            const bin = for (pr) |i| {
                if (std.mem.indexOfScalar(u8, data[i][0..@min(data[i].len, 4096)], 0) != null) break true;
            } else false;
            if (bin and !std.mem.eql(u8, data[pr[0]], data[pr[1]])) {
                cli.warn(ctx, "diff failed: Binary files {s} and {s} differ", .{ ops[pr[0]], ops[pr[1]] });
                return 2;
            }
        }
    }

    var ext: Ext = .{ .ctx = ctx, .program = program, .text = text, .strip_cr = strip_cr, .common_middle = letter != null or merge, .paths = .{ ops[0], ops[1], ops[2] } };
    var tmp_paths: [3]?[]u8 = .{ null, null, null };
    defer for (tmp_paths) |tp| if (tp) |pth| {
        Io.Dir.cwd().deleteFile(ctx.io, pth) catch {};
        gpa.free(pth);
    };
    if (external) {
        // Standard input was consumed above: hand the program a copy.
        for (0..3) |i| {
            if (!std.mem.eql(u8, ops[i], "-")) continue;
            const dir = cli.getenv(ctx, "TMPDIR") orelse "/tmp";
            const stamp: i96 = Io.Timestamp.now(ctx.io, .real).nanoseconds;
            const pth = std.fmt.allocPrint(gpa, "{s}/diff3.{x}", .{ dir, @as(u64, @truncate(@as(u96, @bitCast(stamp)))) }) catch return 2;
            tmp_paths[i] = pth;
            const f = Io.Dir.cwd().createFile(ctx.io, pth, .{ .exclusive = true }) catch |e| {
                cli.warn(ctx, "{s}: {s}", .{ pth, cli.errText(e) });
                return 2;
            };
            defer f.close(ctx.io);
            f.writeStreamingAll(ctx.io, data[i]) catch return 2;
            ext.paths[i] = pth;
        }
    }
    var res = diff3.merge3(gpa, data[0], data[1], data[2], .{
        .strip_trailing_cr = strip_cr,
        .common_middle = letter != null or merge,
        .external = if (external) .{ .context = &ext, .func = Ext.run } else null,
    }) catch |e| {
        if (ext.failed) return 2;
        if (e == error.InvalidEdits) {
            cli.warn(ctx, "diff failed: the comparison program's output does not match the files", .{});
            return 2;
        }
        cli.warn(ctx, "memory exhausted", .{});
        return 2;
    };
    defer res.deinit();
    var buf: [16384]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    var status: u8 = 0;
    if (letter != null and !merge) {
        var wn: u8 = 0;
        while (wn < res.missing_newline) : (wn += 1) cli.warn(ctx, "No newline at end of file", .{});
    }
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
