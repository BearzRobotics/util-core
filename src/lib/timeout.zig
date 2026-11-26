// SPDX-License-Identifier: GPL-2.0-or-later
//! timeout library: run a command with a time limit.
//! Reference: GNU coreutils manual "timeout invocation" (9.7).
//!
//! The child is started with std.process.spawn. The supervisor then waits on
//! a pidfd and a signalfd (`sys.Watcher`) with a poll timeout, so no signal
//! handler is ever installed: TERM, INT, HUP and QUIT sent to timeout are read
//! from the signalfd and forwarded to the command. Exit status: 124 on timeout
//! (unless --preserve-status), 125 on timeout's own failure, 126/127 when the
//! command cannot be run, otherwise the command's status.
//!
//! Decision 0004: blocking signals (creating the `sys.Watcher`), becoming a
//! process-group leader, ignoring SIGTTIN and SIGTTOU (a caller that may share
//! a terminal with the command needs `sys.catchTerminalStops` around `spawn`),
//! and re-raising the command's fatal signal on the
//! host are process-wide actions; the caller does them (see
//! `src/commands/timeout.zig`) and hands the ready `Watcher` to `supervise`.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

/// Signals that terminate or interrupt timeout and are passed to the
/// command; the caller creates the Watcher for these.
pub const watched_signals = [_]u8{ sys.signo.HUP, sys.signo.INT, sys.signo.QUIT, sys.signo.TERM };

pub const Options = struct {
    /// --foreground: do not signal the whole process group.
    foreground: bool = false,
    /// --preserve-status.
    preserve_status: bool = false,
    /// --verbose: report each signal sent.
    verbose: bool = false,
    /// --kill-after in nanoseconds.
    kill_after: ?u64 = null,
    /// Signal sent on timeout.
    signal: u8 = sys.signo.TERM,
    /// Time limit in nanoseconds; 0 means none.
    duration: u64,
};

pub const Event = union(enum) {
    /// A signal is being sent to the command (only with `verbose`).
    sending_signal: u8,
};
pub const Observer = common.Observer(Event);

/// Parse a DURATION: a non-negative decimal number with an optional suffix
/// s, m, h or d. Returns nanoseconds, saturating; null if invalid.
pub fn parseDuration(text: []const u8) ?u64 {
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

/// Start the command. The caller makes itself a group leader first unless
/// --foreground.
pub fn spawn(env: Env, command: []const []const u8) std.process.SpawnError!std.process.Child {
    return std.process.spawn(env.io, .{ .argv = command });
}

/// Exit status when the command cannot be started.
pub fn spawnFailureStatus(e: anyerror) u8 {
    return if (e == error.FileNotFound) 127 else 126;
}

pub const Outcome = union(enum) {
    /// Waiting failed; the caller reports it and exits with 125.
    wait_failed,
    finished: Finished,
};

pub const Finished = struct {
    /// Exit status of timeout.
    status: u8,
    /// The command died from this signal and timeout did not cause it: the
    /// caller should die from it too, so its parent sees the real cause.
    reraise: ?u8 = null,
};

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

const Supervisor = struct {
    obs: Observer,
    verbose: bool,
    foreground: bool,
    /// Copies of our own signals still to arrive on the signalfd.
    self_signals: u32 = 0,
    last_self: u8 = 0,

    fn sendTo(s: *Supervisor, pid: sys.Pid, sig: u8) void {
        if (s.verbose) s.obs.emit(.{ .sending_signal = sig });
        _ = sys.sendSignal(pid, sig);
        if (!s.foreground) {
            // The whole group includes timeout itself; its copy will arrive on
            // the signalfd and must not be forwarded again.
            _ = sys.signalOwnGroup(sig);
            for (watched_signals) |ws| if (ws == sig) {
                s.last_self = sig;
                s.self_signals += 1;
            };
        }
        // A stopped process (the command, or one of its children stopped for
        // reading the terminal) must be continued to see the signal.
        if (sig != sys.signo.KILL and sig != sys.signo.CONT) {
            _ = sys.sendSignal(pid, sys.signo.CONT);
            if (!s.foreground) _ = sys.signalOwnGroup(sys.signo.CONT);
        }
    }
};

/// Wait for the started command (`pid`), enforcing the time limit and
/// forwarding signals read from `w`. Does not close `w`.
pub fn supervise(env: Env, opts: Options, pid: sys.Pid, w: sys.Watcher, obs: Observer) Outcome {
    var sup: Supervisor = .{ .obs = obs, .verbose = opts.verbose, .foreground = opts.foreground };
    var timed_out = false;
    var sent_kill = false;
    var deadline: ?i96 = if (opts.duration == 0) null else nowNs(env.io) + @as(i96, opts.duration);

    var result: sys.WaitResult = .none;
    while (true) {
        var remaining: ?u64 = null;
        if (deadline) |d| {
            const left = d - nowNs(env.io);
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
                    sup.sendTo(pid, opts.signal);
                    deadline = if (opts.kill_after) |k| nowNs(env.io) + @as(i96, k) else null;
                } else {
                    sent_kill = true;
                    sup.sendTo(pid, sys.signo.KILL);
                    deadline = null;
                }
            },
            .signal => |s| {
                if (sup.self_signals > 0 and s == sup.last_self) {
                    sup.self_signals -= 1;
                    continue;
                }
                sup.sendTo(pid, s);
                if (opts.kill_after) |k| if (deadline == null) {
                    deadline = nowNs(env.io) + @as(i96, k);
                };
            },
            .failed => return .wait_failed,
        }
    }

    switch (result) {
        .exited => |code| {
            if (timed_out and !opts.preserve_status) return .{ .finished = .{ .status = 124 } };
            return .{ .finished = .{ .status = code } };
        },
        .signaled => |sig| {
            if (timed_out and !opts.preserve_status) return .{ .finished = .{ .status = 124 } };
            return .{ .finished = .{
                .status = 128 +| sig,
                .reraise = if (!timed_out) sig else null,
            } };
        },
        .none => return .{ .finished = .{ .status = 125 } },
    }
}

test "parseDuration" {
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), parseDuration("1"));
    try std.testing.expectEqual(@as(?u64, 120_000_000_000), parseDuration("2m"));
    try std.testing.expectEqual(@as(?u64, 500_000_000), parseDuration("0.5s"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("-1"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration(""));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("s"));
}
