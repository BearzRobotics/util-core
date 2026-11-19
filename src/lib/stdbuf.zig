// SPDX-License-Identifier: GPL-2.0-or-later
//! stdbuf library: prepare the environment that makes a command run with
//! modified buffering of its standard streams.
//! Reference: GNU coreutils manual "stdbuf invocation" (9.7).
//!
//! Works like GNU stdbuf: the modes go into _STDBUF_I/O/E and the shared
//! library libstdbuf.so (a LD_PRELOAD shim that calls setvbuf) is added to
//! LD_PRELOAD. We do not ship that library; the one installed with GNU
//! coreutils (/usr/libexec/coreutils/libstdbuf.so) is used. Programs that do
//! not use C stdio, or are statically linked, are unaffected (as with GNU).
//!
//! Replacing the process is a process-wide action (decision 0004) and stays
//! in the wrapper (`src/commands/stdbuf.zig`).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const count_arg = @import("../count_arg.zig");

pub const Env = common.Env;
pub const Map = std.process.Environ.Map;

pub const Stream = enum { input, output, @"error" };

pub const Mode = union(enum) {
    /// "L": line buffered.
    line,
    /// A buffer size in bytes (0 is unbuffered).
    size: u64,
};

pub const ModeError = error{
    /// -iL: line buffering stdin is meaningless.
    LineBufferedInput,
    /// Not a size.
    InvalidMode,
    /// A size that does not fit.
    ValueTooLarge,
};

/// Parse the MODE of -i, -o or -e.
pub fn parseMode(stream: Stream, text: []const u8) ModeError!Mode {
    if (std.mem.eql(u8, text, "L")) {
        if (stream == .input) return error.LineBufferedInput;
        return .line;
    }
    const c = count_arg.parse(text);
    if (c == null or c.?.sign != .none or text.len == 0 or !std.ascii.isDigit(text[0])) return error.InvalidMode;
    if (c.?.value == std.math.maxInt(u64)) return error.ValueTooLarge;
    return .{ .size = c.?.value };
}

/// Where libstdbuf.so is searched.
pub const lib_candidates = [_][]const u8{
    "/usr/libexec/coreutils/libstdbuf.so",
    "/usr/lib/coreutils/libstdbuf.so",
    "/usr/local/libexec/coreutils/libstdbuf.so",
    "/usr/libexec/libstdbuf.so",
};

/// The first installed libstdbuf.so, or null.
pub fn findLibrary(io: Io) ?[]const u8 {
    for (lib_candidates) |c| {
        Io.Dir.cwd().access(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

pub const Modes = struct {
    input: ?Mode = null,
    output: ?Mode = null,
    @"error": ?Mode = null,

    pub fn any(m: Modes) bool {
        return m.input != null or m.output != null or m.@"error" != null;
    }
};

/// Copy of `base` with _STDBUF_* set from `modes` and `lib` appended to
/// LD_PRELOAD. `arena` owns everything.
pub fn environment(arena: std.mem.Allocator, base: ?*const Map, modes: Modes, lib: []const u8) error{OutOfMemory}!Map {
    var env = Map.init(arena);
    if (base) |src| {
        var it = src.iterator();
        while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.*);
    }
    const names = [_][]const u8{ "_STDBUF_I", "_STDBUF_O", "_STDBUF_E" };
    const all = [_]?Mode{ modes.input, modes.output, modes.@"error" };
    for (all, names) |m, n| if (m) |mode| {
        const text: []const u8 = switch (mode) {
            .line => "L",
            .size => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
        };
        try env.put(n, text);
    };
    const preload = if (env.get("LD_PRELOAD")) |old|
        try std.fmt.allocPrint(arena, "{s}:{s}", .{ old, lib })
    else
        lib;
    try env.put("LD_PRELOAD", preload);
    return env;
}

test "mode parsing" {
    try std.testing.expectError(error.LineBufferedInput, parseMode(.input, "L"));
    try std.testing.expect((try parseMode(.output, "L")) == .line);
    try std.testing.expectEqual(@as(u64, 4096), (try parseMode(.output, "4096")).size);
    try std.testing.expectError(error.InvalidMode, parseMode(.output, "-1"));
    try std.testing.expectError(error.InvalidMode, parseMode(.output, "x"));
}

test "environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var base = Map.init(arena.allocator());
    try base.put("LD_PRELOAD", "a.so");
    const e = try environment(arena.allocator(), &base, .{ .output = .line, .@"error" = .{ .size = 0 } }, "/l.so");
    try std.testing.expectEqualStrings("L", e.get("_STDBUF_O").?);
    try std.testing.expectEqualStrings("0", e.get("_STDBUF_E").?);
    try std.testing.expectEqualStrings("a.so:/l.so", e.get("LD_PRELOAD").?);
}
