// SPDX-License-Identifier: GPL-2.0-or-later
//! install library: copy files and set attributes.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "install
//! invocation" (9.7) and GNU coreutils 9.6 src/install.c. The copying is done
//! by src/copy.zig. SELinux options are accepted and ignored by the wrapper.
//!
//! The caller parses the command line, resolves user/group names and modes,
//! sets umask 0 for the process (install needs exact modes) and tells `run`
//! what to do with the operands (`Plan`). Diagnostics, verbose lines and
//! prompts go through `copy.Sink`.

const std = @import("std");
const common = @import("common.zig");
const copy = @import("../copy.zig");
const quote = @import("../quote.zig");
const sys = @import("../sys.zig");
const E = std.os.linux.E;

pub const Env = common.Env;
pub const Event = copy.Event;
pub const Observer = copy.Observer;
pub const Prompt = copy.Prompt;
pub const Confirm = copy.Confirm;
pub const Sink = copy.Sink;

pub const unset: u32 = std.math.maxInt(u32);

pub const Options = struct {
    /// Program name used in the -v "creating directory" lines.
    name: []const u8 = "install",
    /// Engine options (backups, preserve_timestamps, verbose, ...); the
    /// caller preconfigures the install defaults.
    x: copy.Opts = .{},
    mode: u32 = 0o755,
    dir_mode: u32 = 0o755,
    /// `unset` keeps the current owner/group.
    owner_id: u32 = unset,
    group_id: u32 = unset,
    strip_files: bool = false,
    strip_program: []const u8 = "strip",
    /// -C: skip the copy when the destination already matches.
    copy_only_if_needed: bool = false,
};

pub const Plan = union(enum) {
    /// -d: create each operand as a directory.
    directories,
    /// operands = [from, to]; with `make_ancestors` (-D) the leading
    /// directories of `to` are created.
    file: struct { make_ancestors: bool },
    /// Install every operand into `target`. `target_exists` is false when it
    /// is to be created by -D (`make_ancestors`).
    into_directory: struct { target: []const u8, target_exists: bool, make_ancestors: bool },
};

pub const Error = error{
    OutOfMemory,
    /// GNU exits at once (after the diagnostic) without flushing pending
    /// standard output; the caller should do the same.
    Fatal,
};

const St = struct {
    env: Env,
    o: Options,
    sink: Sink,
    fatal: bool = false,

    fn x(s: *St) *copy.Opts {
        return &s.o.x;
    }

    fn flush(s: *St) void {
        s.sink.observer.emit(.flush);
    }

    /// Flush, then report.
    fn warn(s: *St, comptime fmt: []const u8, args: anytype) void {
        s.flush();
        s.warnNoFlush(fmt, args);
    }

    fn warnNoFlush(s: *St, comptime fmt: []const u8, args: anytype) void {
        const t = std.fmt.allocPrint(s.env.gpa, fmt, args) catch return;
        defer s.env.gpa.free(t);
        s.sink.observer.emit(.{ .diag = t });
    }
};

/// Run the installation. Returns false when anything failed.
pub fn run(env: Env, options: Options, operands: []const []const u8, plan: Plan, sink: Sink) Error!bool {
    var s: St = .{ .env = env, .o = options, .sink = sink };
    var ok = true;
    switch (plan) {
        .directories => {
            for (operands) |d| if (!processDir(&s, d)) {
                ok = false;
            };
            return ok;
        },
        else => {},
    }

    var c = copy.Copier.init(env, sink, s.o.x);
    defer c.deinit();
    c.umask = 0;
    switch (plan) {
        .directories => unreachable,
        .file => |f| {
            if (f.make_ancestors and !mkAncestors(&s, operands[1])) return false;
            ok = installFileInFile(&s, &c, operands[0], operands[1]);
        },
        .into_directory => |t| {
            const td = t.target;
            var target_ok = t.target_exists;
            c.x.track_dest = true;
            for (operands, 0..) |from, i| {
                const to = try copy.joinName(env.gpa, td, lastComponent(from));
                defer env.gpa.free(to);
                if (!target_ok or (i == 0 and t.make_ancestors)) {
                    if (t.make_ancestors and i == 0) {
                        if (!mkAncestors(&s, to)) {
                            ok = false;
                            continue;
                        }
                        target_ok = true;
                    }
                }
                if (!installFileInFile(&s, &c, from, to)) ok = false;
                if (s.fatal) return error.Fatal;
            }
        },
    }
    if (s.fatal) return error.Fatal;
    return ok;
}

fn lastComponent(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    const t = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, t, '/');
    return if (slash) |s| t[s + 1 ..] else t;
}

fn extraMode(m: u32) bool {
    return (m & ~@as(u32, 0o777 | 0o170000)) != 0;
}

fn sameContent(a: []const u8, b: []const u8) bool {
    var e: E = .SUCCESS;
    const fa = sys.openFd(a, sys.O.RDONLY, 0, &e) orelse return false;
    defer _ = sys.closeFd(fa);
    const fb = sys.openFd(b, sys.O.RDONLY, 0, &e) orelse return false;
    defer _ = sys.closeFd(fb);
    var ba: [4096]u8 = undefined;
    var bb: [4096]u8 = undefined;
    while (true) {
        const na = readFull(fa, &ba) orelse return false;
        const nb = readFull(fb, &bb) orelse return false;
        if (na != nb) return false;
        if (na == 0) return true;
        if (!std.mem.eql(u8, ba[0..na], bb[0..nb])) return false;
    }
}

fn readFull(fd: i32, buf: []u8) ?usize {
    var e: E = .SUCCESS;
    var n: usize = 0;
    while (n < buf.len) {
        const r = sys.readFd(fd, buf[n..], &e) orelse return null;
        if (r == 0) break;
        n += r;
    }
    return n;
}

fn needCopy(s: *St, src: []const u8, dest: []const u8) bool {
    var e: E = .SUCCESS;
    if (extraMode(s.o.mode)) return true;
    const ss = sys.fileStat(src, true, &e) orelse return true;
    const ds = sys.fileStat(dest, false, &e) orelse return true;
    if (!ss.isReg() or !ds.isReg() or extraMode(ss.mode) or extraMode(ds.mode)) return true;
    if (ss.size != ds.size or (ds.mode & 0o7777) != s.o.mode) return true;
    const id = sys.identity();
    if (s.o.owner_id == unset) {
        if (ds.uid != id.uid) return true;
    } else if (ds.uid != s.o.owner_id) return true;
    if (s.o.group_id == unset) {
        if (ds.gid != id.gid) return true;
    } else if (ds.gid != s.o.group_id) return true;
    return !sameContent(src, dest);
}

fn changeAttributes(s: *St, name: []const u8) bool {
    if (!(s.o.owner_id == unset and s.o.group_id == unset)) {
        if (sys.chownAt(name, s.o.owner_id, s.o.group_id, true)) |ce| {
            s.warn("cannot change ownership of {f}: {s}", .{ quote.quoteA(name), sys.errnoText(ce) });
            return false;
        }
    }
    if (sys.chmodPath(name, s.o.mode, false)) |ce| {
        s.warn("cannot change permissions of {f}: {s}", .{ quote.quoteA(name), sys.errnoText(ce) });
        return false;
    }
    return true;
}

fn stripFile(s: *St, name: []const u8) bool {
    const env = s.env;
    var safe = name;
    var tmp: ?[]u8 = null;
    defer if (tmp) |t| env.gpa.free(t);
    if (name.len > 0 and name[0] == '-') {
        tmp = std.fmt.allocPrint(env.gpa, "./{s}", .{name}) catch return false;
        safe = tmp.?;
    }
    s.flush();
    const child = std.process.spawn(env.io, .{ .argv = &.{ s.o.strip_program, safe } }) catch {
        // GNU forks first: the child reports the failure and the parent then
        // sees a failed strip.
        s.warnNoFlush("cannot run {f}: No such file or directory", .{quote.quoteA(s.o.strip_program)});
        s.warnNoFlush("strip process terminated abnormally", .{});
        return false;
    };
    const pid: i32 = @intCast(child.id.?);
    switch (sys.waitPid(pid, true)) {
        .exited => |c| if (c == 0) return true,
        else => {},
    }
    s.warnNoFlush("strip process terminated abnormally", .{});
    return false;
}

fn installFileInFile(s: *St, c: *copy.Copier, from: []const u8, to: []const u8) bool {
    var e: E = .SUCCESS;
    var from_sb: sys.FileStat = undefined;
    if (c.x.preserve_timestamps) {
        from_sb = sys.fileStat(from, true, &e) orelse {
            s.warn("cannot stat {f}: {s}", .{ quote.quoteA(from), sys.errnoText(e) });
            return false;
        };
    }
    var copied = true;
    if (s.o.copy_only_if_needed and !needCopy(s, from, to)) {
        copied = false;
    } else {
        var into_self = false;
        var rs: ?bool = null;
        if (!c.copy(from, to, 0, &into_self, &rs)) return false;
    }
    if (!copied) return true;
    if (s.o.strip_files) {
        if (!stripFile(s, to)) {
            if (sys.unlinkPath(to, false)) |ue| {
                s.warnNoFlush("cannot unlink {f}: {s}", .{ quote.quoteA(to), sys.errnoText(ue) });
                s.fatal = true;
            }
            return false;
        }
    }
    if (c.x.preserve_timestamps and (s.o.strip_files or !from_sb.isReg())) {
        const ts = [2]sys.TimeSpec{ .{ .sec = from_sb.atime_s, .nsec = from_sb.atime_ns }, .{ .sec = from_sb.mtime_s, .nsec = from_sb.mtime_ns } };
        if (sys.setTimes(to, -1, ts, false)) |te| {
            s.warn("cannot set timestamps for {f}: {s}", .{ quote.quoteA(to), sys.errnoText(te) });
            return false;
        }
    }
    return changeAttributes(s, to);
}

fn announceMkdir(s: *St, dir: []const u8) void {
    if (s.o.x.verbose) {
        var buf: [8300]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{s}: creating directory {f}\n", .{ s.o.name, quote.quoteA(dir) }) catch return;
        s.sink.observer.emit(.{ .out = t });
    }
}

/// Create every missing leading directory of `path` (not `path` itself).
fn mkAncestors(s: *St, path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len and path[i] == '/') i += 1;
    while (std.mem.indexOfScalarPos(u8, path, i, '/')) |sl| {
        const prefix = path[0..sl];
        var e: E = .SUCCESS;
        if (sys.fileStat(prefix, true, &e)) |ps| {
            if (!ps.isDir()) {
                s.warn("cannot create directory {f}: Not a directory", .{quote.quoteA(prefix)});
                return false;
            }
        } else {
            if (sys.mkdirPath(prefix, 0o755)) |me| {
                s.warn("cannot create directory {f}: {s}", .{ quote.quoteA(path), sys.errnoText(me) });
                return false;
            }
            announceMkdir(s, prefix);
        }
        i = sl + 1;
        while (i < path.len and path[i] == '/') i += 1;
    }
    return true;
}

fn processDir(s: *St, dir_in: []const u8) bool {
    var end = dir_in.len;
    while (end > 1 and dir_in[end - 1] == '/') end -= 1;
    const dir = dir_in[0..end];
    if (!mkAncestors(s, dir)) return false;
    var e: E = .SUCCESS;
    if (sys.fileStat(dir, true, &e)) |st| {
        if (!st.isDir()) {
            s.warn("cannot create directory {f}: File exists", .{quote.quoteA(dir)});
            return false;
        }
    } else {
        const create_mode = if (s.o.owner_id != unset or s.o.group_id != unset) s.o.dir_mode & 0o700 else s.o.dir_mode;
        if (sys.mkdirPath(dir, create_mode)) |me| {
            if (me == .ACCES) {
                s.warn("cannot change permissions of {f}: No such file or directory", .{quote.quoteA(dir)});
            } else s.warn("cannot create directory {f}: {s}", .{ quote.quoteA(dir), sys.errnoText(me) });
            return false;
        }
        announceMkdir(s, dir);
    }
    if (!(s.o.owner_id == unset and s.o.group_id == unset)) {
        if (sys.chownAt(dir, s.o.owner_id, s.o.group_id, true)) |ce| {
            s.warn("cannot change owner and permissions of {f}: {s}", .{ quote.quoteA(dir), sys.errnoText(ce) });
            return false;
        }
    }
    if (sys.chmodPath(dir, s.o.dir_mode, false)) |ce| {
        s.warn("cannot change permissions of {f}: {s}", .{ quote.quoteA(dir), sys.errnoText(ce) });
        return false;
    }
    return true;
}
