// SPDX-License-Identifier: GPL-2.0-or-later
//! rm: thin wrapper over `util_core.rm` (decision 0004). Parses arguments the
//! way GNU rm does, asks the questions and words the diagnostics; the removal
//! walk is in src/lib/rm.zig.
//!
//! Deviations: --preserve-root=all is treated as plain --preserve-root.

const std = @import("std");
const cli = @import("../cli.zig");
const rm = @import("../lib/rm.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "force", "interactive", "one-file-system", "no-preserve-root", "preserve-root", "recursive", "dir", "verbose", "help", "version" };

const Interactive = rm.Interactive;
const Config = rm.Options;

const State = struct {
    ctx: cli.Context,
    out: *cli.Out,
};

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
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
            const value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (value != null and k != 1 and k != 4) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => {
                    cfg.force = true;
                    cfg.interactive = .never;
                },
                1 => {
                    const w = value orelse "always";
                    if (matchWord(w, &.{ "never", "no", "none" })) {
                        cfg.interactive = .never;
                    } else if (matchWord(w, &.{"once"})) {
                        cfg.interactive = .once;
                    } else if (matchWord(w, &.{ "always", "yes" })) {
                        cfg.interactive = .always;
                    } else {
                        cli.warn(ctx, "invalid argument {f} for '--interactive'\nValid arguments are:\n  - 'never', 'no', 'none'\n  - 'once'\n  - 'always', 'yes'\nTry '{s} --help' for more information.", .{ cli.quoteC(w), ctx.name });
                        return 1;
                    }
                    cfg.force = false;
                },
                2 => cfg.one_file_system = true,
                3 => cfg.preserve_root = false,
                4 => {
                    if (value) |v| {
                        if (!std.mem.eql(u8, v, "all")) {
                            cli.warn(ctx, "unrecognized --preserve-root argument: {f}", .{cli.quoteC(v)});
                            return 1;
                        }
                    }
                    cfg.preserve_root = true;
                },
                5 => cfg.recursive = true,
                6 => cfg.dirs = true,
                7 => cfg.verbose = true,
                8 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..], 0..) |c, ci| switch (c) {
            'f' => {
                cfg.force = true;
                cfg.interactive = .never;
            },
            'i' => {
                cfg.force = false;
                cfg.interactive = .always;
            },
            'I' => {
                cfg.force = false;
                cfg.interactive = .once;
            },
            'r', 'R' => cfg.recursive = true,
            'd' => cfg.dirs = true,
            'v' => cfg.verbose = true,
            else => {
                if (ci == 0 and Io.Dir.cwd().statFile(ctx.io, a, .{ .follow_symlinks = false }) != error.FileNotFound) {
                    // GNU: an argument like "-a" that exists as a file is probably a file name.
                    cli.warn(ctx, "invalid option -- '{c}'\nTry '{s} ./{s}' to remove the file {f}.\nTry '{s} --help' for more information.", .{ c, ctx.name, a, cli.quoteA(a), ctx.name });
                } else cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (files.items.len == 0) {
        if (cfg.force) return 0;
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    cfg.stdin_tty = Io.File.stdin().isTty(ctx.io) catch false;

    var out = cli.Out.init(ctx.io);
    var st: State = .{ .ctx = ctx, .out = &out };

    // -I: a single prompt for more than three files or for recursion.
    if (cfg.interactive == .once and (files.items.len > 3 or cfg.recursive)) {
        var buf: [128]u8 = undefined;
        const n = files.items.len;
        const msg = std.fmt.bufPrint(&buf, "remove {d} {s}{s}? ", .{ n, if (n == 1) "argument" else "arguments", if (cfg.recursive) " recursively" else "" }) catch "";
        if (!ask(ctx, msg)) return 0;
    }

    const env: rm.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const ok = rm.run(env, cfg, files.items, .{ .context = &st, .func = report }, .{ .context = &st, .func = confirm });
    out.flush();
    if (out.failed) return 1;
    return if (ok) 0 else 1;
}

/// Word one library event the way GNU rm does.
fn report(context: ?*anyopaque, ev: rm.Event) void {
    const st: *State = @ptrCast(@alignCast(context.?));
    const ctx = st.ctx;
    switch (ev) {
        .removed => |r| st.out.print("{s} {f}\n", .{ if (r.dir) "removed directory" else "removed", cli.quoteA(r.path) }),
        .failed => |f| cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(f.path), sys.errnoText(f.errno) }),
        .unreadable => |u| cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(u.path), sys.errnoText(u.errno) }),
        .refuse_dot => |p| cli.warn(ctx, "refusing to remove '.' or '..' directory: skipping {f}", .{cli.quoteA(p)}),
        .refuse_root => |r| {
            cli.warn(ctx, "it is dangerous to operate recursively on {f}{s}", .{ cli.quoteA(r.path), if (r.literal) "" else " (same as '/')" });
            cli.warn(ctx, "use --no-preserve-root to override this failsafe", .{});
        },
        .other_device => |p| cli.warn(ctx, "skipping {f}, since it's on a different device", .{cli.quoteA(p)}),
    }
}

/// Ask the question GNU rm would ask for this removal.
fn confirm(context: ?*anyopaque, p: rm.Prompt) bool {
    const st: *State = @ptrCast(@alignCast(context.?));
    var buf: [4400]u8 = undefined;
    const q = switch (p.action) {
        .descend => std.fmt.bufPrint(&buf, "descend into directory {f}? ", .{cli.quoteA(p.path)}) catch return false,
        .remove => std.fmt.bufPrint(&buf, "remove {s}{s} {f}? ", .{ if (p.write_protected) "write-protected " else "", kindWords(p.kind, p.size), cli.quoteA(p.path) }) catch return false,
    };
    return ask(st.ctx, q);
}

fn matchWord(w: []const u8, options: []const []const u8) bool {
    if (w.len == 0) return false;
    for (options) |o| if (std.mem.startsWith(u8, o, w)) return true;
    return false;
}

/// Print `ctx.name: text` to stderr (no newline) and read a y/n answer.
fn ask(ctx: cli.Context, text: []const u8) bool {
    var buf: [4400]u8 = undefined;
    const prompt = std.fmt.bufPrint(&buf, "{s}: {s}", .{ ctx.name, text }) catch return false;
    Io.File.stderr().writeStreamingAll(ctx.io, prompt) catch {};
    var line: [256]u8 = undefined;
    var n: usize = 0;
    // Read one line byte by byte so nothing past it is consumed.
    while (n < line.len) {
        var b: [1]u8 = undefined;
        const got = cli.readChunk(ctx.io, Io.File.stdin(), &b) catch 0;
        if (got == 0) break;
        if (b[0] == '\n') break;
        line[n] = b[0];
        n += 1;
    }
    if (n == 0) return false;
    return line[0] == 'y' or line[0] == 'Y';
}

fn kindWords(kind: Io.File.Kind, size: u64) []const u8 {
    return switch (kind) {
        .file => if (size == 0) "regular empty file" else "regular file",
        .directory => "directory",
        .sym_link => "symbolic link",
        .named_pipe => "fifo",
        .unix_domain_socket => "socket",
        .block_device => "block special file",
        .character_device => "character special file",
        else => "file",
    };
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: rm [OPTION]... [FILE]...\nRemove (unlink) the FILE(s).\n\n  -f, --force           ignore nonexistent files and arguments, never prompt\n  -i                    prompt before every removal\n  -I                    prompt once before removing more than three files, or\n                          when removing recursively; less intrusive than -i,\n                          while still giving protection against most mistakes\n      --interactive[=WHEN]  prompt according to WHEN: never, once (-I), or\n                          always (-i); without WHEN, prompt always\n      --one-file-system  when removing a hierarchy recursively, skip any\n                          directory that is on a file system different from\n                          that of the corresponding command line argument\n      --no-preserve-root  do not treat '/' specially\n      --preserve-root[=all]  do not remove '/' (default);\n                              with 'all', reject any command line argument\n                              on a separate device from its parent\n  -r, -R, --recursive   remove directories and their contents recursively\n  -d, --dir             remove empty directories\n  -v, --verbose         explain what is being done\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
