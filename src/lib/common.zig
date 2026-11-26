// SPDX-License-Identifier: GPL-2.0-or-later
//! Types shared by the command libraries in `src/lib/` (decision 0004).
//!
//! A command library never parses arguments, never prints to a terminal and
//! never exits. It receives an `Env` (the `std.Io` instance and an allocator),
//! writes results to a caller-supplied `*Io.Writer`, and reports problems that
//! do not stop the whole operation (an unreadable file, say) through an
//! `Observer`, so the caller decides how to word and where to send them.

const std = @import("std");
const sys = @import("../sys.zig");
const Io = std.Io;

/// What every library entry point needs from its host.
pub const Env = struct {
    io: Io,
    gpa: std.mem.Allocator,
    /// Environment variables; null when the host provides none.
    environ: ?*const std.process.Environ.Map = null,

    pub fn getenv(env: Env, key: []const u8) ?[]const u8 {
        const map = env.environ orelse return null;
        return map.get(key);
    }
};

/// Callback sink for the events one command defines. The default drops them.
pub fn Observer(comptime Event: type) type {
    return struct {
        const Self = @This();
        context: ?*anyopaque = null,
        func: ?*const fn (context: ?*anyopaque, event: Event) void = null,

        pub const none: Self = .{};

        pub fn emit(o: Self, event: Event) void {
            if (o.func) |f| f(o.context, event);
        }
    };
}

/// Where an input comes from. `name` is how the caller refers to it in
/// diagnostics and machine-readable output (null: standard input given
/// implicitly, no operand).
pub const Input = struct {
    name: ?[]const u8,
    source: Source,

    pub const Source = union(enum) {
        /// Opened relative to the current directory.
        path: []const u8,
        /// Already open (standard input, or a descriptor the host owns).
        file: Io.File,
    };

    /// An open file the library must not close.
    pub fn open(in: Input, io: Io) !Opened {
        return switch (in.source) {
            .path => |p| .{
                .file = try Io.Dir.cwd().openFile(io, p, .{ .allow_directory = false }),
                .owned = true,
            },
            .file => |f| .{ .file = f, .owned = false },
        };
    }

    pub const Opened = struct {
        file: Io.File,
        owned: bool,

        pub fn close(o: Opened, io: Io) void {
            if (o.owned) o.file.close(io);
        }
    };
};

/// Read up to `buf.len` bytes; 0 at end of input.
pub fn readChunk(io: Io, file: Io.File, buf: []u8) !usize {
    return file.readStreaming(io, &.{buf}) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => e,
    };
}

/// Whether the size of a regular file can be trusted. /proc reports size 0
/// for files with contents, and sysfs one block (4096) for a few bytes; as in
/// GNU only a size over a block is trusted, and then only if its last byte can
/// be read. Reading such a short file through costs nothing.
pub fn sizeIsReal(io: Io, file: Io.File, size: u64) !bool {
    var e: std.os.linux.E = .SUCCESS;
    const block: u64 = if (sys.fstatFd(file.handle, &e)) |st| st.blksize else 0;
    if (size <= @max(block, 4096)) return false;
    var last: [1]u8 = undefined;
    return try file.readPositionalAll(io, &last, size - 1) == 1;
}
