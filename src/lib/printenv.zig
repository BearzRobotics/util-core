// SPDX-License-Identifier: GPL-2.0-or-later
//! printenv: print environment variables (library form, decision 0004).
//!
//! No names: every NAME=value. With names: the value of each variable that is
//! set (a name containing '=' is never found). The environment is
//! `Env.environ`; without one nothing is set.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const json = @import("../json.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// Byte that ends each output line (NUL with -0). Not used by `json`.
    terminator: u8 = '\n',
    /// Extension (decision 0003): one JSON object of NAME: value.
    json: bool = false,
};

pub const Result = struct {
    /// Requested names that are not set (GNU exits 1 when this is not 0).
    missing: usize = 0,
};

/// Prints the requested variables (all of them when `names` is empty).
pub fn run(env: Env, opts: Options, names: []const []const u8, out: *Io.Writer) Io.Writer.Error!Result {
    var res: Result = .{};
    const map = env.environ orelse {
        res.missing = names.len;
        return res;
    };
    if (opts.json) {
        // A requested name that is not set is left out of the object.
        var first = true;
        try out.writeByte('{');
        if (names.len == 0) {
            var it = map.iterator();
            while (it.next()) |e| {
                if (!first) try out.writeByte(',');
                first = false;
                try json.writeString(out, e.key_ptr.*);
                try out.writeByte(':');
                try json.writeString(out, e.value_ptr.*);
            }
        } else for (names) |n| {
            const v = if (std.mem.indexOfScalar(u8, n, '=') == null) map.get(n) else null;
            if (v) |value| {
                if (!first) try out.writeByte(',');
                first = false;
                try json.writeString(out, n);
                try out.writeByte(':');
                try json.writeString(out, value);
            } else res.missing += 1;
        }
        try out.writeAll("}\n");
        return res;
    }
    if (names.len == 0) {
        var it = map.iterator();
        while (it.next()) |e| {
            try out.writeAll(e.key_ptr.*);
            try out.writeByte('=');
            try out.writeAll(e.value_ptr.*);
            try out.writeByte(opts.terminator);
        }
    } else for (names) |n| {
        if (std.mem.indexOfScalar(u8, n, '=') == null) if (map.get(n)) |v| {
            try out.writeAll(v);
            try out.writeByte(opts.terminator);
            continue;
        };
        res.missing += 1;
    }
    return res;
}

test "printenv names and missing" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("A", "1");
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const env: Env = .{ .io = undefined, .gpa = std.testing.allocator, .environ = &map };
    const r = try run(env, .{}, &.{ "A", "B", "A=1" }, &aw.writer);
    try std.testing.expectEqualStrings("1\n", aw.written());
    try std.testing.expectEqual(@as(usize, 2), r.missing);
}

test "printenv json" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("A", "1");
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const env: Env = .{ .io = undefined, .gpa = std.testing.allocator, .environ = &map };
    _ = try run(env, .{ .json = true }, &.{}, &aw.writer);
    try std.testing.expectEqualStrings("{\"A\":\"1\"}\n", aw.written());
}
