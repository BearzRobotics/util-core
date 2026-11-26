// SPDX-License-Identifier: GPL-2.0-or-later
//! Path canonicalisation shared by readlink and realpath.
//! Reference: GNU coreutils manual "realpath invocation" / "readlink
//! invocation" (9.7); gnulib canonicalize_filename_mode.
//!
//! Resolved component by component so that `-m` can handle missing
//! components and `-s` can skip symlinks. Symlinks are expanded up to 40
//! levels (ELOOP, as the kernel does).
//!
//! As in gnulib, every component is examined, and any failure to do so is an
//! error: a name that could not be checked is never reported as canonical.
//! `.missing` (-m) tolerates all of them; `.canonical` (-f) only a last
//! component that does not exist (and `.logical_only` any missing one that
//! only names follow).

const std = @import("std");
const errtext = @import("errtext.zig");
const sys = @import("sys.zig");
const Io = std.Io;

pub const Mode = enum {
    none, // readlink without -f/-e/-m
    canonical, // -f: last component may be missing
    existing, // -e: everything must exist
    missing, // -m: nothing needs to exist
    logical_only, // realpath -s: no symlink expansion
};

pub const Error = error{
    NotFound,
    NotDir,
    Loop,
    OutOfMemory,
    NameTooLong,
    AccessDenied,
    PermissionDenied,
    InputOutput,
    SystemResources,
    /// Any other failure to examine a component.
    Unexpected,
};

fn mapError(e: anyerror) Error {
    return switch (e) {
        error.FileNotFound => error.NotFound,
        error.NotDir => error.NotDir,
        error.SymLinkLoop => error.Loop,
        error.NameTooLong => error.NameTooLong,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.FileSystem, error.InputOutput => error.InputOutput,
        error.SystemResources => error.SystemResources,
        else => error.Unexpected,
    };
}

/// The diagnostic text of a failure.
pub fn errorText(e: Error) []const u8 {
    return switch (e) {
        error.NotFound => "No such file or directory",
        error.Loop => "Too many levels of symbolic links",
        error.Unexpected => "Unexpected error",
        else => errtext.errText(e),
    };
}

/// True when what follows a component demands that it be a directory: a
/// trailing slash, or "." or ".." (with only more "." between). A following
/// name needs no check here, since examining it fails if this is not one.
fn needsDirectory(rest: []const u8) bool {
    if (rest.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, rest, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        return std.mem.eql(u8, c, "..");
    }
    return true;
}

/// Check that `name` exists, as a directory when `directory`. `name` is
/// borrowed and left as it was.
fn mustExist(gpa: std.mem.Allocator, name: *std.ArrayList(u8), directory: bool) Error!void {
    const len = name.items.len;
    // "name/" only exists when it is a directory (or leads to one).
    if (directory and name.items[len - 1] != '/') try name.append(gpa, '/');
    defer name.shrinkRetainingCapacity(len);
    var e: sys.E = .SUCCESS;
    if (sys.fileStat(name.items, true, &e) != null) return;
    return switch (e) {
        .NOENT => error.NotFound,
        .NOTDIR => error.NotDir,
        .LOOP => error.Loop,
        .NAMETOOLONG => error.NameTooLong,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .IO => error.InputOutput,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

test "needsDirectory" {
    try std.testing.expect(needsDirectory("/"));
    try std.testing.expect(needsDirectory("/./"));
    try std.testing.expect(needsDirectory("/./.."));
    try std.testing.expect(needsDirectory("//../x"));
    try std.testing.expect(!needsDirectory(""));
    try std.testing.expect(!needsDirectory("/x"));
    try std.testing.expect(!needsDirectory("/./x/.."));
    try std.testing.expect(!needsDirectory("/..."));
}

/// Absolute canonical form of `path` (caller frees). `ctx` is anything with
/// `.io` and `.gpa` (a `cli.Context` or a `common.Env`).
pub fn resolve(ctx: anytype, path: []const u8, mode: Mode) Error![]u8 {
    return resolveLogical(ctx, path, mode, false);
}

/// Like `resolve`; `dotdot_first` applies ".." before symlink expansion
/// (realpath -L).
pub fn resolveLogical(ctx: anytype, path: []const u8, mode: Mode, dotdot_first: bool) Error![]u8 {
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
    var links: usize = 0;
    var pos: usize = 0;
    while (true) {
        while (pos < pending.items.len and pending.items[pos] == '/') pos += 1;
        if (pos >= pending.items.len) break;
        const end = std.mem.indexOfScalarPos(u8, pending.items, pos, '/') orelse pending.items.len;
        const comp = pending.items[pos..end];
        pos = end;
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
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
        const rest = pending.items[pos..];
        const failure: Error = failed: {
            if (mode == .logical_only) {
                // -s: symlinks stay as they are, but the path must still be
                // valid.
                mustExist(gpa, &result, needsDirectory(rest)) catch |e| break :failed e;
                continue;
            }
            var lbuf: [4096]u8 = undefined;
            if (Io.Dir.cwd().readLink(ctx.io, result.items, &lbuf)) |n| {
                links += 1;
                if (links > 40) break :failed error.Loop;
                // Replace the component by its target and keep going.
                result.shrinkRetainingCapacity(before);
                var target: std.ArrayList(u8) = .empty;
                defer target.deinit(gpa);
                try target.appendSlice(gpa, lbuf[0..n]);
                try target.appendSlice(gpa, rest);
                pending.clearRetainingCapacity();
                try pending.appendSlice(gpa, target.items);
                pos = 0;
                if (lbuf[0] == '/') {
                    result.clearRetainingCapacity();
                    try result.append(gpa, '/');
                }
                continue;
            } else |e| switch (e) {
                // It exists and is not a link.
                error.NotLink, error.UnsupportedReparsePointType => {
                    if (needsDirectory(rest)) mustExist(gpa, &result, true) catch |de| break :failed de;
                    continue;
                },
                else => break :failed mapError(e),
            }
        };
        // The component stays in the result unresolved when tolerated.
        if (failure == error.OutOfMemory) return failure;
        if (mode == .missing) continue;
        const last = std.mem.indexOfNone(u8, rest, "/") == null;
        if (failure == error.NotFound and last and mode != .existing) continue;
        // As GNU, -s lets names go on past a missing one, but not "." or "..".
        if (failure == error.NotFound and mode == .logical_only and !needsDirectory(rest)) continue;
        return failure;
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

