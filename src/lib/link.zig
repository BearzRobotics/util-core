// SPDX-License-Identifier: GPL-2.0-or-later
//! link library: create a hard link by calling link(2).
//! Reference: GNU coreutils manual "link invocation" (9.7).

const std = @import("std");
const builtin = @import("builtin");
const winapi = @import("../sys/windows.zig");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

/// Make `new` a hard link to `existing` (both relative to the current
/// directory). The error is the system's; the caller words it.
pub fn run(env: Env, existing: []const u8, new: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (comptime builtin.os.tag == .windows) return winapi.hardLink(cwd.handle, existing, cwd.handle, new, false);
    try cwd.hardLink(existing, cwd, new, env.io, .{});
}
