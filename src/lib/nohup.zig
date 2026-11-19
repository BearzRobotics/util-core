// SPDX-License-Identifier: GPL-2.0-or-later
//! nohup library: what to do about the standard streams of a command that
//! must survive a hangup.
//! Reference: GNU coreutils manual "nohup invocation" (9.7); POSIX.1-2024 nohup.
//!
//! If standard input is a terminal it is replaced by an unreadable descriptor;
//! if standard output is a terminal it is appended to ./nohup.out (or
//! $HOME/nohup.out); a terminal standard error is sent to standard output.
//!
//! Redirecting descriptors, ignoring SIGHUP and replacing the process are
//! process-wide actions (decision 0004) and stay in the wrapper
//! (`src/commands/nohup.zig`); this module makes the decisions.

const std = @import("std");

/// What is known about the three standard streams.
pub const Streams = struct {
    stdin_tty: bool,
    stdout_tty: bool,
    stderr_tty: bool,
    /// Standard output is not a terminal and descriptor 1 is not open.
    stdout_closed: bool,
};

/// The notice printed when standard output is sent to nohup.out.
pub const OutputNotice = enum { appending_output, ignoring_input_and_appending_output };
/// The notice printed when standard error follows standard output.
pub const StderrNotice = enum { redirecting_stderr, ignoring_input_and_redirecting_stderr };

pub const Plan = struct {
    /// Replace standard input by an unreadable descriptor.
    unusable_stdin: bool,
    /// Print "ignoring input" (nothing else is said about it).
    notice_ignoring_input: bool,
    /// Append standard output to nohup.out.
    redirect_stdout: bool,
    stdout_notice: OutputNotice,
    /// Make standard error a copy of standard output.
    redirect_stderr: bool,
    /// Set when `redirect_stderr` and standard output is not a terminal.
    stderr_notice: ?StderrNotice,
};

/// The order of the actions is: stdin, stdout, stderr.
pub fn plan(s: Streams) Plan {
    return .{
        .unusable_stdin = s.stdin_tty,
        .notice_ignoring_input = s.stdin_tty and !s.stdout_tty and !s.stderr_tty,
        .redirect_stdout = s.stdout_tty or (s.stdout_closed and s.stderr_tty),
        .stdout_notice = if (s.stdin_tty) .ignoring_input_and_appending_output else .appending_output,
        .redirect_stderr = s.stderr_tty,
        .stderr_notice = if (s.stderr_tty and !s.stdout_tty)
            (if (s.stdin_tty) StderrNotice.ignoring_input_and_redirecting_stderr else StderrNotice.redirecting_stderr)
        else
            null,
    };
}

/// Name of the output file in the current directory.
pub const output_name = "nohup.out";

/// "$HOME/nohup.out" in `buf`; null when HOME is unset or the path is too long.
pub fn homeOutputPath(home: ?[]const u8, buf: []u8) ?[]const u8 {
    const h = home orelse return null;
    return std.fmt.bufPrint(buf, "{s}/" ++ output_name, .{h}) catch null;
}

test "plan for a fully interactive session" {
    const p = plan(.{ .stdin_tty = true, .stdout_tty = true, .stderr_tty = true, .stdout_closed = false });
    try std.testing.expect(p.unusable_stdin and p.redirect_stdout and p.redirect_stderr);
    try std.testing.expect(!p.notice_ignoring_input);
    try std.testing.expect(p.stderr_notice == null);
    try std.testing.expectEqual(OutputNotice.ignoring_input_and_appending_output, p.stdout_notice);
}

test "plan with only stderr on a terminal" {
    const p = plan(.{ .stdin_tty = false, .stdout_tty = false, .stderr_tty = true, .stdout_closed = false });
    try std.testing.expect(!p.redirect_stdout and p.redirect_stderr);
    try std.testing.expectEqual(StderrNotice.redirecting_stderr, p.stderr_notice.?);
}
