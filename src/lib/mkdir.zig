// SPDX-License-Identifier: GPL-2.0-or-later
//! mkdir library: make directories.
//! References: GNU coreutils manual "mkdir invocation" (9.7); POSIX.1-2024
//! mkdir.
//!
//! Each directory is created and changed relative to its open parent
//! (dirat.zig), and the change is refused if a symbolic link has taken the new
//! directory's place.
//!
//! The caller resolves -m MODE against the umask with src/mode.zig and passes
//! the result and the bits the text decided (`Options.mode_decided`). As in
//! GNU (gnulib mkdir-p and dirchownmod), the directory gets exactly the mode
//! in those bits; a set-ID bit it inherited stays unless decided. With
//! `parents`, missing parents get the umask-modified mode plus u+wx (GNU:
//! "=rwx,u+wx") and keep what they inherit, and existing directories are not
//! an error. SELinux/SMACK contexts are not supported.

const std = @import("std");
const sys = @import("../sys.zig");
const dirat = @import("../dirat.zig");
const mode_mod = @import("../mode.zig");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// -p: create missing parents, no error for an existing directory.
    parents: bool = false,
    /// Exact final mode (already resolved against the umask), or null for
    /// a=rwx - umask.
    mode: ?u16 = null,
    /// The bits of `mode` that its text decides (the `decided` of mode.zig's
    /// `applyTracked`). Null: as for `mode` written in octal, which leaves an
    /// inherited set-ID bit unless `mode` sets it.
    mode_decided: ?u16 = null,
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
    create_failed: struct { path: []const u8, errno: sys.E },
    /// Setting the permissions of `path` failed.
    chmod_failed: struct { path: []const u8, errno: sys.E },
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
            var pe: sys.E = .SUCCESS;
            const spot = dirat.Spot.open(prefix, &pe) orelse {
                observer.emit(.{ .create_failed = .{ .path = prefix, .errno = pe } });
                return false;
            };
            defer spot.close();
            if (sys.mkdirAt(spot.dir, spot.name, pmode)) |e| {
                if (e == .EXIST) continue;
                observer.emit(.{ .create_failed = .{ .path = prefix, .errno = e } });
                return false;
            }
            // The kernel's set-group-ID inheritance must survive this.
            if (pmode != (pmode & ~options.umask)) _ = spot.setModeKeeping(0o040000, pmode, 0o7000);
            if (options.verbose) observer.emit(.{ .created = prefix });
        }
        // Final component: an existing directory is not an error with -p.
        if (Io.Dir.cwd().statFile(io, trimmed, .{})) |s| {
            if (s.kind == .directory) return true;
            observer.emit(.{ .exists = path });
            return false;
        } else |_| {}
    }
    var decided: u16 = 0;
    var create_mode: u16 = 0o777;
    if (options.mode) |m| {
        decided = options.mode_decided orelse ((m & mode_mod.set_id_bits) | 0o1777);
        // With special bits to settle afterwards, GNU creates the directory
        // closed to writing by others, and that shows where the mode leaves
        // the write bits open ("g-s" gives rwxr-xr-x).
        const special = decided & mode_mod.set_id_bits != 0 or m & 0o1000 != 0;
        create_mode = m & @as(u16, if (special) 0o1755 else 0o1777);
    }
    var pe: sys.E = .SUCCESS;
    const spot = dirat.Spot.open(path, &pe) orelse {
        observer.emit(.{ .create_failed = .{ .path = path, .errno = pe } });
        return false;
    };
    defer spot.close();
    if (sys.mkdirAt(spot.dir, spot.name, create_mode)) |e| {
        // With -p it does not matter who made the directory, also when that
        // happened after the look above. Its mode is left as it is.
        if (options.parents and e == .EXIST) {
            if (Io.Dir.cwd().statFile(io, path, .{})) |s| {
                if (s.kind == .directory) return true;
            } else |_| {}
        }
        observer.emit(.{ .create_failed = .{ .path = path, .errno = e } });
        return false;
    }
    if (options.verbose) observer.emit(.{ .created = path });
    if (options.mode) |m| {
        // The kernel applied the umask at creation; set the exact mode now.
        if (setNewMode(spot, create_mode, m, decided)) |e| {
            observer.emit(.{ .chmod_failed = .{ .path = path, .errno = e } });
            return false;
        }
    }
    return true;
}

/// Give the directory just created with `create_mode` its final mode: `mode`
/// where a decided bit is not yet right, and what it already has (counting an
/// inherited set-ID bit) everywhere else.
fn setNewMode(spot: dirat.Spot, create_mode: u16, mode: u16, decided: u16) ?sys.E {
    var err: sys.E = .SUCCESS;
    const now = sys.fileStatAt(spot.dir, spot.name, false, &err) orelse return err;
    const had: u32 = create_mode | (now.mode & mode_mod.set_id_bits);
    const wrong = (had ^ mode) & decided != 0;
    return spot.setMode(0o040000, if (wrong) mode | (had & ~@as(u32, decided)) else had);
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
