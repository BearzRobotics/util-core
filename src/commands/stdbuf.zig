//! stdbuf — run a command with modified buffering of its standard streams.
//! Reference: GNU coreutils manual "stdbuf invocation" (9.7).
//!
//! Works like GNU stdbuf: the modes go into _STDBUF_I/O/E and the shared
//! library libstdbuf.so (a LD_PRELOAD shim that calls setvbuf) is added to
//! LD_PRELOAD. We do not ship that library; the one installed with GNU
//! coreutils (/usr/libexec/coreutils/libstdbuf.so) is used. Programs that do
//! not use C stdio, or are statically linked, are unaffected (as with GNU).

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const exec = @import("../exec.zig");
const count_arg = @import("../count_arg.zig");
const Io = std.Io;

const help_text = @embedFile("../help/stdbuf.txt");

const lib_candidates = [_][]const u8{
    "/usr/libexec/coreutils/libstdbuf.so",
    "/usr/lib/coreutils/libstdbuf.so",
    "/usr/local/libexec/coreutils/libstdbuf.so",
    "/usr/libexec/libstdbuf.so",
};

pub fn main(ctx: cli.Context) u8 {
    var modes: [3]?[]const u8 = .{ null, null, null }; // i, o, e
    var p = getopt.Parser.init(ctx, "+i:o:e:", &.{
        .{ .name = "input", .arg = .required, .id = 'i' },
        .{ .name = "output", .arg = .required, .id = 'o' },
        .{ .name = "error", .arg = .required, .id = 'e' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 125,
        .opt => |o| switch (o.id) {
            'i', 'o', 'e' => {
                const idx: usize = if (o.id == 'i') 0 else if (o.id == 'o') 1 else 2;
                const m = o.arg.?;
                if (idx == 0 and std.mem.eql(u8, m, "L")) {
                    getopt.usageError(ctx, "line buffering stdin is meaningless", .{});
                    return 125;
                }
                if (!std.mem.eql(u8, m, "L")) {
                    const c = count_arg.parse(m);
                    if (c == null or c.?.sign != .none or m.len == 0 or !std.ascii.isDigit(m[0])) {
                        cli.warn(ctx, "invalid mode {f}", .{cli.quoteC(m)});
                        return 125;
                    }
                    if (c.?.value == std.math.maxInt(u64)) {
                        cli.warn(ctx, "invalid mode {f}: Value too large for defined data type", .{cli.quoteC(m)});
                        return 125;
                    }
                }
                modes[idx] = m;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 125,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 125,
            else => unreachable,
        },
    };
    const command = p.operands.items;
    if (command.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 125;
    }
    if (modes[0] == null and modes[1] == null and modes[2] == null) {
        getopt.usageError(ctx, "you must specify a buffering mode option", .{});
        return 125;
    }

    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    if (ctx.environ) |src| {
        var it = src.iterator();
        while (it.next()) |e| env.put(e.key_ptr.*, e.value_ptr.*) catch return 125;
    }
    const names = [_][]const u8{ "_STDBUF_I", "_STDBUF_O", "_STDBUF_E" };
    for (modes, names) |m, n| if (m) |mode| {
        const text: []const u8 = if (std.mem.eql(u8, mode, "L")) "L" else blk: {
            const v = count_arg.parse(mode).?.value;
            break :blk std.fmt.allocPrint(a, "{d}", .{v}) catch return 125;
        };
        env.put(n, text) catch return 125;
    };
    var lib: ?[]const u8 = null;
    for (lib_candidates) |c| {
        Io.Dir.cwd().access(ctx.io, c, .{}) catch continue;
        lib = c;
        break;
    }
    const l = lib orelse {
        cli.warn(ctx, "failed to find libstdbuf.so", .{});
        return 125;
    };
    const preload = if (env.get("LD_PRELOAD")) |old|
        std.fmt.allocPrint(a, "{s}:{s}", .{ old, l }) catch return 125
    else
        l;
    env.put("LD_PRELOAD", preload) catch return 125;

    var argv: std.ArrayList([]const u8) = .empty;
    for (command) |c| argv.append(a, c) catch return 125;
    return exec.execStyled(ctx, command[0], argv.items, &env, .run);
}
