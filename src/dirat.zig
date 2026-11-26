// SPDX-License-Identifier: GPL-2.0-or-later
//! Descriptor-relative directory traversal for the commands that walk trees.
//!
//! A walker that hands full path strings to the kernel resolves every
//! component again at each call. Someone who can rename directories in the
//! tree can then put a symbolic link where a directory was and send the walker
//! (and what it deletes or runs) somewhere else, and nothing past PATH_MAX can
//! be reached at all. So a walker keeps the directory it is reading open and
//! names each entry relative to it: `sys.fileStatAt`, `sys.unlinkAt` and the
//! others, with the descriptor from `fdOf` and the bare entry name.
//!
//! Ownership: `enter` fills in a caller-owned `Level`, usually on the stack of
//! the recursive walker; `leave` closes it. A level must not move while a
//! child level points to it.
//!
//! Only the deepest `max_open` levels stay open, so that a deep tree does not
//! use up the descriptors. `leave` reopens a closed parent through the
//! child's ".." and checks that it is the same directory. A level entered
//! through a symbolic link keeps its parent open, since ".." would lead
//! elsewhere. Path strings are for messages only.
//!
//! The walkers recurse, one stack frame per level, and keep each level's path
//! for messages, so `enter` refuses to go deeper than `max_depth` levels or
//! `max_path` bytes of names (ENAMETOOLONG) instead of letting a made-up tree
//! overflow the stack or exhaust memory.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");

/// Windows cannot open ".." from a handle, so everything stays open there.
const max_open: usize = if (builtin.os.tag == .windows) std.math.maxInt(usize) else 32;

/// Unoptimised frames are several times larger.
pub const max_depth = if (builtin.mode == .debug) 4_000 else 10_000;
pub const max_path = 64 * 1024;

pub const Level = struct {
    parent: ?*Level,
    fd: sys.Handle,
    open: bool,
    dev: u64,
    ino: u64,
    /// The name this level was entered by is a symbolic link.
    through_link: bool,
    depth: usize,
    /// Bytes in the names from the first level down, separators included.
    path_len: usize,
};

pub fn devOf(st: sys.FileStat) u64 {
    return (@as(u64, st.dev_major) << 32) | st.dev_minor;
}

/// The descriptor that names in the directory `level` are relative to; the
/// current directory for null (the operands of a command).
pub fn fdOf(level: ?*const Level) sys.Handle {
    const l = level orelse return sys.cwdFd();
    return l.fd;
}

pub const Options = struct {
    /// Follow `name` when it is a symbolic link. Otherwise it is refused
    /// with ENOTDIR.
    follow: bool = false,
    /// What the caller saw (and decided on) when it examined the entry. A
    /// different directory in its place is refused with ENOENT. A different
    /// device alone is accepted: renaming cannot move a directory between
    /// devices, but opening an automount point mounts it.
    expect: ?sys.FileStat = null,
    /// Refuse a different device too (find -xdev).
    same_device: bool = false,
};

/// Open the directory `name` in `parent` (null: relative to the current
/// directory) as `level`. Returns null on success and the errno otherwise;
/// `level` is then unused.
pub fn enter(level: *Level, parent: ?*Level, name: []const u8, options: Options) ?sys.E {
    const depth = if (parent) |p| p.depth + 1 else 0;
    const path_len = name.len + if (parent) |p| p.path_len + 1 else 0;
    if (depth > max_depth or path_len > max_path) return .NAMETOOLONG;
    var err: sys.E = .SUCCESS;
    const nofollow: u32 = if (options.follow) 0 else sys.O.NOFOLLOW;
    const fd = sys.openFdAt(fdOf(parent), name, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NONBLOCK | nofollow, 0, &err) orelse return err;
    const st = sys.fstatFd(fd, &err) orelse {
        _ = sys.closeFd(fd);
        return err;
    };
    if (options.expect) |seen| {
        const other_device = devOf(seen) != devOf(st);
        if ((other_device and options.same_device) or (!other_device and seen.ino != st.ino)) {
            _ = sys.closeFd(fd);
            return .NOENT;
        }
    }
    var through_link = false;
    if (options.follow) {
        const own = sys.fileStatAt(fdOf(parent), name, false, &err);
        through_link = own == null or own.?.isLink();
    }
    level.* = .{ .parent = parent, .fd = fd, .open = true, .dev = devOf(st), .ino = st.ino, .through_link = through_link, .depth = depth, .path_len = path_len };

    // Close the ancestor that has just become the max_open'th.
    var child = level;
    var steps: usize = 1;
    while (steps < max_open) : (steps += 1) child = child.parent orelse return null;
    const old = child.parent orelse return null;
    if (old.open and !child.through_link) {
        _ = sys.closeFd(old.fd);
        old.open = false;
        old.fd = sys.invalid_handle;
    }
    return null;
}

/// Close `level` and make its parent usable again. Returns the errno when the
/// parent had been closed and cannot be had back (ENOENT: the directory was
/// moved meanwhile); the caller must then stop working in the parent.
pub fn leave(level: *Level) ?sys.E {
    defer {
        if (level.open) _ = sys.closeFd(level.fd);
        level.open = false;
        level.fd = sys.invalid_handle;
    }
    const parent = level.parent orelse return null;
    if (parent.open) return null;
    if (!level.open) return .NOENT;
    var err: sys.E = .SUCCESS;
    const fd = sys.openFdAt(level.fd, "..", sys.O.RDONLY | sys.O.DIRECTORY, 0, &err) orelse return err;
    const st = sys.fstatFd(fd, &err) orelse {
        _ = sys.closeFd(fd);
        return err;
    };
    if (devOf(st) != parent.dev or st.ino != parent.ino) {
        _ = sys.closeFd(fd);
        return .NOENT;
    }
    parent.fd = fd;
    parent.open = true;
    return null;
}

test "walking past the open limit, links and replaced directories" {
    if (builtin.os.tag != .linux) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const depth = max_open + 8;
    var path_buf: [4096]u8 = undefined;
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var w: std.Io.Writer = .fixed(&path_buf);
    for (0..depth) |_| {
        try w.writeAll("d/");
        try tmp.dir.createDirPath(io, w.buffered()[0 .. w.buffered().len - 1]);
    }

    var top: Level = undefined;
    try std.testing.expectEqual(@as(?sys.E, null), enter(&top, null, root, .{}));
    var levels: [depth]Level = undefined;
    var parent: *Level = &top;
    for (&levels) |*l| {
        try std.testing.expectEqual(@as(?sys.E, null), enter(l, parent, "d", .{}));
        parent = l;
    }
    try std.testing.expect(!top.open);
    var i: usize = depth;
    while (i > 0) {
        i -= 1;
        try std.testing.expectEqual(@as(?sys.E, null), leave(&levels[i]));
    }
    try std.testing.expect(top.open);

    var err: sys.E = .SUCCESS;
    const seen = sys.fileStatAt(top.fd, "d", false, &err).?;
    try tmp.dir.rename("d", tmp.dir, "moved", io);
    try tmp.dir.symLink(io, "moved", "d", .{});
    var child: Level = undefined;
    try std.testing.expectEqual(@as(?sys.E, .NOTDIR), enter(&child, &top, "d", .{}));
    try tmp.dir.deleteFile(io, "d");
    try tmp.dir.createDir(io, "d", .default_dir);
    try std.testing.expectEqual(@as(?sys.E, .NOENT), enter(&child, &top, "d", .{ .expect = seen }));
    _ = leave(&top);
}
