// SPDX-License-Identifier: GPL-2.0-or-later
//! Running a subsidiary program (`--diff-program` of diff3 and sdiff) and
//! describing how it ended the way GNU diffutils words it; `spawn` is also how
//! find and xargs start commands.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

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

/// `std.process.spawn` with the rest of `execvp`: a file the kernel cannot
/// execute (a script without a `#!` line) is run by /bin/sh, as glibc does.
/// Used for the commands of find -exec and xargs too.
pub fn spawn(env: Env, options: std.process.SpawnOptions) !std.process.Child {
    return std.process.spawn(env.io, options) catch |e| {
        if (e != error.InvalidExe or builtin.os.tag == .windows) return e;
        // The shell is given the file that was found, not the name: it would
        // look for a bare name in the current directory first.
        var arena = std.heap.ArenaAllocator.init(env.gpa);
        defer arena.deinit();
        var script = try searchPath(env, arena.allocator(), options.argv[0], options.cwd) orelse return e;
        // Not to be taken for an option of the shell.
        if (script.len > 0 and script[0] == '-') script = try std.fmt.allocPrint(arena.allocator(), "./{s}", .{script});
        const argv = try std.mem.concat(arena.allocator(), []const u8, &.{ &.{ "/bin/sh", script }, options.argv[1..] });
        var shell = options;
        shell.argv = argv;
        return std.process.spawn(env.io, shell);
    };
}

/// The file `std.process.spawn` starts for `name`: `name` itself when it has a
/// slash, else the first executable file of that name in a PATH directory
/// (empty entries are skipped, as there). Relative entries are looked up from
/// `cwd`, where the command runs. Null when there is none.
fn searchPath(env: Env, arena: std.mem.Allocator, name: []const u8, cwd: std.process.Child.Cwd) error{OutOfMemory}!?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    const dir = switch (cwd) {
        .inherit => sys.cwdFd(),
        .dir => |d| d.handle,
        .path => return null, // not used by any caller
    };
    var entries = std.mem.tokenizeScalar(u8, env.getenv("PATH") orelse "/usr/local/bin:/bin/:/usr/bin", ':');
    while (entries.next()) |entry| {
        const candidate = try std.fmt.allocPrint(arena, "{s}/{s}", .{ entry, name });
        var err: sys.E = .SUCCESS;
        const found = sys.fileStatAt(dir, candidate, true, &err) orelse continue;
        if (!found.isDir() and sys.accessAt(dir, candidate, 1) == null) return candidate;
    }
    return null;
}

/// Run `argv` with its standard output captured; standard input and error
/// are inherited.
pub fn capture(env: Env, argv: []const []const u8) !Run {
    const gpa = env.gpa;
    var child = spawn(env, .{ .argv = argv, .stdout = .pipe }) catch |e| {
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
    var child = spawn(env, .{ .argv = argv }) catch |e| return spawnStatus(e);
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
