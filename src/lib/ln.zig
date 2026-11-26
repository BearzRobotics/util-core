// SPDX-License-Identifier: GPL-2.0-or-later
//! ln library: make links between files.
//! Reference: GNU coreutils manual "ln invocation" (9.7); POSIX.1-2024 ln.
//!
//! Same-file detection compares inode numbers only (std.Io.File.Stat has no
//! device number), so two files on different devices that share an inode
//! number are wrongly taken for one file.
//!
//! The caller decides which operands are sources and what the destination is
//! (`Target`); this module creates the links, handles existing destinations
//! and backups, and reports through the `Observer`.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const paths = @import("../paths.zig");
const sys = @import("../sys.zig");
const replacelink = @import("../replacelink.zig");

pub const Env = common.Env;

pub const Backup = enum { none, simple, numbered, existing };

pub const Options = struct {
    symbolic: bool = false,
    force: bool = false,
    interactive: bool = false,
    /// -L: hard links follow a symlink source.
    logical: bool = false,
    relative: bool = false,
    verbose: bool = false,
    backup: Backup = .none,
    suffix: []const u8 = "~",
};

/// Where the links go.
pub const Target = union(enum) {
    /// Each source is linked into this directory under its base name.
    dir: []const u8,
    /// A single source is linked to exactly this name (`sources` has one
    /// entry).
    name: []const u8,
};

pub const Event = union(enum) {
    /// `-v`: `dest` now links to `src`; `backup` is the name the old
    /// destination was moved to.
    linked: struct { dest: []const u8, src: []const u8, symbolic: bool, backup: ?[]const u8 },
    /// Source could not be accessed (hard links).
    cannot_access: struct { path: []const u8, err: anyerror },
    /// Hard link to a directory refused.
    directory_source: []const u8,
    /// The destination exists and none of force/interactive/backup was given.
    exists: struct { dest: []const u8, symbolic: bool },
    same_file: struct { src: []const u8, dest: []const u8 },
    backup_failed: struct { dest: []const u8, err: anyerror },
    remove_failed: struct { dest: []const u8, err: anyerror },
    link_failed: struct { dest: []const u8, src: []const u8, symbolic: bool, errno: sys.E },
    /// After a failed link, the backup could not be renamed back to `dest`.
    unbackup_failed: struct { dest: []const u8, errno: sys.E },
};
pub const Observer = common.Observer(Event);

/// Asked before replacing `dest` with -i; true means go ahead.
pub const Confirm = struct {
    context: ?*anyopaque = null,
    func: *const fn (context: ?*anyopaque, dest: []const u8) bool,
};

/// Link every source; returns false when any failed.
pub fn run(env: Env, options: Options, sources: []const []const u8, target: Target, observer: Observer, confirm: Confirm) error{OutOfMemory}!bool {
    var ok = true;
    switch (target) {
        .dir => |d| for (sources) |src| {
            const base = baseName(src);
            const dest = if (std.mem.endsWith(u8, d, "/"))
                try std.fmt.allocPrint(env.gpa, "{s}{s}", .{ d, base })
            else
                try std.fmt.allocPrint(env.gpa, "{s}/{s}", .{ d, base });
            defer env.gpa.free(dest);
            if (!try link(env, options, src, dest, observer, confirm)) ok = false;
        },
        .name => |dest| {
            if (!try link(env, options, sources[0], dest, observer, confirm)) ok = false;
        },
    }
    return ok;
}

pub fn baseName(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') end -= 1;
    const s = p[0..end];
    const idx = std.mem.lastIndexOfScalar(u8, s, '/') orelse return s;
    return if (idx + 1 < s.len) s[idx + 1 ..] else s;
}

fn exists(env: Env, path: []const u8) ?Io.File.Stat {
    return Io.Dir.cwd().statFile(env.io, path, .{ .follow_symlinks = false }) catch null;
}

/// Make one link `dest` -> `src`. Returns false after reporting a failure.
pub fn link(env: Env, cfg: Options, src: []const u8, dest: []const u8, observer: Observer, confirm: Confirm) error{OutOfMemory}!bool {
    const cwd = Io.Dir.cwd();

    // Source checks for hard links.
    var src_stat: ?Io.File.Stat = null;
    if (!cfg.symbolic) {
        const st = cwd.statFile(env.io, src, .{ .follow_symlinks = cfg.logical }) catch |e| {
            observer.emit(.{ .cannot_access = .{ .path = src, .err = e } });
            return false;
        };
        if (st.kind == .directory) {
            observer.emit(.{ .directory_source = src });
            return false;
        }
        src_stat = st;
    }

    var made_backup: ?[]u8 = null;
    var replacing = false; // -f or -i, without a backup
    defer if (made_backup) |b| env.gpa.free(b);
    if (exists(env, dest)) |dst| {
        if (!cfg.force and !cfg.interactive and cfg.backup == .none) {
            observer.emit(.{ .exists = .{ .dest = dest, .symbolic = cfg.symbolic } });
            return false;
        }
        if (src_stat == null) {
            // Symbolic links: the source need not exist, but if it does, a
            // destination that is the same file is refused.
            src_stat = cwd.statFile(env.io, src, .{ .follow_symlinks = cfg.logical }) catch null;
        }
        if (src_stat) |ss| {
            if (ss.inode == dst.inode and cfg.backup == .none) {
                observer.emit(.{ .same_file = .{ .src = src, .dest = dest } });
                return false;
            }
        }
        if (cfg.interactive) {
            if (!confirm.func(confirm.context, dest)) return false;
        }
        if (cfg.backup != .none) {
            const bname = backupName(env, cfg, dest) orelse return error.OutOfMemory;
            cwd.rename(dest, cwd, bname, env.io) catch |e| {
                observer.emit(.{ .backup_failed = .{ .dest = dest, .err = e } });
                env.gpa.free(bname);
                return false;
            };
            made_backup = bname;
        } else {
            if (src_stat) |ss| if (ss.inode == dst.inode) {
                observer.emit(.{ .same_file = .{ .src = src, .dest = dest } });
                return false;
            };
            if (dst.kind == .directory) {
                observer.emit(.{ .remove_failed = .{ .dest = dest, .err = error.IsDir } });
                return false;
            }
            replacing = true;
        }
    }

    var target: []const u8 = src;
    var rel: ?[]u8 = null;
    defer if (rel) |r| env.gpa.free(r);
    if (cfg.symbolic and cfg.relative) {
        rel = relativeSymlinkTarget(env, src, dest);
        if (rel) |r| target = r;
    }
    const kind: replacelink.Kind = if (cfg.symbolic) .symbolic else .{ .hard = .{ .follow = cfg.logical } };
    const failure = if (replacing)
        replacelink.replace(env.io, target, dest, kind)
    else switch (kind) {
        .symbolic => sys.symlinkPath(target, dest),
        .hard => |h| sys.linkPath(target, dest, h.follow),
    };
    if (failure) |errno| {
        observer.emit(.{ .link_failed = .{ .dest = dest, .src = src, .symbolic = cfg.symbolic, .errno = errno } });
        if (made_backup) |b| {
            if (sys.renamePath(b, dest, 0)) |re| observer.emit(.{ .unbackup_failed = .{ .dest = dest, .errno = re } });
        }
        return false;
    }
    if (cfg.verbose) observer.emit(.{ .linked = .{ .dest = dest, .src = target, .symbolic = cfg.symbolic, .backup = made_backup } });
    return true;
}

fn backupName(env: Env, cfg: Options, dest: []const u8) ?[]u8 {
    var kind = cfg.backup;
    if (kind == .existing) {
        // Numbered when a numbered backup of this file already exists.
        var n: usize = 1;
        kind = .simple;
        while (n < 10) : (n += 1) {
            const cand = std.fmt.allocPrint(env.gpa, "{s}.~{d}~", .{ dest, n }) catch return null;
            defer env.gpa.free(cand);
            if (exists(env, cand) != null) {
                kind = .numbered;
                break;
            }
        }
    }
    if (kind == .simple) return std.fmt.allocPrint(env.gpa, "{s}{s}", .{ dest, cfg.suffix }) catch null;
    var n: usize = 1;
    while (true) : (n += 1) {
        const cand = std.fmt.allocPrint(env.gpa, "{s}.~{d}~", .{ dest, n }) catch return null;
        if (exists(env, cand) == null) return cand;
        env.gpa.free(cand);
    }
}

/// Target of a relative symlink named `dest` pointing at `src`.
fn relativeSymlinkTarget(env: Env, src: []const u8, dest: []const u8) ?[]u8 {
    const src_abs = paths.resolve(env, src, .missing) catch return null;
    defer env.gpa.free(src_abs);
    const dest_dir_part = if (std.mem.lastIndexOfScalar(u8, dest, '/')) |i| (if (i == 0) "/" else dest[0..i]) else ".";
    const dir_abs = paths.resolve(env, dest_dir_part, .missing) catch return null;
    defer env.gpa.free(dir_abs);
    return paths.relativeTo(env.gpa, src_abs, dir_abs) catch null;
}
