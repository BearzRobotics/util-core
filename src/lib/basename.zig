// SPDX-License-Identifier: GPL-2.0-or-later
//! basename: strip directory and suffix (library form, decision 0004).
//!
//! Only '/' is treated as a separator (also on Windows; backslash handling is
//! not yet specified for this command).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// Suffix removed from every name (never from a name equal to it).
    suffix: ?[]const u8 = null,
    /// Byte that ends each output line (NUL with -z).
    terminator: u8 = '\n',
};

/// Writes the base name of each of `names`, each followed by the terminator.
pub fn run(env: Env, opts: Options, names: []const []const u8, out: *Io.Writer) Io.Writer.Error!void {
    _ = env;
    for (names) |n| {
        try out.writeAll(baseName(n, opts.suffix));
        try out.writeByte(opts.terminator);
    }
}

/// POSIX/GNU basename of `path` with an optional suffix removed. The result
/// borrows from `path`. A suffix equal to the whole name is not removed.
pub fn baseName(path: []const u8, suffix: ?[]const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    if (end == 1 and path[0] == '/') return path[0..1]; // all slashes -> "/"
    const start = if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |s| s + 1 else 0;
    var name = path[start..end];
    if (suffix) |suf| {
        if (suf.len > 0 and suf.len < name.len and std.mem.endsWith(u8, name, suf)) {
            name = name[0 .. name.len - suf.len];
        }
    }
    return name;
}

test "baseName" {
    const t = std.testing;
    try t.expectEqualStrings("echo", baseName("/usr/bin/echo", null));
    try t.expectEqualStrings("bin", baseName("/usr/bin/", null));
    try t.expectEqualStrings("/", baseName("///", null));
    try t.expectEqualStrings("", baseName("", null));
    try t.expectEqualStrings(".", baseName(".", null));
    try t.expectEqualStrings("script", baseName("script.sh", ".sh"));
    try t.expectEqualStrings(".sh", baseName(".sh", ".sh")); // whole name kept
    try t.expectEqualStrings("script.sh", baseName("script.sh", ".py"));
    try t.expectEqualStrings("archive", baseName("a/archive.tar.gz", ".tar.gz"));
}

test "basename run" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try run(.{ .io = undefined, .gpa = std.testing.allocator }, .{ .suffix = ".c", .terminator = 0 }, &.{ "/x/a.c", "b" }, &aw.writer);
    try std.testing.expectEqualStrings("a\x00b\x00", aw.written());
}
