// SPDX-License-Identifier: GPL-2.0-or-later
//! pwd: print the working directory (library form, decision 0004).
//!
//! POSIX defaults to -L; GNU's standalone pwd defaults to -P unless
//! POSIXLY_CORRECT is set (the caller decides, via `Options.logical`).
//! Logical mode uses $PWD only if it is absolute, has no "." or ".."
//! component, and names the same directory as the physical working directory;
//! otherwise it behaves like physical mode (both specs).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// -L: prefer $PWD (from `Env.environ`) when it is valid.
    logical: bool = false,
};

pub const Error = std.process.CurrentPathError || Io.Writer.Error;

/// The directory to print, in `buf`'s storage or borrowed from the
/// environment. Fails when the current directory cannot be determined.
pub fn currentDir(env: Env, opts: Options, buf: *[Io.Dir.max_path_bytes]u8) std.process.CurrentPathError![]const u8 {
    const n = try std.process.currentPath(env.io, buf);
    const physical = buf[0..n];
    if (opts.logical) if (env.getenv("PWD")) |env_pwd| {
        if (pwdIsValid(env.io, env_pwd, physical)) return env_pwd;
    };
    return physical;
}

/// Writes the working directory and a newline.
pub fn run(env: Env, opts: Options, out: *Io.Writer) Error!void {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try currentDir(env, opts, &buf);
    try out.writeAll(path);
    try out.writeByte('\n');
}

/// True when `candidate` is absolute, free of "." / ".." components, and
/// resolves to the same directory as `physical`.
fn pwdIsValid(io: Io, candidate: []const u8, physical: []const u8) bool {
    if (!hasNoDotComponents(candidate)) return false;
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = Io.Dir.realPathFileAbsolute(io, candidate, &buf) catch return false;
    return std.mem.eql(u8, buf[0..n], physical);
}

fn hasNoDotComponents(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

test "hasNoDotComponents" {
    const t = std.testing;
    try t.expect(hasNoDotComponents("/a/b"));
    try t.expect(hasNoDotComponents("/"));
    try t.expect(!hasNoDotComponents("a/b"));
    try t.expect(!hasNoDotComponents("/a/./b"));
    try t.expect(!hasNoDotComponents("/a/../b"));
    try t.expect(!hasNoDotComponents(""));
}
