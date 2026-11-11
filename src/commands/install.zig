// SPDX-License-Identifier: GPL-2.0-or-later
//! install — copy files and set attributes.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "install
//! invocation" (9.7) and GNU coreutils 9.6 src/install.c. The copying is done
//! by src/copy.zig. SELinux options are accepted and ignored.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const copy = @import("../copy.zig");
const backup = @import("../backup.zig");
const mode_mod = @import("../mode.zig");
const userdb = @import("../userdb.zig");
const Io = std.Io;
const E = std.os.linux.E;

const help_text = @embedFile("../help/install.txt");

const unset: u32 = std.math.maxInt(u32);

const St = struct {
    ctx: cli.Context,
    out: *cli.Out,
    mode: u32 = 0o755,
    dir_mode: u32 = 0o755,
    owner_id: u32 = unset,
    group_id: u32 = unset,
    strip_files: bool = false,
    strip_program: []const u8 = "strip",
    copy_only_if_needed: bool = false,
    verbose: bool = false,
    x: copy.Opts,
};

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

pub fn main(ctx: cli.Context) u8 {
    var out = cli.Out.init(ctx.io);
    const rc = run(ctx, &out);
    out.flush();
    return rc;
}

fn lastComponent(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    const t = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, t, '/');
    return if (slash) |s| t[s + 1 ..] else t;
}

fn extraMode(m: u32) bool {
    return (m & ~@as(u32, 0o777 | 0o170000)) != 0;
}

fn sameContent(ctx: cli.Context, a: []const u8, b: []const u8) bool {
    var e: E = .SUCCESS;
    const fa = sys.openFd(a, sys.O.RDONLY, 0, &e) orelse return false;
    defer _ = sys.closeFd(fa);
    const fb = sys.openFd(b, sys.O.RDONLY, 0, &e) orelse return false;
    defer _ = sys.closeFd(fb);
    var ba: [4096]u8 = undefined;
    var bb: [4096]u8 = undefined;
    _ = ctx;
    while (true) {
        const na = readFull(fa, &ba) orelse return false;
        const nb = readFull(fb, &bb) orelse return false;
        if (na != nb) return false;
        if (na == 0) return true;
        if (!std.mem.eql(u8, ba[0..na], bb[0..nb])) return false;
    }
}

fn readFull(fd: i32, buf: []u8) ?usize {
    var e: E = .SUCCESS;
    var n: usize = 0;
    while (n < buf.len) {
        const r = sys.readFd(fd, buf[n..], &e) orelse return null;
        if (r == 0) break;
        n += r;
    }
    return n;
}

fn needCopy(s: *St, src: []const u8, dest: []const u8) bool {
    var e: E = .SUCCESS;
    if (extraMode(s.mode)) return true;
    const ss = sys.fileStat(src, true, &e) orelse return true;
    const ds = sys.fileStat(dest, false, &e) orelse return true;
    if (!ss.isReg() or !ds.isReg() or extraMode(ss.mode) or extraMode(ds.mode)) return true;
    if (ss.size != ds.size or (ds.mode & 0o7777) != s.mode) return true;
    const id = sys.identity();
    if (s.owner_id == unset) {
        if (ds.uid != id.uid) return true;
    } else if (ds.uid != s.owner_id) return true;
    if (s.group_id == unset) {
        if (ds.gid != id.gid) return true;
    } else if (ds.gid != s.group_id) return true;
    return !sameContent(s.ctx, src, dest);
}

fn changeAttributes(s: *St, name: []const u8) bool {
    const ctx = s.ctx;
    if (!(s.owner_id == unset and s.group_id == unset)) {
        if (sys.chownAt(name, s.owner_id, s.group_id, true)) |ce| {
            s.out.flush();
            cli.warn(ctx, "cannot change ownership of {f}: {s}", .{ cli.quoteA(name), sys.errnoText(ce) });
            return false;
        }
    }
    if (sys.chmodPath(name, s.mode, false)) |ce| {
        s.out.flush();
        cli.warn(ctx, "cannot change permissions of {f}: {s}", .{ cli.quoteA(name), sys.errnoText(ce) });
        return false;
    }
    return true;
}

fn stripFile(s: *St, name: []const u8) bool {
    const ctx = s.ctx;
    var safe = name;
    var tmp: ?[]u8 = null;
    defer if (tmp) |t| ctx.gpa.free(t);
    if (name.len > 0 and name[0] == '-') {
        tmp = std.fmt.allocPrint(ctx.gpa, "./{s}", .{name}) catch return false;
        safe = tmp.?;
    }
    s.out.flush();
    const child = std.process.spawn(ctx.io, .{ .argv = &.{ s.strip_program, safe } }) catch {
        // GNU forks first: the child reports the failure and the parent then
        // sees a failed strip.
        cli.warn(ctx, "cannot run {f}: No such file or directory", .{cli.quoteA(s.strip_program)});
        cli.warn(ctx, "strip process terminated abnormally", .{});
        return false;
    };
    const pid: i32 = @intCast(child.id.?);
    switch (sys.waitPid(pid, true)) {
        .exited => |c| if (c == 0) return true,
        else => {},
    }
    cli.warn(ctx, "strip process terminated abnormally", .{});
    return false;
}

fn installFileInFile(s: *St, c: *copy.Copier, from: []const u8, to: []const u8) bool {
    const ctx = s.ctx;
    var e: E = .SUCCESS;
    var from_sb: sys.FileStat = undefined;
    if (c.x.preserve_timestamps) {
        from_sb = sys.fileStat(from, true, &e) orelse {
            s.out.flush();
            cli.warn(ctx, "cannot stat {f}: {s}", .{ cli.quoteA(from), sys.errnoText(e) });
            return false;
        };
    }
    var copied = true;
    if (s.copy_only_if_needed and !needCopy(s, from, to)) {
        copied = false;
    } else {
        var into_self = false;
        var rs: ?bool = null;
        if (!c.copy(from, to, 0, &into_self, &rs)) return false;
    }
    if (!copied) return true;
    if (s.strip_files) {
        if (!stripFile(s, to)) {
            if (sys.unlinkPath(to, false)) |ue| {
                cli.warn(ctx, "cannot unlink {f}: {s}", .{ cli.quoteA(to), sys.errnoText(ue) });
                std.process.exit(1);
            }
            return false;
        }
    }
    if (c.x.preserve_timestamps and (s.strip_files or !from_sb.isReg())) {
        const ts = [2]sys.TimeSpec{ .{ .sec = from_sb.atime_s, .nsec = from_sb.atime_ns }, .{ .sec = from_sb.mtime_s, .nsec = from_sb.mtime_ns } };
        if (sys.setTimes(to, -1, ts, false)) |te| {
            s.out.flush();
            cli.warn(ctx, "cannot set timestamps for {f}: {s}", .{ cli.quoteA(to), sys.errnoText(te) });
            return false;
        }
    }
    return changeAttributes(s, to);
}

fn announceMkdir(s: *St, dir: []const u8) void {
    if (s.x.verbose) {
        s.out.print("{s}: creating directory {f}\n", .{ s.ctx.name, cli.quoteA(dir) });
    }
}

/// Create every missing leading directory of `path` (not `path` itself).
fn mkAncestors(s: *St, path: []const u8) bool {
    const ctx = s.ctx;
    var i: usize = 0;
    while (i < path.len and path[i] == '/') i += 1;
    while (std.mem.indexOfScalarPos(u8, path, i, '/')) |sl| {
        const prefix = path[0..sl];
        var e: E = .SUCCESS;
        if (sys.fileStat(prefix, true, &e)) |ps| {
            if (!ps.isDir()) {
                s.out.flush();
                cli.warn(ctx, "cannot create directory {f}: Not a directory", .{cli.quoteA(prefix)});
                return false;
            }
        } else {
            if (sys.mkdirPath(prefix, 0o755)) |me| {
                s.out.flush();
                cli.warn(ctx, "cannot create directory {f}: {s}", .{ cli.quoteA(path), sys.errnoText(me) });
                return false;
            }
            announceMkdir(s, prefix);
        }
        i = sl + 1;
        while (i < path.len and path[i] == '/') i += 1;
    }
    return true;
}

fn processDir(s: *St, dir_in: []const u8) bool {
    const ctx = s.ctx;
    var end = dir_in.len;
    while (end > 1 and dir_in[end - 1] == '/') end -= 1;
    const dir = dir_in[0..end];
    if (!mkAncestors(s, dir)) return false;
    var e: E = .SUCCESS;
    if (sys.fileStat(dir, true, &e)) |st| {
        if (!st.isDir()) {
            s.out.flush();
            cli.warn(ctx, "cannot create directory {f}: File exists", .{cli.quoteA(dir)});
            return false;
        }
    } else {
        const create_mode = if (s.owner_id != unset or s.group_id != unset) s.dir_mode & 0o700 else s.dir_mode;
        if (sys.mkdirPath(dir, create_mode)) |me| {
            s.out.flush();
            if (me == .ACCES) {
                cli.warn(ctx, "cannot change permissions of {f}: No such file or directory", .{cli.quoteA(dir)});
            } else cli.warn(ctx, "cannot create directory {f}: {s}", .{ cli.quoteA(dir), sys.errnoText(me) });
            return false;
        }
        announceMkdir(s, dir);
    }
    if (!(s.owner_id == unset and s.group_id == unset)) {
        if (sys.chownAt(dir, s.owner_id, s.group_id, true)) |ce| {
            s.out.flush();
            cli.warn(ctx, "cannot change owner and permissions of {f}: {s}", .{ cli.quoteA(dir), sys.errnoText(ce) });
            return false;
        }
    }
    if (sys.chmodPath(dir, s.dir_mode, false)) |ce| {
        s.out.flush();
        cli.warn(ctx, "cannot change permissions of {f}: {s}", .{ cli.quoteA(dir), sys.errnoText(ce) });
        return false;
    }
    return true;
}

fn run(ctx: cli.Context, out: *cli.Out) u8 {
    var x: copy.Opts = .{};
    x.copy_as_regular = true;
    x.dereference = .always;
    x.unlink_dest_before_opening = true;
    x.install_mode = true;
    x.set_mode = true;
    x.mode = 0o600;
    x.chown_privileges = sys.identity().euid == 0;
    x.owner_privileges = x.chown_privileges;
    var s: St = .{ .ctx = ctx, .out = out, .x = x };
    var specified_mode: ?[]const u8 = null;
    var make_backups = false;
    var backup_suffix: ?[]const u8 = null;
    var version_control: ?[]const u8 = null;
    var mkdir_and_install = false;
    var dir_arg = false;
    var target_directory: ?[]const u8 = null;
    var no_target_directory = false;
    var owner_name: ?[]const u8 = null;
    var group_name: ?[]const u8 = null;
    var strip_program_specified = false;

    var p = getopt.Parser.init(ctx, "bcCsDdg:m:o:pt:TvS:Z", &.{
        .{ .name = "backup", .arg = .optional, .id = 'b' },
        .{ .name = "compare", .id = 'C' },
        .{ .name = "debug", .id = 1100 },
        .{ .name = "directory", .id = 'd' },
        .{ .name = "group", .arg = .required, .id = 'g' },
        .{ .name = "mode", .arg = .required, .id = 'm' },
        .{ .name = "owner", .arg = .required, .id = 'o' },
        .{ .name = "preserve-timestamps", .id = 'p' },
        .{ .name = "strip", .id = 's' },
        .{ .name = "strip-program", .arg = .required, .id = 1101 },
        .{ .name = "suffix", .arg = .required, .id = 'S' },
        .{ .name = "target-directory", .arg = .required, .id = 't' },
        .{ .name = "no-target-directory", .id = 'T' },
        .{ .name = "verbose", .id = 'v' },
        .{ .name = "preserve-context", .id = 1102 },
        .{ .name = "context", .arg = .optional, .id = 1103 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'b' => {
                make_backups = true;
                if (o.arg) |a| version_control = a;
            },
            'c' => {},
            'C' => s.copy_only_if_needed = true,
            's' => s.strip_files = true,
            1100 => {
                s.x.debug = true;
                s.x.verbose = true;
            },
            1101 => {
                s.strip_program = o.arg.?;
                strip_program_specified = true;
            },
            'd' => dir_arg = true,
            'D' => mkdir_and_install = true,
            'v' => s.x.verbose = true,
            'g' => group_name = o.arg.?,
            'm' => specified_mode = o.arg.?,
            'o' => owner_name = o.arg.?,
            'p' => s.x.preserve_timestamps = true,
            'S' => {
                make_backups = true;
                backup_suffix = o.arg.?;
            },
            't' => {
                if (target_directory != null) {
                    cli.warn(ctx, "multiple target directories specified", .{});
                    return 1;
                }
                target_directory = o.arg.?;
            },
            'T' => no_target_directory = true,
            1102 => cli.warn(ctx, "WARNING: ignoring --preserve-context; this kernel is not SELinux-enabled", .{}),
            'Z', 1103 => if (o.arg != null) cli.warn(ctx, "warning: ignoring --context; it requires an SELinux-enabled kernel", .{}),
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (dir_arg and s.strip_files) {
        cli.warn(ctx, "the strip option may not be used when installing a directory", .{});
        return 1;
    }
    if (dir_arg and target_directory != null) {
        cli.warn(ctx, "target directory not allowed when installing a directory", .{});
        return 1;
    }
    s.x.backup_type = if (make_backups) (backup.parseVersion(ctx, "backup type", version_control) orelse return 1) else .none;
    backup.setSimpleSuffix(ctx, backup_suffix);

    const operands = p.operands.items;
    var n_files = operands.len;
    if (n_files <= @intFromBool(!(dir_arg or target_directory != null))) {
        if (n_files == 0) {
            cli.warn(ctx, "missing file operand", .{});
        } else cli.warn(ctx, "missing destination file operand after {f}", .{cli.quoteA(operands[0])});
        return usageFail(ctx);
    }
    var e: E = .SUCCESS;
    var target_ok = true;
    if (no_target_directory) {
        if (target_directory != null) {
            cli.warn(ctx, "cannot combine --target-directory (-t) and --no-target-directory (-T)", .{});
            return 1;
        }
        if (n_files > 2) {
            cli.warn(ctx, "extra operand {f}", .{cli.quoteA(operands[2])});
            return usageFail(ctx);
        }
    } else if (target_directory) |t| {
        const st = sys.fileStat(t, true, &e);
        target_ok = st != null and st.?.isDir();
        if (!target_ok) {
            const err: E = if (st == null) e else .NOTDIR;
            if (!(mkdir_and_install and err == .NOENT)) {
                cli.warn(ctx, "failed to access {f}: {s}", .{ cli.quoteA(t), sys.errnoText(err) });
                return 1;
            }
        }
    } else if (!dir_arg) {
        const last = operands[n_files - 1];
        const st = sys.fileStat(last, true, &e);
        if (st != null and st.?.isDir()) {
            target_directory = last;
            n_files -= 1;
        } else if (n_files > 2) {
            cli.warn(ctx, "target {f}: {s}", .{ cli.quoteA(last), sys.errnoText(if (st == null) e else .NOTDIR) });
            return 1;
        }
    }
    if (specified_mode) |m| {
        const mm = mode_mod.apply(m, 0, false, 0) orelse {
            cli.warn(ctx, "invalid mode {f}", .{cli.quoteC(m)});
            return 1;
        };
        s.mode = mm;
        s.dir_mode = mode_mod.apply(m, 0, true, 0).?;
    }
    if (strip_program_specified and !s.strip_files) {
        cli.warn(ctx, "WARNING: ignoring --strip-program option as -s option was not specified", .{});
    }
    if (s.copy_only_if_needed and s.x.preserve_timestamps) {
        cli.warn(ctx, "options --compare (-C) and --preserve-timestamps are mutually exclusive", .{});
        return usageFail(ctx);
    }
    if (s.copy_only_if_needed and s.strip_files) {
        cli.warn(ctx, "options --compare (-C) and --strip are mutually exclusive", .{});
        return usageFail(ctx);
    }
    if (s.copy_only_if_needed and extraMode(s.mode)) {
        cli.warn(ctx, "the --compare (-C) option is ignored when you specify a mode with non-permission bits", .{});
    }

    var db = userdb.Db.load(ctx.gpa, ctx.io);
    defer db.deinit();
    if (owner_name) |on| {
        if (db.userByName(on)) |u| {
            s.owner_id = u.uid;
        } else {
            const v = std.fmt.parseInt(u32, on, 0) catch {
                cli.warn(ctx, "invalid user {f}", .{cli.quoteA(on)});
                return 1;
            };
            s.owner_id = v;
        }
    }
    if (group_name) |gn| {
        if (db.groupByName(gn)) |g| {
            s.group_id = g.gid;
        } else {
            const v = std.fmt.parseInt(u32, gn, 0) catch {
                cli.warn(ctx, "invalid group {f}", .{cli.quoteA(gn)});
                return 1;
            };
            s.group_id = v;
        }
    }

    // install runs with umask 0 so that modes are exact.
    _ = sys.setUmask(0);

    var ok = true;
    if (dir_arg) {
        for (operands) |d| if (!processDir(&s, d)) {
            ok = false;
        };
        return if (ok) 0 else 1;
    }

    var c = copy.Copier.init(ctx, out, s.x);
    defer c.deinit();
    c.umask = 0;
    if (target_directory == null) {
        const from = operands[0];
        const to = operands[1];
        if (mkdir_and_install and !mkAncestors(&s, to)) return 1;
        ok = installFileInFile(&s, &c, from, to);
    } else {
        const td = target_directory.?;
        c.x.track_dest = true;
        for (operands[0..n_files], 0..) |from, i| {
            const to = copy.joinName(ctx.gpa, td, lastComponent(from)) catch return 1;
            defer ctx.gpa.free(to);
            if (!target_ok or (i == 0 and mkdir_and_install)) {
                if (mkdir_and_install and i == 0) {
                    if (!mkAncestors(&s, to)) {
                        ok = false;
                        continue;
                    }
                    var ee: E = .SUCCESS;
                    if (sys.fileStat(td, true, &ee) == null) {
                        // -D also creates the target directory itself (via the
                        // ancestors of "target/name").
                    }
                    target_ok = true;
                }
            }
            if (!installFileInFile(&s, &c, from, to)) ok = false;
        }
    }
    return if (ok) 0 else 1;
}
