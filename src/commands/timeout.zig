// SPDX-License-Identifier: GPL-2.0-or-later
//! timeout — run a command with a time limit.
//! Reference: GNU coreutils manual "timeout invocation" (9.7).
//!
//! The supervision loop is in src/lib/timeout.zig. This wrapper does the
//! process-wide parts: becoming a process-group leader, ignoring the terminal
//! stop signals, blocking the watched
//! signals (creating the `sys.Watcher`) and re-raising the command's fatal
//! signal on itself.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const timeout = @import("../lib/timeout.zig");

const help_text = @embedFile("../help/timeout.txt");

const longs = [_]getopt.Long{
    .{ .name = "foreground", .id = 'f' },
    .{ .name = "kill-after", .arg = .required, .id = 'k' },
    .{ .name = "preserve-status", .id = 'p' },
    .{ .name = "signal", .arg = .required, .id = 's' },
    .{ .name = "verbose", .id = 'v' },
};

pub fn main(ctx: cli.Context) u8 {
    var foreground = false;
    var preserve = false;
    var verbose = false;
    var kill_after: ?u64 = null;
    var signal: u8 = 15;
    var p = getopt.Parser.init(ctx, "+fk:ps:v", &longs);
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 125,
        .opt => |o| switch (o.id) {
            'f' => foreground = true,
            'p' => preserve = true,
            'v' => verbose = true,
            'k' => kill_after = timeout.parseDuration(o.arg.?) orelse {
                getopt.usageError(ctx, "invalid time interval {f}", .{cli.quoteC(o.arg.?)});
                return 125;
            },
            's' => signal = sys.signalNumber(o.arg.?) orelse {
                getopt.usageError(ctx, "{f}: invalid signal", .{cli.quoteC(o.arg.?)});
                return 125;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 125,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 125,
            else => unreachable,
        },
    };
    const ops = p.operands.items;
    if (ops.len < 2) {
        // GNU prints no message here, only the hint.
        cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
        return 125;
    }
    const duration = timeout.parseDuration(ops[0]) orelse {
        getopt.usageError(ctx, "invalid time interval {f}", .{cli.quoteC(ops[0])});
        return 125;
    };
    const command = ops[1..];

    if (!foreground) sys.becomeGroupLeader();
    const env: timeout.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    // A command that reads the terminal from our group stops the whole group;
    // we must keep running to enforce the limit. It starts with the default
    // actions, as under GNU.
    //
    // Were SIGCHLD ignored, the kernel would reap the command itself and its
    // exit status would be lost.
    if (sys.signalNumber("CHLD")) |chld| _ = sys.setSignal(chld, .default);
    // Until they are watched for, a signal must not end us and leave the
    // command running without a limit.
    const watched: timeout.Watched = .init(signal);
    sys.holdSignals(watched.list());
    sys.catchTerminalStops();
    const spawned = timeout.spawn(env, command);
    sys.ignoreTerminalStops();
    var child = spawned catch |e| {
        const text: []const u8 = switch (e) {
            error.FileNotFound => "No such file or directory",
            error.AccessDenied, error.PermissionDenied => "Permission denied",
            error.InvalidExe => "Exec format error",
            error.IsDir => "Is a directory",
            error.NotDir => "Not a directory",
            else => @errorName(e),
        };
        cli.warn(ctx, "failed to run command {f}: {s}", .{ cli.quoteC(command[0]), text });
        return timeout.spawnFailureStatus(e);
    };
    const pid = child.id.?;
    // Blocks the watched signals; they are read from the signalfd instead.
    const w = sys.Watcher.init(pid, watched.list()) orelse {
        cli.warn(ctx, "unable to monitor the command", .{});
        child.kill(ctx.io);
        return 125;
    };
    defer w.deinit();
    // One that came before they were blocked is passed on like the others.
    if (sys.takeCaughtSignal()) |sig| sys.raiseHeld(sig);

    var rep: Report = .{ .ctx = &ctx, .name = command[0] };
    const outcome = timeout.supervise(env, .{
        .foreground = foreground,
        .preserve_status = preserve,
        .verbose = verbose,
        .kill_after = kill_after,
        .signal = signal,
        .duration = duration,
    }, pid, w, .{ .context = &rep, .func = report });
    switch (outcome) {
        .wait_failed => {
            cli.warn(ctx, "error waiting for the command", .{});
            return 125;
        },
        .finished => |f| {
            if (f.reraise) |sig| {
                // Die from the same signal, so the parent sees the real cause.
                _ = sys.setSignal(sig, .default);
                sys.unblockSignal(sig);
                _ = sys.raiseSelf(sig);
            }
            return f.status;
        },
    }
}

const Report = struct { ctx: *const cli.Context, name: []const u8 };

fn report(context: ?*anyopaque, ev: timeout.Event) void {
    const r: *Report = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .sending_signal => |sig| {
            var nb: [16]u8 = undefined;
            const sn = sys.signalName(sig, &nb) orelse "?";
            cli.warn(r.ctx.*, "sending signal {s} to command {f}", .{ sn, cli.quoteC(r.name) });
        },
    }
}
