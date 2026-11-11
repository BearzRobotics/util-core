// SPDX-License-Identifier: GPL-2.0-or-later
//! nohup — run a program immune to hangups.
//! Reference: GNU coreutils manual "nohup invocation" (9.7); POSIX.1-2024 nohup.
//!
//! If standard input is a terminal it is replaced by an unreadable descriptor;
//! if standard output is a terminal it is appended to ./nohup.out (or
//! $HOME/nohup.out); a terminal standard error is sent to standard output.

const std = @import("std");
const cli = @import("../cli.zig");
const exec = @import("../exec.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
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

    const stdin_tty = Io.File.stdin().isTty(ctx.io) catch false;
    const stdout_tty = Io.File.stdout().isTty(ctx.io) catch false;
    const stderr_tty = Io.File.stderr().isTty(ctx.io) catch false;
    const stdout_closed = !stdout_tty and !sys.fdOpen(1);

    if (stdin_tty) {
        // Opened write-only on purpose: reads then fail instead of hanging.
        const null_file = Io.Dir.cwd().openFile(ctx.io, "/dev/null", .{ .mode = .write_only }) catch {
            cli.warn(ctx, "failed to render standard input unusable", .{});
            return 125;
        };
        _ = sys.dup2(null_file.handle, 0);
        if (null_file.handle != 0) null_file.close(ctx.io);
        if (!stdout_tty and !stderr_tty) cli.warn(ctx, "ignoring input", .{});
    }

    if (stdout_tty or (stdout_closed and stderr_tty)) {
        var buf: [4096]u8 = undefined;
        var shown: []const u8 = "nohup.out";
        const file = sys.openAppendMode("nohup.out", 0o600) catch |e1| blk: {
            const home = cli.getenv(ctx, "HOME");
            const p = if (home) |h| std.fmt.bufPrint(&buf, "{s}/nohup.out", .{h}) catch null else null;
            if (p) |path| {
                if (sys.openAppendMode(path, 0o600)) |f| {
                    shown = path;
                    break :blk f;
                } else |e2| {
                    cli.warn(ctx, "failed to open {f}: {s}", .{ cli.quoteA("nohup.out"), cli.errText(e1) });
                    cli.warn(ctx, "failed to open {f}: {s}", .{ cli.quoteA(path), cli.errText(e2) });
                    return 125;
                }
            }
            cli.warn(ctx, "failed to open {f}: {s}", .{ cli.quoteA("nohup.out"), cli.errText(e1) });
            return 125;
        };
        _ = sys.dup2(file.handle, 1);
        if (file.handle != 1) file.close(ctx.io);
        if (stdin_tty)
            cli.warn(ctx, "ignoring input and appending output to {f}", .{cli.quoteA(shown)})
        else
            cli.warn(ctx, "appending output to {f}", .{cli.quoteA(shown)});
    }
    if (stderr_tty) {
        if (!stdout_tty) {
            if (stdin_tty)
                cli.warn(ctx, "ignoring input and redirecting stderr to stdout", .{})
            else
                cli.warn(ctx, "redirecting stderr to stdout", .{});
        }
        _ = sys.dup2(1, 2);
    }

    _ = sys.setSignal(1, .ignore);
    sys.restoreSigpipe();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    for (args) |a| argv.append(ctx.gpa, a) catch return 125;
    return exec.execStyled(ctx, args[0], argv.items, null, .run);
}
