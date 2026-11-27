// SPDX-License-Identifier: GPL-2.0-or-later
//! tree: thin wrapper over `util_core.tree` (decision 0004). Parses the
//! options as tree 2.3.1 does and words its option diagnostics; the listing,
//! sorting, filtering and the XML/JSON forms are in src/lib/tree.zig.

const std = @import("std");
const numparse = @import("../numparse.zig");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const tree = @import("../lib/tree.zig");
const LX = std.os.linux;
const Io = std.Io;

/// These commands have always used the general-purpose allocator without
/// leak checking (their results live until exit).

const help_text = @embedFile("../help/tree.txt");

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 2;
}

/// Whether to colour, as GNU decides it: never without $TERM. -C always does;
/// else -n and $NO_COLOR forbid it, and it takes a terminal (or
/// $CLICOLOR_FORCE) and a table, which $CLICOLOR also provides.
fn wantColor(ctx: cli.Context, forced: bool, forbidden: bool) bool {
    if (cli.getenv(ctx, "TERM") == null) return false;
    if (forced) return true;
    if (forbidden) return false;
    if (cli.getenv(ctx, "NO_COLOR")) |v| if (v.len > 0) return false;
    const clicolor_force = cli.getenv(ctx, "CLICOLOR_FORCE") != null;
    if (!clicolor_force and !(Io.File.stdout().isTty(ctx.io) catch false)) return false;
    const env: tree.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    return clicolor_force or cli.getenv(ctx, "CLICOLOR") != null or tree.colorSpec(env) != null;
}

pub fn main(ctx: cli.Context) u8 {
    const env: tree.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    var o: tree.Options = .{};
    var patterns: std.ArrayList([]const u8) = .empty;
    defer patterns.deinit(ctx.gpa);
    var ignores: std.ArrayList([]const u8) = .empty;
    defer ignores.deinit(ctx.gpa);
    var out_file: ?[]const u8 = null;
    var charset: ?[]const u8 = null;
    o.utf8_locale = tree.localeIsUtf8(env);
    var p = getopt.Parser.init(ctx, "acdfghilnpqrstuvxADFI:L:NP:QSUXCJHT:o:R", &.{
        .{ .name = "version", .id = 2000 },
        .{ .name = "help", .id = 2001 },
        .{ .name = "inodes", .id = 2002 },
        .{ .name = "device", .id = 2003 },
        .{ .name = "noreport", .id = 2004 },
        .{ .name = "nolinks", .id = 2005 },
        .{ .name = "dirsfirst", .id = 2006 },
        .{ .name = "filesfirst", .id = 2007 },
        .{ .name = "matchdirs", .id = 2008 },
        .{ .name = "metafirst", .id = 2009 },
        .{ .name = "prune", .id = 2010 },
        .{ .name = "si", .id = 2011 },
        .{ .name = "du", .id = 2012 },
        .{ .name = "ignore-case", .id = 2013 },
        .{ .name = "charset", .arg = .required, .id = 2014 },
        .{ .name = "filelimit", .arg = .required, .id = 2015 },
        .{ .name = "timefmt", .arg = .required, .id = 2016 },
        .{ .name = "sort", .arg = .required, .id = 2017 },
        .{ .name = "opt-toggle", .id = 2018 },
        .{ .name = "fromfile", .id = 2019 },
        .{ .name = "fromtabfile", .id = 2020 },
        .{ .name = "gitignore", .id = 2021 },
        .{ .name = "info", .id = 2022 },
        .{ .name = "hyperlink", .id = 2023 },
        .{ .name = "fflinks", .id = 2024 },
        .{ .name = "acl", .id = 2025 },
        .{ .name = "selinux", .id = 2026 },
        .{ .name = "condense", .id = 2027 },
        .{ .name = "compress", .arg = .required, .id = 2028 },
        .{ .name = "gitfile", .arg = .required, .id = 2029 },
        .{ .name = "infofile", .arg = .required, .id = 2030 },
        .{ .name = "hintro", .arg = .required, .id = 2031 },
        .{ .name = "houtro", .arg = .required, .id = 2032 },
        .{ .name = "scheme", .arg = .required, .id = 2033 },
        .{ .name = "authority", .arg = .required, .id = 2034 },
    });
    defer p.deinit();
    p.silent = true;
    var no_color = false;
    var color_forced = false;
    while (true) switch (p.next()) {
        .done => break,
        .bad => {
            const d = p.last_diag;
            if (std.mem.startsWith(u8, d, "invalid option -- '")) {
                cli.warn(ctx, "Invalid argument -`{c}'.", .{d[d.len - 2]});
            } else if (std.mem.startsWith(u8, d, "unrecognized option '")) {
                cli.warn(ctx, "Invalid argument `{s}'.", .{d[21 .. d.len - 1]});
            } else if (std.mem.startsWith(u8, d, "option requires an argument -- '")) {
                const ch = d[d.len - 2];
                if (ch == 'L' or ch == 'P' or ch == 'I' or ch == 'o' or ch == 'T') cli.warn(ctx, "Missing argument to -{c} option.", .{ch}) else cli.warn(ctx, "Invalid argument -`{c}'.", .{ch});
            } else if (std.mem.indexOf(u8, d, "requires an argument") != null) {
                const nm = if (std.mem.indexOfScalar(u8, d, '\'')) |k| d[k + 1 ..] else d;
                const e2 = std.mem.indexOfScalar(u8, nm, '\'') orelse nm.len;
                cli.warn(ctx, "Missing argument to {s}", .{nm[0..e2]});
            } else cli.warn(ctx, "Invalid argument `{s}'.", .{d});
            return usageErr();
        },
        .opt => |opt| switch (opt.id) {
            'a' => o.all = true,
            'd' => o.dirs_only = true,
            'l' => o.follow = true,
            'f' => o.full_path = true,
            'x' => o.xdev = true,
            'L' => {
                const v = numparse.parseInt(i64, opt.arg.?, 10) catch {
                    cli.warn(ctx, "Invalid level, must be greater than 0.", .{});
                    return 1;
                };
                if (v < 1) {
                    cli.warn(ctx, "Invalid level, must be greater than 0.", .{});
                    return 1;
                }
                o.max_level = v;
            },
            'P' => patterns.append(ctx.gpa, opt.arg.?) catch return oom(ctx),
            'I' => ignores.append(ctx.gpa, opt.arg.?) catch return oom(ctx),
            'o' => out_file = opt.arg.?,
            'q' => o.q = true,
            'N' => o.raw = true,
            'Q' => o.quote = true,
            'p' => o.perms = true,
            'u' => o.user = true,
            'g' => o.group = true,
            's' => o.size = true,
            'h' => {
                o.human = true;
                o.size = true;
            },
            'D' => o.date = true,
            'F' => o.classify = true,
            'v' => o.sort = .version,
            't' => o.sort = .mtime,
            'c' => o.sort = .ctime,
            'U' => o.sort = .none,
            'r' => o.reverse = true,
            'i' => o.no_indent = true,
            'A' => o.ansi = true,
            'S' => o.cp437 = true,
            'n' => no_color = true,
            'C' => color_forced = true,
            'X' => o.mode = .xml,
            'J' => o.mode = .json,
            'T', 'H', 'R' => {},
            2000 => {
                const v = if (o.utf8_locale) "tree v2.3.1 \u{a9} 1996 - 2026 by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser, Kyosuke Tokoro\n" else "tree v2.3.1 (c) 1996 - 2026 by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser, Kyosuke Tokoro\n";
                return if (cli.writeStdout(ctx.io, v)) 0 else 1;
            },
            2001 => {
                if (o.utf8_locale) {
                    const h = std.mem.replaceOwned(u8, ctx.gpa, help_text, "(c)", "\u{a9}") catch return 1;
                    defer ctx.gpa.free(h);
                    return if (cli.writeStdout(ctx.io, h)) 0 else 1;
                }
                return if (cli.writeStdout(ctx.io, help_text)) 0 else 1;
            },
            2002 => o.inodes = true,
            2003 => o.device = true,
            2004 => o.noreport = true,
            2006 => o.dirsfirst = true,
            2007 => o.filesfirst = true,
            2008 => o.matchdirs = true,
            2010 => o.prune = true,
            2011 => {
                o.si = true;
                o.human = true;
                o.size = true;
            },
            2012 => {
                o.du = true;
                o.size = true;
            },
            2013 => o.icase = true,
            2014 => charset = opt.arg.?,
            2015 => o.filelimit = numparse.parseInt(i64, opt.arg.?, 10) catch -1,
            2016 => {
                o.timefmt = opt.arg.?;
                o.date = true;
            },
            2017 => {
                const a = opt.arg.?;
                if (std.mem.eql(u8, a, "name")) o.sort = .name else if (std.mem.eql(u8, a, "version")) o.sort = .version else if (std.mem.eql(u8, a, "size")) o.sort = .size else if (std.mem.eql(u8, a, "mtime")) o.sort = .mtime else if (std.mem.eql(u8, a, "ctime")) o.sort = .ctime else if (std.mem.eql(u8, a, "none")) o.sort = .none else {
                    cli.writeStderrNoNl(ctx, "tree: Sort type '{s}' not valid, should be one of: ", .{a});
                    _ = cli.writeStdout(ctx.io, "name,version,size,mtime,ctime,none\n");
                    return 1;
                }
            },
            else => {},
        },
    };
    o.use_utf8_lines = o.utf8_locale;
    if (charset) |cs| {
        o.use_utf8_lines = std.ascii.eqlIgnoreCase(cs, "utf-8") or std.ascii.eqlIgnoreCase(cs, "utf8");
        o.entity_lines = !o.use_utf8_lines and !std.ascii.eqlIgnoreCase(cs, "ascii") and !std.ascii.eqlIgnoreCase(cs, "us-ascii");
    }
    o.color = wantColor(ctx, color_forced, no_color);
    o.patterns = patterns.items;
    o.ignores = ignores.items;

    var out_file_handle: ?Io.File = null;
    if (out_file) |f| {
        var err: LX.E = .SUCCESS;
        const fd = sys.openFd(f, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, 0o666, &err) orelse {
            cli.warn(ctx, "invalid filename '{s}'", .{f});
            return 1;
        };
        out_file_handle = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    }
    defer if (out_file_handle) |fh| fh.close(ctx.io);

    var buf: [8192]u8 = undefined;
    var w = (out_file_handle orelse Io.File.stdout()).writerStreaming(ctx.io, &buf);
    // tree itself ignores a failed write; a report that was cut off is not a
    // success here.
    const result = tree.run(env, o, p.operands.items, &w.interface, .{}) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => return writeFailed(ctx, w.err),
    };
    w.interface.flush() catch return writeFailed(ctx, w.err);
    return result.exit_status;
}

fn writeFailed(ctx: cli.Context, err: ?Io.File.Writer.Error) u8 {
    // A reader that has gone has seen all it wanted.
    if (err) |e| if (e == error.BrokenPipe) return 0;
    cli.warn(ctx, "write error: {s}", .{cli.errText(err orelse error.WriteFailed)});
    return 1;
}

fn usageErr() u8 {
    const cut = std.mem.indexOf(u8, help_text, "  ------- Listing options") orelse help_text.len;
    _ = sys.writeAllFd(std.Io.File.stderr().handle, help_text[0..cut]);
    return 1;
}
