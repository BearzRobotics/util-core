// SPDX-License-Identifier: GPL-2.0-or-later
//! hostid: print the numeric identifier of the current host (library form,
//! decision 0004). glibc gethostid(): /etc/hostid if present, otherwise
//! derived from the IPv4 address of the host name in /etc/hosts.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const Options = struct {};

/// The host identifier (0 when nothing identifies the host).
pub fn hostId(env: Env) u32 {
    if (Io.Dir.cwd().openFile(env.io, "/etc/hostid", .{})) |f| {
        defer f.close(env.io);
        var b: [4]u8 = undefined;
        const n = common.readChunk(env.io, f, &b) catch 0;
        if (n == 4) return std.mem.readInt(u32, &b, .little);
    } else |_| {}
    // 32-bit value whose bytes are the address as it sits in memory, with its
    // 16-bit halves swapped.
    const uts = sys.uname();
    const host = uts.nodename();
    const f = Io.Dir.cwd().openFile(env.io, "/etc/hosts", .{}) catch return 0;
    defer f.close(env.io);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(env.gpa);
    while (true) {
        text.ensureUnusedCapacity(env.gpa, 4096) catch return 0;
        const n = common.readChunk(env.io, f, text.unusedCapacitySlice()) catch return 0;
        if (n == 0) break;
        text.items.len += n;
    }
    return fromHosts(text.items, host);
}

/// The identifier derived from the address `host` has in hosts-file `text`.
pub fn fromHosts(text: []const u8, host: []const u8) u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
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

/// Writes the identifier as eight lowercase hex digits and a newline.
pub fn run(env: Env, opts: Options, out: *Io.Writer) Io.Writer.Error!void {
    _ = opts;
    try out.print("{x:0>8}\n", .{hostId(env)});
}

test "fromHosts" {
    try std.testing.expectEqual(@as(u32, 0x007f0100), fromHosts("127.0.0.1 localhost box\n", "box"));
    try std.testing.expectEqual(@as(u32, 0), fromHosts("127.0.0.1 localhost\n", "other"));
}
