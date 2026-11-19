// SPDX-License-Identifier: GPL-2.0-or-later
//! updatedb: thin wrapper over `util_core.updatedb` (decision 0004). Reads the
//! script's environment variables and `--option=value` flags exactly as the
//! GNU updatedb script does and words the diagnostics; the walk, pruning,
//! sorting and front coding are in src/lib/updatedb.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const updatedb = @import("../lib/updatedb.zig");

/// updatedb has always used the general-purpose allocator without leak checking.
const gpa = std.heap.smp_allocator;

fn envOr(ctx: cli.Context, name: []const u8, default: []const u8) []const u8 {
    return cli.getenv(ctx, name) orelse default;
}

/// Write one complete diagnostic to standard error.
fn stderrLine(ctx: cli.Context, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(msg);
    std.Io.File.stderr().writeStreamingAll(ctx.io, msg) catch {};
}

fn report(context: ?*anyopaque, ev: updatedb.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .find_error => |e| stderrLine(ctx.*, "find: '{s}': {s}\n", .{ e.path, e.text }),
        .find_bad_number => |e| stderrLine(ctx.*, "find: Expected a positive decimal integer argument to {s}, but got '{s}'\n", .{ e.option, e.value }),
        .find_unknown_predicate => |o| stderrLine(ctx.*, "find: unknown predicate `{s}'\n", .{o}),
        .prune_trailing_slash => |pp| stderrLine(ctx.*, "{s}: {s}: pruned paths should not contain trailing slashes\n", .{ ctx.name, pp }),
        .create_failed => |e| stderrLine(ctx.*, "{s}: {s}: {s}\nFailed to generate {s}\n", .{ ctx.name, e.tmp, e.text, e.tmp }),
        .move_failed => |e| stderrLine(ctx.*, "mv: cannot move '{s}' to '{s}': {s}\n", .{ e.from, e.to, e.text }),
        .empty_database => stderrLine(ctx.*, "updatedb: new database would be empty\n", .{}),
    }
}

pub fn main(ctx: cli.Context) u8 {
    var o: updatedb.Options = .{
        .findoptions = envOr(ctx, "FINDOPTIONS", ""),
        .searchpaths = envOr(ctx, "SEARCHPATHS", "/"),
        .netpaths = envOr(ctx, "NETPATHS", ""),
        .prunepaths = envOr(ctx, "PRUNEPATHS", updatedb.default_prunepaths),
        .prunefs = envOr(ctx, "PRUNEFS", updatedb.default_prunefs),
        .output = envOr(ctx, "LOCATE_DB", updatedb.default_output),
    };
    var dbformat: []const u8 = "";
    for (ctx.args) |arg| {
        const a: []const u8 = arg;
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const opt = if (eq) |k| a[0..k] else a;
        const val = if (eq) |k| a[k + 1 ..] else a;
        const m = std.mem.eql;
        if (m(u8, opt, "--findoptions")) o.findoptions = val else if (m(u8, opt, "--localpaths")) o.searchpaths = val else if (m(u8, opt, "--netpaths")) o.netpaths = val else if (m(u8, opt, "--prunepaths")) o.prunepaths = val else if (m(u8, opt, "--prunefs")) o.prunefs = val else if (m(u8, opt, "--output")) o.output = val else if (m(u8, opt, "--netuser") or m(u8, opt, "--localuser")) {} else if (m(u8, opt, "--changecwd")) o.changecwd = val else if (m(u8, opt, "--dbformat")) dbformat = val else if (m(u8, opt, "--version")) {
            const v =
                \\
                \\updatedb (GNU findutils) 4.10.0
                \\Copyright (C) 1994-2024 Free Software Foundation, Inc.
                \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>
                \\This is free software: you are free to change and redistribute it.
                \\There is NO WARRANTY, to the extent permitted by law.
                \\
                \\Written by Eric B. Decker, James Youngman, and Kevin Dalley.
                \\
                \\
            ;
            return if (cli.writeStdout(ctx.io, v)) 0 else 1;
        } else if (m(u8, opt, "--help")) {
            const t =
                \\Usage: %s [--findoptions='-option1 -option2...']
                \\       [--localpaths='dir1 dir2...'] [--netpaths='dir1 dir2...']
                \\       [--prunepaths='dir1 dir2...'] [--prunefs='fs1 fs2...']
                \\       [--output=dbfile] [--netuser=user] [--localuser=user]
                \\       [--dbformat] [--version] [--help]
                \\
                \\Please see also the documentation at https://www.gnu.org/software/findutils/.
                \\Report (and track progress on fixing) bugs in the updatedb
                \\program via the GNU findutils bug-reporting page at
                \\https://savannah.gnu.org/bugs/?group=findutils or, if
                \\you have no web access, by sending email to <bug-findutils@gnu.org>.
                \\
                \\
            ;
            const out = std.mem.replaceOwned(u8, gpa, t, "%s", ctx.name) catch return 1;
            return if (cli.writeStdout(ctx.io, out)) 0 else 1;
        } else {
            stderrLine(ctx, "updatedb: invalid option {s}\nTry '{s} --help' for more information.\n", .{ opt, ctx.name });
            return 1;
        }
    }
    if (dbformat.len > 0 and !std.mem.eql(u8, dbformat, "LOCATE02")) {
        if (std.mem.eql(u8, dbformat, "slocate")) o.format = .slocate else {
            stderrLine(ctx, "Unsupported locate database format {s}: Supported formats are:\nLOCATE02, slocate\n", .{dbformat});
            return 1;
        }
    }

    const env: updatedb.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    const result = updatedb.run(env, o, .{ .context = @constCast(&ctx), .func = report }) catch return 1;
    return result.status;
}
