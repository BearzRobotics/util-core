// SPDX-License-Identifier: GPL-2.0-or-later
//! rm library: remove files or directories.
//! References: GNU coreutils manual "rm invocation" (9.7); POSIX.1-2024 rm.
//!
//! Deviations: --preserve-root=all is treated as plain --preserve-root (the
//! caller maps both to `preserve_root`).
//!
//! The library never prompts or prints: confirmation goes through a
//! caller-supplied `Confirm` callback, and everything that is reported
//! (failures, refusals, the -v "removed" lines) through the `Observer`.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const Interactive = enum { never, once, always, default };

pub const Options = struct {
    force: bool = false,
    /// `.once` is the caller's business (one prompt before `run`); the
    /// library treats it like `.never`.
    interactive: Interactive = .default,
    recursive: bool = false,
    /// -d: remove empty directories.
    dirs: bool = false,
    verbose: bool = false,
    preserve_root: bool = true,
    one_file_system: bool = false,
    /// Standard input is a terminal (enables the default write-protect prompt).
    stdin_tty: bool = false,
};

pub const Event = union(enum) {
    /// Removed `path` (the -v message); `dir` is true for a directory.
    removed: struct { path: []const u8, dir: bool },
    /// Could not remove `path`.
    failed: struct { path: []const u8, err: anyerror },
    /// "." or ".." given as an operand with -r.
    refuse_dot: []const u8,
    /// An operand that is (or resolves to) "/" with preserve_root.
    refuse_root: struct { path: []const u8, literal: bool },
    /// A directory on another device with --one-file-system.
    other_device: []const u8,
};
pub const Observer = common.Observer(Event);

/// What the user is asked. Wording is the caller's.
pub const Prompt = struct {
    path: []const u8,
    kind: Io.File.Kind,
    size: u64,
    action: enum { descend, remove },
    /// For `.remove`: the file is not writable.
    write_protected: bool = false,
};

/// Returns true to proceed.
pub const Confirm = struct {
    context: ?*anyopaque = null,
    func: *const fn (context: ?*anyopaque, prompt: Prompt) bool,

    fn ask(c: Confirm, p: Prompt) bool {
        return c.func(c.context, p);
    }
};

const State = struct {
    env: Env,
    opts: Options,
    observer: Observer,
    confirm: Confirm,
    ok: bool = true,
    root_dev: u64 = 0, // device of the current operand (--one-file-system)
    nerr: usize = 0, // hard failures so far (declined prompts do not count)

    fn fail(st: *State) void {
        st.ok = false;
        st.nerr += 1;
    }
};

/// Remove each operand. Returns false when anything failed.
pub fn run(env: Env, options: Options, paths: []const []const u8, observer: Observer, confirm: Confirm) bool {
    var st: State = .{ .env = env, .opts = options, .observer = observer, .confirm = confirm };
    for (paths) |p| removeArg(&st, p);
    return st.ok;
}

fn removeArg(st: *State, path: []const u8) void {
    const cfg = st.opts;
    // "." and ".." as the last component are never removed.
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
    if (cfg.recursive and (std.mem.eql(u8, last, ".") or std.mem.eql(u8, last, ".."))) {
        st.observer.emit(.{ .refuse_dot = path });
        st.fail();
        return;
    }
    if (cfg.preserve_root and cfg.recursive and isRoot(st.env, path)) {
        st.observer.emit(.{ .refuse_root = .{ .path = path, .literal = std.mem.eql(u8, path, "/") } });
        st.fail();
        return;
    }
    _ = remove(st, path, true);
}

fn isRoot(env: Env, p: []const u8) bool {
    if (p.len > 0 and std.mem.indexOfNone(u8, p, "/") == null) return true;
    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(env.io, p, &buf) catch return false;
    return std.mem.eql(u8, buf[0..n], "/");
}

/// Remove `path` (recursively when asked). Returns true when it is gone.
fn remove(st: *State, path: []const u8, is_arg: bool) bool {
    const env = st.env;
    const cfg = st.opts;
    const cwd = Io.Dir.cwd();
    const lst = cwd.statFile(env.io, path, .{ .follow_symlinks = false }) catch |e| {
        if (cfg.force and e == error.FileNotFound) return true;
        st.observer.emit(.{ .failed = .{ .path = path, .err = e } });
        st.fail();
        return false;
    };

    if (lst.kind == .directory) {
        if (!cfg.recursive) {
            if (cfg.dirs) return removeEmptyDir(st, path, lst);
            st.observer.emit(.{ .failed = .{ .path = path, .err = error.IsDir } });
            st.fail();
            return false;
        }
        if (cfg.one_file_system) {
            var de: std.os.linux.E = .SUCCESS;
            if (sys.fileStat(path, false, &de)) |fs| {
                const dev = (@as(u64, fs.dev_major) << 32) | fs.dev_minor;
                if (is_arg) {
                    st.root_dev = dev;
                } else if (dev != st.root_dev) {
                    st.observer.emit(.{ .other_device = path });
                    st.fail();
                    return false;
                }
            }
        }
        if (cfg.interactive == .always) {
            if (!st.confirm.ask(.{ .path = path, .kind = lst.kind, .size = lst.size, .action = .descend })) return false;
        }
        var dir = cwd.openDir(env.io, path, .{ .iterate = true }) catch |e| {
            st.observer.emit(.{ .failed = .{ .path = path, .err = e } });
            st.fail();
            return false;
        };
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| env.gpa.free(n);
            names.deinit(env.gpa);
        }
        var it = dir.iterate();
        while (it.next(env.io) catch null) |entry| {
            const dup = env.gpa.dupe(u8, entry.name) catch break;
            names.append(env.gpa, dup) catch {
                env.gpa.free(dup);
                break;
            };
        }
        dir.close(env.io);
        var kept = false; // a child failed or was declined, so the directory cannot be empty
        for (names.items) |n| {
            const child = if (std.mem.endsWith(u8, path, "/"))
                std.fmt.allocPrint(env.gpa, "{s}{s}", .{ path, n }) catch return false
            else
                std.fmt.allocPrint(env.gpa, "{s}/{s}", .{ path, n }) catch return false;
            defer env.gpa.free(child);
            if (!remove(st, child, false)) kept = true;
        }
        if (kept) return false; // GNU leaves the directory without asking again
        return removeEmptyDir(st, path, lst);
    }

    // Anything that is not a directory.
    switch (cfg.interactive) {
        .always => {
            const wp = lst.kind != .sym_link and !writable(env, path);
            if (!st.confirm.ask(.{ .path = path, .kind = lst.kind, .size = lst.size, .action = .remove, .write_protected = wp })) return false;
        },
        .default => if (cfg.stdin_tty and lst.kind != .sym_link and !writable(env, path)) {
            if (!st.confirm.ask(.{ .path = path, .kind = lst.kind, .size = lst.size, .action = .remove, .write_protected = true })) return false;
        },
        else => {},
    }
    cwd.deleteFile(env.io, path) catch |e| {
        st.observer.emit(.{ .failed = .{ .path = path, .err = e } });
        st.fail();
        return false;
    };
    if (cfg.verbose) st.observer.emit(.{ .removed = .{ .path = path, .dir = false } });
    return true;
}

fn writable(env: Env, path: []const u8) bool {
    Io.Dir.cwd().access(env.io, path, .{ .write = true }) catch return false;
    return true;
}

fn removeEmptyDir(st: *State, path: []const u8, lst: Io.File.Stat) bool {
    const env = st.env;
    const cfg = st.opts;
    if (cfg.interactive == .always) {
        const wp = lst.kind != .sym_link and !writable(env, path);
        if (!st.confirm.ask(.{ .path = path, .kind = lst.kind, .size = lst.size, .action = .remove, .write_protected = wp })) return false;
    } else if (cfg.interactive == .default and cfg.stdin_tty and !writable(env, path)) {
        if (!st.confirm.ask(.{ .path = path, .kind = .directory, .size = lst.size, .action = .remove, .write_protected = true })) return false;
    }
    Io.Dir.cwd().deleteDir(env.io, path) catch |e| {
        // rmdir("/") says EBUSY; GNU's message is the one for a non-empty directory.
        // Likewise "." (EINVAL) is reported as a non-empty directory.
        const busy_root = (e == error.FileBusy and isRoot(env, path)) or (e == error.Unexpected and std.mem.endsWith(u8, std.mem.trimEnd(u8, path, "/"), "."));
        st.observer.emit(.{ .failed = .{ .path = path, .err = if (busy_root) error.DirNotEmpty else e } });
        st.fail();
        return false;
    };
    if (cfg.verbose) st.observer.emit(.{ .removed = .{ .path = path, .dir = true } });
    return true;
}
