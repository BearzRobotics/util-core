//! nproc — print the number of processing units available.
//! Reference: GNU coreutils manual "nproc invocation" (9.7).
//! The default honours OMP_NUM_THREADS and OMP_THREAD_LIMIT as GNU does.

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "all", "ignore", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var all = false;
    var ignore: usize = 0;
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) continue;
        if (a.len < 2 or a[0] != '-') {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
            return 1;
        }
        if (a[1] != '-') {
            cli.invalidShort(ctx, a[1]);
            return 1;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
        const k = switch (m) {
            .found => |k| k,
            else => {
                cli.badLong(ctx, a, m);
                return 1;
            },
        };
        switch (k) {
            0 => all = true,
            1 => {
                var v: []const u8 = undefined;
                if (eq) |e| {
                    v = a[e + 1 ..];
                } else {
                    i += 1;
                    if (i >= ctx.args.len) {
                        cli.warn(ctx, "option '--ignore' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    v = ctx.args[i];
                }
                ignore = std.fmt.parseInt(usize, v, 10) catch {
                    cli.warn(ctx, "invalid number: {f}", .{cli.quoteC(v)});
                    return 1;
                };
            },
            2 => return help(ctx),
            else => return if (cli.printVersion(ctx)) 0 else 1,
        }
    }
    var n: usize = if (all) installed(ctx) else available(ctx);
    n = if (n > ignore) n - ignore else 1;
    var buf: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{d}\n", .{n}) catch return 1;
    return if (cli.writeStdout(ctx.io, line)) 0 else 1;
}

/// CPUs the process may use, limited by the OpenMP environment variables.
fn available(ctx: cli.Context) usize {
    var n: usize = sys.affinityCpus() orelse installed(ctx);
    if (cli.getenv(ctx, "OMP_NUM_THREADS")) |v| {
        // First comma-separated item, as OpenMP defines it.
        const first = std.mem.trim(u8, v[0 .. std.mem.indexOfScalar(u8, v, ',') orelse v.len], " \t");
        if (std.fmt.parseInt(usize, first, 10)) |t| {
            if (t > 0) n = t;
        } else |_| {}
    }
    if (cli.getenv(ctx, "OMP_THREAD_LIMIT")) |v| {
        if (std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10)) |t| {
            if (t > 0 and t < n) n = t;
        } else |_| {}
    }
    return @max(n, 1);
}

/// Processors configured in the system: cpuN directories of /sys/devices/system/cpu.
fn installed(ctx: cli.Context) usize {
    var dir = Io.Dir.cwd().openDir(ctx.io, "/sys/devices/system/cpu", .{ .iterate = true }) catch return sys.affinityCpus() orelse 1;
    defer dir.close(ctx.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |e| {
        if (e.name.len > 3 and std.mem.startsWith(u8, e.name, "cpu") and std.ascii.isDigit(e.name[3])) n += 1;
    }
    return if (n == 0) (sys.affinityCpus() orelse 1) else n;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: nproc [OPTION]...\nPrint the number of processing units available to the current process,\nwhich may be less than the number of online processors\n\n      --all      print the number of installed processors\n      --ignore=N  if possible, exclude N processing units\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
