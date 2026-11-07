//! hostid — print the numeric identifier of the current host.
//! Reference: GNU coreutils manual "hostid invocation" (9.7); glibc
//! gethostid(): /etc/hostid if present, otherwise derived from the IPv4
//! address of the host name in /etc/hosts.

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

pub fn main(ctx: cli.Context) u8 {
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (std.mem.eql(u8, a, "--help")) return help(ctx);
        if (std.mem.eql(u8, a, "--version")) return if (cli.printVersion(ctx)) 0 else 1;
        if (std.mem.eql(u8, a, "--")) continue;
        if (a.len > 1 and a[0] == '-') {
            if (a[1] == '-') {
                const m = cli.matchLong(a[2..], &.{ "help", "version" });
                switch (m) {
                    .found => |k| return if (k == 0) help(ctx) else if (cli.printVersion(ctx)) 0 else 1,
                    else => {
                        cli.badLong(ctx, a, m);
                        return 1;
                    },
                }
            }
            cli.invalidShort(ctx, a[1]);
            return 1;
        }
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
        return 1;
    }
    const id = hostId(ctx);
    var buf: [16]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{x:0>8}\n", .{id}) catch return 1;
    return if (cli.writeStdout(ctx.io, line)) 0 else 1;
}

fn hostId(ctx: cli.Context) u32 {
    if (Io.Dir.cwd().openFile(ctx.io, "/etc/hostid", .{})) |f| {
        defer f.close(ctx.io);
        var b: [4]u8 = undefined;
        const n = cli.readChunk(ctx.io, f, &b) catch 0;
        if (n == 4) return std.mem.readInt(u32, &b, .little);
    } else |_| {}
    // 32-bit value whose bytes are the address as it sits in memory, with its
    // 16-bit halves swapped.
    const host = sys.uname().nodename;
    const f = Io.Dir.cwd().openFile(ctx.io, "/etc/hosts", .{}) catch return 0;
    defer f.close(ctx.io);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(ctx.gpa);
    while (true) {
        text.ensureUnusedCapacity(ctx.gpa, 4096) catch return 0;
        const n = cli.readChunk(ctx.io, f, text.unusedCapacitySlice()) catch return 0;
        if (n == 0) break;
        text.items.len += n;
    }
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    while (lines.next()) |l0| {
        const l = l0[0 .. std.mem.indexOfScalar(u8, l0, '#') orelse l0.len];
        var tok = std.mem.tokenizeAny(u8, l, " \t");
        const addr = tok.next() orelse continue;
        while (tok.next()) |name| {
            if (!std.mem.eql(u8, name, host)) continue;
            var oct: [4]u8 = undefined;
            var parts = std.mem.splitScalar(u8, addr, '.');
            var k: usize = 0;
            while (parts.next()) |p| : (k += 1) {
                if (k >= 4) break;
                oct[k] = std.fmt.parseInt(u8, p, 10) catch break;
            } else if (k == 4) {
                const mem = std.mem.readInt(u32, &oct, .little);
                return (mem << 16) | (mem >> 16);
            }
        }
    }
    return 0;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: hostid [OPTION]\nPrint the numeric identifier (in hexadecimal) for the current host.\n\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
