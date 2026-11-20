// SPDX-License-Identifier: GPL-2.0-or-later
//! Running a subsidiary program (`--diff-program` of diff3 and sdiff) and
//! describing how it ended the way GNU diffutils words it.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

/// A status above any exit code: the program was killed by a signal.
pub const abnormal: u32 = 0x10000;

pub const Run = struct {
    /// Everything the program wrote to its standard output.
    output: []u8,
    /// Exit status; 127 when it was not found, 126 when it could not be
    /// started, `abnormal` after a signal.
    status: u32,
};

fn statusOf(term: std.process.Child.Term) u32 {
    return switch (term) {
        .exited => |c| c,
        else => abnormal,
    };
}

fn spawnStatus(err: anyerror) u32 {
    return if (err == error.FileNotFound) 127 else 126;
}

/// `execvp` semantics: a file the kernel cannot execute (no `#!` line) is run
/// by the shell, as glibc does.
fn spawnArgv(env: Env, argv: []const []const u8, stdout: std.process.SpawnOptions.StdIo) !std.process.Child {
    return std.process.spawn(env.io, .{ .argv = argv, .stdout = stdout }) catch |e| {
        if (e != error.InvalidExe) return e;
        var sh: std.ArrayList([]const u8) = .empty;
        defer sh.deinit(env.gpa);
        try sh.append(env.gpa, "/bin/sh");
        try sh.appendSlice(env.gpa, argv);
        return std.process.spawn(env.io, .{ .argv = sh.items, .stdout = stdout });
    };
}

/// Run `argv` with its standard output captured; standard input and error
/// are inherited.
pub fn capture(env: Env, argv: []const []const u8) !Run {
    const gpa = env.gpa;
    var child = spawnArgv(env, argv, .pipe) catch |e| {
        if (e == error.OutOfMemory) return e;
        return .{ .output = try gpa.alloc(u8, 0), .status = spawnStatus(e) };
    };
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var chunk: [65536]u8 = undefined;
    const out = child.stdout.?;
    while (true) {
        const n = out.readStreaming(env.io, &.{&chunk}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => break,
        };
        if (n == 0) break;
        try list.appendSlice(gpa, chunk[0..n]);
    }
    const term = child.wait(env.io) catch return .{ .output = try list.toOwnedSlice(gpa), .status = abnormal };
    return .{ .output = try list.toOwnedSlice(gpa), .status = statusOf(term) };
}

/// Run `argv` with all three standard streams inherited (what `exec` would
/// do); returns the exit status as `capture` does.
pub fn inherit(env: Env, argv: []const []const u8) u32 {
    var child = spawnArgv(env, argv, .inherit) catch |e| return spawnStatus(e);
    const term = child.wait(env.io) catch return abnormal;
    return statusOf(term);
}

/// The wording of GNU's check_child_status for a status that is not OK, as
/// "subsidiary program 'X' failed (exit status N)" and its variants.
pub fn describe(buf: []u8, program: []const u8, status: u32) []const u8 {
    return switch (status) {
        126 => std.fmt.bufPrint(buf, "subsidiary program '{s}' could not be invoked", .{program}) catch "subsidiary program could not be invoked",
        127 => std.fmt.bufPrint(buf, "subsidiary program '{s}' not found", .{program}) catch "subsidiary program not found",
        abnormal => std.fmt.bufPrint(buf, "subsidiary program '{s}' failed", .{program}) catch "subsidiary program failed",
        else => std.fmt.bufPrint(buf, "subsidiary program '{s}' failed (exit status {d})", .{ program, status }) catch "subsidiary program failed",
    };
}
