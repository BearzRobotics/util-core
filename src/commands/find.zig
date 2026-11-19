// SPDX-License-Identifier: GPL-2.0-or-later
//! find: thin wrapper over `util_core.find` (decision 0004). Handles the
//! leading options (-H -L -P -D -O), --help/--version, the split between
//! start points and the expression, answers the -ok questions on the
//! terminal and words the diagnostics. The expression parser, the walk and the
//! actions are in src/lib/find.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const find = @import("../lib/find.zig");
const LX = std.os.linux;
const Io = std.Io;

/// find has always used the general-purpose allocator without leak checking.
const gpa = std.heap.smp_allocator;

const help_text = @embedFile("../help/find.txt");

const Ui = struct {
    ctx: cli.Context,
    utf8: bool,

    fn q(u: *const Ui, text: []const u8) []const u8 {
        return find.quoteMsg(gpa, text, u.utf8) catch text;
    }
};

fn report(context: ?*anyopaque, ev: find.Event) void {
    const u: *const Ui = @ptrCast(@alignCast(context.?));
    const ctx = u.ctx;
    switch (ev) {
        .path_error => |e| cli.warn(ctx, "{s}: {s}", .{ u.q(e.path), e.text }),
        .loop => |e| cli.warn(ctx, "File system loop detected; {s} is part of the same file system loop as {s}.", .{ u.q(e.path), u.q(e.ancestor) }),
        .delete_failed => |e| cli.warn(ctx, "cannot delete {s}: {s}", .{ u.q(e.path), e.text }),
        .exec_failed => |e| cli.warn(ctx, "{s}: {s}", .{ u.q(e.program), e.text }),
        .no_security_context => |p| cli.warn(ctx, "getfilecon failed: {s}: No data available", .{u.q(p)}),
        .warning => |t| cli.warn(ctx, "{s}", .{t}),
    }
}

/// -ok: print the question on stderr, read one line from standard input.
fn confirm(context: ?*anyopaque, prompt: []const u8) bool {
    _ = context;
    _ = sys.writeAllFd(2, prompt);
    var line: [256]u8 = undefined;
    var k: usize = 0;
    var err: LX.E = .SUCCESS;
    while (k < line.len) {
        var b: [1]u8 = undefined;
        const got = sys.readFd(0, &b, &err) orelse break;
        if (got == 0) break;
        if (b[0] == '\n') break;
        line[k] = b[0];
        k += 1;
    }
    return !(k == 0 or (line[0] != 'y' and line[0] != 'Y'));
}

fn debugFlags(u: *const Ui, list: []const u8) void {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |f| {
        const known = [_][]const u8{ "exec", "opt", "rates", "search", "stat", "time", "tree", "all" };
        var ok = false;
        for (known) |k| {
            if (std.mem.eql(u8, k, f)) ok = true;
        }
        if (!ok) cli.warn(u.ctx, "Ignoring unrecognised debug flag {s}", .{u.q(f)});
    }
}

fn looksLikeExpr(a: []const u8) bool {
    if (a.len == 0) return false;
    if (a[0] == '-' and a.len > 1) return true;
    return std.mem.eql(u8, a, "(") or std.mem.eql(u8, a, "!");
}

pub fn main(ctx: cli.Context) u8 {
    const env: find.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    const ui: Ui = .{ .ctx = ctx, .utf8 = find.localeIsUtf8(env) };
    var follow: find.Follow = .physical;
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    for (ctx.args) |a| args_list.append(gpa, a) catch return oom(ctx);
    const args = args_list.items;
    var i: usize = 0;
    // leading options
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-H")) {
            follow = .command_line;
        } else if (std.mem.eql(u8, a, "-L")) {
            follow = .logical;
        } else if (std.mem.eql(u8, a, "-P")) {
            follow = .physical;
        } else if (std.mem.eql(u8, a, "-D")) {
            i += 1;
            if (i >= args.len) {
                cli.warn(ctx, "Missing argument after the -D option.\nTry '{s} --help' for more information.", .{ctx.name});
                return 1;
            }
            if (std.mem.eql(u8, args[i], "help")) {
                const t =
                    \\Valid arguments for -D:
                    \\exec       Show diagnostic information relating to -exec, -execdir, -ok and -okdir
                    \\opt        Show diagnostic information relating to optimisation
                    \\rates      Indicate how often each predicate succeeded
                    \\search     Navigate the directory tree verbosely
                    \\stat       Trace calls to stat(2) and lstat(2)
                    \\time       Show diagnostic information relating to time-of-day and timestamp comparisons
                    \\tree       Display the expression tree
                    \\all        Set all of the debug flags (but help)
                    \\help       Explain the various -D options
                    \\
                ;
                return if (cli.writeStdout(ctx.io, t)) 0 else 1;
            }
            debugFlags(&ui, args[i]);
        } else if (std.mem.startsWith(u8, a, "-D")) {
            debugFlags(&ui, a[2..]);
        } else if (std.mem.startsWith(u8, a, "-O")) {
            const rest = a[2..];
            if (rest.len == 0) {
                cli.warn(ctx, "The -O option must be immediately followed by a decimal integer", .{});
                return 1;
            }
            if (!std.ascii.isDigit(rest[0])) {
                cli.warn(ctx, "Please specify a decimal number immediately after -O", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else break;
        i += 1;
    }
    if (args.len >= 1) {
        if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-help")) {
            const text = std.mem.replaceOwned(u8, gpa, help_text, "@NAME@", ctx.name) catch return 1;
            return if (cli.writeStdout(ctx.io, text)) 0 else 1;
        }
        if (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "-version")) {
            const v =
                \\find (GNU findutils) 4.10.0
                \\Copyright (C) 2024 Free Software Foundation, Inc.
                \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
                \\This is free software: you are free to change and redistribute it.
                \\There is NO WARRANTY, to the extent permitted by law.
                \\
                \\Written by Eric B. Decker, James Youngman, and Kevin Dalley.
                \\Features enabled: D_TYPE O_NOFOLLOW(enabled) LEAF_OPTIMISATION FTS(FTS_CWDFD) CBO(level=1) 
                \\
            ;
            return if (cli.writeStdout(ctx.io, v)) 0 else 1;
        }
    }
    // start points
    var starts: std.ArrayList([]const u8) = .empty;
    defer starts.deinit(gpa);
    while (i < args.len and !looksLikeExpr(args[i])) : (i += 1) {
        starts.append(gpa, args[i]) catch return oom(ctx);
    }

    const observer: find.Observer = .{ .context = @constCast(&ui), .func = report };
    var diag: find.Diagnostic = .{};
    defer diag.deinit(gpa);
    var expr = find.compile(env, args[i..], .{
        .follow = follow,
        .no_starts = starts.items.len == 0,
        .utf8 = ui.utf8,
    }, observer, &diag) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.Invalid => {
            for (diag.lines) |l| cli.warn(ctx, "{s}", .{l});
            return 1;
        },
    };
    defer expr.deinit();

    var stdout = Io.File.stdout().writerStreaming(ctx.io, &.{});
    var stderr = Io.File.stderr().writerStreaming(ctx.io, &.{});
    const result = expr.run(starts.items, &stdout.interface, .{ .stderr = &stderr.interface, .confirm = .{ .func = confirm } }, observer) catch return oom(ctx);
    if (result.write_failed) cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
    return result.exit_status;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}
