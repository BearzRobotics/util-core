//! pwd — print the working directory.
//! References: GNU coreutils manual "pwd invocation" (9.7); POSIX.1-2024 pwd.
//!
//! Options -L / -P (last wins). POSIX defaults to -L; GNU's standalone pwd
//! defaults to -P unless POSIXLY_CORRECT is set. We follow GNU.
//! -L uses $PWD only if it is absolute, has no "." or ".." component, and
//! names the same directory as the physical working directory; otherwise it
//! behaves like -P (both specs).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");

const long_names = [_][]const u8{ "logical", "physical", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var logical = cli.getenv(ctx, "POSIXLY_CORRECT") != null;
    var i: usize = 0;
    var operands: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            operands += ctx.args.len - i - 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') {
            operands += 1;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => logical = true,
                    1 => logical = false,
                    2 => return help(ctx),
                    else => return if (cli.printVersion(ctx)) 0 else 1,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        } else for (a[1..]) |c| switch (c) {
            'L' => logical = true,
            'P' => logical = false,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (operands > 0) cli.warn(ctx, "ignoring non-option arguments", .{});

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(ctx.io, &buf) catch |e| {
        cli.warn(ctx, "cannot get current directory: {s}", .{cli.errText(e)});
        return 1;
    };
    const physical = buf[0..n];
    var path: []const u8 = physical;
    if (logical) if (cli.getenv(ctx, "PWD")) |env_pwd| {
        if (pwdIsValid(ctx.io, env_pwd, physical)) path = env_pwd;
    };

    var out = cli.Out.init(ctx.io);
    out.write(path);
    out.writeByte('\n');
    out.flush();
    return if (out.failed) 1 else 0;
}

/// True when `candidate` is absolute, free of "." / ".." components, and
/// resolves to the same directory as `physical`.
fn pwdIsValid(io: Io, candidate: []const u8, physical: []const u8) bool {
    if (!hasNoDotComponents(candidate)) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.realPathFileAbsolute(io, candidate, &buf) catch return false;
    return std.mem.eql(u8, buf[0..n], physical);
}

fn hasNoDotComponents(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: pwd [OPTION]...\n" ++
        "Print the full filename of the current working directory.\n\n" ++
        "  -L, --logical   use PWD from environment, even if it contains symlinks\n" ++
        "  -P, --physical  avoid all symlinks (default unless POSIXLY_CORRECT is set)\n" ++
        "      --help      display this help and exit\n" ++
        "      --version   output version information and exit\n")) 0 else 1;
}

test "hasNoDotComponents" {
    const t = std.testing;
    try t.expect(hasNoDotComponents("/a/b"));
    try t.expect(hasNoDotComponents("/"));
    try t.expect(!hasNoDotComponents("a/b"));
    try t.expect(!hasNoDotComponents("/a/./b"));
    try t.expect(!hasNoDotComponents("/a/../b"));
    try t.expect(!hasNoDotComponents(""));
}
