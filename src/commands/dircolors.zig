// SPDX-License-Identifier: GPL-2.0-or-later
//! dircolors: thin wrapper over `util_core.dircolors` (decision 0004). Parses
//! arguments the way GNU dircolors does and words the diagnostics; the
//! database parser and the LS_COLORS writer are in src/lib/dircolors.zig.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const dc = @import("../lib/dircolors.zig");

/// Name as it appears in a diagnostic: quoted with single quotes only when it
/// contains characters a shell would interpret.
fn writeName(w: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8) !void {
    const plain = name.len > 0 and for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_-./+,:=@%", c) != null)) break false;
    } else true;
    if (plain) return w.appendSlice(gpa, name);
    try w.append(gpa, '\'');
    for (name) |c| {
        if (c == '\'') try w.appendSlice(gpa, "'\\''") else try w.append(gpa, c);
    }
    try w.append(gpa, '\'');
}

const long_options = [_]struct { name: []const u8, id: u8 }{
    .{ .name = "sh", .id = 'b' },
    .{ .name = "bourne-shell", .id = 'b' },
    .{ .name = "csh", .id = 'c' },
    .{ .name = "c-shell", .id = 'c' },
    .{ .name = "print-database", .id = 'p' },
    .{ .name = "print-ls-colors", .id = 'L' },
    .{ .name = "help", .id = 'h' },
    .{ .name = "version", .id = 'V' },
};

pub fn main(ctx: cli.Context) u8 {
    var opts: dc.Options = .{};
    var operands: [2]?[]const u8 = .{ null, null };
    var n_operands: usize = 0;
    var only_operands = false;

    for (ctx.args) |a| {
        if (only_operands or a.len < 2 or a[0] != '-') {
            if (n_operands < 2) operands[n_operands] = a;
            n_operands += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            const id = longOption(a[2..]) orelse return badOption(ctx, a);
            switch (id) {
                'h' => return help(ctx),
                'V' => return if (cli.printVersion(ctx)) 0 else 1,
                else => applyOption(&opts, id),
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'b', 'c', 'p' => applyOption(&opts, c),
            else => return badOption(ctx, a),
        };
    }

    // These checks and their order follow GNU.
    if ((opts.print_database or opts.print_ls_colors) and opts.shell != .unknown)
        return usageError(ctx, "the options to output non shell syntax,\nand to select a shell syntax are mutually exclusive");
    if (opts.print_database and opts.print_ls_colors)
        return usageError(ctx, "options --print-database and --print-ls-colors are mutually exclusive");
    const allowed: usize = if (opts.print_database) 0 else 1;
    if (n_operands > allowed) {
        const extra = operands[allowed].?;
        if (opts.print_database) {
            cli.warn(ctx, "extra operand '{s}'\nfile operands cannot be combined with --print-database (-p)\nTry '{s} --help' for more information.", .{ extra, ctx.name });
        } else {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ extra, ctx.name });
        }
        return 1;
    }

    const database: ?dc.Input = if (operands[0]) |path|
        (if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } })
    else
        null;

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: dc.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    dc.run(env, opts, database, &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
        error.Failed => return 1,
        error.OutOfMemory => return fail(ctx, "out of memory"),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    if (!cli.flushWriter(&stdout)) return 1;
    return 0;
}

fn report(context: ?*anyopaque, ev: dc.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .no_shell => cli.warn(ctx.*, "no SHELL environment variable, and no shell type option given", .{}),
        .read_failed => |r| {
            var name: std.ArrayList(u8) = .empty;
            defer name.deinit(ctx.gpa);
            writeName(&name, ctx.gpa, r.path) catch {};
            cli.warn(ctx.*, "{s}: {s}", .{ name.items, cli.errText(r.err) });
        },
        .problem => |p| {
            var name: std.ArrayList(u8) = .empty;
            defer name.deinit(ctx.gpa);
            if (p.path) |path| writeName(&name, ctx.gpa, path) catch {} else name.appendSlice(ctx.gpa, "<internal>") catch {};
            switch (p.problem.kind) {
                .missing_second_token => cli.warn(ctx.*, "{s}:{d}: invalid line;  missing second token", .{ name.items, p.problem.line }),
                .unrecognized_keyword => cli.warn(ctx.*, "{s}:{d}: unrecognized keyword '{s}'", .{ name.items, p.problem.line, p.problem.keyword }),
            }
        },
    }
}

fn applyOption(opts: *dc.Options, id: u8) void {
    switch (id) {
        'b' => opts.shell = .bourne,
        'c' => opts.shell = .c,
        'p' => opts.print_database = true,
        'L' => opts.print_ls_colors = true,
        else => unreachable,
    }
}

/// Long option by exact name or unambiguous prefix (as getopt_long does).
fn longOption(name: []const u8) ?u8 {
    var found: ?u8 = null;
    for (long_options) |o| {
        if (std.mem.eql(u8, o.name, name)) return o.id;
        if (std.mem.startsWith(u8, o.name, name)) {
            if (found != null and found.? != o.id) return null; // ambiguous
            found = o.id;
        }
    }
    return found;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: dircolors [OPTION]... [FILE]\n" ++
        "Output commands to set the LS_COLORS environment variable.\n\n" ++
        "Determine format of output:\n" ++
        "  -b, --sh, --bourne-shell    output Bourne shell code to set LS_COLORS\n" ++
        "  -c, --csh, --c-shell        output C shell code to set LS_COLORS\n" ++
        "  -p, --print-database        output defaults\n" ++
        "      --print-ls-colors       output fully escaped colors for display\n" ++
        "      --help     display this help and exit\n" ++
        "      --version  output version information and exit\n\n" ++
        "If FILE is specified, read it to determine which colors to use for which\n" ++
        "file types and extensions.  Otherwise, a precompiled database is used.\n" ++
        "For details on the format of these files, run 'dircolors --print-database'.\n")) 0 else 1;
}

fn fail(ctx: cli.Context, msg: []const u8) u8 {
    cli.warn(ctx, "{s}", .{msg});
    return 1;
}

fn usageError(ctx: cli.Context, msg: []const u8) u8 {
    cli.warn(ctx, "{s}\nTry '{s} --help' for more information.", .{ msg, ctx.name });
    return 1;
}

fn badOption(ctx: cli.Context, opt: []const u8) u8 {
    if (opt.len >= 2 and opt[0] == '-' and opt[1] != '-') {
        cli.invalidShort(ctx, opt[1]);
    } else {
        const nm = opt[2..];
        var buf: [512]u8 = undefined;
        var n: usize = 0;
        var cnt: usize = 0;
        for (long_options) |o| {
            if (nm.len > 0 and std.mem.startsWith(u8, o.name, nm)) {
                const piece = std.fmt.bufPrint(buf[n..], " '--{s}'", .{o.name}) catch break;
                n += piece.len;
                cnt += 1;
            }
        }
        if (cnt > 1) {
            cli.warn(ctx, "option '{s}' is ambiguous; possibilities:{s}\nTry '{s} --help' for more information.", .{ opt, buf[0..n], ctx.name });
        } else cli.warn(ctx, "unrecognized option '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    }
    return 1;
}

test "long option prefixes" {
    try std.testing.expectEqual(@as(?u8, 'b'), longOption("sh"));
    try std.testing.expectEqual(@as(?u8, 'p'), longOption("print-d"));
    try std.testing.expectEqual(@as(?u8, 'L'), longOption("print-l"));
    try std.testing.expectEqual(@as(?u8, null), longOption("print")); // ambiguous
    try std.testing.expectEqual(@as(?u8, 'c'), longOption("c-"));
    try std.testing.expectEqual(@as(?u8, null), longOption("x"));
}
