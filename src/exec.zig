// SPDX-License-Identifier: GPL-2.0-or-later
//! Running another program for env, nohup, nice, stdbuf, chroot and timeout.
//!
//! std.process.replace never consults PATH from a custom environment map, but
//! the GNU tools use execvp after changing their own environment, so a PATH
//! given to `env` must be searched. `resolve` does that search.

const std = @import("std");
const builtin = @import("builtin");
const programpath = @import("programpath.zig");
const cli = @import("cli.zig");
const sys = @import("sys.zig");
const Io = std.Io;

/// Find `prog` the way execvp does. A name containing '/' is used as is;
/// otherwise each PATH element (empty = current directory; default
/// "/bin:/usr/bin" if PATH is unset) is tried and the first executable regular
/// file wins. If none is executable but one existed, `denied` is set.
pub fn resolve(ctx: cli.Context, arena: std.mem.Allocator, env: ?*const std.process.Environ.Map, prog: []const u8, denied: *bool) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // ";"-separated PATH, ".exe" and the rest, and never the current
        // directory.
        const found: @import("lib/common.zig").Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = env };
        return programpath.resolve(found, arena, prog) catch null;
    }
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
    return execReporting(ctx, prog, argv, env, style, null);
}

/// `execStyled` in nohup's style for a caller that has redirected standard
/// error: a failure is reported on `terminal`, the stream it had before.
pub fn execRestoring(ctx: cli.Context, prog: []const u8, argv: []const []const u8, terminal: ?sys.Handle) u8 {
    return execReporting(ctx, prog, argv, null, .run, terminal);
}

fn execReporting(ctx: cli.Context, prog: []const u8, argv: []const []const u8, env: ?*const std.process.Environ.Map, style: Style, terminal: ?sys.Handle) u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    var denied = false;
    const path = resolve(ctx, arena.allocator(), env orelse ctx.environ, prog, &denied) orelse {
        if (terminal) |fd| _ = sys.dup2(fd, 2);
        report(ctx, style, prog, if (denied) "Permission denied" else "No such file or directory");
        return if (denied) 126 else 127;
    };
    if (builtin.os.tag == .windows) return runInstead(ctx, path, argv, env orelse ctx.environ, style, prog);
    var err = std.process.replace(ctx.io, .{
        .exe = .{ .explicit = .{ .dir = Io.Dir.cwd(), .path = path } },
        .argv = argv,
        .environ_map = env orelse ctx.environ,
    });
    // As execvp, a file the kernel cannot execute (a script without a "#!"
    // line) is given to the shell.
    if (err == error.InvalidExe and @import("builtin").os.tag != .windows) {
        err = replaceWithShell(ctx, arena.allocator(), path, argv, env orelse ctx.environ);
    }
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
    if (terminal) |fd| _ = sys.dup2(fd, 2);
    report(ctx, style, prog, text);
    return if (err == error.FileNotFound) 127 else 126;
}

/// Windows cannot put another program in this one's place: run it, wait, and
/// end with its status.
fn runInstead(ctx: cli.Context, path: []const u8, argv: []const []const u8, env: ?*const std.process.Environ.Map, style: Style, prog: []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const args = arena.allocator().dupe([]const u8, argv) catch {
        report(ctx, style, prog, "Cannot allocate memory");
        return 126;
    };
    if (args.len > 0) args[0] = path;
    var child = std.process.spawn(ctx.io, .{ .argv = args, .environ_map = env }) catch |e| {
        report(ctx, style, prog, switch (e) {
            error.FileNotFound => "No such file or directory",
            error.AccessDenied, error.PermissionDenied => "Permission denied",
            error.InvalidExe => "Exec format error",
            else => @errorName(e),
        });
        return if (e == error.FileNotFound) 127 else 126;
    };
    const term = child.wait(ctx.io) catch return 126;
    return switch (term) {
        .exited => |code| code,
        else => 126,
    };
}

fn report(ctx: cli.Context, style: Style, prog: []const u8, text: []const u8) void {
    switch (style) {
        .env => cli.warn(ctx, "{f}: {s}", .{ cli.quoteC(prog), text }),
        .run => cli.warn(ctx, "failed to run command {f}: {s}", .{ cli.quoteC(prog), text }),
    }
}

/// Run `sh PATH ARG...` in this process's place; returns only on failure.
fn replaceWithShell(ctx: cli.Context, arena: std.mem.Allocator, path: []const u8, argv: []const []const u8, env: ?*const std.process.Environ.Map) std.process.ReplaceError {
    // Not to be taken for an option of the shell.
    const script = if (path.len > 0 and path[0] == '-') std.fmt.allocPrint(arena, "./{s}", .{path}) catch return error.OutOfMemory else path;
    const shell = std.mem.concat(arena, []const u8, &.{ &.{ "/bin/sh", script }, argv[@min(argv.len, 1)..] }) catch return error.OutOfMemory;
    return std.process.replace(ctx.io, .{
        .exe = .{ .explicit = .{ .dir = Io.Dir.cwd(), .path = "/bin/sh" } },
        .argv = shell,
        .environ_map = env,
    });
}
