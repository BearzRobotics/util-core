// SPDX-License-Identifier: GPL-2.0-or-later
//! Line-by-line git change marks for `cat`'s bat-style view (like bat's
//! gutter): which lines of a file were added, modified, or have lines
//! removed next to them, comparing the working tree with the index.
//!
//! There is no git library here: `git diff -U0` is run and its hunk headers
//! are read. When git is not installed, the file is not in a repository, it
//! is untracked, or nothing differs, `load` returns null and the view has
//! no marker column (bat does the same).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Mark = enum {
    added,
    modified,
    /// Lines were removed directly above this (the first) line.
    removed_above,
    /// Lines were removed directly below this line.
    removed_below,

    pub fn char(m: Mark) []const u8 {
        return switch (m) {
            .added => "+",
            .modified => "~",
            .removed_above => "‾",
            .removed_below => "_",
        };
    }
};

pub const Changes = struct {
    marks: std.AutoHashMapUnmanaged(u64, Mark) = .empty,

    pub fn deinit(c: *Changes, gpa: std.mem.Allocator) void {
        c.marks.deinit(gpa);
    }

    /// Mark of a 1-based line, if it has one.
    pub fn at(c: *const Changes, line: u64) ?Mark {
        return c.marks.get(line);
    }

    pub fn isEmpty(c: *const Changes) bool {
        return c.marks.count() == 0;
    }

    /// Read the hunk headers of a `git diff -U0` output.
    pub fn parse(gpa: std.mem.Allocator, diff: []const u8) !Changes {
        var c: Changes = .{};
        errdefer c.deinit(gpa);
        var it = std.mem.splitScalar(u8, diff, '\n');
        while (it.next()) |line| {
            const h = parseHunk(line) orelse continue;
            if (h.new_count == 0) {
                // Pure removal: the new side's start is the line before it.
                if (h.new_start == 0) {
                    try c.marks.put(gpa, 1, .removed_above);
                } else try c.marks.put(gpa, h.new_start, .removed_below);
            } else {
                const mark: Mark = if (h.old_count == 0) .added else .modified;
                var n: u64 = 0;
                while (n < h.new_count) : (n += 1) try c.marks.put(gpa, h.new_start + n, mark);
            }
        }
        return c;
    }
};

pub const Hunk = struct { old_count: u64, new_start: u64, new_count: u64 };

/// `@@ -12,3 +14,2 @@` (counts default to 1).
pub fn parseHunk(line: []const u8) ?Hunk {
    if (!std.mem.startsWith(u8, line, "@@ -")) return null;
    var rest = line[4..];
    const old = number(&rest) orelse return null;
    var old_count: u64 = 1;
    if (rest.len > 0 and rest[0] == ',') {
        rest = rest[1..];
        old_count = (number(&rest) orelse return null);
    }
    if (!std.mem.startsWith(u8, rest, " +")) return null;
    rest = rest[2..];
    const new_start = number(&rest) orelse return null;
    var new_count: u64 = 1;
    if (rest.len > 0 and rest[0] == ',') {
        rest = rest[1..];
        new_count = (number(&rest) orelse return null);
    }
    _ = old;
    return .{ .old_count = old_count, .new_start = new_start, .new_count = new_count };
}

fn number(s: *[]const u8) ?u64 {
    var i: usize = 0;
    while (i < s.len and s.*[i] >= '0' and s.*[i] <= '9') i += 1;
    if (i == 0) return null;
    const v = std.fmt.parseInt(u64, s.*[0..i], 10) catch return null;
    s.* = s.*[i..];
    return v;
}

/// The change marks of `path` (relative to the current directory), or null
/// when there is nothing to show. Runs `git`; never reports an error.
pub fn load(env: common.Env, path: []const u8) ?Changes {
    const gpa = env.gpa;
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    var child = std.process.spawn(env.io, .{
        .argv = &.{ "git", "-C", dir, "diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--", base },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .environ_map = env.environ,
    }) catch return null;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var chunk: [16384]u8 = undefined;
    const out = child.stdout.?;
    var failed = false;
    while (true) {
        const n = out.readStreaming(env.io, &.{&chunk}) catch break;
        if (n == 0) break;
        // A pathological diff is not worth the memory; show no marks.
        if (list.items.len + n > 64 * 1024 * 1024) {
            failed = true;
            continue;
        }
        list.appendSlice(gpa, chunk[0..n]) catch {
            failed = true;
        };
    }
    const term = child.wait(env.io) catch return null;
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok or failed) return null;
    var c = Changes.parse(gpa, list.items) catch return null;
    if (c.isEmpty()) {
        c.deinit(gpa);
        return null;
    }
    return c;
}

test "hunk headers" {
    const h = parseHunk("@@ -12,3 +14,2 @@ fn x").?;
    try std.testing.expectEqual(@as(u64, 3), h.old_count);
    try std.testing.expectEqual(@as(u64, 14), h.new_start);
    try std.testing.expectEqual(@as(u64, 2), h.new_count);
    const one = parseHunk("@@ -2 +2 @@").?;
    try std.testing.expectEqual(@as(u64, 1), one.old_count);
    try std.testing.expectEqual(@as(u64, 1), one.new_count);
    try std.testing.expect(parseHunk("+@@ -1 +1 @@") == null);
    try std.testing.expect(parseHunk("@@ -x +1 @@") == null);
}

test "marks follow bat" {
    const gpa = std.testing.allocator;
    var c = try Changes.parse(gpa,
        \\diff --git a/f b/f
        \\--- a/f
        \\+++ b/f
        \\@@ -2 +2,3 @@
        \\@@ -5,2 +7,0 @@
        \\@@ -9,0 +11,2 @@
        \\@@ -1 +0,0 @@
    );
    defer c.deinit(gpa);
    try std.testing.expectEqual(Mark.modified, c.at(2).?);
    try std.testing.expectEqual(Mark.modified, c.at(4).?);
    try std.testing.expect(c.at(5) == null);
    try std.testing.expectEqual(Mark.removed_below, c.at(7).?);
    try std.testing.expectEqual(Mark.added, c.at(11).?);
    try std.testing.expectEqual(Mark.added, c.at(12).?);
    try std.testing.expectEqual(Mark.removed_above, c.at(1).?);
}
