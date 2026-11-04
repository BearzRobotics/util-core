//! tee — copy standard input to standard output and to files.
//! References: GNU coreutils manual "tee invocation" (9.7); POSIX.1-2024 tee.
//!
//! Options: -a/--append, -i/--ignore-interrupts, -p, --output-error[=MODE].
//! As in POSIX and current GNU, a FILE named "-" is a file called "-", not
//! standard output. Output is not buffered: each chunk read is written
//! immediately to every destination.
//!
//! Error handling follows the GNU manual's --output-error table. Without the
//! option SIGPIPE keeps its default action (the process dies), as in GNU;
//! with it SIGPIPE is ignored so a broken pipe surfaces as a write error.
//! -a is implemented with O_APPEND and is POSIX-only for now.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const cli = @import("../cli.zig");

const long_names = [_][]const u8{ "append", "ignore-interrupts", "output-error", "help", "version" };

const Mode = enum { default, warn, warn_nopipe, exit, exit_nopipe };

const Output = struct {
    file: Io.File,
    name: []const u8,
    /// Standard output is never closed here.
    is_stdout: bool,
    alive: bool = true,
};

pub fn main(ctx: cli.Context) u8 {
    var append = false;
    var ignore_int = false;
    var mode: Mode = .default;
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => append = true,
                    1 => ignore_int = true,
                    2 => mode = if (eq) |e| parseMode(a[e + 1 ..]) orelse {
                        cli.warn(ctx, "invalid argument '{s}' for '--output-error'\n" ++
                            "Valid arguments are:\n  - 'warn'\n  - 'warn-nopipe'\n  - 'exit'\n  - 'exit-nopipe'\n" ++
                            "Try '{s} --help' for more information.", .{ a[e + 1 ..], ctx.name });
                        return 1;
                    } else .warn_nopipe,
                    3 => return help(ctx),
                    else => return if (cli.printVersion(ctx)) 0 else 1,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        } else for (a[1..]) |c| switch (c) {
            'a' => append = true,
            'i' => ignore_int = true,
            'p' => mode = .warn_nopipe,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    const paths = ctx.args[i..];

    if (comptime builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (ignore_int) setSignal(.INT, std.posix.SIG.IGN);
        // Zig's runtime ignores SIGPIPE; GNU tee lets it kill the process
        // unless --output-error was given.
        if (mode == .default) setSignal(.PIPE, std.posix.SIG.DFL);
    }

    var outs: std.ArrayList(Output) = .empty;
    defer outs.deinit(ctx.gpa);
    outs.append(ctx.gpa, .{ .file = Io.File.stdout(), .name = "standard output", .is_stdout = true }) catch return oom(ctx);

    var status: u8 = 0;
    for (paths) |p| {
        const file = openOutput(ctx.io, p, append) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ p, cli.errText(e) });
            status = 1;
            if (mode == .exit or mode == .exit_nopipe) return 1;
            continue;
        };
        outs.append(ctx.gpa, .{ .file = file, .name = p, .is_stdout = false }) catch return oom(ctx);
    }
    defer for (outs.items) |o| if (!o.is_stdout) o.file.close(ctx.io);

    var live: usize = outs.items.len;
    const stdin = Io.File.stdin();
    var buf: [64 * 1024]u8 = undefined;
    while (live > 0) {
        const n = cli.readChunk(ctx.io, stdin, &buf) catch |e| {
            cli.warn(ctx, "standard input: {s}", .{cli.errText(e)});
            status = 1;
            break;
        };
        if (n == 0) break;
        for (outs.items) |*o| {
            if (!o.alive) continue;
            o.file.writeStreamingAll(ctx.io, buf[0..n]) catch |e| {
                const pipe = e == error.BrokenPipe;
                const quiet = pipe and (mode == .warn_nopipe or mode == .exit_nopipe);
                if (!quiet) {
                    cli.warn(ctx, "{s}: {s}", .{ o.name, cli.errText(e) });
                    status = 1;
                }
                if (mode == .exit or (mode == .exit_nopipe and !pipe)) return 1;
                o.alive = false;
                live -= 1;
            };
        }
    }
    return status;
}

fn parseMode(text: []const u8) ?Mode {
    if (std.mem.eql(u8, text, "warn")) return .warn;
    if (std.mem.eql(u8, text, "warn-nopipe")) return .warn_nopipe;
    if (std.mem.eql(u8, text, "exit")) return .exit;
    if (std.mem.eql(u8, text, "exit-nopipe")) return .exit_nopipe;
    return null;
}

fn openOutput(io: Io, path: []const u8, append: bool) !Io.File {
    if (append) {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.Unsupported;
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
            .CLOEXEC = true,
        }, 0o666);
        return .{ .handle = fd, .flags = .{ .nonblocking = false } };
    }
    return Io.Dir.cwd().createFile(io, path, .{});
}

fn setSignal(sig: std.posix.SIG, handler: ?std.posix.Sigaction.handler_fn) void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &act, null);
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tee [OPTION]... [FILE]...\n" ++
        "Copy standard input to each FILE, and also to standard output.\n\n" ++
        "  -a, --append              append to the given FILEs, do not overwrite\n" ++
        "  -i, --ignore-interrupts   ignore interrupt signals\n" ++
        "  -p                        operate in a more appropriate manner with pipes\n" ++
        "      --output-error[=MODE] set behavior on write error: warn, warn-nopipe,\n" ++
        "                            exit, exit-nopipe\n" ++
        "      --help                display this help and exit\n" ++
        "      --version             output version information and exit\n")) 0 else 1;
}

test "parseMode" {
    try std.testing.expectEqual(Mode.warn, parseMode("warn").?);
    try std.testing.expectEqual(Mode.exit_nopipe, parseMode("exit-nopipe").?);
    try std.testing.expect(parseMode("x") == null);
}
