// SPDX-License-Identifier: GPL-2.0-or-later
//! Running another program for env, nohup, nice, stdbuf, chroot and timeout.
//!
//! std.process.replace never consults PATH from a custom environment map, but
//! the GNU tools use execvp after changing their own environment, so a PATH
//! given to `env` must be searched. `resolve` does that search.

const std = @import("std");
const cli = @import("cli.zig");
const Io = std.Io;

/// Find `prog` the way execvp does. A name containing '/' is used as is;
/// otherwise each PATH element (empty = current directory; default
/// "/bin:/usr/bin" if PATH is unset) is tried and the first executable regular
/// file wins. If none is executable but one existed, `denied` is set.
pub fn resolve(ctx: cli.Context, arena: std.mem.Allocator, env: ?*const std.process.Environ.Map, prog: []const u8, denied: *bool) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, prog, '/') != null) return prog;
    const path: []const u8 = if (env) |m| (m.get("PATH") orelse "/bin:/usr/bin") else "/bin:/usr/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = std.fmt.allocPrint(arena, "{s}/{s}", .{ if (dir.len == 0) "." else dir, prog }) catch return null;
        const cwd = Io.Dir.cwd();
        cwd.access(ctx.io, full, .{ .execute = true }) catch |e| {
            if (e == error.AccessDenied or e == error.PermissionDenied) denied.* = true;
            continue;
        };
        const st = cwd.statFile(ctx.io, full, .{}) catch continue;
        if (st.kind == .directory) continue;
        return full;
    }
    return null;
}

/// Replace this process with `argv` (argv[0] is what the program sees,
/// `prog` is what is looked up). Returns only on failure, after printing a
/// diagnostic in GNU style; the result is the exit status GNU uses: 127 when
/// the program is not found, 126 when it exists but cannot be run.
pub const Style = enum {
    /// `env: 'prog': No such file or directory`
    env,
    /// `nohup: failed to run command 'prog': No such file or directory`
    run,
};

pub fn exec(ctx: cli.Context, prog: []const u8, argv: []const []const u8, env: ?*const std.process.Environ.Map) u8 {
    return execStyled(ctx, prog, argv, env, .env);
}

pub fn execStyled(ctx: cli.Context, prog: []const u8, argv: []const []const u8, env: ?*const std.process.Environ.Map, style: Style) u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    var denied = false;
    const path = resolve(ctx, arena.allocator(), env orelse ctx.environ, prog, &denied) orelse {
        report(ctx, style, prog, if (denied) "Permission denied" else "No such file or directory");
        return if (denied) 126 else 127;
    };
    const err = std.process.replace(ctx.io, .{
        .exe = .{ .explicit = .{ .dir = Io.Dir.cwd(), .path = path } },
        .argv = argv,
        .environ_map = env orelse ctx.environ,
    });
    const text: []const u8 = switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.InvalidExe => "Exec format error",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.FileBusy => "Text file busy",
        error.SystemResources, error.OutOfMemory => "Cannot allocate memory",
        else => @errorName(err),
    };
    report(ctx, style, prog, text);
    return if (err == error.FileNotFound) 127 else 126;
}

fn report(ctx: cli.Context, style: Style, prog: []const u8, text: []const u8) void {
    switch (style) {
        .env => cli.warn(ctx, "{f}: {s}", .{ cli.quoteC(prog), text }),
        .run => cli.warn(ctx, "failed to run command {f}: {s}", .{ cli.quoteC(prog), text }),
    }
}
