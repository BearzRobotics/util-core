// SPDX-License-Identifier: GPL-2.0-or-later
//! timeout — run a command with a time limit.
//! Reference: GNU coreutils manual "timeout invocation" (9.7).
//!
//! The child is started with std.process.spawn. The parent then waits on a
//! pidfd and a signalfd (src/sys.zig `Watcher`) with a poll timeout, so no
//! signal handler is ever installed: TERM, INT, HUP and QUIT sent to timeout
//! are read from the signalfd and forwarded to the command. Exit status: 124
//! on timeout (unless --preserve-status), 125 on timeout's own failure,
//! 126/127 when the command cannot be run, otherwise the command's status.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const help_text = @embedFile("../help/timeout.txt");

const longs = [_]getopt.Long{
    .{ .name = "foreground", .id = 'f' },
    .{ .name = "kill-after", .arg = .required, .id = 'k' },
    .{ .name = "preserve-status", .id = 'p' },
    .{ .name = "signal", .arg = .required, .id = 's' },
    .{ .name = "verbose", .id = 'v' },
};

/// Parse a DURATION: a non-negative decimal number with an optional suffix
/// s, m, h or d. Returns nanoseconds, saturating; null if invalid.
fn parseDuration(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var num = text;
    var mult: f64 = 1;
    switch (text[text.len - 1]) {
        's' => num = text[0 .. text.len - 1],
        'm' => {
            num = text[0 .. text.len - 1];
            mult = 60;
        },
        'h' => {
            num = text[0 .. text.len - 1];
            mult = 3600;
        },
        'd' => {
            num = text[0 .. text.len - 1];
            mult = 86400;
        },
        else => {},
    }
    if (num.len == 0 or num[0] == '-') return null;
    const v = std.fmt.parseFloat(f64, num) catch return null;
    if (std.math.isNan(v) or v < 0) return null;
    const ns = v * mult * 1e9;
    if (ns >= 1.8e19) return std.math.maxInt(u64);
    return @intFromFloat(ns);
}

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
            'k' => kill_after = parseDuration(o.arg.?) orelse {
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
    const duration = parseDuration(ops[0]) orelse {
        getopt.usageError(ctx, "invalid time interval {f}", .{cli.quoteC(ops[0])});
        return 125;
    };
    const command = ops[1..];

    if (!foreground) sys.becomeGroupLeader();
    var child = std.process.spawn(ctx.io, .{ .argv = command }) catch |e| {
        const text: []const u8 = switch (e) {
            error.FileNotFound => "No such file or directory",
            error.AccessDenied, error.PermissionDenied => "Permission denied",
            error.InvalidExe => "Exec format error",
            error.IsDir => "Is a directory",
            error.NotDir => "Not a directory",
            else => @errorName(e),
        };
        cli.warn(ctx, "failed to run command {f}: {s}", .{ cli.quoteC(command[0]), text });
        return if (e == error.FileNotFound) 127 else 126;
    };
    const pid: i32 = @intCast(child.id.?);
    // Signals that terminate or interrupt timeout are passed to the command.
    const watched = [_]u8{ 1, 2, 3, 15 };
    const w = sys.Watcher.init(pid, &watched) orelse {
        cli.warn(ctx, "unable to monitor the command", .{});
        child.kill(ctx.io);
        return 125;
    };
    defer w.deinit();

    var timed_out = false;
    var sent_kill = false;
    var self_signals: u32 = 0;
    var deadline: ?i96 = if (duration == 0) null else nowNs(ctx.io) + @as(i96, duration);

    var result: sys.WaitResult = .none;
    while (true) {
        var remaining: ?u64 = null;
        if (deadline) |d| {
            const left = d - nowNs(ctx.io);
            remaining = if (left > 0) @intCast(@min(left, std.math.maxInt(u64))) else 0;
        }
        switch (w.wait(remaining)) {
            .child_exited => {
                result = sys.waitPid(pid, true);
                break;
            },
            .timeout => {
                if (!sent_kill and !timed_out) {
                    timed_out = true;
                    sendTo(ctx, verbose, pid, signal, foreground, &self_signals, command[0]);
                    deadline = if (kill_after) |k| nowNs(ctx.io) + @as(i96, k) else null;
                    if (signal != 9) {
                        // A stopped command needs CONT to see the signal.
                        if (signal != 18) _ = sys.sendSignal(pid, 18);
                    }
                } else {
                    sent_kill = true;
                    sendTo(ctx, verbose, pid, 9, foreground, &self_signals, command[0]);
                    deadline = null;
                }
            },
            .signal => |s| {
                if (self_signals > 0 and s == lastSelf) {
                    self_signals -= 1;
                    continue;
                }
                sendTo(ctx, verbose, pid, s, foreground, &self_signals, command[0]);
                if (kill_after) |k| if (deadline == null) {
                    deadline = nowNs(ctx.io) + @as(i96, k);
                };
            },
            .failed => {
                cli.warn(ctx, "error waiting for the command", .{});
                return 125;
            },
        }
    }

    switch (result) {
        .exited => |code| {
            if (timed_out and !preserve) return 124;
            return code;
        },
        .signaled => |sig| {
            if (timed_out and !preserve) return 124;
            if (!timed_out) {
                // Die from the same signal, so the parent sees the real cause.
                _ = sys.setSignal(sig, .default);
                sys.unblockSignal(sig);
                _ = sys.sendSignal(@intCast(std.os.linux.getpid()), sig);
            }
            return 128 +| sig;
        },
        .none => return 125,
    }
}

var lastSelf: u8 = 0;

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

fn sendTo(ctx: cli.Context, verbose: bool, pid: i32, sig: u8, foreground: bool, self_signals: *u32, name: []const u8) void {
    if (verbose) {
        var nb: [16]u8 = undefined;
        const sn = sys.signalName(sig, &nb) orelse "?";
        cli.warn(ctx, "sending signal {s} to command {f}", .{ sn, cli.quoteC(name) });
    }
    _ = sys.sendSignal(pid, sig);
    if (!foreground) {
        // The whole group includes timeout itself; its copy will arrive on
        // the signalfd and must not be forwarded again.
        _ = sys.sendSignal(0, sig);
        for ([_]u8{ 1, 2, 3, 15 }) |ws| if (ws == sig) {
            lastSelf = sig;
            self_signals.* += 1;
        };
    }
}
