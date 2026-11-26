// SPDX-License-Identifier: GPL-2.0-or-later
//! Operating-system facilities that std.Io (Zig 0.17.1) does not provide.
//!
//! The project does all file, stream, clock and process I/O through `std.Io`
//! (ai/AGENTS.md §13). The few things below have no std.Io equivalent in the
//! toolchain checked on 2026-11-07 (`~/.zvm/0.17.1/lib/std/Io*`): signal
//! dispositions, the umask, the terminal-size ioctl, probing whether a pid
//! exists, and opening a file with O_APPEND. They are collected here so that
//! (a) commands never touch std.posix / std.os directly, (b) each exception is
//! documented in one place, and (c) each can be replaced by a std.Io call as
//! soon as one exists.
//!
//! Platforms: the Linux implementations are in this file; every other
//! operating system (macOS, Windows) is served by `sys/other.zig`, which uses
//! std.Io where it can, libc (macOS) or kernel32 (Windows) otherwise, and
//! reports `E.NOSYS` / `E.OPNOTSUPP` for facilities that cannot exist there
//! (chroot, mknod, signals on Windows, ...). See docs/portability.md.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const is_linux = builtin.os.tag == .linux;
const other = @import("sys/other.zig");

/// Portable errno vocabulary (the Linux numbering and names). Other
/// operating systems map their error codes onto it.
pub const E = std.os.linux.E;

/// Operating-system file handle: a descriptor (i32) on POSIX systems, a HANDLE
/// on Windows. Always the type of `Io.File.handle`.
pub const Handle = Io.File.Handle;

/// Child process identifier as `std.process.Child.id`: a pid on POSIX
/// systems, the process HANDLE on Windows.
pub const Pid = std.process.Child.Id;

/// True where signals, process groups and descriptor juggling (nohup, env
/// signal options) exist.
pub const has_jobcontrol = builtin.os.tag != .windows;

/// The handle for descriptor number `fd` as a shell sees it (`test -t FD`):
/// any descriptor on POSIX systems, only 0, 1 and 2 on Windows.
pub fn handleFromFd(fd: i32) ?Handle {
    if (comptime builtin.os.tag != .windows) return fd;
    return switch (fd) {
        0 => Io.File.stdin().handle,
        1 => Io.File.stdout().handle,
        2 => Io.File.stderr().handle,
        else => null,
    };
}

/// A handle that refers to nothing (-1 on POSIX systems).
pub const invalid_handle: Handle = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

/// Permissions value for creating a file or directory with POSIX `mode`. On
/// Windows only the write bits matter (they select the read-only attribute).
pub fn permissionsFromMode(mode: u32) Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) {
        return if (mode & 0o222 == 0) @enumFromInt(1) else .default_file; // FILE_ATTRIBUTE_READONLY
    }
    return Io.File.Permissions.fromMode(@intCast(mode & 0o7777));
}

/// Signal numbers of the host (Linux numbering is used as the abstract
/// numbering on Windows, where signals do not exist).
pub const signo = if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) struct {
    pub const HUP: u8 = 1;
    pub const INT: u8 = 2;
    pub const QUIT: u8 = 3;
    pub const KILL: u8 = 9;
    pub const PIPE: u8 = 13;
    pub const ALRM: u8 = 14;
    pub const TERM: u8 = 15;
    pub const STOP: u8 = 17;
    pub const TSTP: u8 = 18;
    pub const CONT: u8 = 19;
} else struct {
    pub const HUP: u8 = 1;
    pub const INT: u8 = 2;
    pub const QUIT: u8 = 3;
    pub const KILL: u8 = 9;
    pub const PIPE: u8 = 13;
    pub const ALRM: u8 = 14;
    pub const TERM: u8 = 15;
    pub const STOP: u8 = 19;
    pub const TSTP: u8 = 20;
    pub const CONT: u8 = 18;
};

pub const Signal = enum { int, pipe };

fn posixSignal(sg: Signal) std.posix.SIG {
    return switch (sg) {
        .int => .INT,
        .pipe => .PIPE,
    };
}

fn setDisposition(sg: Signal, ignore: bool) void {
    if (comptime !is_linux) return other.setDisposition(sg == .pipe, ignore);
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = if (ignore) std.posix.SIG.IGN else std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(posixSignal(sg), &act, null);
}

/// Ignore `sig` for the rest of the process.
pub fn ignoreSignal(sg: Signal) void {
    setDisposition(sg, true);
}

/// Restore the default action of `sig`.
pub fn defaultSignal(sg: Signal) void {
    setDisposition(sg, false);
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
    return other.umask();
}

/// Width in columns of the terminal on standard output, or null when it is
/// not a terminal or the system cannot say.
pub fn terminalColumns() ?usize {
    if (comptime !is_linux) return other.terminalColumns();
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(1, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    return if (rc == 0 and ws.col > 0) ws.col else null;
}

/// The controlling terminal in raw mode (the built-in pager's input).
pub const Tty = @import("sys/tty.zig").Tty;
pub const TtySize = @import("sys/tty.zig").Size;

/// Windows: enable ANSI escapes and UTF-8 on the console. Elsewhere true.
pub fn enableAnsiOutput() bool {
    if (comptime is_linux) return true;
    return other.enableAnsiOutput();
}

/// True when process `pid` exists (kill(pid, 0)); EPERM counts as existing.
/// Always true where there is no kill(2).
pub fn processAlive(pid: i32) bool {
    if (comptime !is_linux) return other.processAlive(pid);
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |e| return e == error.PermissionDenied;
    return true;
}

/// Open `path` for appending, creating it if needed, with O_APPEND so that
/// concurrent writers do not overwrite each other. Io.Dir.createFile has no
/// append mode, and emulating it with a seek is not atomic.
pub fn openAppend(path: []const u8) !Io.File {
    if (comptime !is_linux) return other.openAppendMode(path, 0o666);
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o666);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

// ------------------------------------------------- process and host identity
// No std.Io API exists for these (identity, host name, CPU affinity, group
// list). Linux only; other systems report "unknown"/zero values.

pub const Identity = struct { uid: u32, euid: u32, gid: u32, egid: u32 };

pub fn identity() Identity {
    if (comptime !is_linux) return other.identity();
    return .{
        .uid = std.os.linux.getuid(),
        .euid = std.os.linux.geteuid(),
        .gid = std.os.linux.getgid(),
        .egid = std.os.linux.getegid(),
    };
}

/// Supplementary group ids of the calling process, in kernel order.
pub fn supplementaryGroups(buf: []u32) []u32 {
    if (comptime !is_linux) return other.supplementaryGroups(buf);
    const n = std.os.linux.getgroups(buf.len, @ptrCast(buf.ptr));
    if (@as(isize, @bitCast(n)) < 0) return buf[0..0];
    return buf[0..n];
}

/// uname(2) result. The strings are read from the stored buffers through
/// methods, so copying the struct never leaves a slice pointing at a dead frame.
pub const Uname = struct {
    raw: if (is_linux) std.os.linux.utsname else other.UnameBuf,

    pub fn sysname(u: *const Uname) []const u8 {
        if (comptime !is_linux) return u.raw.get(0);
        return std.mem.sliceTo(&u.raw.sysname, 0);
    }
    pub fn nodename(u: *const Uname) []const u8 {
        if (comptime !is_linux) return u.raw.get(1);
        return std.mem.sliceTo(&u.raw.nodename, 0);
    }
    pub fn release(u: *const Uname) []const u8 {
        if (comptime !is_linux) return u.raw.get(2);
        return std.mem.sliceTo(&u.raw.release, 0);
    }
    pub fn version(u: *const Uname) []const u8 {
        if (comptime !is_linux) return u.raw.get(3);
        return std.mem.sliceTo(&u.raw.version, 0);
    }
    pub fn machine(u: *const Uname) []const u8 {
        if (comptime !is_linux) return u.raw.get(4);
        return std.mem.sliceTo(&u.raw.machine, 0);
    }
};

pub fn uname() Uname {
    var u: Uname = undefined;
    if (comptime is_linux) {
        _ = std.os.linux.uname(&u.raw);
    } else u.raw = other.uname();
    return u;
}

/// Number of CPUs the process may run on (sched_getaffinity), or null.
pub fn affinityCpus() ?usize {
    if (comptime !is_linux) return null;
    const set = std.posix.sched_getaffinity(0) catch return null;
    var n: usize = 0;
    for (set) |w| n += @popCount(w);
    return n;
}

// ------------------------------------------------------------------- statx
// std.Io.File.Stat has no owner, device, block count or device numbers, which
// test, stat, ls, du, find and chown need. This is the Linux statx(2) result.

pub const FileStat = struct {
    mode: u32, // file type bits and permissions
    uid: u32,
    gid: u32,
    nlink: u32,
    ino: u64,
    size: u64,
    blocks: u64, // 512-byte units
    blksize: u32,
    dev_major: u32,
    dev_minor: u32,
    rdev_major: u32,
    rdev_minor: u32,
    atime_s: i64,
    atime_ns: u32,
    mtime_s: i64,
    mtime_ns: u32,
    ctime_s: i64,
    ctime_ns: u32,
    btime_s: i64,
    btime_ns: u32,
    has_btime: bool,

    pub fn isDir(s: FileStat) bool {
        return s.mode & 0o170000 == 0o040000;
    }
    pub fn isReg(s: FileStat) bool {
        return s.mode & 0o170000 == 0o100000;
    }
    pub fn isLink(s: FileStat) bool {
        return s.mode & 0o170000 == 0o120000;
    }
};

/// stat (follow = true) or lstat of `path`; null if the call fails. `err`
/// receives the error.
pub fn fileStat(path: []const u8, follow: bool, err: *E) ?FileStat {
    if (comptime !is_linux) return other.fileStat(path, follow, err);
    var buf: [4097]u8 = undefined;
    if (path.len >= 4096) {
        err.* = .NAMETOOLONG;
        return null;
    }
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const L = std.os.linux;
    var sx: L.Statx = undefined;
    var flags: u32 = L.AT.NO_AUTOMOUNT;
    if (!follow) flags |= L.AT.SYMLINK_NOFOLLOW;
    const rc = L.statx(L.AT.FDCWD, @ptrCast(&buf), flags, .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true, .ATIME = true, .MTIME = true, .CTIME = true, .INO = true, .SIZE = true, .BLOCKS = true, .BTIME = true }, &sx);
    const e = L.errno(rc);
    if (e != .SUCCESS) {
        err.* = e;
        return null;
    }
    return statxToFileStat(sx);
}

fn statxToFileStat(sx: std.os.linux.Statx) FileStat {
    return .{
        .mode = sx.mode,
        .uid = sx.uid,
        .gid = sx.gid,
        .nlink = sx.nlink,
        .ino = sx.ino,
        .size = sx.size,
        .blocks = sx.blocks,
        .blksize = sx.blksize,
        .dev_major = sx.dev_major,
        .dev_minor = sx.dev_minor,
        .rdev_major = sx.rdev_major,
        .rdev_minor = sx.rdev_minor,
        .atime_s = sx.atime.sec,
        .atime_ns = sx.atime.nsec,
        .mtime_s = sx.mtime.sec,
        .mtime_ns = sx.mtime.nsec,
        .ctime_s = sx.ctime.sec,
        .ctime_ns = sx.ctime.nsec,
        .btime_s = sx.btime.sec,
        .btime_ns = sx.btime.nsec,
        .has_btime = sx.mask.BTIME,
    };
}

/// strerror-style text for a Linux errno.
pub fn errnoText(e: E) []const u8 {
    return switch (e) {
        .NOENT => "No such file or directory",
        .ACCES => "Permission denied",
        .PERM => "Operation not permitted",
        .NOTDIR => "Not a directory",
        .LOOP => "Too many levels of symbolic links",
        .NAMETOOLONG => "File name too long",
        .ISDIR => "Is a directory",
        .NOMEM => "Cannot allocate memory",
        .IO => "Input/output error",
        .INVAL => "Invalid argument",
        .EXIST => "File exists",
        .NOTEMPTY => "Directory not empty",
        .XDEV => "Invalid cross-device link",
        .ROFS => "Read-only file system",
        .NOSPC => "No space left on device",
        .BUSY => "Device or resource busy",
        .MLINK => "Too many links",
        .FBIG => "File too large",
        .TXTBSY => "Text file busy",
        .OVERFLOW => "Value too large for defined data type",
        .NODATA => "No data available",
        .BADF => "Bad file descriptor",
        .FAULT => "Bad address",
        .PIPE => "Broken pipe",
        .RANGE => "Numerical result out of range",
        .DOM => "Numerical argument out of domain",
        .AGAIN => "Resource temporarily unavailable",
        .INTR => "Interrupted system call",
        .NOSYS => "Function not implemented",
        .NXIO => "No such device or address",
        .NODEV => "No such device",
        .NOTTY => "Inappropriate ioctl for device",
        .SRCH => "No such process",
        .CHILD => "No child processes",
        .NFILE => "Too many open files in system",
        .MFILE => "Too many open files",
        .SPIPE => "Illegal seek",
        .DQUOT => "Disk quota exceeded",
        .STALE => "Stale file handle",
        .OPNOTSUPP => "Operation not supported",
        else => @tagName(e),
    };
}

/// Monotonic clock in nanoseconds (for elapsed-time measurements only).
pub fn monotonicNs() i128 {
    if (comptime !is_linux) return other.monotonicNs();
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

// ----------------------------------------------------------------- signals
// Signal names and dispositions by number, for env, nohup, timeout and kill.
// std.Io has no signal API (see docs/decisions/0002-std-io-exceptions.md).

/// Names of signals 1..31 on Linux (generic architectures), without "SIG".
pub const signal_names = if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) [_][]const u8{
    "HUP",  "INT",  "QUIT", "ILL",   "TRAP", "ABRT",  "EMT", "FPE",
    "KILL", "BUS",  "SEGV", "SYS",   "PIPE", "ALRM",  "TERM", "URG",
    "STOP", "TSTP", "CONT", "CHLD",  "TTIN", "TTOU",  "IO",  "XCPU",
    "XFSZ", "VTALRM", "PROF", "WINCH", "INFO", "USR1", "USR2",
} else [_][]const u8{
    "HUP",  "INT",  "QUIT", "ILL",   "TRAP", "ABRT",   "BUS", "FPE",
    "KILL", "USR1", "SEGV", "USR2",  "PIPE", "ALRM",   "TERM", "STKFLT",
    "CHLD", "CONT", "STOP", "TSTP",  "TTIN", "TTOU",   "URG", "XCPU",
    "XFSZ", "VTALRM", "PROF", "WINCH", "POLL", "PWR",  "SYS",
};

/// Name of signal `n` (1..64, not 32/33 which libc reserves): the table above
/// or RTMIN+k / RTMAX-k for real-time signals. `buf` holds the formatted name.
pub fn signalName(n: u8, buf: *[16]u8) ?[]const u8 {
    if (n >= 1 and n <= 31) return signal_names[n - 1];
    if (!is_linux or n < 34 or n > 64) return null;
    if (n == 34) return "RTMIN";
    if (n == 64) return "RTMAX";
    if (n <= 49) return std.fmt.bufPrint(buf, "RTMIN+{d}", .{n - 34}) catch null;
    return std.fmt.bufPrint(buf, "RTMAX-{d}", .{64 - n}) catch null;
}

/// Signal number for a name ("INT", "SIGINT", case-insensitive) or a decimal
/// number; null if unknown. "IO" is accepted as an alias of POLL.
pub fn signalNumber(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    if (std.ascii.isDigit(text[0])) {
        const n = std.fmt.parseInt(u8, text, 10) catch return null;
        return if (n <= 64) n else null;
    }
    var name = text;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) name = name[3..];
    if (is_linux and std.ascii.eqlIgnoreCase(name, "IO")) return 29;
    if (std.ascii.eqlIgnoreCase(name, "CLD")) name = "CHLD";
    for (signal_names, 1..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return @intCast(i);
    var n: u8 = 34;
    while (is_linux and n <= 64) : (n += 1) {
        var buf: [16]u8 = undefined;
        if (signalName(n, &buf)) |nm| if (std.ascii.eqlIgnoreCase(nm, name)) return n;
    }
    return null;
}

pub const Disposition = enum { default, ignore, block };

/// Set the action for signal `num` (1..64) in this process; it is inherited
/// across exec, which is how `env` and `nohup` use it.
pub fn setSignal(num: u8, d: Disposition) bool {
    if (comptime !is_linux) return other.setSignal(num, d);
    const L = std.os.linux;
    const sig: L.SIG = @enumFromInt(num);
    // KILL and STOP can be blocked (silently ineffective) but not caught or ignored.
    if ((num == 9 or num == 19) and d != .block) return false;
    switch (d) {
        .block => {
            var set = L.sigemptyset();
            L.sigaddset(&set, sig);
            _ = L.sigprocmask(L.SIG.BLOCK, &set, null);
            return true;
        },
        .default, .ignore => {
            const act: L.Sigaction = .{
                .handler = .{ .handler = if (d == .ignore) L.SIG.IGN else L.SIG.DFL },
                .mask = L.sigemptyset(),
                .flags = 0,
            };
            return L.errno(L.sigaction(sig, &act, null)) == .SUCCESS;
        },
    }
}

/// Unblock signal `num` (used before running a child that should see it).
pub fn unblockSignal(num: u8) void {
    if (comptime !is_linux) return other.unblockSignal(num);
    const L = std.os.linux;
    var set = L.sigemptyset();
    L.sigaddset(&set, @enumFromInt(num));
    _ = L.sigprocmask(L.SIG.UNBLOCK, &set, null);
}

/// Current action of signal `num`: .ignore, .default, or null when a handler
/// is installed (or on error). Also reports whether it is blocked.
pub const SignalState = struct { disp: ?Disposition, blocked: bool };
pub fn signalState(num: u8) SignalState {
    if (comptime !is_linux) return other.signalState(num);
    const L = std.os.linux;
    const sig: L.SIG = @enumFromInt(num);
    if (num == 9 or num == 19) return .{ .disp = .default, .blocked = false };
    var old: L.Sigaction = undefined;
    _ = L.sigaction(sig, null, &old);
    var cur: L.sigset_t = undefined;
    _ = L.sigprocmask(L.SIG.BLOCK, null, &cur);
    const blocked = L.sigismember(&cur, sig);
    const h = old.handler.handler;
    const d: ?Disposition = if (h == L.SIG.IGN) .ignore else if (h == L.SIG.DFL or h == null) .default else null;
    return .{ .disp = d, .blocked = blocked };
}

/// kill(2): send `sig` to `pid`. Returns the errno on failure. On Windows the
/// process handle is terminated for any signal but 0 (the only thing a signal
/// can mean there).
pub fn sendSignal(pid: Pid, sig: u8) ?E {
    if (comptime !is_linux) return other.sendSignal(pid, sig);
    const rc = std.os.linux.kill(pid, @enumFromInt(sig));
    const e = std.os.linux.errno(rc);
    return if (e == .SUCCESS) null else e;
}

/// kill(0, sig): signal every process of our own process group.
pub fn signalOwnGroup(sig: u8) ?E {
    if (comptime !is_linux) return other.signalOwnGroup(sig);
    const rc = std.os.linux.kill(0, @enumFromInt(sig));
    const e = std.os.linux.errno(rc);
    return if (e == .SUCCESS) null else e;
}

/// Send `sig` to this process itself.
pub fn raiseSelf(sig: u8) ?E {
    if (comptime !is_linux) return other.raiseSelf(sig);
    const rc = std.os.linux.kill(@intCast(std.os.linux.getpid()), @enumFromInt(sig));
    const e = std.os.linux.errno(rc);
    return if (e == .SUCCESS) null else e;
}

// ------------------------------------------------- processes and descriptors
// Linux system calls used by nohup, nice, timeout, sync, chroot, mkfifo and
// mknod; none has a std.Io equivalent.

const LX = std.os.linux;

fn errOf(rc: usize) ?LX.E {
    const e = LX.errno(rc);
    return if (e == .SUCCESS) null else e;
}

/// dup2(2).
pub fn dup2(old: Handle, new: i32) ?LX.E {
    if (comptime !is_linux) return other.dup2(old, new);
    return errOf(LX.dup2(old, new));
}

/// True when descriptor `fd` is open (fcntl F_GETFD succeeds).
pub fn fdOpen(fd: i32) bool {
    if (comptime !is_linux) return other.fdOpen(fd);
    return LX.errno(LX.fcntl(fd, LX.F.GETFD, 0)) == .SUCCESS;
}

/// Open `path` for appending, creating it with `mode` if needed.
pub fn openAppendMode(path: []const u8, mode: u32) !Io.File {
    if (comptime !is_linux) return other.openAppendMode(path, mode);
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, mode);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Scheduling priority ("niceness") of this process, -20..19.
pub fn getNice() i32 {
    if (comptime !is_linux) return other.getNice();
    // The raw syscall returns 20 - nice.
    const rc = LX.syscall2(.getpriority, 0, 0);
    return 20 - @as(i32, @intCast(@as(isize, @bitCast(rc))));
}

/// setpriority(PRIO_PROCESS, 0, nice).
pub fn setNice(value: i32) ?LX.E {
    if (comptime !is_linux) return other.setNice(value);
    return errOf(LX.syscall3(.setpriority, 0, 0, @bitCast(@as(isize, value))));
}

/// Make this process a process-group leader (setpgid(0, 0)).
pub fn becomeGroupLeader() void {
    if (comptime !is_linux) return other.becomeGroupLeader();
    _ = LX.syscall2(.setpgid, 0, 0);
}

/// chroot(2).
pub fn chroot(path: [:0]const u8) ?LX.E {
    if (comptime !is_linux) return other.chrootPath(path);
    return errOf(LX.chroot(path.ptr));
}

/// sync(2), fsync(2), fdatasync(2) and syncfs(2) on an open descriptor.
pub const SyncKind = enum { all, data, file, fs };
pub fn syncFile(fd: Handle, kind: SyncKind) ?LX.E {
    if (comptime !is_linux) return other.syncFile(fd, kind);
    return switch (kind) {
        .all => blk: {
            LX.sync();
            break :blk null;
        },
        .data => errOf(LX.fdatasync(fd)),
        .file => errOf(LX.fsync(fd)),
        .fs => errOf(LX.syncfs(fd)),
    };
}

/// mknodat(2) relative to the working directory; `mode` includes the file
/// type bits (S_IFIFO, S_IFCHR, ...) and `dev` is makedev(major, minor).
pub fn mknod(path: [:0]const u8, mode: u32, dev: u64) ?LX.E {
    if (comptime !is_linux) return other.mknodPath(path, mode, dev);
    return errOf(LX.mknodat(LX.AT.FDCWD, path.ptr, mode, @intCast(dev)));
}

/// Result of waiting for a child.
pub const WaitResult = union(enum) { exited: u8, signaled: u8, none };

/// waitpid(pid, WNOHANG or blocking).
pub fn waitPid(pid: Pid, block: bool) WaitResult {
    if (comptime !is_linux) return other.waitPid(pid, block);
    var status: i32 = 0;
    while (true) {
        const rc = LX.waitpid(pid, &status, if (block) 0 else LX.W.NOHANG);
        switch (LX.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return .none,
        }
        if (rc == 0) return .none;
        const st: u32 = @bitCast(status);
        if (LX.W.IFEXITED(st)) return .{ .exited = LX.W.EXITSTATUS(st) };
        if (LX.W.IFSIGNALED(st)) return .{ .signaled = @intCast(@intFromEnum(LX.W.TERMSIG(st))) };
        return .none;
    }
}

/// Resources a finished child used (the fields of getrusage(2), in common
/// units). Fields a platform cannot report stay 0.
pub const Usage = struct {
    user_ns: u64 = 0,
    sys_ns: u64 = 0,
    max_rss_kb: u64 = 0,
    minor_faults: u64 = 0,
    major_faults: u64 = 0,
    vol_switches: u64 = 0,
    invol_switches: u64 = 0,
    swaps: u64 = 0,
    in_blocks: u64 = 0,
    out_blocks: u64 = 0,
    msgs_sent: u64 = 0,
    msgs_received: u64 = 0,
    signals: u64 = 0,
};

pub const WaitUsage = struct { result: WaitResult, usage: Usage };

/// Block until child `pid` ends and return how it ended with its resource
/// usage (wait4(2); GetProcessTimes on Windows, where the process handle is
/// closed). Only for a child the caller started and has not waited for.
pub fn waitUsage(pid: Pid) WaitUsage {
    if (comptime !is_linux) return other.waitUsage(pid);
    var status: i32 = 0;
    var ru: LX.rusage = std.mem.zeroes(LX.rusage);
    while (true) {
        const rc = LX.wait4(pid, &status, 0, &ru);
        switch (LX.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return .{ .result = .none, .usage = .{} },
        }
        const st: u32 = @bitCast(status);
        const result: WaitResult = if (LX.W.IFEXITED(st))
            .{ .exited = LX.W.EXITSTATUS(st) }
        else if (LX.W.IFSIGNALED(st))
            .{ .signaled = @intCast(@intFromEnum(LX.W.TERMSIG(st))) }
        else
            .none;
        const tv = struct {
            fn ns(t: LX.timeval) u64 {
                return @as(u64, @intCast(@max(t.sec, 0))) * 1_000_000_000 + @as(u64, @intCast(@max(t.usec, 0))) * 1000;
            }
            fn u(v: isize) u64 {
                return @intCast(@max(v, 0));
            }
        };
        return .{ .result = result, .usage = .{
            .user_ns = tv.ns(ru.utime),
            .sys_ns = tv.ns(ru.stime),
            .max_rss_kb = tv.u(ru.maxrss),
            .minor_faults = tv.u(ru.minflt),
            .major_faults = tv.u(ru.majflt),
            .vol_switches = tv.u(ru.nvcsw),
            .invol_switches = tv.u(ru.nivcsw),
            .swaps = tv.u(ru.nswap),
            .in_blocks = tv.u(ru.inblock),
            .out_blocks = tv.u(ru.oublock),
            .msgs_sent = tv.u(ru.msgsnd),
            .msgs_received = tv.u(ru.msgrcv),
            .signals = tv.u(ru.nsignals),
        } };
    }
}

/// Hardware counters (Linux perf_event_open), the way poop and crap use them:
/// opened before a child is started, they stay off until that child execs
/// (`enable_on_exec`, inherited), so only the command is counted. One set per
/// run: `open`, start the child, `read`, `close`. Any counter the kernel or
/// CPU refuses (perf_event_paranoid, virtual machines, other systems) is null.
pub const Perf = struct {
    pub const Kind = enum { cycles, instructions, cache_references, cache_misses, branch_misses };
    pub const count = 5;
    pub const Sample = [count]?u64;

    fds: [count]i32 = @splat(-1),

    pub fn open() Perf {
        var p: Perf = .{};
        if (comptime !is_linux) return p;
        const hw = LX.PERF.COUNT.HW;
        const cfg = [count]hw{ .CPU_CYCLES, .INSTRUCTIONS, .CACHE_REFERENCES, .CACHE_MISSES, .BRANCH_MISSES };
        for (cfg, 0..) |c, i| {
            if (i > 0 and p.fds[0] < 0) break; // no group leader
            var attr: LX.perf_event_attr = .{
                .type = .HARDWARE,
                .config = @intFromEnum(c),
                .flags = .{ .disabled = true, .inherit = true, .exclude_kernel = true, .exclude_hv = true, .enable_on_exec = true },
            };
            const leader: i32 = if (i == 0) -1 else p.fds[0];
            const rc = LX.perf_event_open(&attr, 0, -1, leader, 8); // PERF_FLAG_FD_CLOEXEC
            if (LX.errno(rc) == .SUCCESS) p.fds[i] = @intCast(rc);
        }
        if (p.fds[0] >= 0) {
            _ = LX.ioctl(p.fds[0], 0x2401, 1); // PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP
            _ = LX.ioctl(p.fds[0], 0x2403, 1); // PERF_EVENT_IOC_RESET
        }
        return p;
    }

    pub fn available(p: Perf) bool {
        return p.fds[0] >= 0;
    }

    /// True when counters can be opened at all (a probe that opens and closes).
    pub fn probe() bool {
        var p = open();
        defer p.close();
        return p.available();
    }

    /// Counts so far; call after the child ended.
    pub fn read(p: Perf) Sample {
        var out: Sample = @splat(null);
        if (comptime !is_linux) return out;
        for (p.fds, 0..) |fd, i| if (fd >= 0) {
            var v: u64 = 0;
            const n = LX.read(fd, @ptrCast(&v), 8);
            if (LX.errno(n) == .SUCCESS and n == 8) out[i] = v;
        };
        return out;
    }

    pub fn close(p: *Perf) void {
        if (comptime !is_linux) return;
        for (&p.fds) |*fd| if (fd.* >= 0) {
            _ = LX.close(fd.*);
            fd.* = -1;
        };
    }
};

/// An event source for `timeout`: waits until the child exits, a watched
/// signal arrives, or the timeout passes. Signals are received through a
/// signalfd so no handler (and no async-signal-safety concern) is needed.
pub const Watcher = struct {
    pidfd: i32,
    sigfd: i32,
    /// State of the non-Linux implementations (sys/other.zig).
    extra: if (is_linux) void else other.WatchState = if (is_linux) {} else undefined,

    pub const Event = union(enum) { child_exited, signal: u8, timeout, failed };

    /// Block `signals` and open descriptors for `pid` and for those signals.
    pub fn init(pid: Pid, signals: []const u8) ?Watcher {
        if (comptime !is_linux) {
            const st = other.watchInit(pid, signals) orelse return null;
            return .{ .pidfd = -1, .sigfd = -1, .extra = st };
        }
        var set = LX.sigemptyset();
        for (signals) |s| LX.sigaddset(&set, @enumFromInt(s));
        _ = LX.sigprocmask(LX.SIG.BLOCK, &set, null);
        const sfd = LX.signalfd(-1, &set, LX.SFD.CLOEXEC);
        if (LX.errno(sfd) != .SUCCESS) return null;
        const pfd = LX.syscall2(.pidfd_open, @intCast(pid), 0);
        if (LX.errno(pfd) != .SUCCESS) return null;
        return .{ .pidfd = @intCast(pfd), .sigfd = @intCast(sfd), .extra = {} };
    }

    /// Wait up to `timeout_ns` (null = forever).
    pub fn wait(w: Watcher, timeout_ns: ?u64) Event {
        if (comptime !is_linux) return other.watchWait(w.extra, timeout_ns);
        var fds = [_]LX.pollfd{
            .{ .fd = w.pidfd, .events = LX.POLL.IN, .revents = 0 },
            .{ .fd = w.sigfd, .events = LX.POLL.IN, .revents = 0 },
        };
        while (true) {
            var ts: LX.timespec = undefined;
            var tsp: ?*LX.timespec = null;
            if (timeout_ns) |t| {
                ts = .{ .sec = @intCast(t / std.time.ns_per_s), .nsec = @intCast(t % std.time.ns_per_s) };
                tsp = &ts;
            }
            const rc = LX.ppoll(&fds, fds.len, tsp, null);
            switch (LX.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return .failed,
            }
            if (rc == 0) return .timeout;
            if (fds[1].revents & LX.POLL.IN != 0) {
                var info: LX.signalfd_siginfo = undefined;
                const n = LX.read(w.sigfd, @ptrCast(&info), @sizeOf(LX.signalfd_siginfo));
                if (LX.errno(n) == .SUCCESS and n == @sizeOf(LX.signalfd_siginfo)) return .{ .signal = @intCast(info.signo) };
            }
            if (fds[0].revents & LX.POLL.IN != 0) return .child_exited;
        }
    }

    pub fn deinit(w: Watcher) void {
        if (comptime !is_linux) return other.watchDeinit(w.extra);
        _ = LX.close(w.pidfd);
        _ = LX.close(w.sigfd);
    }
};

// ------------------------------------------------------------- the clock

/// clock_settime(CLOCK_REALTIME); needs CAP_SYS_TIME.
pub fn setRealtime(sec: i64, nsec: u32) ?LX.E {
    if (comptime !is_linux) return other.setRealtime(sec, nsec);
    const ts: LX.timespec = .{ .sec = sec, .nsec = nsec };
    return errOf(LX.clock_settime(.REALTIME, &ts));
}

// ------------------------------------------------------------ file times

pub const TimeSpec = struct {
    sec: i64 = 0,
    nsec: i64 = 0,
    /// UTIME_NOW / UTIME_OMIT are encoded in nsec as in utimensat(2).
    pub const now_ns: i64 = (1 << 30) - 1;
    pub const omit_ns: i64 = (1 << 30) - 2;
};

/// utimensat(2) on `path` (cwd-relative), or futimens on `fd` when path is
/// null. `times` null means "now" for both. Returns the errno on failure.
pub fn setTimes(path: ?[]const u8, fd: Handle, times: ?[2]TimeSpec, nofollow: bool) ?LX.E {
    if (comptime !is_linux) return other.setTimes(path, fd, times, nofollow);
    var ts: [2]LX.timespec = undefined;
    var tp: ?*[2]LX.timespec = null;
    if (times) |t| {
        for (0..2) |i| ts[i] = .{ .sec = t[i].sec, .nsec = t[i].nsec };
        tp = &ts;
    }
    var buf: [4097]u8 = undefined;
    if (path) |p| {
        if (p.len >= 4096) return .NAMETOOLONG;
        @memcpy(buf[0..p.len], p);
        buf[p.len] = 0;
        const flags: u32 = if (nofollow) LX.AT.SYMLINK_NOFOLLOW else 0;
        return errOf(LX.utimensat(LX.AT.FDCWD, @ptrCast(&buf), tp, flags));
    }
    return errOf(LX.utimensat(fd, null, tp, 0));
}

/// fchownat(2) on `path` (cwd-relative); uid or gid == maxInt(u32) leaves
/// that id unchanged. `nofollow` changes a symbolic link itself.
pub fn chownAt(path: []const u8, uid: u32, gid: u32, nofollow: bool) ?LX.E {
    if (comptime !is_linux) return other.chownAt(path, uid, gid, nofollow);
    var buf: [4097]u8 = undefined;
    if (path.len >= 4096) return .NAMETOOLONG;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const flags: u32 = if (nofollow) LX.AT.SYMLINK_NOFOLLOW else 0;
    return errOf(LX.fchownat(LX.AT.FDCWD, @ptrCast(&buf), uid, gid, flags));
}

// ------------------------------------------------ file systems and xattrs

pub const StatFs = struct {
    type: u64,
    bsize: u64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: u64,
    namelen: u64,
    frsize: u64,
};

/// statfs(2) of `path`; `err` receives the errno on failure.
pub fn statfs(path: []const u8, err: *LX.E) ?StatFs {
    if (comptime !is_linux) return other.statfs(path, err);
    var buf: [4097]u8 = undefined;
    if (path.len >= 4096) {
        err.* = .NAMETOOLONG;
        return null;
    }
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var raw: [15]u64 = undefined;
    const rc = LX.syscall2(.statfs, @intFromPtr(&buf), @intFromPtr(&raw));
    if (LX.errno(rc) != .SUCCESS) {
        err.* = LX.errno(rc);
        return null;
    }
    // struct statfs on x86_64: f_type f_bsize f_blocks f_bfree f_bavail f_files
    // f_ffree f_fsid[2] f_namelen f_frsize f_flags f_spare[4]
    const fsid_lo: u64 = raw[7] & 0xffffffff;
    const fsid_hi: u64 = raw[7] >> 32;
    return .{
        .type = raw[0], .bsize = raw[1], .blocks = raw[2], .bfree = raw[3], .bavail = raw[4],
        .files = raw[5], .ffree = raw[6], .fsid = (fsid_lo << 32) | fsid_hi,
        .namelen = raw[8], .frsize = raw[9],
    };
}

/// getxattr(2)/lgetxattr(2) into `buf`; returns the value length.
pub fn getXattr(path: []const u8, name: [:0]const u8, follow: bool, buf: []u8, err: *LX.E) ?usize {
    if (comptime !is_linux) return other.getXattr(path, name, follow, buf, err);
    var pbuf: [4097]u8 = undefined;
    if (path.len >= 4096) {
        err.* = .NAMETOOLONG;
        return null;
    }
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const rc = LX.syscall4(if (follow) .getxattr else .lgetxattr, @intFromPtr(&pbuf), @intFromPtr(name.ptr), @intFromPtr(buf.ptr), buf.len);
    if (LX.errno(rc) != .SUCCESS) {
        err.* = LX.errno(rc);
        return null;
    }
    return rc;
}

// ------------------------------------------------ errno-faithful file calls
// cp, mv and install must report the exact strerror text of the failing call
// (and use O_EXCL, O_NOFOLLOW, renameat2 and similar flags), which the error
// sets of std.Io.Dir do not preserve. These wrappers return the errno.

/// NUL-terminated copy of `path` in `buf`.
fn cstr(buf: *[4097]u8, path: []const u8) ?[*:0]const u8 {
    if (path.len >= 4096) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

pub const O = struct {
    pub const RDONLY: u32 = 0;
    pub const WRONLY: u32 = 1;
    pub const RDWR: u32 = 2;
    pub const CREAT: u32 = 0o100;
    pub const EXCL: u32 = 0o200;
    pub const NOCTTY: u32 = 0o400;
    pub const TRUNC: u32 = 0o1000;
    pub const NONBLOCK: u32 = 0o4000;
    pub const DIRECTORY: u32 = 0o200000;
    pub const NOFOLLOW: u32 = 0o400000;
    pub const CLOEXEC: u32 = 0o2000000;
};

/// openat(AT_FDCWD, path, flags | O_CLOEXEC, mode).
pub fn openFd(path: []const u8, flags: u32, mode: u32, err: *LX.E) ?Handle {
    if (comptime !is_linux) return other.openFd(path, flags, mode, err);
    var b: [4097]u8 = undefined;
    const p = cstr(&b, path) orelse {
        err.* = .NAMETOOLONG;
        return null;
    };
    const rc = LX.syscall4(.openat, @bitCast(@as(isize, LX.AT.FDCWD)), @intFromPtr(p), flags | O.CLOEXEC, mode);
    const e = LX.errno(rc);
    if (e != .SUCCESS) {
        err.* = e;
        return null;
    }
    return @intCast(rc);
}

/// One directory entry as the kernel returns it.
pub const RawEntry = struct { name: []u8, dtype: u8, ino: u64 = 0 };

/// Free a list returned by `readDirRaw` or `readDirNames`.
pub fn freeDirEntries(gpa: std.mem.Allocator, entries: []RawEntry) void {
    for (entries) |entry| gpa.free(entry.name);
    gpa.free(entries);
}

/// `readDirRaw` without "." and "..". The list is complete or the call fails:
/// a walk that copies or removes must never mistake a read error for the end
/// of the directory.
pub fn readDirNames(gpa: std.mem.Allocator, path: []const u8, err: *LX.E) ?[]RawEntry {
    const all = readDirRaw(gpa, path, err) orelse return null;
    var kept: usize = 0;
    for (all) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            gpa.free(entry.name);
            continue;
        }
        all[kept] = entry;
        kept += 1;
    }
    var list: std.ArrayList(RawEntry) = .fromOwnedSlice(all);
    list.shrinkRetainingCapacity(kept);
    return list.toOwnedSlice(gpa) catch {
        for (list.items) |entry| gpa.free(entry.name);
        list.deinit(gpa);
        err.* = .NOMEM;
        return null;
    };
}

/// All entries of the directory `path` in readdir order, including "." and
/// ".." (std.Io hides them). Names are allocated with `gpa`.
pub fn readDirRaw(gpa: std.mem.Allocator, path: []const u8, err: *LX.E) ?[]RawEntry {
    if (comptime !is_linux) return other.readDirRaw(gpa, path, err);
    const fd = openFd(path, O.RDONLY | O.DIRECTORY, 0, err) orelse return null;
    defer _ = closeFd(fd);
    var list: std.ArrayList(RawEntry) = .empty;
    // Whatever has not been handed to the caller (every failure path).
    defer {
        for (list.items) |x| gpa.free(x.name);
        list.deinit(gpa);
    }
    var buf: [32768]u8 align(8) = undefined;
    while (true) {
        const rc = LX.syscall3(.getdents64, @bitCast(@as(isize, fd)), @intFromPtr(&buf), buf.len);
        const e = LX.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) {
            err.* = e;
            return null;
        }
        if (rc == 0) break;
        var off: usize = 0;
        while (off < rc) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], .little);
            const dtype = buf[off + 18];
            const nm = std.mem.sliceTo(buf[off + 19 .. off + reclen], 0);
            const dup = gpa.dupe(u8, nm) catch {
                err.* = .NOMEM;
                return null;
            };
            const ino = std.mem.readInt(u64, buf[off..][0..8], .little);
            list.append(gpa, .{ .name = dup, .dtype = dtype, .ino = ino }) catch {
                gpa.free(dup);
                err.* = .NOMEM;
                return null;
            };
            off += reclen;
        }
    }
    return list.toOwnedSlice(gpa) catch {
        err.* = .NOMEM;
        return null;
    };
}

pub fn closeFd(fd: Handle) ?LX.E {
    if (comptime !is_linux) return other.closeFd(fd);
    return errOf(LX.close(fd));
}

/// read(2); returns the byte count (0 at end of file).
pub fn readFd(fd: Handle, buf: []u8, err: *LX.E) ?usize {
    if (comptime !is_linux) return other.readFd(fd, buf, err);
    while (true) {
        const rc = LX.read(fd, buf.ptr, buf.len);
        const e = LX.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) {
            err.* = e;
            return null;
        }
        return rc;
    }
}

/// `readFd` that also returns when a caught signal interrupts it (.INTR), so
/// the caller can act on the signal before reading again.
pub fn readFdInterruptible(fd: Handle, buf: []u8, err: *LX.E) ?usize {
    if (comptime !is_linux) return other.readFd(fd, buf, err);
    const rc = LX.read(fd, buf.ptr, buf.len);
    const e = LX.errno(rc);
    if (e != .SUCCESS) {
        err.* = e;
        return null;
    }
    return rc;
}

/// `writeFd` that also returns .INTR, like `readFdInterruptible`.
pub fn writeFdInterruptible(fd: Handle, bytes: []const u8, err: *LX.E) ?usize {
    if (comptime !is_linux) return other.writeFd(fd, bytes, err);
    const rc = LX.write(fd, bytes.ptr, bytes.len);
    const e = LX.errno(rc);
    if (e != .SUCCESS) {
        err.* = e;
        return null;
    }
    return rc;
}

/// One write(2); returns the byte count written.
pub fn writeFd(fd: Handle, bytes: []const u8, err: *LX.E) ?usize {
    if (comptime !is_linux) return other.writeFd(fd, bytes, err);
    while (true) {
        const rc = LX.write(fd, bytes.ptr, bytes.len);
        const e = LX.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) {
            err.* = e;
            return null;
        }
        return rc;
    }
}

/// fcntl(F_GETFL): the file status flags (O_APPEND, O_DIRECT, ...). Systems
/// without them report 0.
pub fn getStatusFlags(fd: Handle, err: *LX.E) ?usize {
    if (comptime !is_linux) return 0;
    const rc = LX.fcntl(fd, LX.F.GETFL, 0);
    const e = LX.errno(rc);
    if (e != .SUCCESS) {
        err.* = e;
        return null;
    }
    return rc;
}

/// fcntl(F_SETFL).
pub fn setStatusFlags(fd: Handle, flags: usize) ?LX.E {
    if (comptime !is_linux) return null;
    return errOf(LX.fcntl(fd, LX.F.SETFL, flags));
}

/// Write all of `bytes`.
pub fn writeAllFd(fd: Handle, bytes: []const u8) ?LX.E {
    if (comptime !is_linux) return other.writeAllFd(fd, bytes);
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = LX.write(fd, bytes.ptr + off, bytes.len - off);
        const e = LX.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return e;
        off += rc;
    }
    return null;
}

pub fn mkdirPath(path: []const u8, mode: u32) ?LX.E {
    if (comptime !is_linux) return other.mkdirPath(path, mode);
    var b: [4097]u8 = undefined;
    const p = cstr(&b, path) orelse return .NAMETOOLONG;
    return errOf(LX.mkdirat(LX.AT.FDCWD, p, mode));
}

/// unlinkat(AT_FDCWD, path, removedir ? AT_REMOVEDIR : 0).
pub fn unlinkPath(path: []const u8, removedir: bool) ?LX.E {
    if (comptime !is_linux) return other.unlinkPath(path, removedir);
    var b: [4097]u8 = undefined;
    const p = cstr(&b, path) orelse return .NAMETOOLONG;
    return errOf(LX.unlinkat(LX.AT.FDCWD, p, if (removedir) LX.AT.REMOVEDIR else 0));
}

pub const RENAME_NOREPLACE: u32 = 1;
pub const RENAME_EXCHANGE: u32 = 2;

pub fn renamePath(old: []const u8, new: []const u8, flags: u32) ?LX.E {
    if (comptime !is_linux) return other.renamePath(old, new, flags);
    var b1: [4097]u8 = undefined;
    var b2: [4097]u8 = undefined;
    const p1 = cstr(&b1, old) orelse return .NAMETOOLONG;
    const p2 = cstr(&b2, new) orelse return .NAMETOOLONG;
    return errOf(LX.syscall5(.renameat2, @bitCast(@as(isize, LX.AT.FDCWD)), @intFromPtr(p1), @bitCast(@as(isize, LX.AT.FDCWD)), @intFromPtr(p2), flags));
}

/// linkat(2); `follow` makes a hard link to the target of a symlink.
pub fn linkPath(old: []const u8, new: []const u8, follow: bool) ?LX.E {
    if (comptime !is_linux) return other.linkPath(old, new, follow);
    var b1: [4097]u8 = undefined;
    var b2: [4097]u8 = undefined;
    const p1 = cstr(&b1, old) orelse return .NAMETOOLONG;
    const p2 = cstr(&b2, new) orelse return .NAMETOOLONG;
    return errOf(LX.linkat(LX.AT.FDCWD, p1, LX.AT.FDCWD, p2, if (follow) LX.AT.SYMLINK_FOLLOW else 0));
}

pub fn symlinkPath(target: []const u8, path: []const u8) ?LX.E {
    if (comptime !is_linux) return other.symlinkPath(target, path);
    var b1: [4097]u8 = undefined;
    var b2: [4097]u8 = undefined;
    const p1 = cstr(&b1, target) orelse return .NAMETOOLONG;
    const p2 = cstr(&b2, path) orelse return .NAMETOOLONG;
    return errOf(LX.symlinkat(p1, LX.AT.FDCWD, p2));
}

pub fn readlinkPath(path: []const u8, buf: []u8, err: *LX.E) ?usize {
    if (comptime !is_linux) return other.readlinkPath(path, buf, err);
    var b: [4097]u8 = undefined;
    const p = cstr(&b, path) orelse {
        err.* = .NAMETOOLONG;
        return null;
    };
    const rc = LX.readlinkat(LX.AT.FDCWD, p, buf.ptr, buf.len);
    const e = LX.errno(rc);
    if (e != .SUCCESS) {
        err.* = e;
        return null;
    }
    return rc;
}

/// fchmodat(2); `nofollow` is honoured by retrying through /proc where the
/// kernel lacks AT_SYMLINK_NOFOLLOW support (symlinks are then left alone).
pub fn chmodPath(path: []const u8, mode: u32, nofollow: bool) ?LX.E {
    if (comptime !is_linux) return other.chmodPath(path, mode, nofollow);
    var b: [4097]u8 = undefined;
    const p = cstr(&b, path) orelse return .NAMETOOLONG;
    if (nofollow) {
        // Symbolic links have no permission bits on Linux.
        var e: LX.E = .SUCCESS;
        if (fileStat(path, false, &e)) |st| {
            if (st.isLink()) return .OPNOTSUPP;
        } else return e;
    }
    return errOf(LX.syscall4(.fchmodat, @bitCast(@as(isize, LX.AT.FDCWD)), @intFromPtr(p), mode, 0));
}

pub fn fchmodFd(fd: Handle, mode: u32) ?LX.E {
    if (comptime !is_linux) return other.fchmodFd(fd, mode);
    return errOf(LX.fchmod(fd, mode));
}

pub fn fchownFd(fd: Handle, uid: u32, gid: u32) ?LX.E {
    if (comptime !is_linux) return other.fchownFd(fd, uid, gid);
    return errOf(LX.fchown(fd, uid, gid));
}

pub fn ftruncateFd(fd: Handle, len: u64) ?LX.E {
    if (comptime !is_linux) return other.ftruncateFd(fd, len);
    return errOf(LX.ftruncate(fd, @intCast(len)));
}

pub fn accessPath(path: []const u8, mode: u32) ?LX.E {
    if (comptime !is_linux) return other.accessPath(path, mode);
    var b: [4097]u8 = undefined;
    const p = cstr(&b, path) orelse return .NAMETOOLONG;
    return errOf(LX.syscall4(.faccessat2, @bitCast(@as(isize, LX.AT.FDCWD)), @intFromPtr(p), mode, 0x200));
}

/// lseek(2): whence 0/1/2 or SEEK_DATA 3 / SEEK_HOLE 4.
pub fn seekFd(fd: Handle, off: i64, whence: u32, err: *LX.E) ?i64 {
    if (comptime !is_linux) return other.seekFd(fd, off, whence, err);
    const rc = LX.syscall3(.lseek, @bitCast(@as(isize, fd)), @bitCast(off), whence);
    const e = LX.errno(rc);
    if (e != .SUCCESS) {
        err.* = e;
        return null;
    }
    return @bitCast(rc);
}

/// statx(2) on an open descriptor.
pub fn fstatFd(fd: Handle, err: *LX.E) ?FileStat {
    if (comptime !is_linux) return other.fstatFd(fd, err);
    var sx: LX.Statx = undefined;
    const rc = LX.statx(fd, "", LX.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true, .ATIME = true, .MTIME = true, .CTIME = true, .INO = true, .SIZE = true, .BLOCKS = true, .BTIME = true }, &sx);
    const e = LX.errno(rc);
    if (e != .SUCCESS) {
        err.* = e;
        return null;
    }
    return statxToFileStat(sx);
}

/// Current umask (read without changing it).
pub fn currentUmask() u32 {
    return umask();
}

/// glibc makedev().
pub fn makedev(major: u64, minor: u64) u64 {
    if (comptime !is_linux) return other.makedev(major, minor);
    return ((major & 0xfff) << 8) | (minor & 0xff) | ((minor & ~@as(u64, 0xff)) << 12) | ((major & ~@as(u64, 0xfff)) << 32);
}

/// umask(2): set the mask and return the previous one.
pub fn setUmask(mask: u32) u32 {
    if (comptime !is_linux) return other.setUmask(mask);
    return @intCast(std.os.linux.syscall1(.umask, mask) & 0o7777);
}

/// Parent process id.
pub fn parentPid() i32 {
    if (comptime !is_linux) return other.parentPid();
    return @intCast(std.os.linux.getppid());
}

// ------------------------------------------- catching terminating signals (ls)
// GNU ls installs handlers for the signals that end or stop it so that a
// coloured listing does not leave the terminal in the last colour: the handler
// only records the signal, and the program acts on it at the next safe point
// (flush, reset the colour, then deliver the signal with its default action).
// std.Io has no signal API (decision 0002).

const catch_signals = [_]u8{ 1, 2, 13, 3, 15, 14, 20 }; // HUP INT PIPE QUIT TERM ALRM TSTP (Linux numbers)
var caught_signal: std.atomic.Value(u8) = .init(0);
var saved_actions: [catch_signals.len]std.os.linux.Sigaction = undefined;
var saved_valid: [catch_signals.len]bool = @splat(false);

pub fn recordCaught(n: u8) void {
    caught_signal.store(n, .release);
}

fn catchHandler(sg: std.os.linux.SIG) callconv(.c) void {
    caught_signal.store(@intCast(@intFromEnum(sg)), .release);
}

fn catchOne(i: usize) void {
    if (comptime !is_linux) return;
    const L = std.os.linux;
    const sig: L.SIG = @enumFromInt(catch_signals[i]);
    var old: L.Sigaction = undefined;
    if (L.errno(L.sigaction(sig, null, &old)) != .SUCCESS) return;
    if (old.handler.handler == L.SIG.IGN) return; // an ignored signal stays ignored
    const act: L.Sigaction = .{
        .handler = .{ .handler = catchHandler },
        .mask = L.sigemptyset(),
        .flags = L.SA.RESTART,
    };
    if (L.errno(L.sigaction(sig, &act, null)) != .SUCCESS) return;
    if (!saved_valid[i]) {
        saved_actions[i] = old;
        saved_valid[i] = true;
    }
}

/// Catch SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM, SIGALRM and SIGTSTP unless
/// they are ignored; a caught signal is recorded for `takeCaughtSignal`.
pub fn catchSignals() void {
    if (comptime !is_linux) return other.catchSignals();
    for (0..catch_signals.len) |i| catchOne(i);
}

/// Put back the actions that were in place before `catchSignals`.
pub fn restoreCaughtSignals() void {
    if (comptime !is_linux) return other.restoreCaughtSignals();
    const L = std.os.linux;
    for (0..catch_signals.len) |i| {
        if (!saved_valid[i]) continue;
        _ = L.sigaction(@enumFromInt(catch_signals[i]), &saved_actions[i], null);
        saved_valid[i] = false;
    }
}

/// The signal recorded by the handler since the last call, or null.
pub fn takeCaughtSignal() ?u8 {
    const v = caught_signal.swap(0, .acq_rel);
    return if (v == 0) null else v;
}

/// Act on a signal from `takeCaughtSignal` as if it had not been caught: the
/// default action runs (SIGTSTP stops the process with SIGSTOP and the handler
/// is installed again when it continues).
pub fn deliverCaughtSignal(sig: u8) void {
    if (comptime !is_linux) return other.deliverCaughtSignal(sig);
    const L = std.os.linux;
    const self: i32 = @intCast(L.getpid());
    if (sig == 20) {
        _ = L.kill(self, @enumFromInt(19));
        return; // execution resumes here after SIGCONT; the handler is still set
    }
    const act: L.Sigaction = .{ .handler = .{ .handler = L.SIG.DFL }, .mask = L.sigemptyset(), .flags = 0 };
    _ = L.sigaction(@enumFromInt(sig), &act, null);
    unblockSignal(sig);
    _ = L.kill(self, @enumFromInt(sig));
}

// ----------------------------------- statistics on request (dd: USR1, INT)
// The handlers only record the signal; the program prints at its next safe
// point. They are installed without SA_RESTART, so that a read or write that
// is waiting returns and that point is reached.

var statistics_requested: std.atomic.Value(bool) = .init(false);
var interrupt_received: std.atomic.Value(bool) = .init(false);

pub fn recordStatisticsRequest() void {
    statistics_requested.store(true, .release);
}

pub fn recordInterrupt() void {
    interrupt_received.store(true, .release);
}

fn statisticsHandler(_: std.os.linux.SIG) callconv(.c) void {
    recordStatisticsRequest();
}

fn interruptHandler(_: std.os.linux.SIG) callconv(.c) void {
    recordInterrupt();
}

/// Catch SIGINT unless it is ignored (once: a second one ends the process even
/// if the first has not been acted on) and, with `on_user_signal`, SIGUSR1
/// (SIGINFO too where it exists). Does nothing on Windows.
pub fn catchStatisticsSignals(on_user_signal: bool) void {
    if (comptime !is_linux) return other.catchStatisticsSignals(on_user_signal);
    const L = std.os.linux;
    if (on_user_signal) {
        const act: L.Sigaction = .{ .handler = .{ .handler = statisticsHandler }, .mask = L.sigemptyset(), .flags = 0 };
        _ = L.sigaction(L.SIG.USR1, &act, null);
    }
    var old: L.Sigaction = undefined;
    if (L.errno(L.sigaction(L.SIG.INT, null, &old)) != .SUCCESS or old.handler.handler == L.SIG.IGN) return;
    const act: L.Sigaction = .{ .handler = .{ .handler = interruptHandler }, .mask = L.sigemptyset(), .flags = L.SA.RESETHAND };
    _ = L.sigaction(L.SIG.INT, &act, null);
}

/// Whether statistics were asked for since the last call.
pub fn takeStatisticsRequest() bool {
    return statistics_requested.swap(false, .acq_rel);
}

pub fn interruptReceived() bool {
    return interrupt_received.load(.acquire);
}

/// End the process the way the caught SIGINT would have.
pub fn dieOfInterrupt() noreturn {
    defaultSignal(.int);
    _ = raiseSelf(signo.INT);
    std.process.exit(128 + @as(u8, signo.INT));
}
