// SPDX-License-Identifier: GPL-2.0-or-later
//! unlink library: remove one file name by calling unlink(2).
//! Reference: GNU coreutils manual "unlink invocation" (9.7).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

/// Remove `path` (relative to the current directory). The error is the
/// system's; the caller words it.
pub fn run(env: Env, path: []const u8) Io.Dir.DeleteFileError!void {
    try Io.Dir.cwd().deleteFile(env.io, path);
}
