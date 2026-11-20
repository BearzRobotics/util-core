// SPDX-License-Identifier: GPL-2.0-or-later
//! nohup — run a program immune to hangups.
//! Reference: GNU coreutils manual "nohup invocation" (9.7); POSIX.1-2024 nohup.
//!
//! The decisions (which streams to redirect, which notices to print) are in
//! src/lib/nohup.zig; the descriptor and signal changes and the exec, which are
//! process-wide, stay here.

const std = @import("std");
const cli = @import("../cli.zig");
const exec = @import("../exec.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const nohup = @import("../lib/nohup.zig");
const Io = std.Io;

const help_text = @embedFile("../help/nohup.txt");

pub fn main(ctx: cli.Context) u8 {
    var parser = getopt.Parser.init(ctx, "+", &.{});
    defer parser.deinit();
    while (true) switch (parser.next()) {
        .done => break,
        .bad => return 125,
        .opt => |o| switch (o.id) {
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 125,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 125,
            else => unreachable,
        },
    };
    const args = parser.operands.items;
    if (args.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 125;
    }

    if (!sys.has_jobcontrol) {
        // No hangup signal and no descriptor redirection to make the command
        // immune: say so instead of pretending (GNU's exit status 125).
        cli.warn(ctx, "not supported on this platform", .{});
        return 125;
    }

    const stdin_tty = Io.File.stdin().isTty(ctx.io) catch false;
    const stdout_tty = Io.File.stdout().isTty(ctx.io) catch false;
    const stderr_tty = Io.File.stderr().isTty(ctx.io) catch false;
    const plan = nohup.plan(.{
        .stdin_tty = stdin_tty,
        .stdout_tty = stdout_tty,
        .stderr_tty = stderr_tty,
        .stdout_closed = !stdout_tty and !sys.fdOpen(1),
    });

    if (plan.unusable_stdin) {
        // Opened write-only on purpose: reads then fail instead of hanging.
        const null_file = Io.Dir.cwd().openFile(ctx.io, "/dev/null", .{ .mode = .write_only }) catch {
            cli.warn(ctx, "failed to render standard input unusable", .{});
            return 125;
        };
        _ = sys.dup2(null_file.handle, 0);
        if (null_file.handle != Io.File.stdin().handle) null_file.close(ctx.io);
        if (plan.notice_ignoring_input) cli.warn(ctx, "ignoring input", .{});
    }

    if (plan.redirect_stdout) {
        var buf: [4096]u8 = undefined;
        var shown: []const u8 = nohup.output_name;
        const file = sys.openAppendMode(nohup.output_name, 0o600) catch |e1| blk: {
            const p = nohup.homeOutputPath(cli.getenv(ctx, "HOME"), &buf);
            if (p) |path| {
                if (sys.openAppendMode(path, 0o600)) |f| {
                    shown = path;
                    break :blk f;
                } else |e2| {
                    cli.warn(ctx, "failed to open {f}: {s}", .{ cli.quoteA(nohup.output_name), cli.errText(e1) });
                    cli.warn(ctx, "failed to open {f}: {s}", .{ cli.quoteA(path), cli.errText(e2) });
                    return 125;
                }
            }
            cli.warn(ctx, "failed to open {f}: {s}", .{ cli.quoteA(nohup.output_name), cli.errText(e1) });
            return 125;
        };
        _ = sys.dup2(file.handle, 1);
        if (file.handle != Io.File.stdout().handle) file.close(ctx.io);
        switch (plan.stdout_notice) {
            .ignoring_input_and_appending_output => cli.warn(ctx, "ignoring input and appending output to {f}", .{cli.quoteA(shown)}),
            .appending_output => cli.warn(ctx, "appending output to {f}", .{cli.quoteA(shown)}),
        }
    }
    if (plan.redirect_stderr) {
        if (plan.stderr_notice) |n| switch (n) {
            .ignoring_input_and_redirecting_stderr => cli.warn(ctx, "ignoring input and redirecting stderr to stdout", .{}),
            .redirecting_stderr => cli.warn(ctx, "redirecting stderr to stdout", .{}),
        };
        _ = sys.dup2(Io.File.stdout().handle, 2);
    }

    _ = sys.setSignal(sys.signo.HUP, .ignore);
    sys.restoreSigpipe();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    for (args) |a| argv.append(ctx.gpa, a) catch return 125;
    return exec.execStyled(ctx, args[0], argv.items, null, .run);
}
