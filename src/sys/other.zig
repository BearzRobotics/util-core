// SPDX-License-Identifier: GPL-2.0-or-later
//! The non-Linux half of src/sys.zig: macOS (and other libc POSIX systems)
//! and Windows. Every function here has the same signature and meaning as the
//! Linux one in sys.zig, which dispatches here with
//! `if (comptime !is_linux) return other.f(...)`.
//!
//! Method: file-system calls go through `std.Io` (the single-threaded
//! `Io` instance, because sys functions carry no `io`), with errors mapped back
//! onto the errno names the commands print. Facilities `std.Io` lacks use
//! libc on macOS and kernel32 on Windows. Where a facility cannot exist on the
//! platform the function returns `E.NOSYS` or `E.OPNOTSUPP`, so the command
//! prints a one-line diagnostic and fails instead of pretending to succeed.
//!
//! Status (docs/portability.md): macOS is compile-checked only (no Mac was
//! available); Windows runs under wine.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("../sys.zig");

const E = sys.E;
const Handle = sys.Handle;
const Pid = sys.Pid;
const FileStat = sys.FileStat;
const O = sys.O;

const is_win = builtin.os.tag == .windows;
const is_darwin = builtin.os.tag.isDarwin();
/// A libc POSIX system (macOS here; the BSDs are expected to work the same).
const is_libc_posix = !is_win and builtin.os.tag != .linux and builtin.os.tag != .wasi;
const c = std.c;

fn io() Io {
    return Io.Threaded.global_single_threaded.io();
}

fn cwd() Io.Dir {
    return Io.Dir.cwd();
}

/// The `std.Io` view of an open directory (or of `sys.cwdFd()`).
fn dirOf(h: Handle) Io.Dir {
    return .{ .handle = h };
}

fn fileOf(h: Handle) Io.File {
    return .{ .handle = h, .flags = .{ .nonblocking = false } };
}

/// Map an `std.Io` error onto the errno it corresponds to.
fn errFrom(e: anyerror) E {
    return switch (e) {
        error.FileNotFound, error.NetworkNotFound => .NOENT,
        error.AccessDenied, error.PermissionDenied => .ACCES,
        error.PathAlreadyExists => .EXIST,
        error.NotDir => .NOTDIR,
        error.IsDir => .ISDIR,
        error.DirNotEmpty => .NOTEMPTY,
        error.NameTooLong => .NAMETOOLONG,
        error.NoSpaceLeft => .NOSPC,
        error.DiskQuota => .DQUOT,
        error.ReadOnlyFileSystem => .ROFS,
        error.SymLinkLoop => .LOOP,
        error.FileBusy => .BUSY,
        error.BadPathName, error.InvalidUtf8, error.InvalidWtf8 => .INVAL,
        error.OperationUnsupported, error.NotSupported, error.Unsupported => .OPNOTSUPP,
        error.CrossDevice => .XDEV,
        error.ProcessFdQuotaExceeded => .MFILE,
        error.SystemFdQuotaExceeded => .NFILE,
        error.SystemResources, error.OutOfMemory => .NOMEM,
        error.FileTooBig => .FBIG,
        error.BrokenPipe => .PIPE,
        error.WouldBlock => .AGAIN,
        error.LinkQuotaExceeded => .MLINK,
        error.NoDevice => .NODEV,
        error.SharingViolation, error.PipeBusy => .BUSY,
        error.Unseekable => .SPIPE,
        error.Canceled => .INTR,
        else => .IO,
    };
}

/// Map a libc errno (macOS) onto the Linux-named vocabulary by name.
fn fromC(e: c.E) E {
    const name = std.enums.tagName(c.E, e) orelse return .IO;
    return std.meta.stringToEnum(E, name) orelse .IO;
}

fn cerr(rc: anytype) ?E {
    if (comptime is_win) return .NOSYS;
    const e = c.errno(rc);
    return if (e == .SUCCESS) null else fromC(e);
}

fn cstr(buf: *[4097]u8, path: []const u8) ?[*:0]const u8 {
    if (path.len >= 4096) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

// ------------------------------------------------------------ Windows kernel32

const win = if (is_win) struct {
    const w = std.os.windows;
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
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
    extern "kernel32" fn GetConsoleScreenBufferInfo(h: w.HANDLE, info: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) c_int;
    extern "kernel32" fn GetConsoleMode(h: w.HANDLE, mode: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleMode(h: w.HANDLE, mode: u32) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleOutputCP(cp: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessTimes(h: w.HANDLE, creation: *u64, exit: *u64, kernel: *u64, user: *u64) callconv(.winapi) c_int;
    const PROCESS_MEMORY_COUNTERS = extern struct {
        cb: u32,
        page_fault_count: u32,
        peak_working_set: usize,
        working_set: usize,
        quota_peak_paged: usize,
        quota_paged: usize,
        quota_peak_nonpaged: usize,
        quota_nonpaged: usize,
        pagefile: usize,
        peak_pagefile: usize,
    };
    extern "kernel32" fn K32GetProcessMemoryInfo(h: w.HANDLE, pmc: *PROCESS_MEMORY_COUNTERS, cb: u32) callconv(.winapi) c_int;
    extern "kernel32" fn WaitForSingleObject(h: w.HANDLE, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn TerminateProcess(h: w.HANDLE, code: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetExitCodeProcess(h: w.HANDLE, code: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetComputerNameA(buf: [*]u8, size: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetDiskFreeSpaceExW(dir: [*:0]const u16, avail: ?*u64, total: ?*u64, free: ?*u64) callconv(.winapi) c_int;
    extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn OpenProcess(access: u32, inherit: c_int, pid: u32) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn CloseHandle(h: w.HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn GetSystemInfo(info: *extern struct { oem: u32, page: u32, minaddr: ?*anyopaque, maxaddr: ?*anyopaque, mask: usize, cpus: u32, gran: u32, level: u16, rev: u16 }) callconv(.winapi) void;
} else struct {};

// ------------------------------------------------------------------ signals

pub fn setDisposition(is_pipe: bool, ignore: bool) void {
    if (comptime !is_libc_posix) return;
    const act: c.Sigaction = .{
        .handler = .{ .handler = if (ignore) c.SIG.IGN else c.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    _ = c.sigaction(if (is_pipe) c.SIG.PIPE else c.SIG.INT, &act, null);
}

pub fn setSignal(num: u8, d: sys.Disposition) bool {
    if (comptime !is_libc_posix) return false;
    const sg: c.SIG = @enumFromInt(num);
    if ((num == sys.signo.KILL or num == sys.signo.STOP) and d != .block) return false;
    switch (d) {
        .block => {
            var set = std.posix.sigemptyset();
            std.posix.sigaddset(&set, sg);
            return c.sigprocmask(c.SIG.BLOCK, &set, null) == 0;
        },
        .default, .ignore => {
            const act: c.Sigaction = .{
                .handler = .{ .handler = if (d == .ignore) c.SIG.IGN else c.SIG.DFL },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            return c.sigaction(sg, &act, null) == 0;
        },
    }
}

pub fn unblockSignal(num: u8) void {
    if (comptime !is_libc_posix) return;
    var set = std.posix.sigemptyset();
    std.posix.sigaddset(&set, @enumFromInt(num));
    _ = c.sigprocmask(c.SIG.UNBLOCK, &set, null);
}

pub fn signalState(num: u8) sys.SignalState {
    if (comptime !is_libc_posix) return .{ .disp = .default, .blocked = false };
    const sg: c.SIG = @enumFromInt(num);
    if (num == sys.signo.KILL or num == sys.signo.STOP) return .{ .disp = .default, .blocked = false };
    var old: c.Sigaction = undefined;
    _ = c.sigaction(sg, null, &old);
    var cur: c.sigset_t = undefined;
    _ = c.sigprocmask(c.SIG.BLOCK, null, &cur);
    const blocked = std.posix.sigismember(&cur, sg);
    const h = old.handler.handler;
    const d: ?sys.Disposition = if (h == c.SIG.IGN) .ignore else if (h == c.SIG.DFL or h == null) .default else null;
    return .{ .disp = d, .blocked = blocked };
}

pub fn sendSignal(pid: Pid, sg: u8) ?E {
    if (comptime is_win) {
        if (sg == 0) return null;
        return if (win.TerminateProcess(pid, 1) != 0) null else .PERM;
    }
    return cerr(c.kill(pid, @enumFromInt(sg)));
}

pub fn signalOwnGroup(sg: u8) ?E {
    if (comptime is_win) return .NOSYS;
    return cerr(c.kill(0, @enumFromInt(sg)));
}

pub fn raiseSelf(sg: u8) ?E {
    if (comptime is_win) return .NOSYS;
    return cerr(c.kill(c.getpid(), @enumFromInt(sg)));
}

fn statisticsHandler(_: c.SIG) callconv(.c) void {
    sys.recordStatisticsRequest();
}

fn interruptHandler(_: c.SIG) callconv(.c) void {
    sys.recordInterrupt();
}

pub fn catchStatisticsSignals(on_user_signal: bool) void {
    if (comptime !is_libc_posix) return;
    if (on_user_signal) {
        const act: c.Sigaction = .{ .handler = .{ .handler = statisticsHandler }, .mask = std.posix.sigemptyset(), .flags = 0 };
        _ = c.sigaction(c.SIG.USR1, &act, null);
        if (comptime @hasField(c.SIG, "INFO")) _ = c.sigaction(c.SIG.INFO, &act, null);
    }
    var old: c.Sigaction = undefined;
    if (c.sigaction(c.SIG.INT, null, &old) != 0 or old.handler.handler == c.SIG.IGN) return;
    const act: c.Sigaction = .{ .handler = .{ .handler = interruptHandler }, .mask = std.posix.sigemptyset(), .flags = c.SA.RESETHAND };
    _ = c.sigaction(c.SIG.INT, &act, null);
}

var saved_catch: [7]c.Sigaction = undefined;
var saved_catch_valid: [7]bool = @splat(false);

fn catchHandler(sg: c.SIG) callconv(.c) void {
    sys.recordCaught(@intCast(@intFromEnum(sg)));
}

fn catchList() [7]u8 {
    const s = sys.signo;
    return .{ s.HUP, s.INT, s.PIPE, s.QUIT, s.TERM, s.ALRM, s.TSTP };
}

pub fn catchSignals() void {
    if (comptime !is_libc_posix) return;
    const list = catchList();
    for (list, 0..) |num, i| {
        const sg: c.SIG = @enumFromInt(num);
        var old: c.Sigaction = undefined;
        if (c.sigaction(sg, null, &old) != 0) continue;
        if (old.handler.handler == c.SIG.IGN) continue;
        const act: c.Sigaction = .{
            .handler = .{ .handler = catchHandler },
            .mask = std.posix.sigemptyset(),
            .flags = c.SA.RESTART,
        };
        if (c.sigaction(sg, &act, null) != 0) continue;
        if (!saved_catch_valid[i]) {
            saved_catch[i] = old;
            saved_catch_valid[i] = true;
        }
    }
}

pub fn restoreCaughtSignals() void {
    if (comptime !is_libc_posix) return;
    const list = catchList();
    for (list, 0..) |num, i| {
        if (!saved_catch_valid[i]) continue;
        _ = c.sigaction(@enumFromInt(num), &saved_catch[i], null);
        saved_catch_valid[i] = false;
    }
}

pub fn deliverCaughtSignal(sg: u8) void {
    if (comptime !is_libc_posix) return;
    if (sg == sys.signo.TSTP) {
        _ = c.kill(c.getpid(), @enumFromInt(sys.signo.STOP));
        return;
    }
    const act: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    _ = c.sigaction(@enumFromInt(sg), &act, null);
    unblockSignal(sg);
    _ = c.kill(c.getpid(), @enumFromInt(sg));
}

// -------------------------------------------------- umask, terminal, identity

extern "c" fn getgroups(n: c_int, list: [*]u32) c_int;
extern "c" fn getpriority(which: c_int, who: u32) c_int;
extern "c" fn setpriority(which: c_int, who: u32, prio: c_int) c_int;
extern "c" fn chroot(path: [*:0]const u8) c_int;
extern "c" fn mknodat(dir: c_int, path: [*:0]const u8, mode: u16, dev: i32) c_int;
extern "c" fn clock_settime(clk: c_int, ts: *const c.timespec) c_int;

pub fn umask() u16 {
    if (comptime !is_libc_posix) return 0o022;
    const old = c.umask(0o022);
    _ = c.umask(old);
    return @intCast(old & 0o7777);
}

pub fn setUmask(mask: u32) u32 {
    if (comptime !is_libc_posix) return 0o022;
    return @intCast(c.umask(@intCast(mask)) & 0o7777);
}

pub fn terminalColumns() ?usize {
    if (comptime is_win) {
        var info: win.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        const h = std.os.windows.peb().ProcessParameters.hStdOutput;
        if (win.GetConsoleScreenBufferInfo(h, &info) == 0) return null;
        const cols = @as(i32, info.right) - @as(i32, info.left) + 1;
        return if (cols > 0) @intCast(cols) else null;
    }
    var ws: std.posix.winsize = undefined;
    const rc = c.ioctl(1, c.T.IOCGWINSZ, @intFromPtr(&ws));
    return if (rc == 0 and ws.col > 0) ws.col else null;
}

/// Prepare a Windows console for ANSI output: turn on virtual terminal
/// processing (escape sequences) and UTF-8 output (box-drawing characters).
/// Returns false when stdout is not a console or the console refuses (very
/// old conhost); callers then keep escapes off. A no-op returning true elsewhere.
pub fn enableAnsiOutput() bool {
    if (comptime !is_win) return true;
    const h = std.os.windows.peb().ProcessParameters.hStdOutput;
    var mode: u32 = 0;
    if (win.GetConsoleMode(h, &mode) == 0) return false;
    // ENABLE_VIRTUAL_TERMINAL_PROCESSING (0x4) only. Not DISABLE_NEWLINE_AUTO_RETURN (0x8):
    // we write plain \n, and with that flag a line feed no longer returns the
    // cursor to column 0, so text stair-steps after a full-width line.
    if (win.SetConsoleMode(h, mode | 0x4) == 0) return false;
    _ = win.SetConsoleOutputCP(65001);
    return true;
}

pub fn processAlive(pid: i32) bool {
    if (comptime is_win) {
        const h = win.OpenProcess(0x00100000, 0, @intCast(pid)) orelse return false; // SYNCHRONIZE
        defer _ = win.CloseHandle(h);
        return win.WaitForSingleObject(h, 0) == 0x102; // WAIT_TIMEOUT: still running
    }
    if (c.kill(pid, @enumFromInt(0)) == 0) return true;
    return c.errno(@as(c_int, -1)) == .PERM;
}

pub fn identity() sys.Identity {
    // Windows has no uid/gid: every id is reported as 0 (see docs/portability.md).
    if (comptime !is_libc_posix) return .{ .uid = 0, .euid = 0, .gid = 0, .egid = 0 };
    return .{ .uid = c.getuid(), .euid = c.geteuid(), .gid = c.getgid(), .egid = c.getegid() };
}

pub fn supplementaryGroups(buf: []u32) []u32 {
    if (comptime !is_libc_posix) return buf[0..0];
    const n = getgroups(@intCast(buf.len), buf.ptr);
    if (n < 0) return buf[0..0];
    return buf[0..@intCast(n)];
}

pub const UnameBuf = struct {
    f: [5][256]u8,
    n: [5]usize,

    pub fn get(u: *const UnameBuf, i: usize) []const u8 {
        return u.f[i][0..u.n[i]];
    }

    fn set(u: *UnameBuf, i: usize, text: []const u8) void {
        const len = @min(text.len, 255);
        @memcpy(u.f[i][0..len], text[0..len]);
        u.n[i] = len;
    }
};

pub fn uname() UnameBuf {
    var u: UnameBuf = undefined;
    for (0..5) |i| u.n[i] = 0;
    if (comptime is_win) {
        u.set(0, "Windows_NT");
        var name: [256]u8 = undefined;
        var size: u32 = name.len;
        u.set(1, if (win.GetComputerNameA(&name, &size) != 0) name[0..size] else "localhost");
        var v: std.os.windows.OSVERSIONINFOW = std.mem.zeroes(std.os.windows.OSVERSIONINFOW);
        v.dwOSVersionInfoSize = @sizeOf(std.os.windows.OSVERSIONINFOW);
        _ = std.os.windows.ntdll.RtlGetVersion(&v);
        var rel: [32]u8 = undefined;
        u.set(2, std.fmt.bufPrint(&rel, "{d}.{d}", .{ v.dwMajorVersion, v.dwMinorVersion }) catch "10.0");
        var ver: [32]u8 = undefined;
        u.set(3, std.fmt.bufPrint(&ver, "{d}", .{v.dwBuildNumber}) catch "0");
        u.set(4, machineName());
        return u;
    }
    var raw: c.utsname = undefined;
    if (c.uname(&raw) == 0) {
        u.set(0, std.mem.sliceTo(&raw.sysname, 0));
        u.set(1, std.mem.sliceTo(&raw.nodename, 0));
        u.set(2, std.mem.sliceTo(&raw.release, 0));
        u.set(3, std.mem.sliceTo(&raw.version, 0));
        u.set(4, std.mem.sliceTo(&raw.machine, 0));
    } else {
        u.set(0, "unknown");
        u.set(1, "unknown");
        u.set(2, "unknown");
        u.set(3, "unknown");
        u.set(4, machineName());
    }
    return u;
}

fn machineName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => if (is_darwin) "arm64" else "aarch64",
        .x86 => "i686",
        else => @tagName(builtin.cpu.arch),
    };
}

// ------------------------------------------------------------------- stat

fn kindMode(kind: Io.File.Kind) u32 {
    return switch (kind) {
        .directory => 0o040000,
        .file => 0o100000,
        .sym_link => 0o120000,
        .block_device => 0o060000,
        .character_device => 0o020000,
        .named_pipe => 0o010000,
        .unix_domain_socket => 0o140000,
        else => 0o100000,
    };
}

fn splitNs(ts: Io.Timestamp) struct { s: i64, ns: u32 } {
    const ns: i96 = ts.nanoseconds;
    return .{ .s = @intCast(@divFloor(ns, std.time.ns_per_s)), .ns = @intCast(@mod(ns, std.time.ns_per_s)) };
}

fn hasExecutableSuffix(name: []const u8) bool {
    const exts = [_][]const u8{ ".exe", ".bat", ".cmd", ".com" };
    for (exts) |e| if (name.len >= e.len and std.ascii.eqlIgnoreCase(name[name.len - e.len ..], e)) return true;
    return false;
}

/// FileStat from std.Io's portable Stat: no owner, device or block data
/// (Windows has none; ids and device numbers read 0).
fn fromIoStat(st: Io.File.Stat, name: ?[]const u8) FileStat {
    const kind = kindMode(st.kind);
    var perm: u32 = if (st.kind == .directory) 0o755 else 0o644;
    if (st.kind == .file and name != null and hasExecutableSuffix(name.?)) perm = 0o755;
    if (is_win and @intFromEnum(st.permissions) & 1 != 0) perm &= ~@as(u32, 0o222);
    if (comptime !is_win) perm = st.permissions.toMode() & 0o7777;
    const at = if (st.atime) |a| splitNs(a) else splitNs(st.mtime);
    const mt = splitNs(st.mtime);
    const ct = splitNs(st.ctime);
    return .{
        .mode = kind | perm,
        .uid = 0,
        .gid = 0,
        .nlink = @intCast(@min(st.nlink, std.math.maxInt(u32))),
        .ino = @intCast(st.inode),
        .size = st.size,
        .blocks = (st.size + 511) / 512,
        .blksize = if (st.block_size == 0) 4096 else st.block_size,
        .dev_major = 0,
        .dev_minor = 0,
        .rdev_major = 0,
        .rdev_minor = 0,
        .atime_s = at.s,
        .atime_ns = at.ns,
        .mtime_s = mt.s,
        .mtime_ns = mt.ns,
        .ctime_s = ct.s,
        .ctime_ns = ct.ns,
        .btime_s = ct.s,
        .btime_ns = ct.ns,
        .has_btime = false,
    };
}

fn fromCStat(st: c.Stat) FileStat {
    const dev: u32 = @bitCast(st.dev);
    const rdev: u32 = @bitCast(st.rdev);
    const bt = st.birthtime();
    return .{
        .mode = st.mode,
        .uid = st.uid,
        .gid = st.gid,
        .nlink = st.nlink,
        .ino = st.ino,
        .size = @intCast(st.size),
        .blocks = @intCast(st.blocks),
        .blksize = @intCast(st.blksize),
        .dev_major = (dev >> 24) & 0xff,
        .dev_minor = dev & 0xffffff,
        .rdev_major = (rdev >> 24) & 0xff,
        .rdev_minor = rdev & 0xffffff,
        .atime_s = st.atime().sec,
        .atime_ns = @intCast(st.atime().nsec),
        .mtime_s = st.mtime().sec,
        .mtime_ns = @intCast(st.mtime().nsec),
        .ctime_s = st.ctime().sec,
        .ctime_ns = @intCast(st.ctime().nsec),
        .btime_s = bt.sec,
        .btime_ns = @intCast(bt.nsec),
        .has_btime = true,
    };
}

pub fn fileStatAt(dir: Handle, path: []const u8, follow: bool, err: *E) ?FileStat {
    if (comptime is_libc_posix) {
        var b: [4097]u8 = undefined;
        const p = cstr(&b, path) orelse {
            err.* = .NAMETOOLONG;
            return null;
        };
        var st: c.Stat = undefined;
        const flags: u32 = if (follow) 0 else c.AT.SYMLINK_NOFOLLOW;
        if (cerr(c.fstatat(dir, p, &st, flags))) |e| {
            err.* = e;
            return null;
        }
        return fromCStat(st);
    }
    const st = dirOf(dir).statFile(io(), path, .{ .follow_symlinks = follow }) catch |e| {
        err.* = errFrom(e);
        return null;
    };
    return fromIoStat(st, path);
}

pub fn fstatFd(fd: Handle, err: *E) ?FileStat {
    if (comptime is_libc_posix) {
        var st: c.Stat = undefined;
        if (cerr(c.fstat(fd, &st))) |e| {
            err.* = e;
            return null;
        }
        return fromCStat(st);
    }
    const st = fileOf(fd).stat(io()) catch |e| {
        err.* = errFrom(e);
        return null;
    };
    return fromIoStat(st, null);
}

// ---------------------------------------------------- descriptors and files

/// O flags of sys.zig are abstract (the Linux values) on every OS other than
/// Linux; this builds the matching Io open call.
pub fn openFdAt(dir: Handle, path: []const u8, flags: u32, mode: u32, err: *E) ?Handle {
    const acc = flags & 3;
    const follow = flags & O.NOFOLLOW == 0;
    if (flags & O.DIRECTORY != 0) {
        const d = dirOf(dir).openDir(io(), path, .{ .follow_symlinks = follow, .iterate = true }) catch |e| {
            err.* = errFrom(e);
            return null;
        };
        return d.handle;
    }
    const file = if (flags & O.CREAT != 0)
        dirOf(dir).createFile(io(), path, .{
            .read = acc == O.RDWR,
            .truncate = flags & O.TRUNC != 0,
            .exclusive = flags & O.EXCL != 0,
            .permissions = sys.permissionsFromMode(mode),
        })
    else
        dirOf(dir).openFile(io(), path, .{
            .mode = switch (acc) {
                O.WRONLY => .write_only,
                O.RDWR => .read_write,
                else => .read_only,
            },
            .follow_symlinks = follow,
        });
    const f = file catch |e| {
        err.* = errFrom(e);
        return null;
    };
    if (flags & O.CREAT == 0 and flags & O.TRUNC != 0) f.setLength(io(), 0) catch {};
    return f.handle;
}

pub fn closeFd(fd: Handle) ?E {
    if (comptime is_libc_posix) return cerr(c.close(fd));
    fileOf(fd).close(io());
    return null;
}

pub fn readFd(fd: Handle, buf: []u8, err: *E) ?usize {
    var bufs = [_][]u8{buf};
    return fileOf(fd).readStreaming(io(), &bufs) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => {
            err.* = errFrom(e);
            return null;
        },
    };
}

pub fn writeFd(fd: Handle, bytes: []const u8, err: *E) ?usize {
    const empty: []const u8 = "";
    var data = [_][]const u8{bytes};
    return fileOf(fd).writeStreaming(io(), empty, &data, 1) catch {
        err.* = .IO;
        return null;
    };
}

pub fn writeAllFd(fd: Handle, bytes: []const u8) ?E {
    fileOf(fd).writeStreamingAll(io(), bytes) catch return .IO;
    return null;
}

pub fn seekFd(fd: Handle, off: i64, whence: u32, err: *E) ?i64 {
    if (comptime is_libc_posix) {
        // sys.zig numbers SEEK_DATA 3 / SEEK_HOLE 4 (Linux); macOS has them swapped.
        const w: c_int = switch (whence) {
            3 => 4,
            4 => 3,
            else => @intCast(whence),
        };
        const rc = c.lseek(fd, off, w);
        if (rc < 0) {
            err.* = fromC(c.errno(rc));
            return null;
        }
        return rc;
    }
    const f = fileOf(fd);
    const vt = io().vtable;
    const ud = io().userdata;
    switch (whence) {
        0 => vt.fileSeekTo(ud, f, @intCast(@max(off, 0))) catch |e| {
            err.* = errFrom(e);
            return null;
        },
        1 => vt.fileSeekBy(ud, f, off) catch |e| {
            err.* = errFrom(e);
            return null;
        },
        2 => {
            const len = f.length(io()) catch |e| {
                err.* = errFrom(e);
                return null;
            };
            const target = @as(i64, @intCast(len)) + off;
            if (target < 0) {
                err.* = .INVAL;
                return null;
            }
            vt.fileSeekTo(ud, f, @intCast(target)) catch |e| {
                err.* = errFrom(e);
                return null;
            };
        },
        else => {
            err.* = .INVAL; // SEEK_DATA / SEEK_HOLE: no sparse-file support here
            return null;
        },
    }
    return 0; // the new position is not reported by Io; callers only need the error
}

pub fn ftruncateFd(fd: Handle, len: u64) ?E {
    fileOf(fd).setLength(io(), len) catch |e| return errFrom(e);
    return null;
}

pub fn fchmodFd(fd: Handle, mode: u32) ?E {
    fileOf(fd).setPermissions(io(), sys.permissionsFromMode(mode)) catch |e| return errFrom(e);
    return null;
}

pub fn fchownFd(fd: Handle, uid: u32, gid: u32) ?E {
    if (comptime is_libc_posix) return cerr(c.fchown(fd, uid, gid));
    return noOwners(uid, gid);
}

pub fn chownAt(path: []const u8, uid: u32, gid: u32, nofollow: bool) ?E {
    if (comptime is_libc_posix) {
        var b: [4097]u8 = undefined;
        const p = cstr(&b, path) orelse return .NAMETOOLONG;
        return cerr(c.fchownat(c.AT.FDCWD, p, uid, gid, if (nofollow) c.AT.SYMLINK_NOFOLLOW else 0));
    }
    _ = .{ path, nofollow };
    return noOwners(uid, gid);
}

/// Windows has no owners: every file is reported as owned by id 0, so a
/// request for owner 0 (or "leave unchanged") is already true and any other id
/// cannot be honoured.
fn noOwners(uid: u32, gid: u32) ?E {
    const keep = std.math.maxInt(u32);
    if ((uid == 0 or uid == keep) and (gid == 0 or gid == keep)) return null;
    return .PERM;
}

pub fn syncFile(fd: Handle, kind: sys.SyncKind) ?E {
    switch (kind) {
        .all => {
            if (comptime is_libc_posix) {
                c.sync();
                return null;
            }
            return .NOSYS;
        },
        .data, .file, .fs => {
            fileOf(fd).sync(io()) catch |e| return errFrom(e);
            return null;
        },
    }
}

pub fn openAppendMode(path: []const u8, mode: u32) !Io.File {
    if (comptime is_libc_posix) {
        var b: [4097]u8 = undefined;
        const p = cstr(&b, path) orelse return error.NameTooLong;
        const fd = c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c_uint, mode));
        if (fd < 0) return error.AccessDenied;
        return fileOf(fd);
    }
    // Windows: open without truncating and seek to the end. Not atomic with
    // concurrent writers (documented in docs/portability.md).
    const f = try cwd().createFile(io(), path, .{ .truncate = false, .permissions = sys.permissionsFromMode(mode) });
    const len = try f.length(io());
    try io().vtable.fileSeekTo(io().userdata, f, len);
    return f;
}

pub fn dup2(old: Handle, new: i32) ?E {
    if (comptime is_libc_posix) return cerr(c.dup2(old, new));
    return .NOSYS;
}

pub fn fdOpen(fd: i32) bool {
    if (comptime is_libc_posix) return c.fcntl(fd, c.F.GETFD, @as(c_int, 0)) >= 0;
    return true;
}

// ------------------------------------------------------------------- paths

pub fn mkdirAt(dir: Handle, path: []const u8, mode: u32) ?E {
    dirOf(dir).createDir(io(), path, sys.permissionsFromMode(mode)) catch |e| return errFrom(e);
    return null;
}

pub fn unlinkAt(dir: Handle, path: []const u8, removedir: bool) ?E {
    if (removedir) dirOf(dir).deleteDir(io(), path) catch |e| return errFrom(e) else dirOf(dir).deleteFile(io(), path) catch |e| return errFrom(e);
    return null;
}

pub fn renamePath(old: []const u8, new: []const u8, flags: u32) ?E {
    if (flags & sys.RENAME_EXCHANGE != 0) return .OPNOTSUPP;
    if (flags & sys.RENAME_NOREPLACE != 0) {
        Io.Dir.renamePreserve(cwd(), old, cwd(), new, io()) catch |e| return errFrom(e);
        return null;
    }
    Io.Dir.rename(cwd(), old, cwd(), new, io()) catch |e| return errFrom(e);
    return null;
}

pub fn linkPath(old: []const u8, new: []const u8, follow: bool) ?E {
    Io.Dir.hardLink(cwd(), old, cwd(), new, io(), .{ .follow_symlinks = follow }) catch |e| return errFrom(e);
    return null;
}

pub fn symlinkPath(target: []const u8, path: []const u8) ?E {
    var is_dir = false;
    if (comptime is_win) {
        // Windows distinguishes file and directory links; decide from the target.
        if (cwd().statFile(io(), target, .{})) |st| is_dir = st.kind == .directory else |_| {}
    }
    cwd().symLink(io(), target, path, .{ .is_directory = is_dir }) catch |e| return errFrom(e);
    return null;
}

pub fn readlinkAt(dir: Handle, path: []const u8, buf: []u8, err: *E) ?usize {
    return dirOf(dir).readLink(io(), path, buf) catch |e| {
        err.* = errFrom(e);
        return null;
    };
}

pub fn chmodPath(path: []const u8, mode: u32, nofollow: bool) ?E {
    cwd().setFilePermissions(io(), path, sys.permissionsFromMode(mode), .{ .follow_symlinks = !nofollow }) catch |e| return errFrom(e);
    return null;
}

/// chmod of `name` in `dir`. Windows has no links to guard against here (and
/// std cannot change permissions without following one).
pub fn chmodAt(dir: Handle, name: []const u8, mode: u32) ?E {
    dirOf(dir).setFilePermissions(io(), name, sys.permissionsFromMode(mode), .{ .follow_symlinks = is_win }) catch |e| return errFrom(e);
    return null;
}

pub fn accessAt(dir: Handle, path: []const u8, mode: u32) ?E {
    dirOf(dir).access(io(), path, .{ .read = mode & 4 != 0, .write = mode & 2 != 0, .execute = mode & 1 != 0 }) catch |e| return errFrom(e);
    return null;
}

pub fn setTimes(path: ?[]const u8, fd: Handle, times: ?[2]sys.TimeSpec, nofollow: bool) ?E {
    const T = Io.File.SetTimestamp;
    var at: T = .now;
    var mt: T = .now;
    if (times) |t| {
        at = conv(t[0]);
        mt = conv(t[1]);
    }
    if (path) |p| {
        cwd().setTimestamps(io(), p, .{ .follow_symlinks = !nofollow, .access_timestamp = at, .modify_timestamp = mt }) catch |e| return errFrom(e);
    } else {
        fileOf(fd).setTimestamps(io(), .{ .access_timestamp = at, .modify_timestamp = mt }) catch |e| return errFrom(e);
    }
    return null;
}

fn conv(t: sys.TimeSpec) Io.File.SetTimestamp {
    if (t.nsec == sys.TimeSpec.now_ns) return .now;
    if (t.nsec == sys.TimeSpec.omit_ns) return .unchanged;
    return .{ .new = .{ .nanoseconds = @as(i96, t.sec) * std.time.ns_per_s + t.nsec } };
}

// --------------------------------------------------- processes, host, system

pub fn monotonicNs() i128 {
    return io().vtable.now(io().userdata, .awake).nanoseconds;
}

pub fn getNice() i32 {
    if (comptime is_libc_posix) return getpriority(0, 0);
    return 0;
}

pub fn setNice(value: i32) ?E {
    if (comptime is_libc_posix) return cerr(setpriority(0, 0, value));
    return .NOSYS;
}

pub fn becomeGroupLeader() void {
    if (comptime is_libc_posix) _ = c.setpgid(0, 0);
}

pub fn chrootPath(path: [:0]const u8) ?E {
    if (comptime is_libc_posix) return cerr(chroot(path.ptr));
    return .NOSYS;
}

pub fn mknodAt(dir: Handle, path: []const u8, mode: u32, dev: u64) ?E {
    if (comptime is_libc_posix) {
        var b: [4097]u8 = undefined;
        const p = cstr(&b, path) orelse return .NAMETOOLONG;
        return cerr(mknodat(dir, p, @intCast(mode), @intCast(dev)));
    }
    return .NOSYS;
}

/// macOS makedev: major in the top byte of a 32-bit dev_t.
pub fn makedev(major: u64, minor: u64) u64 {
    return ((major & 0xff) << 24) | (minor & 0xffffff);
}

pub fn parentPid() i32 {
    if (comptime is_libc_posix) return c.getppid();
    return 0;
}

pub fn setRealtime(sec: i64, nsec: u32) ?E {
    if (comptime is_libc_posix) {
        const ts: c.timespec = .{ .sec = sec, .nsec = nsec };
        return cerr(clock_settime(0, &ts)); // CLOCK_REALTIME
    }
    return .NOSYS;
}

pub fn waitPid(pid: Pid, block: bool) sys.WaitResult {
    if (comptime is_win) {
        const r = win.WaitForSingleObject(pid, if (block) 0xFFFFFFFF else 0);
        if (r != 0) return .none; // WAIT_OBJECT_0 only
        var code: u32 = 0;
        if (win.GetExitCodeProcess(pid, &code) == 0) return .none;
        // NTSTATUS-style codes (crashes, TerminateProcess(1)) have no signal;
        // report the low byte like a normal exit.
        return .{ .exited = @truncate(code) };
    }
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, if (block) 0 else 1); // WNOHANG = 1
        if (rc < 0) {
            if (c.errno(rc) == .INTR) continue;
            return .none;
        }
        if (rc == 0) return .none;
        const st: u32 = @bitCast(status);
        const sg: u32 = st & 0x7f;
        if (sg == 0) return .{ .exited = @truncate(st >> 8) };
        if (sg != 0x7f) return .{ .signaled = @intCast(sg) };
        return .none;
    }
}

/// Wait for a child and report its usage: GetProcessTimes and the peak
/// working set on Windows, wait4(2) on libc POSIX systems.
pub fn waitUsage(pid: Pid) sys.WaitUsage {
    var u: sys.Usage = .{};
    if (comptime is_win) {
        if (win.WaitForSingleObject(pid, 0xFFFFFFFF) != 0) return .{ .result = .none, .usage = u };
        defer _ = win.CloseHandle(pid);
        var code: u32 = 0;
        if (win.GetExitCodeProcess(pid, &code) == 0) return .{ .result = .none, .usage = u };
        var creation: u64 = 0;
        var exit: u64 = 0;
        var kernel: u64 = 0;
        var user: u64 = 0;
        if (win.GetProcessTimes(pid, &creation, &exit, &kernel, &user) != 0) {
            u.user_ns = user * 100; // FILETIME ticks are 100 ns
            u.sys_ns = kernel * 100;
        }
        var pmc: win.PROCESS_MEMORY_COUNTERS = std.mem.zeroes(win.PROCESS_MEMORY_COUNTERS);
        pmc.cb = @sizeOf(win.PROCESS_MEMORY_COUNTERS);
        if (win.K32GetProcessMemoryInfo(pid, &pmc, pmc.cb) != 0) {
            u.max_rss_kb = pmc.peak_working_set / 1024;
            u.minor_faults = pmc.page_fault_count;
        }
        return .{ .result = .{ .exited = @truncate(code) }, .usage = u };
    }
    var status: c_int = 0;
    var ru: c.rusage = std.mem.zeroes(c.rusage);
    while (true) {
        const rc = c.wait4(pid, &status, 0, &ru);
        if (rc < 0) {
            if (c.errno(rc) == .INTR) continue;
            return .{ .result = .none, .usage = u };
        }
        const st: u32 = @bitCast(status);
        const sg: u32 = st & 0x7f;
        const result: sys.WaitResult = if (sg == 0)
            .{ .exited = @truncate(st >> 8) }
        else if (sg != 0x7f)
            .{ .signaled = @intCast(sg) }
        else
            .none;
        const tvns = struct {
            fn f(t: c.timeval) u64 {
                return @as(u64, @intCast(@max(t.sec, 0))) * 1_000_000_000 + @as(u64, @intCast(@max(t.usec, 0))) * 1000;
            }
            fn n(v: isize) u64 {
                return @intCast(@max(v, 0));
            }
        };
        u = .{
            .user_ns = tvns.f(ru.utime),
            .sys_ns = tvns.f(ru.stime),
            // macOS reports bytes, the other systems kilobytes.
            .max_rss_kb = if (is_darwin) tvns.n(ru.maxrss) / 1024 else tvns.n(ru.maxrss),
            .minor_faults = tvns.n(ru.minflt),
            .major_faults = tvns.n(ru.majflt),
            .vol_switches = tvns.n(ru.nvcsw),
            .invol_switches = tvns.n(ru.nivcsw),
            .swaps = tvns.n(ru.nswap),
            .in_blocks = tvns.n(ru.inblock),
            .out_blocks = tvns.n(ru.oublock),
            .msgs_sent = tvns.n(ru.msgsnd),
            .msgs_received = tvns.n(ru.msgrcv),
            .signals = tvns.n(ru.nsignals),
        };
        return .{ .result = result, .usage = u };
    }
}

/// `timeout`'s event source. Windows: wait on the process handle. libc POSIX:
/// a kqueue watching process exit and the given signals.
pub const WatchState = struct {
    pid: Pid,
    kq: i32,
    pub const Event = sys.Watcher.Event;
};

pub fn watchInit(pid: Pid, signals: []const u8) ?WatchState {
    if (comptime is_win) return .{ .pid = pid, .kq = -1 };
    if (comptime !is_libc_posix) return null;
    // Block the signals so they are only seen through the kqueue.
    var set = std.posix.sigemptyset();
    for (signals) |s| std.posix.sigaddset(&set, @enumFromInt(s));
    _ = c.sigprocmask(c.SIG.BLOCK, &set, null);
    const kq = c.kqueue();
    if (kq < 0) return null;
    var changes: [16]c.Kevent = undefined;
    var n: usize = 0;
    changes[n] = .{ .ident = @intCast(pid), .filter = c.EVFILT.PROC, .flags = c.EV.ADD | c.EV.ENABLE, .fflags = c.NOTE.EXIT, .data = 0, .udata = 0 };
    n += 1;
    for (signals) |s| {
        if (n >= changes.len) break;
        changes[n] = .{ .ident = s, .filter = c.EVFILT.SIGNAL, .flags = c.EV.ADD | c.EV.ENABLE, .fflags = 0, .data = 0, .udata = 0 };
        n += 1;
    }
    const none: [0]c.Kevent = .{};
    if (c.kevent(kq, &changes, @intCast(n), &none, 0, null) < 0) {
        _ = c.close(kq);
        return null;
    }
    return .{ .pid = pid, .kq = kq };
}

pub fn watchWait(w: WatchState, timeout_ns: ?u64) sys.Watcher.Event {
    if (comptime is_win) {
        const ms: u32 = if (timeout_ns) |t| @intCast(@min((t + 999_999) / 1_000_000, 0xFFFFFFFE)) else 0xFFFFFFFF;
        return switch (win.WaitForSingleObject(w.pid, ms)) {
            0 => .child_exited,
            0x102 => .timeout,
            else => .failed,
        };
    }
    if (comptime !is_libc_posix) return .failed;
    var ts: c.timespec = undefined;
    var tsp: ?*const c.timespec = null;
    if (timeout_ns) |t| {
        ts = .{ .sec = @intCast(t / std.time.ns_per_s), .nsec = @intCast(t % std.time.ns_per_s) };
        tsp = &ts;
    }
    var out: [1]c.Kevent = undefined;
    const none: [0]c.Kevent = .{};
    while (true) {
        const n = c.kevent(w.kq, &none, 0, &out, 1, tsp);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return .failed;
        }
        if (n == 0) return .timeout;
        if (out[0].filter == c.EVFILT.SIGNAL) return .{ .signal = @intCast(out[0].ident) };
        return .child_exited;
    }
}

pub fn watchDeinit(w: WatchState) void {
    if (comptime is_libc_posix) _ = c.close(w.kq);
}

// ------------------------------------------------------------- file systems

pub fn statfs(path: []const u8, err: *E) ?sys.StatFs {
    if (comptime is_win) {
        var wbuf: [4097]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(wbuf[0..4096], path) catch {
            err.* = .NAMETOOLONG;
            return null;
        };
        wbuf[n] = 0;
        var avail: u64 = 0;
        var total: u64 = 0;
        var free: u64 = 0;
        if (win.GetDiskFreeSpaceExW(@ptrCast(&wbuf), &avail, &total, &free) == 0) {
            err.* = .NOENT;
            return null;
        }
        const bs: u64 = 4096;
        return .{ .type = 0, .bsize = bs, .blocks = total / bs, .bfree = free / bs, .bavail = avail / bs, .files = 0, .ffree = 0, .fsid = 0, .namelen = 255, .frsize = bs };
    }
    if (comptime !is_libc_posix) {
        err.* = .NOSYS;
        return null;
    }
    var b: [4097]u8 = undefined;
    const p = cstr(&b, path) orelse {
        err.* = .NAMETOOLONG;
        return null;
    };
    var raw: MacStatfs = undefined;
    if (cerr(c_statfs(p, &raw))) |e| {
        err.* = e;
        return null;
    }
    return .{
        .type = raw.f_type,
        .bsize = raw.f_bsize,
        .blocks = raw.f_blocks,
        .bfree = raw.f_bfree,
        .bavail = raw.f_bavail,
        .files = raw.f_files,
        .ffree = raw.f_ffree,
        .fsid = (@as(u64, @bitCast(@as(i64, raw.f_fsid[0]))) << 32) | @as(u32, @bitCast(raw.f_fsid[1])),
        .namelen = 255,
        .frsize = raw.f_bsize,
    };
}

/// struct statfs of macOS with 64-bit inodes.
const MacStatfs = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_reserved: [8]u32,
};

const c_statfs = if (is_libc_posix)
    @extern(*const fn ([*:0]const u8, *MacStatfs) callconv(.c) c_int, .{ .name = if (builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs" })
else
    undefined;

pub fn getXattr(path: []const u8, name: [:0]const u8, follow: bool, buf: []u8, err: *E) ?usize {
    _ = .{ path, name, follow, buf };
    err.* = .OPNOTSUPP; // no SELinux / xattr contexts here
    return null;
}

/// Directory entries through std.Io, with "." and ".." added (the Linux version
/// returns them from getdents). `dtype` uses the DT_* values.
pub fn readDirFd(gpa: std.mem.Allocator, fd: Handle, err: *E) ?[]sys.RawEntry {
    const dir = dirOf(fd);
    var list: std.ArrayList(sys.RawEntry) = .empty;
    const fail = struct {
        fn f(g: std.mem.Allocator, l: *std.ArrayList(sys.RawEntry), er: *E) ?[]sys.RawEntry {
            for (l.items) |x| g.free(x.name);
            l.deinit(g);
            er.* = .NOMEM;
            return null;
        }
    }.f;
    for ([_][]const u8{ ".", ".." }) |n| {
        const dup = gpa.dupe(u8, n) catch return fail(gpa, &list, err);
        list.append(gpa, .{ .name = dup, .dtype = 4 }) catch return fail(gpa, &list, err);
    }
    var it = dir.iterate();
    while (true) {
        const ent = (it.next(io()) catch |e| {
            for (list.items) |x| gpa.free(x.name);
            list.deinit(gpa);
            err.* = errFrom(e);
            return null;
        }) orelse break;
        const dup = gpa.dupe(u8, ent.name) catch return fail(gpa, &list, err);
        const dtype: u8 = switch (ent.kind) {
            .directory => 4,
            .file => 8,
            .sym_link => 10,
            .named_pipe => 1,
            .character_device => 2,
            .block_device => 6,
            .unix_domain_socket => 12,
            else => 0,
        };
        list.append(gpa, .{ .name = dup, .dtype = dtype, .ino = @intCast(ent.inode) }) catch return fail(gpa, &list, err);
    }
    return list.toOwnedSlice(gpa) catch fail(gpa, &list, err);
}
