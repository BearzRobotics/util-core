// SPDX-License-Identifier: GPL-2.0-or-later
//! dirname: strip the last path component (library form, decision 0004).
//! Only '/' is a separator (see basename.zig).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// Byte that ends each output line (NUL with -z).
    terminator: u8 = '\n',
};

/// Writes the directory part of each of `names`, each followed by the
/// terminator.
pub fn run(env: Env, opts: Options, names: []const []const u8, out: *Io.Writer) Io.Writer.Error!void {
    _ = env;
    for (names) |n| {
        try out.writeAll(dirName(n));
        try out.writeByte(opts.terminator);
    }
}

/// POSIX dirname. The result borrows from `path` (or is a static literal).
pub fn dirName(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1; // trailing slashes
    if (end == 1 and path[0] == '/') return "/";
    // Drop the last component.
    while (end > 0 and path[end - 1] != '/') end -= 1;
    if (end == 0) return ".";
    // Drop the slashes that separated it from the parent.
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

test "dirName" {
    const t = std.testing;
    try t.expectEqualStrings("/usr/bin", dirName("/usr/bin/echo"));
    try t.expectEqualStrings("/usr", dirName("/usr/bin/"));
    try t.expectEqualStrings(".", dirName("echo"));
    try t.expectEqualStrings(".", dirName(""));
    try t.expectEqualStrings("/", dirName("/"));
    try t.expectEqualStrings("/", dirName("///"));
    try t.expectEqualStrings("/", dirName("/a"));
    try t.expectEqualStrings("a", dirName("a//b"));
    try t.expectEqualStrings("a", dirName("a/b/"));
    try t.expectEqualStrings(".", dirName("a/"));
    try t.expectEqualStrings("..", dirName("../x"));
}
