// SPDX-License-Identifier: GPL-2.0-or-later
//! ln: thin wrapper over `util_core.ln` (decision 0004). Parses arguments the
//! way GNU ln does, decides what the destination is, asks the -i question and
//! words the diagnostics; links are made by src/lib/ln.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const ln = @import("../lib/ln.zig");
const sys = @import("../sys.zig");
const backup_args = @import("../backup_args.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "backup", "directory", "force", "interactive", "logical", "no-dereference", "physical", "relative", "symbolic", "suffix", "target-directory", "no-target-directory", "verbose", "help", "version" };

const Backup = ln.Backup;

const Config = struct {
    symbolic: bool = false,
    force: bool = false,
    interactive: bool = false,
    logical: bool = false, // -L: hard links follow a symlink source
    no_deref: bool = false,
    relative: bool = false,
    verbose: bool = false,
    no_target_dir: bool = false,
    backup: Backup = .none,
    target_dir: ?[]const u8 = null,
};

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var backup_requested = false;
    var backup_arg: ?[]const u8 = null;
    var suffix_arg: ?[]const u8 = null;

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
            const needs = k == 9 or k == 10;
            if (needs and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                    return 1;
                }
                value = ctx.args[i];
            } else if (!needs and k != 0 and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => {
                    backup_requested = true;
                    backup_arg = value;
                },
                1 => {},
                2 => cfg.force = true,
                3 => cfg.interactive = true,
                4 => cfg.logical = true,
                5 => cfg.no_deref = true,
                6 => cfg.logical = false,
                7 => cfg.relative = true,
                8 => cfg.symbolic = true,
                9 => {
                    // As GNU: giving a suffix asks for backups.
                    backup_requested = true;
                    suffix_arg = value;
                },
                10 => cfg.target_dir = value,
                11 => cfg.no_target_dir = true,
                12 => cfg.verbose = true,
                13 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'b' => backup_requested = true,
            'd', 'F' => {},
            'f' => cfg.force = true,
            'i' => cfg.interactive = true,
            'L' => cfg.logical = true,
            'n' => cfg.no_deref = true,
            'P' => cfg.logical = false,
            'r' => cfg.relative = true,
            's' => cfg.symbolic = true,
            'T' => cfg.no_target_dir = true,
            'v' => cfg.verbose = true,
            'S', 't' => {
                var value: []const u8 = a[j + 1 ..];
                if (value.len == 0) {
                    i += 1;
                    if (i >= ctx.args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    value = ctx.args[i];
                }
                if (a[j] == 'S') {
                    backup_requested = true;
                    suffix_arg = value;
                } else cfg.target_dir = value;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }
    if (backup_requested) {
        cfg.backup = backup_args.parseVersion(ctx, "backup type", backup_arg) orelse return 1;
    }
    if (cfg.relative and !cfg.symbolic) {
        cli.warn(ctx, "cannot do --relative without --symbolic", .{});
        return 1;
    }
    if (cfg.target_dir != null and cfg.no_target_dir) {
        cli.warn(ctx, "cannot combine --target-directory and --no-target-directory", .{});
        return 1;
    }
    const n = files.items.len;
    if (n == 0) {
        cli.warn(ctx, "missing file operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var dest_dir: ?[]const u8 = null;
    var sources: []const []const u8 = files.items;
    if (cfg.target_dir) |d| {
        if (!isDir(ctx, d, true)) {
            if (Io.Dir.cwd().statFile(ctx.io, d, .{})) |_| {
                cli.warn(ctx, "target {f} is not a directory", .{cli.quoteA(d)});
            } else |e| cli.warn(ctx, "failed to access {f}: {s}", .{ cli.quoteA(d), cli.errText(e) });
            return 1;
        }
        dest_dir = d;
    } else if (cfg.no_target_dir) {
        if (n == 1) {
            cli.warn(ctx, "missing destination file operand after {f}\nTry '{s} --help' for more information.", .{ cli.quoteA(files.items[0]), ctx.name });
            return 1;
        }
        if (n > 2) {
            cli.warn(ctx, "extra operand {f}\nTry '{s} --help' for more information.", .{ cli.quoteA(files.items[2]), ctx.name });
            return 1;
        }
    } else if (n == 1) {
        dest_dir = ".";
    } else {
        const last = files.items[n - 1];
        if (isDir(ctx, last, !cfg.no_deref)) {
            dest_dir = last;
            sources = files.items[0 .. n - 1];
        } else if (n > 2) {
            if (Io.Dir.cwd().statFile(ctx.io, last, .{})) |_| {
                cli.warn(ctx, "target {f} is not a directory", .{cli.quoteA(last)});
            } else |e| cli.warn(ctx, "target {f}: {s}", .{ cli.quoteA(last), cli.errText(e) });
            return 1;
        }
    }

    const env: ln.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const options: ln.Options = .{
        .symbolic = cfg.symbolic,
        .force = cfg.force,
        .interactive = cfg.interactive,
        .logical = cfg.logical,
        .relative = cfg.relative,
        .verbose = cfg.verbose,
        .backup = cfg.backup,
        .suffix = backup_args.simpleSuffix(ctx, suffix_arg),
    };
    const target: ln.Target = if (dest_dir) |d| .{ .dir = d } else .{ .name = files.items[1] };
    const srcs: []const []const u8 = if (dest_dir != null) sources else files.items[0..1];
    const ok = ln.run(env, options, srcs, target, .{ .context = @constCast(&ctx), .func = report }, .{ .context = @constCast(&ctx), .func = confirm }) catch return 1;
    return if (ok) 0 else 1;
}

/// Word one library event the way GNU ln does.
fn report(context: ?*anyopaque, ev: ln.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .linked => |l| {
            var buf: [8192]u8 = undefined;
            const arrow: []const u8 = if (l.symbolic) "->" else "=>";
            const line = if (l.backup) |b|
                std.fmt.bufPrint(&buf, "{f} ~ {f} {s} {f}\n", .{ cli.quoteA(b), cli.quoteA(l.dest), arrow, cli.quoteA(l.src) }) catch return
            else
                std.fmt.bufPrint(&buf, "{f} {s} {f}\n", .{ cli.quoteA(l.dest), arrow, cli.quoteA(l.src) }) catch return;
            _ = cli.writeStdout(ctx.io, line);
        },
        .cannot_access => |f| cli.warn(ctx.*, "failed to access {f}: {s}", .{ cli.quoteA(f.path), cli.errText(f.err) }),
        .directory_source => |p| cli.warn(ctx.*, "{f}: hard link not allowed for directory", .{cli.quote(p)}),
        .exists => |f| cli.warn(ctx.*, "failed to create {s} {f}: File exists", .{ kindName(f.symbolic), cli.quoteA(f.dest) }),
        .same_file => |f| cli.warn(ctx.*, "{f} and {f} are the same file", .{ cli.quoteA(f.src), cli.quoteA(f.dest) }),
        .backup_failed => |f| cli.warn(ctx.*, "cannot backup {f}: {s}", .{ cli.quoteA(f.dest), sys.errnoText(f.errno) }),
        .remove_failed => |f| cli.warn(ctx.*, "cannot remove {f}: {s}", .{ cli.quoteA(f.dest), cli.errText(f.err) }),
        // GNU names the target of a symbolic link only when it can be at fault.
        .link_failed => |f| if (f.symbolic and (f.errno == .NAMETOOLONG or f.src.len == 0))
            cli.warn(ctx.*, "failed to create {s} {f} -> {f}: {s}", .{ kindName(true), cli.quoteA(f.dest), cli.quoteA(f.src), sys.errnoText(f.errno) })
        else if (f.symbolic)
            cli.warn(ctx.*, "failed to create {s} {f}: {s}", .{ kindName(true), cli.quoteA(f.dest), sys.errnoText(f.errno) })
        else
            cli.warn(ctx.*, "failed to create {s} {f} => {f}: {s}", .{ kindName(false), cli.quoteA(f.dest), cli.quoteA(f.src), sys.errnoText(f.errno) }),
        .unbackup_failed => |f| cli.warn(ctx.*, "cannot un-backup {f}: {s}", .{ cli.quoteA(f.dest), sys.errnoText(f.errno) }),
    }
}

fn kindName(symbolic: bool) []const u8 {
    return if (symbolic) "symbolic link" else "hard link";
}

/// The -i question: "ln: replace 'dest'? " on stderr, a line of stdin as the answer.
fn confirm(context: ?*anyopaque, dest: []const u8) bool {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.writeStderrNoNl(ctx.*, "{s}: replace {f}? ", .{ ctx.name, cli.quoteA(dest) });
    return cli.readYes(ctx.io, Io.File.stdin());
}

fn isDir(ctx: cli.Context, path: []const u8, follow: bool) bool {
    const st = Io.Dir.cwd().statFile(ctx.io, path, .{ .follow_symlinks = follow }) catch return false;
    return st.kind == .directory;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: ln [OPTION]... [-T] TARGET LINK_NAME\n  or:  ln [OPTION]... TARGET\n  or:  ln [OPTION]... TARGET... DIRECTORY\n  or:  ln [OPTION]... -t DIRECTORY TARGET...\nIn the 1st form, create a link to TARGET with the name LINK_NAME.\nIn the 2nd form, create a link to TARGET in the current directory.\nIn the 3rd and 4th forms, create links to each TARGET in DIRECTORY.\nCreate hard links by default, symbolic links with --symbolic.\n\n  -b                          like --backup but does not accept an argument\n      --backup[=CONTROL]      make a backup of each existing destination file\n  -d, -F, --directory         allow the superuser to attempt to hard link\n                                directories (note: will probably fail due to\n                                system restrictions, even for the superuser)\n  -f, --force                 remove existing destination files\n  -i, --interactive           prompt whether to remove destinations\n  -L, --logical               dereference TARGETs that are symbolic links\n  -n, --no-dereference        treat LINK_NAME as a normal file if\n                                it is a symbolic link to a directory\n  -P, --physical              make hard links directly to symbolic links\n  -r, --relative              with -s, create links relative to link location\n  -s, --symbolic              make symbolic links instead of hard links\n  -S, --suffix=SUFFIX         override the usual backup suffix\n  -t, --target-directory=DIRECTORY  specify the DIRECTORY in which to create\n                                the links\n  -T, --no-target-directory   treat LINK_NAME as a normal file always\n  -v, --verbose               print name of each linked file\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
