// SPDX-License-Identifier: GPL-2.0-or-later
//! nproc: print the number of processing units available (library form,
//! decision 0004). The default honours OMP_NUM_THREADS and OMP_THREAD_LIMIT
//! (read from `Env.environ`) as GNU does.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// --all: processors installed, not just those this process may use.
    all: bool = false,
    /// --ignore=N: exclude N units (never going below 1).
    ignore: usize = 0,
};

/// The number of processing units selected by `opts`.
pub fn count(env: Env, opts: Options) usize {
    const n: usize = if (opts.all) installed(env) else available(env);
    return if (n > opts.ignore) n - opts.ignore else 1;
}

/// Writes the count and a newline.
pub fn run(env: Env, opts: Options, out: *Io.Writer) Io.Writer.Error!void {
    try out.print("{d}\n", .{count(env, opts)});
}

/// CPUs the process may use, limited by the OpenMP environment variables.
pub fn available(env: Env) usize {
    var n: usize = sys.affinityCpus() orelse installed(env);
    if (env.getenv("OMP_NUM_THREADS")) |v| {
        // First comma-separated item, as OpenMP defines it.
        const first = std.mem.trim(u8, v[0 .. std.mem.indexOfScalar(u8, v, ',') orelse v.len], " \t");
        if (std.fmt.parseInt(usize, first, 10)) |t| {
            if (t > 0) n = t;
        } else |_| {}
    }
    if (env.getenv("OMP_THREAD_LIMIT")) |v| {
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10)) |t| {
            if (t > 0 and t < n) n = t;
        } else |_| {}
    }
    return @max(n, 1);
}

/// Processors configured in the system: cpuN directories of /sys/devices/system/cpu.
pub fn installed(env: Env) usize {
    var dir = Io.Dir.cwd().openDir(env.io, "/sys/devices/system/cpu", .{ .iterate = true }) catch return sys.affinityCpus() orelse 1;
    defer dir.close(env.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(env.io) catch null) |e| {
        if (e.name.len > 3 and std.mem.startsWith(u8, e.name, "cpu") and std.ascii.isDigit(e.name[3])) n += 1;
    }
    return if (n == 0) (sys.affinityCpus() orelse 1) else n;
}

test "count is at least one" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("OMP_NUM_THREADS", "3");
    const env: Env = .{ .io = std.testing.io, .gpa = std.testing.allocator, .environ = &map };
    try std.testing.expectEqual(@as(usize, 3), available(env));
    try std.testing.expectEqual(@as(usize, 1), count(env, .{ .ignore = 100 }));
}
