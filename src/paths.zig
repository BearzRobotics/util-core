// SPDX-License-Identifier: GPL-2.0-or-later
//! Path canonicalisation shared by readlink and realpath.
//! Reference: GNU coreutils manual "realpath invocation" / "readlink
//! invocation" (9.7); gnulib canonicalize_filename_mode.
//!
//! Resolved component by component so that `-m` can handle missing
//! components and `-s` can skip symlinks. Symlinks are expanded up to 40
//! levels (ELOOP, as the kernel does).

const std = @import("std");
const cli = @import("cli.zig");
const Io = std.Io;

pub const Mode = enum {
    none, // readlink without -f/-e/-m
    canonical, // -f: last component may be missing
    existing, // -e: everything must exist
    missing, // -m: nothing needs to exist
    logical_only, // realpath -s: no symlink expansion
};

pub const Error = error{ NotFound, NotDir, Loop, OutOfMemory, NameTooLong };

/// Absolute canonical form of `path` (caller frees).
pub fn resolve(ctx: cli.Context, path: []const u8, mode: Mode) Error![]u8 {
    return resolveLogical(ctx, path, mode, false);
}

/// Like `resolve`; `dotdot_first` applies ".." before symlink expansion
/// (realpath -L).
pub fn resolveLogical(ctx: cli.Context, path: []const u8, mode: Mode, dotdot_first: bool) Error![]u8 {
    _ = dotdot_first;
    const gpa = ctx.gpa;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);
    // Work list of path text still to process (symlink targets are pushed back).
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);

    if (path.len == 0) return error.NotFound;
    if (path[0] == '/') {
        try result.append(gpa, '/');
        try pending.appendSlice(gpa, path);
    } else {
        var cwd_buf: [4096]u8 = undefined;
        const n = Io.Dir.cwd().realPath(ctx.io, &cwd_buf) catch return error.NotFound;
        try result.appendSlice(gpa, cwd_buf[0..n]);
        try pending.append(gpa, '/');
        try pending.appendSlice(gpa, path);
    }
    // `pending` starts with '/'; consume components from its front.
    const trailing_slash = path.len > 1 and path[path.len - 1] == '/';
    var links: usize = 0;
    var pos: usize = 0;
    var missing = false; // a component did not exist (-m / last component of -f)
    while (true) {
        while (pos < pending.items.len and pending.items[pos] == '/') pos += 1;
        if (pos >= pending.items.len) break;
        const end = std.mem.indexOfScalarPos(u8, pending.items, pos, '/') orelse pending.items.len;
        const comp = pending.items[pos..end];
        pos = end;
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (missing and mode == .logical_only) return error.NotFound;
            // Pop the last component of the result (never above the root).
            if (result.items.len > 1) {
                var k = result.items.len;
                while (k > 1 and result.items[k - 1] != '/') k -= 1;
                result.shrinkRetainingCapacity(if (k > 1) k - 1 else 1);
            }
            continue;
        }
        const before = result.items.len;
        if (result.items.len > 1) try result.append(gpa, '/');
        try result.appendSlice(gpa, comp);
        if (mode == .logical_only) {
            // -s: symlinks stay as they are, but the path must still be valid.
            if (Io.Dir.cwd().statFile(ctx.io, result.items, .{})) |_| {} else |e| switch (e) {
                error.FileNotFound => missing = true, // tolerated, except before a ".."
                error.NotDir => return error.NotDir,
                error.SymLinkLoop => return error.Loop,
                else => {},
            }
            continue;
        }

        var lbuf: [4096]u8 = undefined;
        if (Io.Dir.cwd().readLink(ctx.io, result.items, &lbuf)) |n| {
            links += 1;
            if (links > 40) {
                // -m tolerates a loop and keeps the component unresolved.
                if (mode == .missing) {
                    missing = true;
                    continue;
                }
                return error.Loop;
            }
            // Replace the component by its target and keep going.
            result.shrinkRetainingCapacity(before);
            var rest: std.ArrayList(u8) = .empty;
            defer rest.deinit(gpa);
            try rest.appendSlice(gpa, lbuf[0..n]);
            try rest.append(gpa, '/');
            try rest.appendSlice(gpa, pending.items[pos..]);
            pending.clearRetainingCapacity();
            try pending.appendSlice(gpa, rest.items);
            pos = 0;
            if (lbuf[0] == '/') {
                result.clearRetainingCapacity();
                try result.append(gpa, '/');
            }
            continue;
        } else |e| switch (e) {
            error.NotLink => {},
            error.FileNotFound => {
                missing = true;
            },
            error.NotDir => {
                if (mode == .missing) {
                    missing = true;
                } else return error.NotDir;
            },
            else => {},
        }
        if (missing) {
            const more = std.mem.indexOfNone(u8, pending.items[pos..], "/") != null;
            switch (mode) {
                .existing => return error.NotFound,
                .canonical => if (more) return error.NotFound,
                else => {},
            }
        }
        // A component that exists and is not the last must be a directory.
        if (!missing and std.mem.indexOfNone(u8, pending.items[pos..], "/") != null) {
            const st = Io.Dir.cwd().statFile(ctx.io, result.items, .{}) catch |e| {
                if (e == error.FileNotFound) return error.NotFound;
                continue;
            };
            if (st.kind != .directory and mode != .missing) return error.NotDir;
        }
    }
    if (mode == .existing and !missing) {
        // Final existence check for -e (covers a trailing symlink to nothing).
        _ = Io.Dir.cwd().statFile(ctx.io, result.items, .{}) catch return error.NotFound;
    }
    if (trailing_slash and mode != .missing) {
        // "name/" demands a directory.
        if (Io.Dir.cwd().statFile(ctx.io, result.items, .{})) |st| {
            if (st.kind != .directory) return error.NotDir;
        } else |e| switch (e) {
            error.FileNotFound => if (mode != .none) return error.NotFound,
            error.NotDir => return error.NotDir,
            else => {},
        }
    }
    return result.toOwnedSlice(gpa);
}

/// `path` relative to directory `from`; both absolute and canonical.
pub fn relativeTo(gpa: std.mem.Allocator, path: []const u8, from: []const u8) ![]u8 {
    var pi = std.mem.tokenizeScalar(u8, path, '/');
    var fi = std.mem.tokenizeScalar(u8, from, '/');
    // Skip the common prefix of components.
    var p_rest: []const u8 = path;
    var f_rest: []const u8 = from;
    _ = &p_rest;
    _ = &f_rest;
    var common: usize = 0;
    var ptoks: std.ArrayList([]const u8) = .empty;
    defer ptoks.deinit(gpa);
    var ftoks: std.ArrayList([]const u8) = .empty;
    defer ftoks.deinit(gpa);
    while (pi.next()) |t| try ptoks.append(gpa, t);
    while (fi.next()) |t| try ftoks.append(gpa, t);
    while (common < ptoks.items.len and common < ftoks.items.len and std.mem.eql(u8, ptoks.items[common], ftoks.items[common])) common += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var ups = ftoks.items.len - common;
    while (ups > 0) : (ups -= 1) {
        if (out.items.len > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, "..");
    }
    for (ptoks.items[common..]) |t| {
        if (out.items.len > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, t);
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa);
}

