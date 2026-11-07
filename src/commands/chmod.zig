//! chmod — change file mode bits.
//! References: GNU coreutils manual "chmod invocation" (9.7); POSIX.1-2024
//! chmod. Mode text is parsed by src/mode.zig.
//!
//! GNU details kept: symbolic modes without a `who` honour the umask; octal
//! modes of fewer than five digits leave the set-user-ID and set-group-ID
//! bits of a directory alone; symbolic links met during -R are skipped.

const std = @import("std");
const cli = @import("../cli.zig");
const mode_mod = @import("../mode.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "changes", "silent", "quiet", "verbose", "dereference", "no-dereference", "no-preserve-root", "preserve-root", "reference", "recursive", "help", "version" };

const Config = struct {
    changes: bool = false,
    quiet: bool = false,
    verbose: bool = false,
    recursive: bool = false,
    preserve_root: bool = false,
    deref_args: bool = true, // -H default; -P clears; -L sets traverse_all
    traverse_all: bool = false,
    no_deref: bool = false, // -h
    umask: u16 = 0,
    mode_text: []const u8 = "",
    reference_mode: ?u16 = null,
};

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    var ref_file: ?[]const u8 = null;
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return 1;
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
            if (k == 8 and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--reference' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                    return 1;
                }
                value = ctx.args[i];
            } else if (k != 8 and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => {
                    cfg.changes = true;
                    cfg.verbose = false;
                },
                1, 2 => cfg.quiet = true,
                3 => {
                    cfg.verbose = true;
                    cfg.changes = false;
                },
                4 => cfg.no_deref = false,
                5 => cfg.no_deref = true,
                6 => cfg.preserve_root = false,
                7 => cfg.preserve_root = true,
                8 => ref_file = value,
                9 => cfg.recursive = true,
                10 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        // Short options; a letter that can only be part of a mode ("-w",
        // "-x", "-rwx") ends option parsing and is the MODE operand.
        var as_mode = false;
        for (a[1..]) |c| switch (c) {
            'c' => {
                cfg.changes = true;
                cfg.verbose = false;
            },
            'f' => cfg.quiet = true,
            'v' => {
                cfg.verbose = true;
                cfg.changes = false;
            },
            'h' => cfg.no_deref = true,
            'R' => cfg.recursive = true,
            'H' => {
                cfg.deref_args = true;
                cfg.traverse_all = false;
            },
            'L' => {
                cfg.deref_args = true;
                cfg.traverse_all = true;
            },
            'P' => {
                cfg.deref_args = false;
                cfg.traverse_all = false;
            },
            'r', 'w', 'x', 'X', 's', 't', 'u', 'g', 'o', 'a' => as_mode = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
        if (as_mode) operands.append(ctx.gpa, a) catch return 1;
    }

    if (ref_file == null) {
        if (operands.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
            return 1;
        }
        cfg.mode_text = operands.orderedRemove(0);
        if (operands.items.len == 0) {
            cli.warn(ctx, "missing operand after {f}\nTry '{s} --help' for more information.", .{ cli.quoteA(cfg.mode_text), ctx.name });
            return 1;
        }
        // Validate the mode text once, against an arbitrary old mode.
        if (mode_mod.apply(cfg.mode_text, 0o644, false, 0) == null) {
            cli.warn(ctx, "invalid mode: {f}\nTry '{s} --help' for more information.", .{ cli.quoteA(cfg.mode_text), ctx.name });
            return 1;
        }
    } else {
        if (operands.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
            return 1;
        }
        const st = Io.Dir.cwd().statFile(ctx.io, ref_file.?, .{}) catch |e| {
            cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteA(ref_file.?), cli.errText(e) });
            return 1;
        };
        cfg.reference_mode = @intCast(st.permissions.toMode() & 0o7777);
    }
    cfg.umask = sys.umask();

    var status: u8 = 0;
    for (operands.items) |f| {
        if (cfg.recursive and cfg.preserve_root and isRoot(ctx, f)) {
            const literal = std.mem.indexOfNone(u8, f, "/") == null;
            cli.warn(ctx, "it is dangerous to operate recursively on {f}{s}\nchmod: use --no-preserve-root to override this failsafe", .{ cli.quoteA(f), if (literal) "" else " (same as '/')" });
            status = 1;
            continue;
        }
        if (!process(ctx, &cfg, f, true)) status = 1;
    }
    return status;
}

fn isRoot(ctx: cli.Context, p: []const u8) bool {
    if (std.mem.indexOfNone(u8, p, "/") == null and p.len > 0) return true;
    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(ctx.io, p, &buf) catch return false;
    return std.mem.eql(u8, buf[0..n], "/");
}

/// Change one file and, with -R, its children. Returns false on any error.
fn process(ctx: cli.Context, cfg: *const Config, path: []const u8, is_arg: bool) bool {
    const cwd = Io.Dir.cwd();
    const follow = if (is_arg) cfg.deref_args and !cfg.no_deref else (cfg.traverse_all and !cfg.no_deref);
    // Symlinks met during traversal are skipped (unless -L), as GNU does.
    const lst = cwd.statFile(ctx.io, path, .{ .follow_symlinks = false }) catch |e| {
        if (!cfg.quiet) cli.warn(ctx, "cannot access {f}: {s}", .{ cli.quoteA(path), cli.errText(e) });
        couldNotAccess(ctx, cfg, path);
        return false;
    };
    if (lst.kind == .sym_link and !is_arg and !cfg.traverse_all) return true;
    const st = if (lst.kind == .sym_link and follow)
        (cwd.statFile(ctx.io, path, .{}) catch |e| {
            if (!cfg.quiet) {
                if (e == error.FileNotFound) {
                    cli.warn(ctx, "cannot operate on dangling symlink {f}", .{cli.quoteA(path)});
                } else cli.warn(ctx, "cannot access {f}: {s}", .{ cli.quoteA(path), cli.errText(e) });
            }
            couldNotAccess(ctx, cfg, path);
            return false;
        })
    else
        lst;
    var ok = true;
    if (lst.kind == .sym_link and !follow) {
        // chmod cannot change a symlink's own mode: leave it, as GNU does.
        return true;
    }
    const old: u16 = @intCast(st.permissions.toMode() & 0o7777);
    const is_dir = st.kind == .directory;
    var new: u16 = undefined;
    if (cfg.reference_mode) |r| {
        new = r;
    } else {
        new = mode_mod.apply(cfg.mode_text, old, is_dir, cfg.umask).?;
        // A directory keeps its set-user-ID and set-group-ID bits unless the
        // mode says so explicitly: octal modes of fewer than five digits and
        // symbolic modes that never mention `s` leave them alone.
        if (is_dir) {
            const octal = std.ascii.isDigit(cfg.mode_text[0]);
            if ((octal and cfg.mode_text.len < 5) or (!octal and std.mem.indexOfScalar(u8, cfg.mode_text, 's') == null)) new |= old & 0o6000;
        }
    }
    if (new != old or true) {
        cwd.setFilePermissions(ctx.io, path, .fromMode(new), .{ .follow_symlinks = follow }) catch |e| {
            if (!cfg.quiet) cli.warn(ctx, "changing permissions of {f}: {s}", .{ cli.quoteA(path), cli.errText(e) });
            ok = false;
        };
    }
    if (ok) {
        report(ctx, cfg, path, old, new);
        // `-r` with a umask: bits the user asked to clear but the umask kept.
        if (cfg.reference_mode == null and !std.ascii.isDigit(cfg.mode_text[0])) {
            const want = mode_mod.apply(cfg.mode_text, old, is_dir, 0).?;
            if (new & ~want & 0o777 != 0) {
                var b1: [10]u8 = undefined;
                var b2: [10]u8 = undefined;
                if (!cfg.quiet) cli.warn(ctx, "{f}: new permissions are {s}, not {s}", .{ cli.quote(path), modeString(&b1, new), modeString(&b2, want) });
                ok = false;
            }
        }
    }
    if (cfg.recursive and (st.kind == .directory)) {
        var dir = cwd.openDir(ctx.io, path, .{ .iterate = true }) catch |e| {
            if (!cfg.quiet) cli.warn(ctx, "cannot read directory {f}: {s}", .{ cli.quoteA(path), cli.errText(e) });
            return false;
        };
        defer dir.close(ctx.io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| ctx.gpa.free(n);
            names.deinit(ctx.gpa);
        }
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            names.append(ctx.gpa, ctx.gpa.dupe(u8, entry.name) catch return false) catch return false;
        }
        for (names.items) |n| {
            const child = if (std.mem.endsWith(u8, path, "/"))
                std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{ path, n }) catch return false
            else
                std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ path, n }) catch return false;
            defer ctx.gpa.free(child);
            if (!process(ctx, cfg, child, false)) ok = false;
        }
    }
    return ok;
}

/// With -v GNU also says so on standard output.
fn couldNotAccess(ctx: cli.Context, cfg: *const Config, path: []const u8) void {
    if (!cfg.verbose) return;
    var vb: [8200]u8 = undefined;
    const vl = std.fmt.bufPrint(&vb, "{f} could not be accessed\n", .{cli.quoteA(path)}) catch return;
    _ = cli.writeStdout(ctx.io, vl);
}

fn report(ctx: cli.Context, cfg: *const Config, path: []const u8, old: u16, new: u16) void {
    if (!cfg.verbose and !cfg.changes) return;
    var buf: [8192]u8 = undefined;
    var os: [10]u8 = undefined;
    var ns: [10]u8 = undefined;
    const line = if (old == new) blk: {
        if (!cfg.verbose) return;
        break :blk std.fmt.bufPrint(&buf, "mode of {f} retained as {o:0>4} ({s})\n", .{ cli.quoteA(path), new, modeString(&ns, new) }) catch return;
    } else std.fmt.bufPrint(&buf, "mode of {f} changed from {o:0>4} ({s}) to {o:0>4} ({s})\n", .{ cli.quoteA(path), old, modeString(&os, old), new, modeString(&ns, new) }) catch return;
    _ = cli.writeStdout(ctx.io, line);
}

/// "rwxr-xr-x" style text of the permission bits (with s/S and t/T).
fn modeString(buf: *[10]u8, m: u16) []const u8 {
    const rwx = "rwxrwxrwx";
    for (0..9) |k| buf[k] = if (m & (@as(u16, 1) << @intCast(8 - k)) != 0) rwx[k] else '-';
    if (m & 0o4000 != 0) buf[2] = if (buf[2] == 'x') 's' else 'S';
    if (m & 0o2000 != 0) buf[5] = if (buf[5] == 'x') 's' else 'S';
    if (m & 0o1000 != 0) buf[8] = if (buf[8] == 'x') 't' else 'T';
    return buf[0..9];
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: chmod [OPTION]... MODE[,MODE]... FILE...\n  or:  chmod [OPTION]... OCTAL-MODE FILE...\n  or:  chmod [OPTION]... --reference=RFILE FILE...\nChange the mode of each FILE to MODE.\nWith --reference, change the mode of each FILE to that of RFILE.\n\n  -c, --changes          like verbose but report only when a change is made\n  -f, --silent, --quiet  suppress most error messages\n  -v, --verbose          output a diagnostic for every file processed\n      --dereference      affect the referent of each symbolic link,\n                           rather than the symbolic link itself\n  -h, --no-dereference   affect each symbolic link, rather than the referent\n      --no-preserve-root  do not treat '/' specially (the default)\n      --preserve-root    fail to operate recursively on '/'\n      --reference=RFILE  use RFILE's mode instead of specifying MODE values.\n                         RFILE is always dereferenced if a symbolic link.\n  -R, --recursive        change files and directories recursively\n\nThe following options modify how a hierarchy is traversed when the -R\noption is also specified.  If more than one is specified, only the final\none takes effect. -H is the default.\n\n  -H                     if a command line argument is a symbolic link\n                         to a directory, traverse it\n  -L                     traverse every symbolic link to a directory\n                         encountered\n  -P                     do not traverse any symbolic links\n\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
