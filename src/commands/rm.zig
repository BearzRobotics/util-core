//! rm — remove files or directories.
//! References: GNU coreutils manual "rm invocation" (9.7); POSIX.1-2024 rm.
//!
//! Deviations: --one-file-system is accepted but not enforced (std.Io.File.Stat
//! has no device number to compare), and --preserve-root=all is treated as
//! plain --preserve-root.

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "force", "interactive", "one-file-system", "no-preserve-root", "preserve-root", "recursive", "dir", "verbose", "help", "version" };

const Interactive = enum { never, once, always, default };

const Config = struct {
    force: bool = false,
    interactive: Interactive = .default,
    recursive: bool = false,
    dirs: bool = false, // -d
    verbose: bool = false,
    preserve_root: bool = true,
    stdin_tty: bool = false,
};

const State = struct {
    ctx: cli.Context,
    cfg: *const Config,
    out: *cli.Out,
    ok: bool = true,
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
                2 => {},
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
    var st: State = .{ .ctx = ctx, .cfg = &cfg, .out = &out };

    // -I: a single prompt for more than three files or for recursion.
    if (cfg.interactive == .once and (files.items.len > 3 or cfg.recursive)) {
        var buf: [128]u8 = undefined;
        const n = files.items.len;
        const msg = std.fmt.bufPrint(&buf, "remove {d} {s}{s}? ", .{ n, if (n == 1) "argument" else "arguments", if (cfg.recursive) " recursively" else "" }) catch "";
        if (!ask(ctx, msg)) return 0;
    }

    for (files.items) |f| removeArg(&st, f);
    out.flush();
    if (out.failed) return 1;
    return if (st.ok) 0 else 1;
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

fn removeArg(st: *State, path: []const u8) void {
    const ctx = st.ctx;
    const cfg = st.cfg;
    // "." and ".." as the last component are never removed.
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
    if (cfg.recursive and (std.mem.eql(u8, last, ".") or std.mem.eql(u8, last, ".."))) {
        cli.warn(ctx, "refusing to remove '.' or '..' directory: skipping {f}", .{cli.quoteA(path)});
        st.ok = false;
        return;
    }
    if (cfg.preserve_root and cfg.recursive and isRoot(ctx, path)) {
        const literal = std.mem.eql(u8, path, "/");
        cli.warn(ctx, "it is dangerous to operate recursively on {f}{s}", .{ cli.quoteA(path), if (literal) "" else " (same as '/')" });
        cli.warn(ctx, "use --no-preserve-root to override this failsafe", .{});
        st.ok = false;
        return;
    }
    _ = remove(st, path, true);
}

fn isRoot(ctx: cli.Context, p: []const u8) bool {
    if (p.len > 0 and std.mem.indexOfNone(u8, p, "/") == null) return true;
    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(ctx.io, p, &buf) catch return false;
    return std.mem.eql(u8, buf[0..n], "/");
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

/// Remove `path` (recursively when asked). Returns true when it is gone.
fn remove(st: *State, path: []const u8, is_arg: bool) bool {
    const ctx = st.ctx;
    const cfg = st.cfg;
    const cwd = Io.Dir.cwd();
    const lst = cwd.statFile(ctx.io, path, .{ .follow_symlinks = false }) catch |e| {
        if (cfg.force and e == error.FileNotFound) return true;
        cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(path), cli.errText(e) });
        st.ok = false;
        return false;
    };
    var buf: [4400]u8 = undefined;

    if (lst.kind == .directory) {
        if (!cfg.recursive) {
            if (cfg.dirs) return removeEmptyDir(st, path, lst, is_arg);
            cli.warn(ctx, "cannot remove {f}: Is a directory", .{cli.quoteA(path)});
            st.ok = false;
            return false;
        }
        if (cfg.interactive == .always) {
            const q = std.fmt.bufPrint(&buf, "descend into directory {f}? ", .{cli.quoteA(path)}) catch return false;
            if (!ask(ctx, q)) return false;
        }
        var dir = cwd.openDir(ctx.io, path, .{ .iterate = true }) catch |e| {
            cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(path), cli.errText(e) });
            st.ok = false;
            return false;
        };
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| ctx.gpa.free(n);
            names.deinit(ctx.gpa);
        }
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            const dup = ctx.gpa.dupe(u8, entry.name) catch break;
            names.append(ctx.gpa, dup) catch {
                ctx.gpa.free(dup);
                break;
            };
        }
        dir.close(ctx.io);
        var all_gone = true;
        for (names.items) |n| {
            const child = if (std.mem.endsWith(u8, path, "/"))
                std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{ path, n }) catch return false
            else
                std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ path, n }) catch return false;
            defer ctx.gpa.free(child);
            if (!remove(st, child, false)) all_gone = false;
        }
        if (!all_gone) return false; // children failed: leave the directory, as GNU does
        return removeEmptyDir(st, path, lst, is_arg);
    }

    // Anything that is not a directory.
    switch (cfg.interactive) {
        .always => {
            const q = std.fmt.bufPrint(&buf, "remove {s}{s} {f}? ", .{ writeProtectedWord(ctx, path, lst), kindWords(lst.kind, lst.size), cli.quoteA(path) }) catch return false;
            if (!ask(ctx, q)) return false;
        },
        .default => if (cfg.stdin_tty and lst.kind != .sym_link and !writable(ctx, path)) {
            const q = std.fmt.bufPrint(&buf, "remove write-protected {s} {f}? ", .{ kindWords(lst.kind, lst.size), cli.quoteA(path) }) catch return false;
            if (!ask(ctx, q)) return false;
        },
        else => {},
    }
    cwd.deleteFile(ctx.io, path) catch |e| {
        cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(path), cli.errText(e) });
        st.ok = false;
        return false;
    };
    if (cfg.verbose) st.out.print("removed {f}\n", .{cli.quoteA(path)});
    return true;
}

/// "write-protected " when -i would say so (not for symlinks), else "".
fn writeProtectedWord(ctx: cli.Context, path: []const u8, lst: Io.File.Stat) []const u8 {
    if (lst.kind == .sym_link) return "";
    return if (writable(ctx, path)) "" else "write-protected ";
}

fn writable(ctx: cli.Context, path: []const u8) bool {
    Io.Dir.cwd().access(ctx.io, path, .{ .write = true }) catch return false;
    return true;
}

fn removeEmptyDir(st: *State, path: []const u8, lst: Io.File.Stat, is_arg: bool) bool {
    _ = is_arg;
    const ctx = st.ctx;
    const cfg = st.cfg;
    var buf: [4400]u8 = undefined;
    if (cfg.interactive == .always) {
        const q = std.fmt.bufPrint(&buf, "remove {s}{s} {f}? ", .{ writeProtectedWord(ctx, path, lst), kindWords(lst.kind, lst.size), cli.quoteA(path) }) catch return false;
        if (!ask(ctx, q)) return false;
    } else if (cfg.interactive == .default and cfg.stdin_tty and !writable(ctx, path)) {
        const q = std.fmt.bufPrint(&buf, "remove write-protected directory {f}? ", .{cli.quoteA(path)}) catch return false;
        if (!ask(ctx, q)) return false;
    }
    Io.Dir.cwd().deleteDir(ctx.io, path) catch |e| {
        // rmdir("/") says EBUSY; GNU's message is the one for a non-empty directory.
        // Likewise "." (EINVAL) is reported as a non-empty directory.
        const busy_root = (e == error.FileBusy and isRoot(ctx, path)) or (e == error.Unexpected and std.mem.endsWith(u8, std.mem.trimEnd(u8, path, "/"), "."));
        cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(path), if (busy_root) "Directory not empty" else cli.errText(e) });
        st.ok = false;
        return false;
    };
    if (cfg.verbose) st.out.print("removed directory {f}\n", .{cli.quoteA(path)});
    return true;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: rm [OPTION]... [FILE]...\nRemove (unlink) the FILE(s).\n\n  -f, --force           ignore nonexistent files and arguments, never prompt\n  -i                    prompt before every removal\n  -I                    prompt once before removing more than three files, or\n                          when removing recursively; less intrusive than -i,\n                          while still giving protection against most mistakes\n      --interactive[=WHEN]  prompt according to WHEN: never, once (-I), or\n                          always (-i); without WHEN, prompt always\n      --one-file-system  when removing a hierarchy recursively, skip any\n                          directory that is on a file system different from\n                          that of the corresponding command line argument\n      --no-preserve-root  do not treat '/' specially\n      --preserve-root[=all]  do not remove '/' (default);\n                              with 'all', reject any command line argument\n                              on a separate device from its parent\n  -r, -R, --recursive   remove directories and their contents recursively\n  -d, --dir             remove empty directories\n  -v, --verbose         explain what is being done\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
