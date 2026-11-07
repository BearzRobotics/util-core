//! Operating-system facilities that std.Io (Zig 0.17.1) does not provide.
//!
//! The project does all file, stream, clock and process I/O through `std.Io`
//! (ai/AGENTS.md §13). The few things below have no std.Io equivalent in the
//! toolchain checked on 2026-11-07 (`~/.zvm/0.17.1/lib/std/Io*`): signal
//! dispositions, the umask, the terminal-size ioctl, probing whether a pid
//! exists, and opening a file with O_APPEND. They are collected here so that
//! (a) commands never touch std.posix / std.os directly, (b) each exception is
//! documented in one place, and (c) each can be replaced by a std.Io call as
//! soon as one exists. Every function degrades gracefully on Windows and WASI.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const has_posix = builtin.os.tag != .windows and builtin.os.tag != .wasi;

pub const Signal = enum { int, pipe };

fn posixSignal(sig: Signal) std.posix.SIG {
    return switch (sig) {
        .int => .INT,
        .pipe => .PIPE,
    };
}

fn setDisposition(sig: Signal, handler: ?std.posix.Sigaction.handler_fn) void {
    if (comptime !has_posix) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(posixSignal(sig), &act, null);
}

/// Ignore `sig` for the rest of the process.
pub fn ignoreSignal(sig: Signal) void {
    setDisposition(sig, std.posix.SIG.IGN);
}

/// Restore the default action of `sig`.
pub fn defaultSignal(sig: Signal) void {
    setDisposition(sig, std.posix.SIG.DFL);
}

/// Zig's runtime ignores SIGPIPE, which would turn `cmd | head` into a write
/// error message. The conventional (GNU) behaviour is to die silently, so
/// every entry point restores the default action; commands that need to see
/// EPIPE (tee --output-error) set it back to ignore.
pub fn restoreSigpipe() void {
    defaultSignal(.pipe);
}

/// The process file-mode creation mask. Linux reads it with umask(2) (set and
/// restore, because the call has no pure query form); other systems fall back
/// to the conventional 022.
pub fn umask() u16 {
    if (comptime builtin.os.tag == .linux) {
        const old = std.os.linux.syscall1(.umask, 0);
        _ = std.os.linux.syscall1(.umask, old);
        return @intCast(old & 0o7777);
    }
    return 0o022;
}

/// Width in columns of the terminal on standard output, or null when it is
/// not a terminal or the system cannot say.
pub fn terminalColumns() ?usize {
    if (comptime !has_posix) return null;
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(1, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    return if (rc == 0 and ws.col > 0) ws.col else null;
}

/// True when process `pid` exists (kill(pid, 0)); EPERM counts as existing.
/// Always true where there is no kill(2).
pub fn processAlive(pid: i32) bool {
    if (comptime !has_posix) return true;
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |e| return e == error.PermissionDenied;
    return true;
}

/// Open `path` for appending, creating it if needed, with O_APPEND so that
/// concurrent writers do not overwrite each other. Io.Dir.createFile has no
/// append mode, and emulating it with a seek is not atomic.
pub fn openAppend(path: []const u8) !Io.File {
    if (comptime !has_posix) return error.Unsupported;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o666);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}
