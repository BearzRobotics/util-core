// SPDX-License-Identifier: GPL-2.0-or-later
//! mktemp — create a temporary file or directory, safely, and print its name.
//! Reference: GNU coreutils manual "mktemp invocation" (9.7). POSIX does not
//! specify mktemp.
//! The template rules and the creation loop are in src/lib/mktemp.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const mktemp = @import("../lib/mktemp.zig");

const help_text = @embedFile("../help/mktemp.txt");

pub fn main(ctx: cli.Context) u8 {
    var make_dir = false;
    var dry_run = false;
    var quiet = false;
    var dir_opt: ?[]const u8 = null; // from -p DIR / --tmpdir=DIR
    var use_tmpdir = false; // -p, --tmpdir
    var tmpdir_t = false; // -t
    var suffix_opt: ?[]const u8 = null;
    var p = getopt.Parser.init(ctx, "dp:qtuV", &.{
        .{ .name = "directory", .id = 'd' },
        .{ .name = "dry-run", .id = 'u' },
        .{ .name = "quiet", .id = 'q' },
        .{ .name = "suffix", .arg = .required, .id = 1100 },
        .{ .name = "tmpdir", .arg = .optional, .id = 'p' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'd' => make_dir = true,
            'u' => dry_run = true,
            'q' => quiet = true,
            't' => {
                use_tmpdir = true;
                tmpdir_t = true;
            },
            'p' => {
                use_tmpdir = true;
                if (o.arg) |a| dir_opt = a;
            },
            1100 => suffix_opt = o.arg,
            'V' => return if (cli.printVersion(ctx)) 0 else 1,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const ops = p.operands.items;
    if (ops.len > 1) {
        getopt.usageError(ctx, "too many templates", .{});
        return 1;
    }
    var template: ?[]const u8 = null;
    if (ops.len == 1) template = ops[0];

    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts: mktemp.Options = .{
        .directory = make_dir,
        .dry_run = dry_run,
        .template = template,
        .suffix = suffix_opt,
        .use_tmpdir = use_tmpdir,
        .tmpdir_t = tmpdir_t,
        .dir = dir_opt,
    };
    const prepared = mktemp.prepare(a, opts, cli.getenv(ctx, "TMPDIR")) catch return 1;
    const plan = switch (prepared) {
        .ok => |pl| pl,
        .bad => |problem| {
            switch (problem) {
                .suffix_has_slash => |s| cli.warn(ctx, "invalid suffix {f}, contains directory separator", .{cli.quoteC(s)}),
                .suffix_needs_x => |t| cli.warn(ctx, "with --suffix, template {f} must end in X", .{cli.quoteC(t)}),
                .too_few_x => |t| cli.warn(ctx, "too few X's in template {f}", .{cli.quoteC(t)}),
                .template_has_slash => |t| cli.warn(ctx, "invalid template, {f}, contains directory separator", .{cli.quoteC(t)}),
                .template_absolute => |t| cli.warn(ctx, "invalid template, {f}; with --tmpdir, it may not be absolute", .{cli.quoteC(t)}),
            }
            return 1;
        },
    };
    const env: mktemp.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const created = mktemp.create(env, a, plan) catch return 1;
    switch (created) {
        .failed => |e| {
            if (!quiet) cli.warn(ctx, "failed to create {s} via template {f}: {s}", .{ if (make_dir) "directory" else "file", cli.quoteA(plan.full), cli.errText(e) });
            return 1;
        },
        .name => |name| {
            const line = std.fmt.allocPrint(a, "{s}\n", .{name}) catch null;
            if (line != null and cli.writeStdout(ctx.io, line.?)) return 0;
            // As GNU: nobody was told the name, so nobody else can remove it.
            if (!dry_run) {
                const cwd = std.Io.Dir.cwd();
                if (make_dir) cwd.deleteDir(ctx.io, name) catch {} else cwd.deleteFile(ctx.io, name) catch {};
            }
            return 1;
        },
    }
}
