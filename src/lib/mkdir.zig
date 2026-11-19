// SPDX-License-Identifier: GPL-2.0-or-later
//! mkdir library: make directories.
//! References: GNU coreutils manual "mkdir invocation" (9.7); POSIX.1-2024
//! mkdir.
//!
//! The final mode is set exactly (the caller resolves -m MODE against the
//! umask with src/mode.zig and passes the result). The directory is created
//! with the mode masked to rwx bits and then chmod'ed, so it is never less
//! restrictive than the mode (POSIX requirement). With `parents`, missing
//! parents get the umask-modified mode plus u+wx (GNU: "=rwx,u+wx") and
//! existing directories are not an error. SELinux/SMACK contexts are not
//! supported.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// -p: create missing parents, no error for an existing directory.
    parents: bool = false,
    /// Exact final mode (already resolved against the umask), or null for
    /// a=rwx - umask.
    mode: ?u16 = null,
    /// -v: report each created directory (`Event.created`).
    verbose: bool = false,
    /// The process umask, supplied by the caller (this library never reads or
    /// changes process-wide state).
    umask: u16 = 0o022,
};

pub const Event = union(enum) {
    /// A directory was created (the -v message).
    created: []const u8,
    /// A prefix of the path exists and is not a directory.
    not_a_directory: []const u8,
    /// The final component exists and is not a directory (-p).
    exists: []const u8,
    /// Creating `path` failed.
    create_failed: struct { path: []const u8, err: anyerror },
    /// Setting the permissions of `path` failed.
    chmod_failed: struct { path: []const u8, err: anyerror },
};
pub const Observer = common.Observer(Event);

/// Create each directory in turn; problems go to `observer` and the run
/// continues. Returns false when any directory failed.
pub fn run(env: Env, options: Options, dirs: []const []const u8, observer: Observer) bool {
    var ok = true;
    for (dirs) |d| {
        if (!makeOne(env, d, options, observer)) ok = false;
    }
    return ok;
}

/// Create `path` (and with `parents` its missing ancestors). Returns false
/// after reporting an error.
pub fn makeOne(env: Env, path: []const u8, options: Options, observer: Observer) bool {
    const io = env.io;
    if (options.parents) {
        // Walk the prefixes of the path, creating the missing ones.
        const trimmed = trimSlashes(path);
        var idx: usize = 0;
        while (idx < trimmed.len) {
            // End of the next component (skip leading slashes first).
            while (idx < trimmed.len and trimmed[idx] == '/') idx += 1;
            while (idx < trimmed.len and trimmed[idx] != '/') idx += 1;
            const prefix = trimmed[0..idx];
            const is_last = idx >= trimmed.len;
            if (is_last) break;
            const st = Io.Dir.cwd().statFile(io, prefix, .{});
            if (st) |s| {
                if (s.kind == .directory) continue;
                observer.emit(.{ .not_a_directory = prefix });
                return false;
            } else |_| {}
            // Parent mode: umask-modified rwx plus u+wx.
            const pmode: u16 = (0o777 & ~options.umask) | 0o300;
            Io.Dir.cwd().createDir(io, prefix, .fromMode(pmode)) catch |e| {
                if (e == error.PathAlreadyExists) continue;
                observer.emit(.{ .create_failed = .{ .path = prefix, .err = e } });
                return false;
            };
            if (pmode != (pmode & ~options.umask)) {
                Io.Dir.cwd().setFilePermissions(io, prefix, .fromMode(pmode), .{}) catch {};
            }
            if (options.verbose) observer.emit(.{ .created = prefix });
        }
        // Final component: an existing directory is not an error with -p.
        if (Io.Dir.cwd().statFile(io, trimmed, .{})) |s| {
            if (s.kind == .directory) return true;
            observer.emit(.{ .exists = path });
            return false;
        } else |_| {}
    }
    const create_mode: u16 = if (options.mode) |m| m & 0o777 else 0o777;
    Io.Dir.cwd().createDir(io, path, .fromMode(create_mode)) catch |e| {
        observer.emit(.{ .create_failed = .{ .path = path, .err = e } });
        return false;
    };
    if (options.verbose) observer.emit(.{ .created = path });
    if (options.mode) |m| {
        // The kernel applied the umask at creation; set the exact mode now.
        Io.Dir.cwd().setFilePermissions(io, path, .fromMode(m), .{}) catch |e| {
            observer.emit(.{ .chmod_failed = .{ .path = path, .err = e } });
            return false;
        };
    }
    return true;
}

fn trimSlashes(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') end -= 1;
    return p[0..end];
}

test "trimSlashes" {
    try std.testing.expectEqualStrings("a/b", trimSlashes("a/b//"));
    try std.testing.expectEqualStrings("/", trimSlashes("///"));
    try std.testing.expectEqualStrings("a", trimSlashes("a"));
}
