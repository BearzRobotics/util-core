// SPDX-License-Identifier: GPL-2.0-or-later
//! sdiff: thin wrapper over `util_core.sdiff` (decision 0004).
//! References: GNU diffutils manual "Interactive Merging with sdiff" (3.12).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const getopt = @import("../getopt.zig");
const sdiff = @import("../lib/sdiff.zig");
const diff = @import("../lib/diff.zig");
const subprog = @import("../lib/subprog.zig");

const help_text = @embedFile("../help/sdiff.txt");

const O = struct {
    const strip_cr = 1100;
    const tabsize = 1101;
    const diff_program = 1102;
    const json = 1200;
};

fn usage(ctx: cli.Context, comptime fmt: []const u8, args: anytype) u8 {
    cli.warn(ctx, fmt, args);
    cli.warn(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 2;
}

/// sdiff runs diff, so these option errors are diff's.
fn diffUsage(ctx: cli.Context, comptime fmt: []const u8, args: anytype) u8 {
    cli.writeStderr(ctx, "diff: " ++ fmt, args);
    cli.writeStderr(ctx, "diff: Try 'diff --help' for more information.", .{});
    return 2;
}

fn parseCount(text: []const u8) ?usize {
    if (text.len == 0) return null;
    var v: usize = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v *| 10 +| (c - '0');
    }
    return v;
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
        if (list.items.len + n > diff.max_input) return error.FileTooBig;
        try list.appendSlice(gpa, b[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

const EditCtx = struct { ctx: *const cli.Context };

/// Run $EDITOR (default "ed") on a temporary file holding `text`.
fn runEditor(context: ?*anyopaque, gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    const ec: *EditCtx = @ptrCast(@alignCast(context.?));
    const ctx = ec.ctx.*;
    const editor = cli.getenv(ctx, "EDITOR") orelse "ed";
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const env: subprog.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    // As GNU: a signal that ends sdiff waits until the copy is gone. SIGINT
    // does not end it here, for Ctrl-C belongs to the editor.
    sys.catchTerminationSignals();
    defer {
        const caught = sys.takeCaughtSignal();
        sys.restoreCaughtSignals();
        if (caught) |sig| if (sig != sys.signo.INT) sys.deliverCaughtSignal(sig);
    }
    const path = subprog.privateCopy(env, arena.allocator(), cli.getenv(ctx, "TMPDIR"), "sdiff", text) catch |e| {
        cli.warn(ctx, "cannot create a temporary file: {s}", .{cli.errText(e)});
        return null;
    };
    defer Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
    const status = subprog.inherit(env, &.{ editor, path });
    if (status != 0) {
        var eb: [512]u8 = undefined;
        cli.warn(ctx, "{s}", .{subprog.describe(&eb, editor, status)});
        return null;
    }
    const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return null;
    defer f.close(ctx.io);
    var list: std.ArrayList(u8) = .empty;
    var b: [8192]u8 = undefined;
    while (true) {
        const n = cli.readChunk(ctx.io, f, &b) catch {
            list.deinit(gpa);
            return null;
        };
        if (n == 0) break;
        list.appendSlice(gpa, b[0..n]) catch return null;
    }
    return list.toOwnedSlice(gpa) catch null;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var o: sdiff.Options = .{};
    o.diff.style = .side_by_side;
    var output: ?[]const u8 = null;
    var as_json = false;
    var ignores: std.ArrayList([]const u8) = .empty;
    var dargs: std.ArrayList([]const u8) = .empty;
    var program: []const u8 = "diff";
    var parser = getopt.Parser.init(ctx, "o:iEZbWBI:aw:lstdHv", &.{
        .{ .name = "output", .arg = .required, .id = 'o' },
        .{ .name = "ignore-case", .id = 'i' },
        .{ .name = "ignore-tab-expansion", .id = 'E' },
        .{ .name = "ignore-trailing-space", .id = 'Z' },
        .{ .name = "ignore-space-change", .id = 'b' },
        .{ .name = "ignore-all-space", .id = 'W' },
        .{ .name = "ignore-blank-lines", .id = 'B' },
        .{ .name = "ignore-matching-lines", .arg = .required, .id = 'I' },
        .{ .name = "strip-trailing-cr", .id = O.strip_cr },
        .{ .name = "text", .id = 'a' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "left-column", .id = 'l' },
        .{ .name = "suppress-common-lines", .id = 's' },
        .{ .name = "expand-tabs", .id = 't' },
        .{ .name = "tabsize", .arg = .required, .id = O.tabsize },
        .{ .name = "minimal", .id = 'd' },
        .{ .name = "speed-large-files", .id = 'H' },
        .{ .name = "diff-program", .arg = .required, .id = O.diff_program },
        .{ .name = "json", .id = O.json },
    });
    parser.ext_min = 1100;
    parser.try_prefix = true;
    defer parser.deinit();
    var text = false;
    while (true) {
        const item = parser.next();
        switch (item) {
            .done => break,
            .bad => return 2,
            .opt => {},
        }
        const a = item.opt;
        switch (a.id) {
            'o' => output = a.arg.?,
            'i' => {
                o.diff.flags.ignore_case = true;
                dargs.append(arena, "-i") catch return 2;
            },
            'E' => {
                o.diff.flags.ignore_tab_expansion = true;
                dargs.append(arena, "-E") catch return 2;
            },
            'Z' => {
                o.diff.flags.ignore_trailing_space = true;
                dargs.append(arena, "-Z") catch return 2;
            },
            'b' => {
                dargs.append(arena, "-b") catch return 2;
                if (!o.diff.flags.ignore_all_space) o.diff.flags.ignore_space_change = true;
            },
            'W' => {
                dargs.append(arena, "-w") catch return 2;
                o.diff.flags.ignore_all_space = true;
                o.diff.flags.ignore_space_change = false;
            },
            'B' => {
                o.diff.ignore_blank_lines = true;
                dargs.append(arena, "-B") catch return 2;
            },
            'I' => {
                ignores.append(arena, a.arg.?) catch return 2;
                dargs.appendSlice(arena, &.{ "-I", a.arg.? }) catch return 2;
            },
            O.strip_cr => {
                o.diff.strip_trailing_cr = true;
                dargs.append(arena, "--strip-trailing-cr") catch return 2;
            },
            'a' => {
                text = true;
                dargs.append(arena, "-a") catch return 2;
            },
            'w' => {
                dargs.appendSlice(arena, &.{ "-W", a.arg.? }) catch return 2;
                const v = parseCount(a.arg.?) orelse 0;
                if (v == 0) return diffUsage(ctx, "invalid width '{s}'", .{a.arg.?});
                o.diff.width = v;
            },
            'l' => {
                o.diff.left_column = true;
                dargs.append(arena, "--left-column") catch return 2;
            },
            's' => o.diff.suppress_common_lines = true,
            't' => {
                o.diff.expand_tabs = true;
                dargs.append(arena, "-t") catch return 2;
            },
            O.tabsize => {
                dargs.appendSlice(arena, &.{ "--tabsize", a.arg.? }) catch return 2;
                const v = parseCount(a.arg.?) orelse 0;
                if (v == 0) return diffUsage(ctx, "invalid tabsize '{s}'", .{a.arg.?});
                o.diff.tab_size = v;
            },
            'd' => {
                o.diff.flags.minimal = true;
                dargs.append(arena, "-d") catch return 2;
            },
            'H' => {
                o.diff.flags.speed_large_files = true;
                dargs.append(arena, "-H") catch return 2;
            },
            O.diff_program => {
                program = a.arg.?;
            },
            O.json => as_json = true,
            'v', getopt.version_id => return if (cli.printVersion(ctx)) 0 else 2,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 2,
            else => unreachable,
        }
    }
    o.diff.ignore_matching = ignores.items;
    const ops = parser.operands.items;
    if (ops.len < 2) {
        const last: []const u8 = if (ctx.args.len > 0) ctx.args[ctx.args.len - 1] else ctx.name;
        return usage(ctx, "missing operand after '{s}'", .{last});
    }
    if (ops.len > 2) return usage(ctx, "extra operand '{s}'", .{ops[2]});
    if (as_json and (output != null or o.diff.expand_tabs or o.diff.left_column or o.diff.suppress_common_lines)) {
        return usage(ctx, "option --json is incompatible with text layout options and -o", .{});
    }
    if (std.mem.eql(u8, ops[0], "-") and std.mem.eql(u8, ops[1], "-")) return usage(ctx, "both files cannot be standard input", .{});
    const external = !std.mem.eql(u8, program, "diff");
    if (external and as_json) return usage(ctx, "option --json is incompatible with --diff-program", .{});
    const senv: subprog.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    if (external and output == null) {
        // GNU runs the program in place of sdiff: diff's options, then -y.
        var argv: std.ArrayList([]const u8) = .empty;
        argv.append(arena, program) catch return 2;
        argv.appendSlice(arena, dargs.items) catch return 2;
        if (o.diff.suppress_common_lines) argv.append(arena, "--suppress-common-lines") catch return 2;
        argv.appendSlice(arena, &.{ "-y", "--", ops[0], ops[1] }) catch return 2;
        const st = subprog.inherit(senv, argv.items);
        if (st == 126 or st == 127) {
            cli.warn(ctx, "{s}: {s}", .{ program, if (st == 127) "No such file or directory" else "Permission denied" });
            return 2;
        }
        return if (st >= subprog.abnormal) 2 else @intCast(st);
    }

    // With -o the files are read as given (a directory operand means the file
    // of the same name in it); the comparison itself names them as typed.
    var fnames: [2][]const u8 = .{ ops[0], ops[1] };
    if (output != null) {
        var is_dir: [2]bool = .{ false, false };
        for (0..2) |i| {
            if (std.mem.eql(u8, ops[i], "-")) {
                cli.warn(ctx, "cannot interactively merge standard input", .{});
                return 2;
            }
            if (Io.Dir.cwd().statFile(ctx.io, ops[i], .{})) |st| {
                is_dir[i] = st.kind == .directory;
            } else |_| {}
        }
        if (is_dir[0] and is_dir[1]) {
            cli.warn(ctx, "both files to be compared are directories", .{});
            return 2;
        }
        for (0..2) |i| {
            if (!is_dir[i]) continue;
            const base = std.fs.path.basename(ops[1 - i]);
            const dir = ops[i];
            const slash: []const u8 = if (dir.len > 0 and dir[dir.len - 1] != '/') "/" else "";
            fnames[i] = std.fmt.allocPrint(arena, "{s}{s}{s}", .{ dir, slash, base }) catch return 2;
        }
    }
    var data: [2][]u8 = .{ &.{}, &.{} };
    defer for (data) |m| gpa.free(m);
    for (0..2) |i| {
        data[i] = readAll(ctx, fnames[i]) catch |e| {
            if (output != null) cli.warn(ctx, "{s}: {s}", .{ fnames[i], cli.errText(e) }) else cli.writeStderr(ctx, "diff: {s}: {s}", .{ ops[i], cli.errText(e) });
            return 2;
        };
    }
    if (!text) for (data, 0..) |d, i| {
        _ = i;
        if (std.mem.indexOfScalar(u8, d[0..@min(d.len, 4096)], 0) != null) {
            const same = std.mem.eql(u8, data[0], data[1]);
            if (same) return 0;
            const msg = std.fmt.allocPrint(arena, "Binary files {s} and {s} differ\n", .{ ops[0], ops[1] }) catch return 2;
            _ = cli.writeStdout(ctx.io, msg);
            return 1;
        }
    };

    const env: sdiff.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    var buf: [16384]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;
    const fail = struct {
        fn f(c: cli.Context, so: *Io.File.Writer) u8 {
            cli.noteStdoutFailure(cli.errText(so.err orelse error.WriteFailed));
            cli.writeErrorWarn(c);
            return 2;
        }
    }.f;
    if (as_json) {
        const differs = sdiff.writeJson(gpa, w, .{ ops[0], ops[1] }, data[0], data[1], o) catch return fail(ctx, &stdout);
        w.flush() catch return fail(ctx, &stdout);
        return if (differs) 1 else 0;
    }
    if (output) |outpath| {
        const of = Io.Dir.cwd().createFile(ctx.io, outpath, .{}) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ outpath, cli.errText(e) });
            return 2;
        };
        defer of.close(ctx.io);
        var obuf: [8192]u8 = undefined;
        var ow = of.writerStreaming(ctx.io, &obuf);
        var ibuf: [4096]u8 = undefined;
        var in = Io.File.stdin().readerStreaming(ctx.io, &ibuf);
        var ec: EditCtx = .{ .ctx = &ctx };
        var rep: Rep = .{ .ctx = ctx };
        if (external) {
            var argv: std.ArrayList([]const u8) = .empty;
            argv.append(arena, program) catch return 2;
            argv.appendSlice(arena, dargs.items) catch return 2;
            argv.appendSlice(arena, &.{ "--sdiff-merge-assist", "--", ops[0], ops[1] }) catch return 2;
            const run = subprog.capture(senv, argv.items) catch return fail(ctx, &stdout);
            defer gpa.free(run.output);
            const st = sdiff.interactExternal(env, o, .{ fnames[0], fnames[1] }, data[0], data[1], run.output, w, &ow.interface, &in.interface, .{ .context = &ec, .func = runEditor }, .{ .context = &rep, .func = Rep.on }) catch return fail(ctx, &stdout);
            ow.interface.flush() catch {};
            w.flush() catch return fail(ctx, &stdout);
            if (st != 0) return st;
            if (run.status > 1) {
                var eb: [512]u8 = undefined;
                cli.warn(ctx, "{s}", .{subprog.describe(&eb, program, run.status)});
                return 2;
            }
            return @intCast(run.status);
        }
        const st = sdiff.interact(env, o, .{ fnames[0], fnames[1] }, data[0], data[1], w, &ow.interface, &in.interface, .{ .context = &ec, .func = runEditor }, .{ .context = &rep, .func = Rep.on }) catch return fail(ctx, &stdout);
        ow.interface.flush() catch {};
        w.flush() catch return fail(ctx, &stdout);
        return st;
    }
    const differs = sdiff.list(env, o, data[0], data[1], w) catch return fail(ctx, &stdout);
    w.flush() catch return fail(ctx, &stdout);
    return if (differs) 1 else 0;
}

const Rep = struct {
    ctx: cli.Context,
    fn on(context: ?*anyopaque, ev: sdiff.Event) void {
        const r: *Rep = @ptrCast(@alignCast(context.?));
        switch (ev) {
            .help => cli.writeStderrNoNl(r.ctx, "ed:\tEdit then use both versions, each decorated with a header.\n" ++
                "eb:\tEdit then use both versions.\n" ++
                "el or e1:\tEdit then use the left version.\n" ++
                "er or e2:\tEdit then use the right version.\n" ++
                "e:\tDiscard both versions then edit a new one.\n" ++
                "l or 1:\tUse the left version.\n" ++
                "r or 2:\tUse the right version.\n" ++
                "s:\tSilently include common lines.\n" ++
                "v:\tVerbosely include common lines.\n" ++
                "q:\tQuit.\n", .{}),
            .editor_failed => |t| cli.warn(r.ctx, "{s}", .{t}),
            .bad_protocol => |t| cli.warn(r.ctx, "{s}", .{t}),
        }
    }
};
