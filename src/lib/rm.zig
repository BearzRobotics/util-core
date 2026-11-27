// SPDX-License-Identifier: GPL-2.0-or-later
//! rm library: remove files or directories.
//! References: GNU coreutils manual "rm invocation" (9.7); POSIX.1-2024 rm.
//!
//! Deviations: --preserve-root=all is treated as plain --preserve-root (the
//! caller maps both to `preserve_root`).
//!
//! The walk is descriptor-relative (dirat.zig): each directory is opened in
//! its parent without following a symbolic link, checked to be the one that
//! was examined, and everything in it is examined and removed through that
//! descriptor. Renaming things in the tree while rm runs cannot send it
//! outside, and the depth is not limited by PATH_MAX. Path strings are only
//! for prompts and messages.
//!
//! The library never prompts or prints: confirmation goes through a
//! caller-supplied `Confirm` callback, and everything that is reported
//! (failures, refusals, the -v "removed" lines) through the `Observer`.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");
const dirat = @import("../dirat.zig");

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
    failed: struct { path: []const u8, errno: sys.E },
    /// The directory `path` could not be listed; nothing in it was touched.
    unreadable: struct { path: []const u8, errno: sys.E },
    /// "." or ".." given as an operand with -r.
    refuse_dot: []const u8,
    /// An operand that is "/" (the same file, however it is named) with
    /// preserve_root.
    refuse_root: struct { path: []const u8, literal: bool },
    /// preserve_root could not examine "/", so nothing is removed.
    unknown_root: sys.E,
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
    /// What "/" is, with recursive and preserve_root.
    root: ?sys.FileStat = null,

    fn fail(st: *State) void {
        st.ok = false;
        st.nerr += 1;
    }
};

/// Remove each operand. Returns false when anything failed.
pub fn run(env: Env, options: Options, paths: []const []const u8, observer: Observer, confirm: Confirm) bool {
    var st: State = .{ .env = env, .opts = options, .observer = observer, .confirm = confirm };
    if (options.recursive and options.preserve_root) {
        var e: sys.E = .SUCCESS;
        st.root = sys.fileStat("/", false, &e) orelse {
            observer.emit(.{ .unknown_root = e });
            return false;
        };
    }
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
    _ = remove(st, null, path, path, true);
}

/// Whether `a` and `b` are the same file: so is "/" under any name, such as
/// a bind mount of it or a symbolic link to it followed by a slash.
fn sameFile(a: sys.FileStat, b: sys.FileStat) bool {
    return a.ino == b.ino and dirat.devOf(a) == dirat.devOf(b);
}

/// How `remove` reaches one file: `name` in the open directory `parent` (an
/// operand is named by its path, from the current directory). `path` is what
/// prompts and messages call it.
const Target = struct {
    parent: ?*dirat.Level,
    name: []const u8,
    path: []const u8,
};

fn failed(st: *State, path: []const u8, errno: sys.E) bool {
    st.observer.emit(.{ .failed = .{ .path = path, .errno = errno } });
    st.fail();
    return false;
}

/// Remove one file (recursively when asked). Returns true when it is gone.
fn remove(st: *State, parent: ?*dirat.Level, name: []const u8, path: []const u8, is_arg: bool) bool {
    const cfg = st.opts;
    const file: Target = .{ .parent = parent, .name = name, .path = path };
    var le: sys.E = .SUCCESS;
    const lst = sys.fileStatAt(dirat.fdOf(parent), name, false, &le) orelse {
        if (cfg.force and le == .NOENT) return true;
        return failed(st, path, le);
    };

    if (lst.isDir()) {
        if (!cfg.recursive) {
            if (cfg.dirs) return removeEmptyDir(st, file, lst);
            return failed(st, path, .ISDIR);
        }
        // Decided on the examination the walk is then bound to (`lst`).
        if (is_arg) if (st.root) |root| if (sameFile(lst, root)) {
            st.observer.emit(.{ .refuse_root = .{ .path = path, .literal = std.mem.eql(u8, path, "/") } });
            st.fail();
            return false;
        };
        if (cfg.one_file_system) {
            const dev = dirat.devOf(lst);
            if (is_arg) {
                st.root_dev = dev;
            } else if (dev != st.root_dev) {
                st.observer.emit(.{ .other_device = path });
                st.fail();
                return false;
            }
        }
        if (cfg.interactive == .always) {
            if (!st.confirm.ask(.{ .path = path, .kind = .directory, .size = lst.size, .action = .descend })) return false;
        }
        return switch (removeContents(st, file, lst)) {
            .empty => removeEmptyDir(st, file, lst),
            .gone => true,
            .kept => false, // GNU leaves the directory without asking again
        };
    }

    // Anything that is not a directory.
    const kind = kindOf(lst.mode);
    switch (cfg.interactive) {
        .always => {
            const wp = kind != .sym_link and !writable(file);
            if (!st.confirm.ask(.{ .path = path, .kind = kind, .size = lst.size, .action = .remove, .write_protected = wp })) return false;
        },
        .default => if (cfg.stdin_tty and kind != .sym_link and !writable(file)) {
            if (!st.confirm.ask(.{ .path = path, .kind = kind, .size = lst.size, .action = .remove, .write_protected = true })) return false;
        },
        else => {},
    }
    if (sys.unlinkAt(dirat.fdOf(parent), name, false)) |e| return failed(st, path, e);
    if (cfg.verbose) st.observer.emit(.{ .removed = .{ .path = path, .dir = false } });
    return true;
}

const Contents = enum {
    /// The directory is to be removed now.
    empty,
    /// It could not be entered, but was empty and has been removed.
    gone,
    /// Something is left: a failure or a declined prompt.
    kept,
};

/// Remove everything in the directory `dir`.
/// On return `dir.parent` is open again, or a failure has been reported.
fn removeContents(st: *State, dir: Target, seen: sys.FileStat) Contents {
    const env = st.env;
    var level: dirat.Level = undefined;
    if (dirat.enter(&level, dir.parent, dir.name, .{ .expect = seen, .same_device = st.opts.one_file_system })) |e| {
        // A directory that cannot be read can be removed if it is empty. As
        // GNU, not with -i, which has promised to look into it.
        if (e == .ACCES and st.opts.interactive != .always) {
            if (st.opts.interactive == .default and st.opts.stdin_tty and !writable(dir)) {
                if (!st.confirm.ask(.{ .path = dir.path, .kind = .directory, .size = seen.size, .action = .remove, .write_protected = true })) return .kept;
            }
            if (sys.unlinkAt(dirat.fdOf(dir.parent), dir.name, true) == null) {
                if (st.opts.verbose) st.observer.emit(.{ .removed = .{ .path = dir.path, .dir = true } });
                return .gone;
            }
        }
        st.observer.emit(.{ .unreadable = .{ .path = dir.path, .errno = e } });
        st.fail();
        return .kept;
    }
    var kept = false;
    var de: sys.E = .SUCCESS;
    if (sys.readDirNamesFd(env.gpa, level.fd, &de)) |names| {
        defer sys.freeDirEntries(env.gpa, names);
        for (names) |n| {
            // A level that could not be reopened cannot be worked in further.
            if (!level.open) break;
            const separator = if (std.mem.endsWith(u8, dir.path, "/")) "" else "/";
            const child = std.fmt.allocPrint(env.gpa, "{s}{s}{s}", .{ dir.path, separator, n.name }) catch {
                _ = failed(st, dir.path, .NOMEM);
                kept = true;
                break;
            };
            defer env.gpa.free(child);
            if (!remove(st, &level, n.name, child, false)) kept = true;
        }
    } else {
        st.observer.emit(.{ .unreadable = .{ .path = dir.path, .errno = de } });
        st.fail();
        kept = true;
    }
    if (dirat.leave(&level)) |e| {
        // The way back is gone: someone moved this directory meanwhile.
        _ = failed(st, dir.path, e);
        return .kept;
    }
    return if (kept) .kept else .empty;
}

fn kindOf(mode: u32) Io.File.Kind {
    return switch (mode & 0o170000) {
        0o100000 => .file,
        0o040000 => .directory,
        0o120000 => .sym_link,
        0o060000 => .block_device,
        0o020000 => .character_device,
        0o010000 => .named_pipe,
        0o140000 => .unix_domain_socket,
        else => .unknown,
    };
}

fn writable(file: Target) bool {
    return sys.accessAt(dirat.fdOf(file.parent), file.name, 2) == null;
}

fn removeEmptyDir(st: *State, dir: Target, lst: sys.FileStat) bool {
    const cfg = st.opts;
    const path = dir.path;
    if (cfg.interactive == .always) {
        if (!st.confirm.ask(.{ .path = path, .kind = .directory, .size = lst.size, .action = .remove, .write_protected = !writable(dir) })) return false;
    } else if (cfg.interactive == .default and cfg.stdin_tty and !writable(dir)) {
        if (!st.confirm.ask(.{ .path = path, .kind = .directory, .size = lst.size, .action = .remove, .write_protected = true })) return false;
    }
    if (sys.unlinkAt(dirat.fdOf(dir.parent), dir.name, true)) |e| {
        // rmdir("/") says EBUSY; GNU's message is the one for a non-empty directory.
        // Likewise "." (EINVAL) is reported as a non-empty directory.
        var root_err: sys.E = .SUCCESS;
        const root = sys.fileStat("/", false, &root_err);
        const busy_root = (e == .BUSY and root != null and sameFile(lst, root.?)) or (e == .INVAL and std.mem.endsWith(u8, std.mem.trimEnd(u8, path, "/"), "."));
        return failed(st, path, if (busy_root) .NOTEMPTY else e);
    }
    if (cfg.verbose) st.observer.emit(.{ .removed = .{ .path = path, .dir = true } });
    return true;
}
