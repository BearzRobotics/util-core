// SPDX-License-Identifier: GPL-2.0-or-later
//! sync: flush file system buffers (library form, decision 0004).
//!
//! No files: sync(2). With files: fsync, or fdatasync (`.data`), or syncfs
//! (`.fs`) on each. Combining modes and requiring operands for --data are
//! argument rules, checked by the caller.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const Options = struct {
    mode: Mode = .file,

    pub const Mode = enum { file, data, fs };
};

pub const Event = union(enum) {
    /// `name` could not be opened.
    open_failed: struct { name: []const u8, errno: std.os.linux.E },
    /// The open `name` could not be put back into blocking mode.
    blocking_failed: struct { name: []const u8, errno: std.os.linux.E },
    /// Synchronising the open `name` failed.
    sync_failed: struct { name: []const u8, errno: std.os.linux.E },
    /// close() failed: some file systems only report a failed write there.
    close_failed: struct { name: []const u8, errno: std.os.linux.E },
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// At least one file failed (events were emitted for each).
    failed: bool = false,
};

/// Open an operand as GNU sync.c does: for reading, or for writing when
/// that is refused, and without waiting (opening a FIFO waits for the other
/// end). On failure `err` says why it could not be read.
fn openOperand(name: []const u8, err: *std.os.linux.E) ?sys.Handle {
    if (sys.openFd(name, sys.O.RDONLY | sys.O.NONBLOCK, 0, err)) |fd| return fd;
    var write_error: std.os.linux.E = .SUCCESS;
    return sys.openFd(name, sys.O.WRONLY | sys.O.NONBLOCK, 0, &write_error);
}

/// `openOperand` only keeps the open from waiting; the calls after it may.
fn makeBlocking(fd: sys.Handle) ?std.os.linux.E {
    var err: std.os.linux.E = .SUCCESS;
    const flags = sys.getStatusFlags(fd, &err) orelse return err;
    return sys.setStatusFlags(fd, flags & ~@as(usize, sys.O.NONBLOCK));
}

/// Synchronises `files`, or everything when there are none.
pub fn run(_: Env, opts: Options, files: []const []const u8, obs: Observer) Result {
    var res: Result = .{};
    if (files.len == 0) {
        _ = sys.syncFile(sys.invalid_handle, .all);
        return res;
    }
    for (files) |name| {
        var open_error: std.os.linux.E = .SUCCESS;
        const fd = openOperand(name, &open_error) orelse {
            obs.emit(.{ .open_failed = .{ .name = name, .errno = open_error } });
            res.failed = true;
            continue;
        };
        const kind: sys.SyncKind = switch (opts.mode) {
            .data => .data,
            .fs => .fs,
            .file => .file,
        };
        if (makeBlocking(fd)) |e| {
            obs.emit(.{ .blocking_failed = .{ .name = name, .errno = e } });
            res.failed = true;
        } else if (sys.syncFile(fd, kind)) |e| {
            obs.emit(.{ .sync_failed = .{ .name = name, .errno = e } });
            res.failed = true;
        }
        if (sys.closeFd(fd)) |e| {
            obs.emit(.{ .close_failed = .{ .name = name, .errno = e } });
            res.failed = true;
        }
    }
    return res;
}

// These open operands but never call `run`, which would sync.
test "an operand is opened without waiting, for writing if need be" {
    if (builtin.os.tag != .linux) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var err: std.os.linux.E = .SUCCESS;
    var buf: [128]u8 = undefined;

    // A FIFO that nothing writes to: a waiting open would never return.
    const fifo = try std.fmt.bufPrintSentinel(&buf, ".zig-cache/tmp/{s}/fifo", .{tmp.sub_path}, 0);
    try std.testing.expectEqual(null, sys.mknod(fifo, 0o010600, 0));
    const p = openOperand(fifo, &err).?;
    defer _ = sys.closeFd(p);
    try std.testing.expectEqual(null, makeBlocking(p));
    try std.testing.expectEqual(0, sys.getStatusFlags(p, &err).? & sys.O.NONBLOCK);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wo", .data = "x" });
    const wo = try std.fmt.bufPrintSentinel(&buf, ".zig-cache/tmp/{s}/wo", .{tmp.sub_path}, 0);
    try std.testing.expectEqual(null, sys.chmodPath(wo, 0o200, false));
    const w = openOperand(wo, &err).?;
    _ = sys.closeFd(w);

    // The reason is the read-only open's.
    const missing = try std.fmt.bufPrintSentinel(&buf, ".zig-cache/tmp/{s}/missing", .{tmp.sub_path}, 0);
    try std.testing.expectEqual(null, openOperand(missing, &err));
    try std.testing.expectEqual(std.os.linux.E.NOENT, err);
}
