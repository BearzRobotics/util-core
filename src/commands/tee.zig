// SPDX-License-Identifier: GPL-2.0-or-later
//! tee — copy standard input to standard output and to files.
//! References: GNU coreutils manual "tee invocation" (9.7); POSIX.1-2024 tee.
//!
//! Options: -a/--append, -i/--ignore-interrupts, -p, --output-error[=MODE].
//! As in POSIX and current GNU, a FILE named "-" is a file called "-", not
//! standard output. Output is not buffered: each chunk read is written
//! immediately to every destination.
//!
//! Error handling follows the GNU manual's --output-error table. Without the
//! option SIGPIPE stays as inherited (normally the process dies; if ignored, a
//! broken pipe is dropped in silence), as in GNU; with it SIGPIPE is ignored so a broken pipe surfaces as a write error.
//! -a is implemented with O_APPEND and is POSIX-only for now.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const tee = @import("../lib/tee.zig");

const long_names = [_][]const u8{ "append", "ignore-interrupts", "output-error", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var append = false;
    var ignore_int = false;
    var mode: tee.Mode = .default;
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
                    2 => mode = if (eq) |e| tee.parseMode(a[e + 1 ..]) orelse {
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

    if (ignore_int) sys.ignoreSignal(.int);
    // SIGPIPE is as tee was started with it, normally the default action;
    // --output-error wants to see EPIPE as an ordinary write error instead.
    if (mode != .default) sys.ignoreSignal(.pipe);

    var dests: std.ArrayList(tee.Destination) = .empty;
    defer dests.deinit(ctx.gpa);
    dests.append(ctx.gpa, .{ .name = "standard output", .target = .{ .file = Io.File.stdout() } }) catch return oom(ctx);
    for (paths) |p| {
        dests.append(ctx.gpa, .{ .name = p, .target = .{ .path = p } }) catch return oom(ctx);
    }

    const env: tee.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = tee.run(env, .{ .append = append, .output_error = mode }, Io.File.stdin(), dests.items, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch return oom(ctx);
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: tee.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err) });
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

