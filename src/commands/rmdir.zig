// SPDX-License-Identifier: GPL-2.0-or-later
//! rmdir — remove empty directories.
//! References: GNU coreutils manual "rmdir invocation" (9.7); POSIX.1-2024
//! rmdir.
//!
//! -p removes each operand and then its parent components in turn (the trailing
//! components are tried even when `.` is reached, where the OS refuses, which
//! matches GNU's output). --ignore-fail-on-non-empty silences "Directory not
//! empty" failures.

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "ignore-fail-on-non-empty", "parents", "verbose", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var ignore_nonempty = false;
    var parents = false;
    var verbose = false;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(ctx.gpa);
    const args = ctx.args;
    var only_operands = false;
    for (args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            dirs.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => ignore_nonempty = true,
                    1 => parents = true,
                    2 => verbose = true,
                    3 => return help(ctx),
                    else => return if (cli.printVersion(ctx)) 0 else 1,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'p' => parents = true,
            'v' => verbose = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (dirs.items.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var status: u8 = 0;
    for (dirs.items) |d| {
        const first = removeOne(ctx, d, false, verbose, ignore_nonempty);
        if (first != .removed) {
            if (first == .failed) status = 1;
            continue;
        }
        if (!parents) continue;
        // Remove the ancestors one at a time, stopping at the first failure.
        var path = d;
        while (parentOf(path)) |parent| {
            path = parent;
            const r = removeOne(ctx, path, true, verbose, ignore_nonempty);
            if (r == .failed) status = 1;
            if (r != .removed) break;
        }
    }
    return status;
}

const Outcome = enum { removed, ignored, failed };

/// Remove one directory, reporting failures. `ignored` is a non-empty
/// directory under --ignore-fail-on-non-empty.
fn removeOne(ctx: cli.Context, path: []const u8, is_parent: bool, verbose: bool, ignore_nonempty: bool) Outcome {
    if (verbose) cli.say(ctx, "removing directory, '{s}'", .{path});
    const result: anyerror!void = if (endsWithDot(path)) error.BadPathName else Io.Dir.cwd().deleteDir(ctx.io, path);
    result catch |e| {
        if (ignore_nonempty and e == error.DirNotEmpty) return .ignored;
        const what = if (is_parent) "directory " else "";
        cli.warn(ctx, "failed to remove {s}'{s}': {s}", .{ what, path, errMessage(e) });
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

fn errMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.BadPathName, error.InvalidUtf8, error.InvalidWtf8 => "Invalid argument",
        else => cli.errText(e),
    };
}

/// The directory name of `path` after dropping trailing slashes, or null when
/// no '/' remains (GNU rmdir -p stops there).
fn parentOf(path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    while (end > 0 and path[end - 1] != '/') end -= 1;
    if (end == 0) return null;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    if (end == 1 and path[0] == '/') return null; // "/" itself is never removed
    return path[0..end];
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: rmdir [OPTION]... DIRECTORY...\n" ++
        "Remove the DIRECTORY(ies), if they are empty.\n\n" ++
        "      --ignore-fail-on-non-empty\n" ++
        "                    ignore each failure to remove a non-empty directory\n" ++
        "  -p, --parents     remove DIRECTORY and its ancestors; e.g., 'rmdir -p a/b'\n" ++
        "                      is similar to 'rmdir a/b a'\n" ++
        "  -v, --verbose     output a diagnostic for every directory processed\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
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
