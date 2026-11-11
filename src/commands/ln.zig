// SPDX-License-Identifier: GPL-2.0-or-later
//! ln — make links between files.
//! Reference: GNU coreutils manual "ln invocation" (9.7); POSIX.1-2024 ln.
//!
//! Same-file detection compares inode numbers only (std.Io.File.Stat has no
//! device number), so two files on different devices that share an inode
//! number are wrongly taken for one file.

const std = @import("std");
const cli = @import("../cli.zig");
const paths = @import("../paths.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "backup", "directory", "force", "interactive", "logical", "no-dereference", "physical", "relative", "symbolic", "suffix", "target-directory", "no-target-directory", "verbose", "help", "version" };

const Backup = enum { none, simple, numbered, existing };

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
    suffix: []const u8 = "~",
    target_dir: ?[]const u8 = null,
};

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    if (cli.getenv(ctx, "SIMPLE_BACKUP_SUFFIX")) |sfx| cfg.suffix = sfx;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var backup_requested = false;
    var backup_arg: ?[]const u8 = null;

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
                9 => cfg.suffix = value.?,
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
                if (a[j] == 'S') cfg.suffix = value else cfg.target_dir = value;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }
    if (backup_requested) {
        const kind: []const u8 = backup_arg orelse (cli.getenv(ctx, "VERSION_CONTROL") orelse "existing");
        cfg.backup = parseBackup(kind) orelse {
            cli.warn(ctx, "invalid argument {f} for 'backup type'\nValid arguments are:\n  - 'none', 'off'\n  - 'simple', 'never'\n  - 'existing', 'nil'\n  - 'numbered', 't'\nTry '{s} --help' for more information.", .{ cli.quoteC(kind), ctx.name });
            return 1;
        };
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
    const cwd = Io.Dir.cwd();
    var status: u8 = 0;

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
    _ = cwd;

    if (dest_dir) |d| {
        for (sources) |src| {
            const base = baseName(src);
            const dest = if (std.mem.endsWith(u8, d, "/"))
                std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{ d, base }) catch return 1
            else
                std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ d, base }) catch return 1;
            defer ctx.gpa.free(dest);
            if (!doLink(ctx, &cfg, src, dest)) status = 1;
        }
    } else {
        if (!doLink(ctx, &cfg, files.items[0], files.items[1])) status = 1;
    }
    return status;
}

fn parseBackup(s: []const u8) ?Backup {
    const table = [_]struct { []const u8, Backup }{
        .{ "none", .none },     .{ "off", .none },      .{ "numbered", .numbered }, .{ "t", .numbered },
        .{ "existing", .existing }, .{ "nil", .existing }, .{ "simple", .simple },   .{ "never", .simple },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], s)) return e[1];
    // Unambiguous prefixes are accepted too.
    var found: ?Backup = null;
    for (table) |e| if (s.len > 0 and std.mem.startsWith(u8, e[0], s)) {
        if (found != null and found.? != e[1]) return null;
        found = e[1];
    };
    return found;
}

fn baseName(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') end -= 1;
    const s = p[0..end];
    const idx = std.mem.lastIndexOfScalar(u8, s, '/') orelse return s;
    return if (idx + 1 < s.len) s[idx + 1 ..] else s;
}

fn isDir(ctx: cli.Context, path: []const u8, follow: bool) bool {
    const st = Io.Dir.cwd().statFile(ctx.io, path, .{ .follow_symlinks = follow }) catch return false;
    return st.kind == .directory;
}

fn exists(ctx: cli.Context, path: []const u8) ?Io.File.Stat {
    return Io.Dir.cwd().statFile(ctx.io, path, .{ .follow_symlinks = false }) catch null;
}

fn doLink(ctx: cli.Context, cfg: *const Config, src: []const u8, dest: []const u8) bool {
    const cwd = Io.Dir.cwd();
    const kind: []const u8 = if (cfg.symbolic) "symbolic link" else "hard link";

    // Source checks for hard links.
    var src_stat: ?Io.File.Stat = null;
    if (!cfg.symbolic) {
        const st = cwd.statFile(ctx.io, src, .{ .follow_symlinks = cfg.logical }) catch |e| {
            cli.warn(ctx, "failed to access {f}: {s}", .{ cli.quoteA(src), cli.errText(e) });
            return false;
        };
        if (st.kind == .directory) {
            cli.warn(ctx, "{f}: hard link not allowed for directory", .{cli.quote(src)});
            return false;
        }
        src_stat = st;
    }

    var made_backup: ?[]u8 = null;
    defer if (made_backup) |b| ctx.gpa.free(b);
    if (exists(ctx, dest)) |dst| {
        if (!cfg.force and !cfg.interactive and cfg.backup == .none) {
            cli.warn(ctx, "failed to create {s} {f}: File exists", .{ kind, cli.quoteA(dest) });
            return false;
        }
        if (src_stat == null) {
            // Symbolic links: the source need not exist, but if it does, a
            // destination that is the same file is refused.
            src_stat = cwd.statFile(ctx.io, src, .{ .follow_symlinks = cfg.logical }) catch null;
        }
        if (src_stat) |ss| {
            if (ss.inode == dst.inode and cfg.backup == .none) {
                cli.warn(ctx, "{f} and {f} are the same file", .{ cli.quoteA(src), cli.quoteA(dest) });
                return false;
            }
        }
        if (cfg.interactive) {
            var pbuf: [4200]u8 = undefined;
            const prompt = std.fmt.bufPrint(&pbuf, "{s}: replace {f}? ", .{ ctx.name, cli.quoteA(dest) }) catch "";
            Io.File.stderr().writeStreamingAll(ctx.io, prompt) catch {};
            if (!answerYes(ctx)) return false;
        }
        if (cfg.backup != .none) {
            const bname = backupName(ctx, cfg, dest) orelse return false;
            cwd.rename(dest, cwd, bname, ctx.io) catch |e| {
                cli.warn(ctx, "cannot backup {f}: {s}", .{ cli.quoteA(dest), cli.errText(e) });
                ctx.gpa.free(bname);
                return false;
            };
            made_backup = bname;
        } else {
            if (src_stat) |ss| if (ss.inode == dst.inode) {
                cli.warn(ctx, "{f} and {f} are the same file", .{ cli.quoteA(src), cli.quoteA(dest) });
                return false;
            };
            cwd.deleteFile(ctx.io, dest) catch |e| {
                cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(dest), cli.errText(e) });
                return false;
            };
        }
    }

    if (cfg.symbolic) {
        var target: []const u8 = src;
        var rel: ?[]u8 = null;
        defer if (rel) |r| ctx.gpa.free(r);
        if (cfg.relative) {
            rel = relativeSymlinkTarget(ctx, src, dest);
            if (rel) |r| target = r;
        }
        cwd.symLink(ctx.io, target, dest, .{}) catch |e| {
            cli.warn(ctx, "failed to create {s} {f}: {s}", .{ kind, cli.quoteA(dest), cli.errText(e) });
            return false;
        };
        if (cfg.verbose) verbose(ctx, dest, target, "->", made_backup);
    } else {
        cwd.hardLink(src, cwd, dest, ctx.io, .{ .follow_symlinks = cfg.logical }) catch |e| {
            cli.warn(ctx, "failed to create {s} {f} => {f}: {s}", .{ kind, cli.quoteA(dest), cli.quoteA(src), cli.errText(e) });
            return false;
        };
        if (cfg.verbose) verbose(ctx, dest, src, "=>", made_backup);
    }
    return true;
}

fn verbose(ctx: cli.Context, dest: []const u8, src: []const u8, arrow: []const u8, backup: ?[]const u8) void {
    var buf: [8192]u8 = undefined;
    const line = if (backup) |b|
        std.fmt.bufPrint(&buf, "{f} ~ {f} {s} {f}\n", .{ cli.quoteA(b), cli.quoteA(dest), arrow, cli.quoteA(src) }) catch return
    else
        std.fmt.bufPrint(&buf, "{f} {s} {f}\n", .{ cli.quoteA(dest), arrow, cli.quoteA(src) }) catch return;
    _ = cli.writeStdout(ctx.io, line);
}

fn answerYes(ctx: cli.Context) bool {
    var b: [128]u8 = undefined;
    const n = cli.readChunk(ctx.io, Io.File.stdin(), &b) catch return false;
    return n > 0 and (b[0] == 'y' or b[0] == 'Y');
}

fn backupName(ctx: cli.Context, cfg: *const Config, dest: []const u8) ?[]u8 {
    var kind = cfg.backup;
    if (kind == .existing) {
        // Numbered when a numbered backup of this file already exists.
        var n: usize = 1;
        kind = .simple;
        while (n < 10) : (n += 1) {
            const cand = std.fmt.allocPrint(ctx.gpa, "{s}.~{d}~", .{ dest, n }) catch return null;
            defer ctx.gpa.free(cand);
            if (exists(ctx, cand) != null) {
                kind = .numbered;
                break;
            }
        }
    }
    if (kind == .simple) return std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{ dest, cfg.suffix }) catch null;
    var n: usize = 1;
    while (true) : (n += 1) {
        const cand = std.fmt.allocPrint(ctx.gpa, "{s}.~{d}~", .{ dest, n }) catch return null;
        if (exists(ctx, cand) == null) return cand;
        ctx.gpa.free(cand);
    }
}

/// Target of a relative symlink named `dest` pointing at `src`.
fn relativeSymlinkTarget(ctx: cli.Context, src: []const u8, dest: []const u8) ?[]u8 {
    const src_abs = paths.resolve(ctx, src, .missing) catch return null;
    defer ctx.gpa.free(src_abs);
    const dest_dir_part = if (std.mem.lastIndexOfScalar(u8, dest, '/')) |i| (if (i == 0) "/" else dest[0..i]) else ".";
    const dir_abs = paths.resolve(ctx, dest_dir_part, .missing) catch return null;
    defer ctx.gpa.free(dir_abs);
    return paths.relativeTo(ctx.gpa, src_abs, dir_abs) catch null;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: ln [OPTION]... [-T] TARGET LINK_NAME\n  or:  ln [OPTION]... TARGET\n  or:  ln [OPTION]... TARGET... DIRECTORY\n  or:  ln [OPTION]... -t DIRECTORY TARGET...\nIn the 1st form, create a link to TARGET with the name LINK_NAME.\nIn the 2nd form, create a link to TARGET in the current directory.\nIn the 3rd and 4th forms, create links to each TARGET in DIRECTORY.\nCreate hard links by default, symbolic links with --symbolic.\n\n  -b                          like --backup but does not accept an argument\n      --backup[=CONTROL]      make a backup of each existing destination file\n  -d, -F, --directory         allow the superuser to attempt to hard link\n                                directories (note: will probably fail due to\n                                system restrictions, even for the superuser)\n  -f, --force                 remove existing destination files\n  -i, --interactive           prompt whether to remove destinations\n  -L, --logical               dereference TARGETs that are symbolic links\n  -n, --no-dereference        treat LINK_NAME as a normal file if\n                                it is a symbolic link to a directory\n  -P, --physical              make hard links directly to symbolic links\n  -r, --relative              with -s, create links relative to link location\n  -s, --symbolic              make symbolic links instead of hard links\n  -S, --suffix=SUFFIX         override the usual backup suffix\n  -t, --target-directory=DIRECTORY  specify the DIRECTORY in which to create\n                                the links\n  -T, --no-target-directory   treat LINK_NAME as a normal file always\n  -v, --verbose               print name of each linked file\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
