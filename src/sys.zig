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

// ------------------------------------------------- process and host identity
// No std.Io API exists for these (identity, host name, CPU affinity, group
// list). Linux only; other systems report "unknown"/zero values.

pub const Identity = struct { uid: u32, euid: u32, gid: u32, egid: u32 };

pub fn identity() Identity {
    if (comptime builtin.os.tag != .linux) return .{ .uid = 0, .euid = 0, .gid = 0, .egid = 0 };
    return .{
        .uid = std.os.linux.getuid(),
        .euid = std.os.linux.geteuid(),
        .gid = std.os.linux.getgid(),
        .egid = std.os.linux.getegid(),
    };
}

/// Supplementary group ids of the calling process, in kernel order.
pub fn supplementaryGroups(buf: []u32) []u32 {
    if (comptime builtin.os.tag != .linux) return buf[0..0];
    const n = std.os.linux.getgroups(buf.len, @ptrCast(buf.ptr));
    if (@as(isize, @bitCast(n)) < 0) return buf[0..0];
    return buf[0..n];
}

pub const Uname = struct {
    sysname: []const u8,
    nodename: []const u8,
    release: []const u8,
    version: []const u8,
    machine: []const u8,
    // Backing storage for the slices above.
    raw: if (builtin.os.tag == .linux) std.os.linux.utsname else void,
};

pub fn uname() Uname {
    if (comptime builtin.os.tag != .linux) return .{ .sysname = "unknown", .nodename = "unknown", .release = "unknown", .version = "unknown", .machine = "unknown", .raw = {} };
    var u: Uname = undefined;
    _ = std.os.linux.uname(&u.raw);
    u.sysname = std.mem.sliceTo(&u.raw.sysname, 0);
    u.nodename = std.mem.sliceTo(&u.raw.nodename, 0);
    u.release = std.mem.sliceTo(&u.raw.release, 0);
    u.version = std.mem.sliceTo(&u.raw.version, 0);
    u.machine = std.mem.sliceTo(&u.raw.machine, 0);
    return u;
}

/// Number of CPUs the process may run on (sched_getaffinity), or null.
pub fn affinityCpus() ?usize {
    if (comptime builtin.os.tag != .linux) return null;
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
pub fn fileStat(path: []const u8, follow: bool, err: *std.os.linux.E) ?FileStat {
    if (comptime builtin.os.tag != .linux) return null;
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
pub fn errnoText(e: std.os.linux.E) []const u8 {
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

// ----------------------------------------------------------------- signals
// Signal names and dispositions by number, for env, nohup, timeout and kill.
// std.Io has no signal API (see docs/decisions/0002-std-io-exceptions.md).

/// Names of signals 1..31 on Linux (generic architectures), without "SIG".
pub const signal_names = [_][]const u8{
    "HUP",  "INT",  "QUIT", "ILL",   "TRAP", "ABRT",   "BUS", "FPE",
    "KILL", "USR1", "SEGV", "USR2",  "PIPE", "ALRM",   "TERM", "STKFLT",
    "CHLD", "CONT", "STOP", "TSTP",  "TTIN", "TTOU",   "URG", "XCPU",
    "XFSZ", "VTALRM", "PROF", "WINCH", "POLL", "PWR",  "SYS",
};

/// Name of signal `n` (1..64, not 32/33 which libc reserves): the table above
/// or RTMIN+k / RTMAX-k for real-time signals. `buf` holds the formatted name.
pub fn signalName(n: u8, buf: *[16]u8) ?[]const u8 {
    if (n >= 1 and n <= 31) return signal_names[n - 1];
    if (n < 34 or n > 64) return null;
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
    if (std.ascii.eqlIgnoreCase(name, "IO")) return 29;
    if (std.ascii.eqlIgnoreCase(name, "CLD")) return 17;
    for (signal_names, 1..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return @intCast(i);
    var n: u8 = 34;
    while (n <= 64) : (n += 1) {
        var buf: [16]u8 = undefined;
        if (signalName(n, &buf)) |nm| if (std.ascii.eqlIgnoreCase(nm, name)) return n;
    }
    return null;
}

pub const Disposition = enum { default, ignore, block };

/// Set the action for signal `num` (1..64) in this process; it is inherited
/// across exec, which is how `env` and `nohup` use it.
pub fn setSignal(num: u8, d: Disposition) bool {
    if (comptime builtin.os.tag != .linux) return false;
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
    if (comptime builtin.os.tag != .linux) return;
    const L = std.os.linux;
    var set = L.sigemptyset();
    L.sigaddset(&set, @enumFromInt(num));
    _ = L.sigprocmask(L.SIG.UNBLOCK, &set, null);
}

/// Current action of signal `num`: .ignore, .default, or null when a handler
/// is installed (or on error). Also reports whether it is blocked.
pub fn signalState(num: u8) struct { disp: ?Disposition, blocked: bool } {
    if (comptime builtin.os.tag != .linux) return .{ .disp = .default, .blocked = false };
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

/// kill(2): send `sig` to `pid` (negative pid = process group). Returns the
/// errno on failure.
pub fn sendSignal(pid: i32, sig: u8) ?std.os.linux.E {
    if (comptime builtin.os.tag != .linux) return .NOSYS;
    const rc = std.os.linux.kill(pid, @enumFromInt(sig));
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
pub fn dup2(old: i32, new: i32) ?LX.E {
    return errOf(LX.dup2(old, new));
}

/// True when descriptor `fd` is open (fcntl F_GETFD succeeds).
pub fn fdOpen(fd: i32) bool {
    return LX.errno(LX.fcntl(fd, LX.F.GETFD, 0)) == .SUCCESS;
}

/// Open `path` for appending, creating it with `mode` if needed.
pub fn openAppendMode(path: []const u8, mode: u32) !Io.File {
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
    // The raw syscall returns 20 - nice.
    const rc = LX.syscall2(.getpriority, 0, 0);
    return 20 - @as(i32, @intCast(@as(isize, @bitCast(rc))));
}

/// setpriority(PRIO_PROCESS, 0, nice).
pub fn setNice(value: i32) ?LX.E {
    return errOf(LX.syscall3(.setpriority, 0, 0, @bitCast(@as(isize, value))));
}

/// Make this process a process-group leader (setpgid(0, 0)).
pub fn becomeGroupLeader() void {
    _ = LX.syscall2(.setpgid, 0, 0);
}

/// chroot(2).
pub fn chroot(path: [:0]const u8) ?LX.E {
    return errOf(LX.chroot(path.ptr));
}

/// sync(2), fsync(2), fdatasync(2) and syncfs(2) on an open descriptor.
pub const SyncKind = enum { all, data, file, fs };
pub fn syncFile(fd: i32, kind: SyncKind) ?LX.E {
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
    return errOf(LX.mknodat(LX.AT.FDCWD, path.ptr, mode, @intCast(dev)));
}

/// Result of waiting for a child.
pub const WaitResult = union(enum) { exited: u8, signaled: u8, none };

/// waitpid(pid, WNOHANG or blocking).
pub fn waitPid(pid: i32, block: bool) WaitResult {
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

/// An event source for `timeout`: waits until the child exits, a watched
/// signal arrives, or the timeout passes. Signals are received through a
/// signalfd so no handler (and no async-signal-safety concern) is needed.
pub const Watcher = struct {
    pidfd: i32,
    sigfd: i32,

    pub const Event = union(enum) { child_exited, signal: u8, timeout, failed };

    /// Block `signals` and open descriptors for `pid` and for those signals.
    pub fn init(pid: i32, signals: []const u8) ?Watcher {
        var set = LX.sigemptyset();
        for (signals) |s| LX.sigaddset(&set, @enumFromInt(s));
        _ = LX.sigprocmask(LX.SIG.BLOCK, &set, null);
        const sfd = LX.signalfd(-1, &set, LX.SFD.CLOEXEC);
        if (LX.errno(sfd) != .SUCCESS) return null;
        const pfd = LX.syscall2(.pidfd_open, @intCast(pid), 0);
        if (LX.errno(pfd) != .SUCCESS) return null;
        return .{ .pidfd = @intCast(pfd), .sigfd = @intCast(sfd) };
    }

    /// Wait up to `timeout_ns` (null = forever).
    pub fn wait(w: Watcher, timeout_ns: ?u64) Event {
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
        _ = LX.close(w.pidfd);
        _ = LX.close(w.sigfd);
    }
};

// ------------------------------------------------------------- the clock

/// clock_settime(CLOCK_REALTIME); needs CAP_SYS_TIME.
pub fn setRealtime(sec: i64, nsec: u32) ?LX.E {
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
pub fn setTimes(path: ?[]const u8, fd: i32, times: ?[2]TimeSpec, nofollow: bool) ?LX.E {
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
