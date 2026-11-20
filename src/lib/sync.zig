// SPDX-License-Identifier: GPL-2.0-or-later
//! sync: flush file system buffers (library form, decision 0004).
//!
//! No files: sync(2). With files: fsync, or fdatasync (`.data`), or syncfs
//! (`.fs`) on each. Combining modes and requiring operands for --data are
//! argument rules, checked by the caller.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const Options = struct {
    mode: Mode = .file,

    pub const Mode = enum { file, data, fs };
};

pub const Event = union(enum) {
    /// `name` could not be opened.
    open_failed: struct { name: []const u8, err: anyerror },
    /// Synchronising the open `name` failed.
    sync_failed: struct { name: []const u8, errno: std.os.linux.E },
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// At least one file failed (events were emitted for each).
    failed: bool = false,
};

/// Synchronises `files`, or everything when there are none.
pub fn run(env: Env, opts: Options, files: []const []const u8, obs: Observer) Result {
    var res: Result = .{};
    if (files.len == 0) {
        _ = sys.syncFile(sys.invalid_handle, .all);
        return res;
    }
    for (files) |name| {
        const f = Io.Dir.cwd().openFile(env.io, name, .{ .mode = .read_only, .allow_directory = true }) catch |e| {
            obs.emit(.{ .open_failed = .{ .name = name, .err = e } });
            res.failed = true;
            continue;
        };
        defer f.close(env.io);
        const kind: sys.SyncKind = switch (opts.mode) {
            .data => .data,
            .fs => .fs,
            .file => .file,
        };
        if (sys.syncFile(f.handle, kind)) |e| {
            obs.emit(.{ .sync_failed = .{ .name = name, .errno = e } });
            res.failed = true;
        }
    }
    return res;
}
