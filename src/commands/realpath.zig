// SPDX-License-Identifier: GPL-2.0-or-later
//! realpath — print the resolved absolute file name.
//! Reference: GNU coreutils manual "realpath invocation" (9.7).

const std = @import("std");
const cli = @import("../cli.zig");
const paths = @import("../paths.zig");
const realpath = @import("../lib/realpath.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "canonicalize-existing", "canonicalize-missing", "logical", "physical", "quiet", "relative-to", "relative-base", "strip", "no-symlinks", "zero", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var mode: paths.Mode = .canonical;
    var quiet = false;
    var zero = false;
    var logical = false;
    var rel_to: ?[]const u8 = null;
    var rel_base: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            const takes = k == 5 or k == 6;
            if (takes and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                    return 1;
                }
                value = ctx.args[i];
            } else if (!takes and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => mode = .existing,
                1 => mode = .missing,
                2 => logical = true,
                3 => logical = false,
                4 => quiet = true,
                5 => rel_to = value,
                6 => rel_base = value,
                7, 8 => mode = .logical_only,
                9 => zero = true,
                10 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'e' => mode = .existing,
            'm' => mode = .missing,
            'L' => logical = true,
            'P' => logical = false,
            'q' => quiet = true,
            's' => mode = .logical_only,
            'z' => zero = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (files.items.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    var rep: Report = .{ .ctx = &ctx, .out = &stdout.interface, .quiet = quiet };
    const env: realpath.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = realpath.run(env, .{
        .mode = mode,
        .logical = logical,
        .zero = zero,
        .relative_to = rel_to,
        .relative_base = rel_base,
    }, files.items, &stdout.interface, .{ .context = &rep, .func = report }) catch |e| switch (e) {
        error.OutOfMemory => return 1,
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    if (result.bad_base) |d| {
        if (!quiet) cli.warn(ctx, "{f}: No such file or directory", .{cli.quote(d)});
        return 1;
    }
    if (!cli.flushWriter(&stdout)) return 1;
    return if (result.failed) 1 else 0;
}

const Report = struct {
    ctx: *const cli.Context,
    out: *Io.Writer,
    quiet: bool,
};

fn report(context: ?*anyopaque, ev: realpath.Event) void {
    const r: *Report = @ptrCast(@alignCast(context.?));
    if (r.quiet) return;
    r.out.flush() catch {};
    const msg = switch (ev.failure) {
        error.NotDir => "Not a directory",
        error.Loop => "Too many levels of symbolic links",
        error.NameTooLong => "File name too long",
        else => "No such file or directory",
    };
    cli.warn(r.ctx.*, "{f}: {s}", .{ cli.quote(ev.name), msg });
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: realpath [OPTION]... FILE...\nPrint the resolved absolute file name;\nall but the last component must exist\n\n  -e, --canonicalize-existing  all components of the path must exist\n  -m, --canonicalize-missing   no path components need exist or be a directory\n  -L, --logical                resolve '..' components before symlinks\n  -P, --physical               resolve symlinks as encountered (default)\n  -q, --quiet                  suppress most error messages\n      --relative-to=DIR        print the resolved path relative to DIR\n      --relative-base=DIR      print absolute paths unless paths below DIR\n  -s, --strip, --no-symlinks   don't expand symlinks\n  -z, --zero                   end each output line with NUL, not newline\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
