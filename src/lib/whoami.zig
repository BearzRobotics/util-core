// SPDX-License-Identifier: GPL-2.0-or-later
//! whoami: print the user name of the effective user ID (library form,
//! decision 0004).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");
const userdb = @import("../userdb.zig");

pub const Env = common.Env;

pub const Options = struct {};

pub const Result = union(enum) {
    /// The name was written.
    printed,
    /// The effective user ID has no name in the user database.
    no_name: u32,
};

/// Writes the effective user's name and a newline.
pub fn run(env: Env, opts: Options, out: *Io.Writer) Io.Writer.Error!Result {
    _ = opts;
    var db = userdb.Db.load(env.gpa, env.io);
    defer db.deinit();
    const id = sys.identity();
    const u = db.userByUid(id.euid) orelse return .{ .no_name = id.euid };
    try out.print("{s}\n", .{u.name});
    return .printed;
}
