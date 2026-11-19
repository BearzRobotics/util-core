// SPDX-License-Identifier: GPL-2.0-or-later
//! arch: print the machine hardware name, same as uname -m (library form,
//! decision 0004).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const Options = struct {};

/// Writes the machine hardware name and a newline.
pub fn run(env: Env, opts: Options, out: *Io.Writer) Io.Writer.Error!void {
    _ = env;
    _ = opts;
    const u = sys.uname();
    try out.print("{s}\n", .{u.machine()});
}
