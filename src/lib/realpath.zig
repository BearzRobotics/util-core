// SPDX-License-Identifier: GPL-2.0-or-later
//! realpath library: print the resolved absolute file name, optionally
//! relative to a directory.
//! Reference: GNU coreutils manual "realpath invocation" (9.7).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const paths = @import("../paths.zig");

pub const Env = common.Env;
pub const Mode = paths.Mode;

pub const Options = struct {
    /// Canonicalisation mode (default `.canonical`; -e `.existing`, -m
    /// `.missing`, -s `.logical_only`).
    mode: Mode = .canonical,
    /// -L: apply ".." before symlinks. Overrides -s, as in GNU.
    logical: bool = false,
    /// -z: terminate with NUL instead of newline.
    zero: bool = false,
    /// --relative-to=DIR.
    relative_to: ?[]const u8 = null,
    /// --relative-base=DIR.
    relative_base: ?[]const u8 = null,
};

pub const Failure = paths.Error;
pub const Event = struct { name: []const u8, failure: Failure };
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// Some name could not be resolved (already reported to the observer).
    failed: bool = false,
    /// --relative-to / --relative-base directory that could not be resolved;
    /// when set nothing was written.
    bad_base: ?Event = null,
};

pub fn isBelow(path: []const u8, base: []const u8) bool {
    if (std.mem.eql(u8, base, "/")) return true;
    if (!std.mem.startsWith(u8, path, base)) return false;
    return path.len == base.len or path[base.len] == '/';
}

/// Resolve each name and write it to `out`.
pub fn run(env: Env, opts: Options, names: []const []const u8, out: *Io.Writer, obs: Observer) (Io.Writer.Error || error{OutOfMemory})!Result {
    var mode = opts.mode;
    // -L (logical) overrides -s: symlinks are expanded then.
    if (opts.logical and mode == .logical_only) mode = .canonical;

    // --relative-to / --relative-base directories are canonicalised first.
    var base_to: ?[]u8 = null;
    defer if (base_to) |b| env.gpa.free(b);
    var base_base: ?[]u8 = null;
    defer if (base_base) |b| env.gpa.free(b);
    const base_mode: Mode = if (mode == .existing) .existing else .missing;
    if (opts.relative_to) |d| base_to = paths.resolve(env, d, base_mode) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .bad_base = .{ .name = d, .failure = e } },
    };
    if (opts.relative_base) |d| base_base = paths.resolve(env, d, base_mode) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .bad_base = .{ .name = d, .failure = e } },
    };
    // A --relative-to directory outside --relative-base disables relative output.
    if (base_to != null and base_base != null and !isBelow(base_to.?, base_base.?)) {
        env.gpa.free(base_to.?);
        base_to = null;
        env.gpa.free(base_base.?);
        base_base = null;
    }
    // --relative-base alone makes --relative-to default to the base.
    if (base_to == null and base_base != null) base_to = try env.gpa.dupe(u8, base_base.?);

    var res: Result = .{};
    for (names) |f| {
        const r = paths.resolveLogical(env, f, mode, opts.logical) catch |e| {
            obs.emit(.{ .name = f, .failure = e });
            res.failed = true;
            continue;
        };
        defer env.gpa.free(r);
        var shown: []const u8 = r;
        var rel_buf: ?[]u8 = null;
        defer if (rel_buf) |b| env.gpa.free(b);
        if (base_to) |to| {
            // With --relative-base, only paths below the base are shortened.
            const below = if (base_base) |bb| isBelow(r, bb) else true;
            if (below) {
                rel_buf = paths.relativeTo(env.gpa, r, to) catch null;
                if (rel_buf) |b| shown = b;
            }
        }
        try out.writeAll(shown);
        try out.writeByte(if (opts.zero) 0 else '\n');
    }
    return res;
}

test "isBelow" {
    try std.testing.expect(isBelow("/a/b", "/a"));
    try std.testing.expect(!isBelow("/ab", "/a"));
    try std.testing.expect(isBelow("/a", "/"));
}
