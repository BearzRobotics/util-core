// SPDX-License-Identifier: GPL-2.0-or-later
//! users: print the login names of the users currently logged in (library
//! form, decision 0004). Reads Linux utmp records (384 bytes; type 7 is a
//! user process).
//!
//! GNU 9.7 (built with systemd) falls back to logind sessions when the utmp
//! file cannot be read and then prints nothing for a bad file name; logind's
//! session files are private data, so an unreadable file prints nothing here.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// The utmp-format file to read.
    path: []const u8 = "/var/run/utmp",
};

const record_size = 384;
const user_process = 7;

/// Writes the sorted, space-separated user names and a newline (nothing at
/// all when nobody is logged in or the file cannot be read).
pub fn run(env: Env, opts: Options, out: *Io.Writer) (Io.Writer.Error || error{OutOfMemory})!void {
    const f = Io.Dir.cwd().openFile(env.io, opts.path, .{}) catch return;
    defer f.close(env.io);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(env.gpa);
    while (true) {
        try data.ensureUnusedCapacity(env.gpa, 64 * 1024);
        const n = common.readChunk(env.io, f, data.unusedCapacitySlice()) catch return;
        if (n == 0) break;
        data.items.len += n;
    }
    try writeNames(env.gpa, data.items, out);
}

/// `run` on utmp records already in memory.
pub fn writeNames(gpa: std.mem.Allocator, data: []const u8, out: *Io.Writer) (Io.Writer.Error || error{OutOfMemory})!void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var off: usize = 0;
    while (off + record_size <= data.len) : (off += record_size) {
        const rec = data[off..][0..record_size];
        const kind = std.mem.readInt(i16, rec[0..2], .little);
        if (kind != user_process) continue;
        const user = std.mem.sliceTo(rec[44..76], 0);
        if (user.len == 0) continue;
        try names.append(gpa, user);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (names.items, 0..) |n, i| {
        if (i > 0) try out.writeByte(' ');
        try out.writeAll(n);
    }
    if (names.items.len > 0) try out.writeByte('\n');
}

test "writeNames sorts user processes" {
    var data: [record_size * 3]u8 = @splat(0);
    const users_in = [_][]const u8{ "zed", "amy" };
    for (users_in, 0..) |u, i| {
        const rec = data[i * record_size ..][0..record_size];
        std.mem.writeInt(i16, rec[0..2], user_process, .little);
        @memcpy(rec[44..][0..u.len], u);
    }
    std.mem.writeInt(i16, data[2 * record_size ..][0..2], 8, .little); // dead process
    @memcpy(data[2 * record_size + 44 ..][0..3], "old");
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeNames(std.testing.allocator, &data, &aw.writer);
    try std.testing.expectEqualStrings("amy zed\n", aw.written());
}
