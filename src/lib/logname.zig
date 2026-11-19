// SPDX-License-Identifier: GPL-2.0-or-later
//! logname: print the user's login name (library form, decision 0004).
//!
//! glibc's getlogin() first consults /proc/self/loginuid; the utmp fallback is
//! not implemented, so a session known only to utmp reports no login name.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const userdb = @import("../userdb.zig");

pub const Env = common.Env;

pub const Options = struct {};

pub const Result = enum { printed, no_login_name };

/// The login name (caller frees), or null when there is no login session.
pub fn loginName(env: Env) ?[]u8 {
    const f = Io.Dir.cwd().openFile(env.io, "/proc/self/loginuid", .{}) catch return null;
    defer f.close(env.io);
    var buf: [32]u8 = undefined;
    const n = common.readChunk(env.io, f, &buf) catch return null;
    const uid = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..n], " \n\x00"), 10) catch return null;
    if (uid == std.math.maxInt(u32)) return null; // (uid_t)-1: no login session
    var db = userdb.Db.load(env.gpa, env.io);
    defer db.deinit();
    const u = db.userByUid(uid) orelse return null;
    return env.gpa.dupe(u8, u.name) catch null;
}

/// Writes the login name and a newline.
pub fn run(env: Env, opts: Options, out: *Io.Writer) Io.Writer.Error!Result {
    _ = opts;
    const name = loginName(env) orelse return .no_login_name;
    defer env.gpa.free(name);
    try out.print("{s}\n", .{name});
    return .printed;
}
