// SPDX-License-Identifier: GPL-2.0-or-later
//! rmdir library: remove empty directories.
//! References: GNU coreutils manual "rmdir invocation" (9.7); POSIX.1-2024
//! rmdir.
//!
//! `parents` removes each operand and then its parent components in turn (the
//! trailing components are tried even when `.` is reached, where the OS
//! refuses, which matches GNU's output). `ignore_fail_on_non_empty` silences
//! "Directory not empty" failures.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// -p: also remove the ancestors, one at a time.
    parents: bool = false,
    /// --ignore-fail-on-non-empty.
    ignore_fail_on_non_empty: bool = false,
};

pub const Event = union(enum) {
    /// About to remove `path` (the -v message; emitted for every attempt).
    removing: []const u8,
    /// Removal failed. `is_parent` is true for an ancestor reached via -p.
    failed: struct { path: []const u8, is_parent: bool, err: anyerror },
};
pub const Observer = common.Observer(Event);

pub const Outcome = enum { removed, ignored, failed };

/// Remove each directory (and, with `parents`, its ancestors). Failures go to
/// `observer`; returns false when any removal failed.
pub fn run(env: Env, options: Options, dirs: []const []const u8, observer: Observer) bool {
    var ok = true;
    for (dirs) |d| {
        const first = removeOne(env, d, false, options, observer);
        if (first != .removed) {
            if (first == .failed) ok = false;
            continue;
        }
        if (!options.parents) continue;
        // Remove the ancestors one at a time, stopping at the first failure.
        var path = d;
        while (parentOf(path)) |parent| {
            path = parent;
            const r = removeOne(env, path, true, options, observer);
            if (r == .failed) ok = false;
            if (r != .removed) break;
        }
    }
    return ok;
}

/// Remove one directory, reporting failures. `ignored` is a non-empty
/// directory under `ignore_fail_on_non_empty`.
pub fn removeOne(env: Env, path: []const u8, is_parent: bool, options: Options, observer: Observer) Outcome {
    observer.emit(.{ .removing = path });
    const result: anyerror!void = if (endsWithDot(path)) error.BadPathName else Io.Dir.cwd().deleteDir(env.io, path);
    result catch |e| {
        if (options.ignore_fail_on_non_empty and e == error.DirNotEmpty) return .ignored;
        observer.emit(.{ .failed = .{ .path = path, .is_parent = is_parent, .err = e } });
        return .failed;
    };
    return .removed;
}

/// rmdir(".") is EINVAL; the standard library treats that as a programmer
/// bug and panics, so report it ourselves.
fn endsWithDot(path: []const u8) bool {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const p = path[0..end];
    return std.mem.eql(u8, p, ".") or std.mem.endsWith(u8, p, "/.");
}

/// The directory name of `path` after dropping trailing slashes, or null when
/// no '/' remains (GNU rmdir -p stops there).
pub fn parentOf(path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    while (end > 0 and path[end - 1] != '/') end -= 1;
    if (end == 0) return null;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    if (end == 1 and path[0] == '/') return null; // "/" itself is never removed
    return path[0..end];
}

test "endsWithDot" {
    try std.testing.expect(endsWithDot("."));
    try std.testing.expect(endsWithDot("a/."));
    try std.testing.expect(endsWithDot("a/./"));
    try std.testing.expect(!endsWithDot(".."));
    try std.testing.expect(!endsWithDot("a/.b"));
}

test "parentOf" {
    const t = std.testing;
    try t.expectEqualStrings("a/b", parentOf("a/b/c").?);
    try t.expectEqualStrings("a", parentOf("a/b//").?);
    try t.expect(parentOf("a") == null);
    try t.expectEqualStrings("/a", parentOf("/a/b").?);
    try t.expect(parentOf("/a") == null);
    try t.expectEqualStrings("./ab", parentOf("./ab/cd").?);
    try t.expectEqualStrings(".", parentOf("./ab").?);
}
