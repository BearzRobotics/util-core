// SPDX-License-Identifier: GPL-2.0-or-later
//! mkfifo library: make named pipes.
//! Reference: GNU coreutils manual "mkfifo invocation" (9.7); POSIX.1-2024 mkfifo.
//!
//! The caller supplies the umask: reading it is a process-wide operation, so
//! it stays in the wrapper.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const mode_mod = @import("../mode.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const ModeError = error{ InvalidMode, NotPermissionBits };

/// Resolve the -m text to the exact permission bits (null without -m).
pub fn resolveMode(text: ?[]const u8, umask: u16) ModeError!?u16 {
    const t = text orelse return null;
    const final = mode_mod.apply(t, 0o666, false, umask) orelse return error.InvalidMode;
    if (final > 0o777) return error.NotPermissionBits;
    return final;
}

pub const Failure = union(enum) {
    /// mknod(2) failed.
    create: std.os.linux.E,
    /// The follow-up chmod for -m failed.
    permissions: anyerror,
};

pub const Event = struct { name: []const u8, failure: Failure };
pub const Observer = common.Observer(Event);

/// Create each FIFO in `names`; `final` is from `resolveMode`. A failing name
/// is reported to `obs` and the rest are still made. Returns whether all
/// succeeded.
pub fn run(env: Env, final: ?u16, names: []const []const u8, obs: Observer) error{OutOfMemory}!bool {
    var ok = true;
    for (names) |name| {
        const z = try env.gpa.dupeSentinel(u8, name, 0);
        defer env.gpa.free(z);
        // With -m the exact mode is set afterwards, so the umask cannot take bits away.
        if (sys.mknod(z, 0o010000 | (final orelse 0o666), 0)) |e| {
            obs.emit(.{ .name = name, .failure = .{ .create = e } });
            ok = false;
            continue;
        }
        if (final) |m| Io.Dir.cwd().setFilePermissions(env.io, name, sys.permissionsFromMode(m), .{}) catch |e| {
            obs.emit(.{ .name = name, .failure = .{ .permissions = e } });
            ok = false;
        };
    }
    return ok;
}
