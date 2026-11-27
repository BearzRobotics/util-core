// SPDX-License-Identifier: GPL-2.0-or-later
//! The controlling terminal for interactive input: raw mode, one byte at a
//! time, and its size. `std.Io` has none of this (decision 0002). POSIX
//! systems open /dev/tty and use termios; Windows opens CONIN$ and switches
//! the console to virtual-terminal input (arrow keys arrive as escape
//! sequences, as on POSIX). Used by the built-in pager of `cat`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_win = builtin.os.tag == .windows;

pub const Size = struct { rows: usize, cols: usize };

const win = if (is_win) struct {
    const w = std.os.windows;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: ?w.HANDLE) callconv(.winapi) w.HANDLE;
    extern "kernel32" fn GetConsoleMode(h: w.HANDLE, mode: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(h: w.HANDLE, mode: u32) callconv(.winapi) c_int;
    extern "kernel32" fn ReadFile(h: w.HANDLE, buf: [*]u8, n: u32, got: *u32, ov: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(h: w.HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn WaitForSingleObject(h: w.HANDLE, ms: u32) callconv(.winapi) u32;
    const CSBI = extern struct {
        size_x: i16,
        size_y: i16,
        cursor_x: i16,
        cursor_y: i16,
        attributes: u16,
        left: i16,
        top: i16,
        right: i16,
        bottom: i16,
        max_x: i16,
        max_y: i16,
    };
    extern "kernel32" fn GetConsoleScreenBufferInfo(h: w.HANDLE, info: *CSBI) callconv(.winapi) c_int;
} else struct {};

/// While a program has the terminal in raw mode and perhaps another screen, a
/// signal must not leave it so. `Guard.arm` has SIGHUP, SIGINT, SIGQUIT and
/// SIGTERM put things back before they end the process, and SIGTSTP before it
/// stops; when it goes on, the terminal is taken again and `Guard.resumed`
/// reports it, so that the screen can be redrawn. Signals that are ignored
/// stay ignored. One terminal at a time; does nothing on Windows.
pub const Guard = struct {
    const sigs = if (is_win) .{} else [_]std.posix.SIG{ .HUP, .INT, .QUIT, .TERM, .TSTP };

    const State = struct {
        tty: std.posix.fd_t,
        saved: std.posix.termios,
        raw: std.posix.termios,
        out: std.posix.fd_t,
        enter: []const u8,
        leave: []const u8,
    };
    var state: if (is_win) void else State = undefined;
    var armed: std.atomic.Value(bool) = .init(false);
    var went_on: std.atomic.Value(bool) = .init(false);
    var previous: if (is_win) void else [sigs.len]std.posix.Sigaction = undefined;
    var caught: [sigs.len]bool = undefined;

    /// `enter` and `leave` are what is written to `out` to take the screen and
    /// to give it back; they must live as long as the guard.
    pub fn arm(t: *const Tty, out: Io.File.Handle, enter: []const u8, leave: []const u8) void {
        if (comptime is_win) return;
        const raw = std.posix.tcgetattr(t.handle) catch return;
        state = .{ .tty = t.handle, .saved = t.saved_termios, .raw = raw, .out = out, .enter = enter, .leave = leave };
        armed.store(true, .release);
        for (sigs, 0..) |sig, i| {
            std.posix.sigaction(sig, null, &previous[i]);
            caught[i] = previous[i].handler.handler != std.posix.SIG.IGN;
            if (caught[i]) catchSignal(sig);
        }
    }

    pub fn disarm() void {
        if (comptime is_win) return;
        if (!armed.swap(false, .acq_rel)) return;
        for (sigs, 0..) |sig, i| {
            if (caught[i]) std.posix.sigaction(sig, &previous[i], null);
        }
    }

    /// Whether the process was stopped and has gone on since the last call.
    pub fn resumed() bool {
        return went_on.swap(false, .acq_rel);
    }

    fn catchSignal(sig: std.posix.SIG) void {
        const act: std.posix.Sigaction = .{ .handler = .{ .handler = handle }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESTART };
        std.posix.sigaction(sig, &act, null);
    }

    // Everything from here on runs in a signal handler.

    fn handle(sig: std.posix.SIG) callconv(.c) void {
        if (comptime is_win) return;
        if (armed.load(.acquire)) {
            send(state.leave);
            std.posix.tcsetattr(state.tty, .NOW, state.saved) catch {};
        }
        // Now as if the signal had not been caught.
        const dfl: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(sig, &dfl, null);
        var only = std.posix.sigemptyset();
        std.posix.sigaddset(&only, sig);
        std.posix.raise(sig) catch {};
        std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &only, null);
        // Only a stop comes back (or is discarded, in an orphaned group).
        if (sig != .TSTP) return;
        catchSignal(sig);
        if (armed.load(.acquire)) {
            std.posix.tcsetattr(state.tty, .NOW, state.raw) catch {};
            send(state.enter);
            went_on.store(true, .release);
        }
    }

    fn send(bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = std.posix.system.write(state.out, rest.ptr, rest.len);
            if (std.posix.errno(n) != .SUCCESS or n == 0) return;
            rest = rest[@intCast(n)..];
        }
    }
};

pub const Tty = struct {
    handle: if (is_win) std.os.windows.HANDLE else std.posix.fd_t,
    saved_termios: if (is_win) void else std.posix.termios,
    saved_mode: if (is_win) u32 else void,

    /// Open the terminal and switch it to raw input. Null when there is no
    /// controlling terminal.
    pub fn open(io: Io) ?Tty {
        if (comptime is_win) {
            const name = std.unicode.utf8ToUtf16LeStringLiteral("CONIN$");
            const h = win.CreateFileW(name, 0xC0000000, 3, null, 3, 0, null);
            if (h == std.os.windows.INVALID_HANDLE_VALUE) return null;
            var mode: u32 = 0;
            if (win.GetConsoleMode(h, &mode) == 0) {
                _ = win.CloseHandle(h);
                return null;
            }
            // Clear PROCESSED_INPUT (1), LINE_INPUT (2), ECHO_INPUT (4); set VIRTUAL_TERMINAL_INPUT (0x200).
            const raw = (mode & ~@as(u32, 7)) | 0x200;
            if (win.SetConsoleMode(h, raw) == 0) {
                _ = win.CloseHandle(h);
                return null;
            }
            return .{ .handle = h, .saved_termios = {}, .saved_mode = mode };
        }
        const f = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch return null;
        const saved = std.posix.tcgetattr(f.handle) catch {
            f.close(io);
            return null;
        };
        var raw = saved;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(f.handle, .FLUSH, raw) catch {
            f.close(io);
            return null;
        };
        return .{ .handle = f.handle, .saved_termios = saved, .saved_mode = {} };
    }

    /// Restore the terminal mode and close it.
    pub fn close(t: *Tty, io: Io) void {
        if (comptime is_win) {
            _ = win.SetConsoleMode(t.handle, t.saved_mode);
            _ = win.CloseHandle(t.handle);
            return;
        }
        std.posix.tcsetattr(t.handle, .FLUSH, t.saved_termios) catch {};
        (Io.File{ .handle = t.handle, .flags = .{ .nonblocking = false } }).close(io);
    }

    /// Next input byte; null at end of input or on error.
    pub fn readByte(t: *const Tty) ?u8 {
        var b: [1]u8 = undefined;
        if (comptime is_win) {
            var got: u32 = 0;
            if (win.ReadFile(t.handle, &b, 1, &got, null) == 0 or got == 0) return null;
            return b[0];
        }
        const n = std.posix.read(t.handle, &b) catch return null;
        return if (n == 1) b[0] else null;
    }

    pub const Wait = union(enum) { byte: u8, idle, closed };

    /// Next input byte, or `.idle` when none comes within `ms` milliseconds.
    /// Where the terminal cannot be polled this waits for a byte.
    pub fn waitByte(t: *const Tty, ms: u32) Wait {
        if (comptime builtin.os.tag == .linux) {
            var fds = [1]std.posix.pollfd{.{ .fd = t.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, @intCast(ms)) catch return .closed;
            if (n == 0) return .idle;
        }
        return if (t.readByte()) |b| .{ .byte = b } else .closed;
    }

    /// Next input byte, waiting at most `ms` milliseconds; null on timeout,
    /// end of input or error.
    pub fn readByteTimeout(t: *const Tty, ms: u32) ?u8 {
        if (comptime is_win) {
            if (win.WaitForSingleObject(t.handle, ms) != 0) return null;
            return t.readByte();
        }
        var fds = [1]std.posix.pollfd{.{ .fd = t.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, @intCast(ms)) catch return null;
        if (n == 0) return null;
        return t.readByte();
    }

    /// Whether there is a terminal `open` could take; its modes are left alone.
    pub fn available(io: Io) bool {
        if (comptime is_win) {
            var t = open(io) orelse return false;
            t.close(io);
            return true;
        }
        const f = Io.Dir.cwd().openFile(io, "/dev/tty", .{ .mode = .read_write }) catch return false;
        f.close(io);
        return true;
    }

    /// The size of the window standard output shows in, for before the
    /// terminal is opened.
    pub fn outputSize() ?Size {
        // Windows asks the output console either way.
        const t: Tty = if (comptime is_win)
            .{ .handle = undefined, .saved_termios = {}, .saved_mode = 0 }
        else
            .{ .handle = std.posix.STDOUT_FILENO, .saved_termios = undefined, .saved_mode = {} };
        return t.size();
    }

    /// Current size of the terminal window.
    pub fn size(t: *const Tty) ?Size {
        if (comptime is_win) {
            var info: win.CSBI = undefined;
            const out = std.os.windows.peb().ProcessParameters.hStdOutput;
            if (win.GetConsoleScreenBufferInfo(out, &info) == 0) return null;
            const rows = @as(i32, info.bottom) - @as(i32, info.top) + 1;
            const cols = @as(i32, info.right) - @as(i32, info.left) + 1;
            if (rows <= 0 or cols <= 0) return null;
            return .{ .rows = @intCast(rows), .cols = @intCast(cols) };
        }
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(t.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc != 0 or ws.row == 0 or ws.col == 0) return null;
        return .{ .rows = ws.row, .cols = ws.col };
    }
};
