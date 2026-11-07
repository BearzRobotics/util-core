//! chown and chgrp — change file owner and group.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "chown invocation"
//! and "chgrp invocation" (9.7), POSIX.1-2024 chown, and GNU coreutils 9.6
//! src/chown.c, src/chown-core.c and lib/userspec.c (control flow of the
//! traversal and the messages were studied there and rewritten). Directories
//! are changed after their contents under -R, as with fts post-order visits.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const userdb = @import("../userdb.zig");
const userspec = @import("../userspec.zig");
const Io = std.Io;

const help_chown = @embedFile("../help/chown.txt");
const help_chgrp = @embedFile("../help/chgrp.txt");

pub const Mode = enum { chown, chgrp };

const unset = userspec.unset;
const Verbosity = enum { off, changes_only, high };
const Walk = enum { physical, comfollow, logical };

const Info = enum { dir_pre, dir_post, dir_unreadable, dir_cycle, other, stat_failed, dangling };

const S = struct {
    ctx: cli.Context,
    mode: Mode,
    db: userdb.Db,
    out: cli.Out,
    verbosity: Verbosity = .off,
    recurse: bool = false,
    force_silent: bool = false,
    affect_referent: bool = true,
    walk: Walk = .physical,
    preserve_root: bool = false,
    root_dev: u64 = 0,
    root_ino: u64 = 0,
    uid: u32 = unset,
    gid: u32 = unset,
    required_uid: u32 = unset,
    required_gid: u32 = unset,
    user_name: ?[]const u8 = null,
    group_name: ?[]const u8 = null,
    ancestors: std.ArrayList([2]u64) = .empty,
    root_hit: bool = false,
    /// GNU reads an uninitialised stat buffer after a failed dereference; in
    /// practice it still holds the previous successful result (or zeros).
    stale_stat: sys.FileStat = std.mem.zeroes(sys.FileStat),

    fn uidName(s: *S, uid: u32, buf: *[16]u8) []const u8 {
        if (s.db.userByUid(uid)) |u| return u.name;
        return std.fmt.bufPrint(buf, "{d}", .{uid}) catch "?";
    }

    fn gidName(s: *S, gid: u32, buf: *[16]u8) []const u8 {
        if (s.db.groupByGid(gid)) |g| return g.name;
        return std.fmt.bufPrint(buf, "{d}", .{gid}) catch "?";
    }
};

fn devKey(st: sys.FileStat) u64 {
    return (@as(u64, st.dev_major) << 32) | st.dev_minor;
}

const Change = enum { succeeded, failed, no_change_requested, not_applied };

fn userGroupStr(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, user: ?[]const u8, group: ?[]const u8) bool {
    if (user) |u| {
        buf.appendSlice(gpa, u) catch {};
        if (group) |g| {
            buf.append(gpa, ':') catch {};
            buf.appendSlice(gpa, g) catch {};
        }
        return true;
    } else if (group) |g| {
        buf.appendSlice(gpa, g) catch {};
        return true;
    }
    return false;
}

fn describeChange(s: *S, file: []const u8, changed: Change, old_user: ?[]const u8, old_group: ?[]const u8, user: ?[]const u8, group: ?[]const u8) void {
    const gpa = s.ctx.gpa;
    if (changed == .not_applied) {
        s.out.print("neither symbolic link {f} nor referent has been changed\n", .{cli.quoteA(file)});
        return;
    }
    var spec: std.ArrayList(u8) = .empty;
    defer spec.deinit(gpa);
    var old_spec: std.ArrayList(u8) = .empty;
    defer old_spec.deinit(gpa);
    const have_spec = userGroupStr(&spec, gpa, user, group);
    const have_old = userGroupStr(&old_spec, gpa, if (user != null) old_user else null, if (group != null) old_group else null);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    const w = struct {
        fn p(l: *std.ArrayList(u8), g: std.mem.Allocator, comptime f: []const u8, a: anytype) void {
            const t = std.fmt.allocPrint(g, f, a) catch return;
            defer g.free(t);
            l.appendSlice(g, t) catch {};
        }
    }.p;
    switch (changed) {
        .succeeded => {
            if (user != null) {
                w(&line, gpa, "changed ownership of {f} from {s} to {s}\n", .{ cli.quoteA(file), old_spec.items, spec.items });
            } else if (group != null) {
                w(&line, gpa, "changed group of {f} from {s} to {s}\n", .{ cli.quoteA(file), old_spec.items, spec.items });
            } else w(&line, gpa, "no change to ownership of {f}\n", .{cli.quoteA(file)});
        },
        .failed => {
            if (have_old) {
                if (user != null) {
                    w(&line, gpa, "failed to change ownership of {f} from {s} to {s}\n", .{ cli.quoteA(file), old_spec.items, spec.items });
                } else if (group != null) {
                    w(&line, gpa, "failed to change group of {f} from {s} to {s}\n", .{ cli.quoteA(file), old_spec.items, spec.items });
                } else w(&line, gpa, "failed to change ownership of {f}\n", .{cli.quoteA(file)});
            } else {
                // old_spec takes the place of spec and spec becomes null.
                if (user != null) {
                    w(&line, gpa, "failed to change ownership of {f} to {s}\n", .{ cli.quoteA(file), spec.items });
                } else if (group != null) {
                    w(&line, gpa, "failed to change group of {f} to {s}\n", .{ cli.quoteA(file), spec.items });
                } else w(&line, gpa, "failed to change ownership of {f}\n", .{cli.quoteA(file)});
            }
        },
        .no_change_requested => {
            if (user != null) {
                w(&line, gpa, "ownership of {f} retained as {s}\n", .{ cli.quoteA(file), old_spec.items });
            } else if (group != null) {
                w(&line, gpa, "group of {f} retained as {s}\n", .{ cli.quoteA(file), old_spec.items });
            } else w(&line, gpa, "ownership of {f} retained\n", .{cli.quoteA(file)});
        },
        .not_applied => unreachable,
    }
    _ = have_spec;
    s.out.write(line.items);
}

const Ent = struct {
    path: []const u8,
    info: Info,
    level: usize,
    st: ?sys.FileStat,
    errno: std.os.linux.E = .SUCCESS,
};

/// chown-core.c change_file_owner. Returns false on error.
fn changeFileOwner(s: *S, ent: *const Ent) bool {
    const ctx = s.ctx;
    var ok = true;
    var do_chown = true;
    var file_stats: ?sys.FileStat = ent.st;
    switch (ent.info) {
        .dir_pre => if (s.recurse) {
            if (s.preserve_root and ent.st != null and devKey(ent.st.?) == s.root_dev and ent.st.?.ino == s.root_ino) {
                rootWarn(ctx, ent.path);
                s.root_hit = true;
                return false;
            }
            return true;
        },
        .dir_post => if (!s.recurse) return true,
        .stat_failed => {
            if (!s.force_silent) cli.warn(ctx, "cannot access {f}: {s}", .{ cli.quoteA(ent.path), sys.errnoText(ent.errno) });
            ok = false;
        },
        .dir_unreadable => {
            if (!s.force_silent) cli.warn(ctx, "cannot read directory {f}: {s}", .{ cli.quoteA(ent.path), sys.errnoText(ent.errno) });
            ok = false;
        },
        .dir_cycle, .other, .dangling => {},
    }
    if (!ok) {
        do_chown = false;
        file_stats = null;
    } else if (s.required_uid == unset and s.required_gid == unset and s.verbosity == .off and !s.preserve_root and !s.affect_referent) {
        do_chown = true;
    } else {
        // Symlinks are dereferenced to find the owner to compare.
        if (s.affect_referent and ent.st != null and ent.st.?.isLink()) {
            var e: std.os.linux.E = .SUCCESS;
            if (sys.fileStat(ent.path, true, &e)) |st| {
                file_stats = st;
                s.stale_stat = st;
            } else {
                if (!s.force_silent) cli.warn(ctx, "cannot dereference {f}: {s}", .{ cli.quoteA(ent.path), sys.errnoText(e) });
                ok = false;
                // GNU then reads its stat buffer for the message.
                file_stats = s.stale_stat;
            }
        }
        do_chown = ok and file_stats != null and
            (s.required_uid == unset or s.required_uid == file_stats.?.uid) and
            (s.required_gid == unset or s.required_gid == file_stats.?.gid);
    }

    const is_dir_info = ent.info == .dir_pre or ent.info == .dir_post or ent.info == .dir_unreadable;
    if (ok and is_dir_info and s.preserve_root and file_stats != null and devKey(file_stats.?) == s.root_dev and file_stats.?.ino == s.root_ino) {
        rootWarn(ctx, ent.path);
        return false;
    }

    var symlink_changed = true;
    if (do_chown) {
        const err = sys.chownAt(ent.path, s.uid, s.gid, !s.affect_referent);
        if (err) |e| {
            if (e == .OPNOTSUPP) {
                symlink_changed = false;
            } else {
                ok = false;
                if (!s.force_silent) {
                    const what = if (s.uid != unset) "changing ownership of" else "changing group of";
                    cli.warn(ctx, "{s} {f}: {s}", .{ what, cli.quoteA(ent.path), sys.errnoText(e) });
                }
            }
        }
    }

    if (s.verbosity != .off) {
        const changed = do_chown and ok and symlink_changed and file_stats != null and
            !((s.uid == unset or s.uid == file_stats.?.uid) and (s.gid == unset or s.gid == file_stats.?.gid));
        if (changed or s.verbosity == .high) {
            const status: Change = if (!ok) .failed else if (!symlink_changed) .not_applied else if (!changed) .no_change_requested else .succeeded;
            var ub: [16]u8 = undefined;
            var gb: [16]u8 = undefined;
            var nu: [16]u8 = undefined;
            var ng: [16]u8 = undefined;
            const old_usr: ?[]const u8 = if (file_stats) |f| s.uidName(f.uid, &ub) else null;
            const old_grp: ?[]const u8 = if (file_stats) |f| s.gidName(f.gid, &gb) else null;
            const new_usr: ?[]const u8 = s.user_name orelse if (s.uid != unset) (std.fmt.bufPrint(&nu, "{d}", .{s.uid}) catch null) else null;
            const new_grp: ?[]const u8 = s.group_name orelse if (s.gid != unset) (std.fmt.bufPrint(&ng, "{d}", .{s.gid}) catch null) else null;
            describeChange(s, ent.path, status, old_usr, old_grp, new_usr, new_grp);
        }
    }
    return ok;
}

fn rootWarn(ctx: cli.Context, path: []const u8) void {
    const same: []const u8 = if (std.mem.eql(u8, path, "/")) "" else " (same as '/')";
    cli.warn(ctx, "it is dangerous to operate recursively on {f}{s}\n{s}: use --no-preserve-root to override this failsafe", .{ cli.quoteA(path), same, ctx.name });
}

/// One fts-style visit of `path` (and below it with -R).
fn visit(s: *S, path: []const u8, level: usize) bool {
    const ctx = s.ctx;
    var ok = true;
    const follow = switch (s.walk) {
        .logical => true,
        .comfollow => level == 0,
        .physical => false,
    };
    var err: std.os.linux.E = .SUCCESS;
    var st_opt = sys.fileStat(path, follow, &err);
    var info: Info = .other;
    if (st_opt == null) {
        if (follow and err == .NOENT) {
            if (sys.fileStat(path, false, &err)) |lst| {
                st_opt = lst;
                info = .dangling;
            }
        }
        if (st_opt == null and level == 0) {
            // fts retries a failed top-level stat once.
            st_opt = sys.fileStat(path, follow, &err);
        }
    }
    if (st_opt == null) {
        const ent: Ent = .{ .path = path, .info = .stat_failed, .level = level, .st = null, .errno = err };
        return changeFileOwner(s, &ent);
    }
    const st = st_opt.?;
    if (info != .dangling and st.isDir()) {
        // Cycle check for logical walks.
        const key = [2]u64{ devKey(st), st.ino };
        var cycle = false;
        for (s.ancestors.items) |a| {
            if (a[0] == key[0] and a[1] == key[1]) cycle = true;
        }
        if (cycle) {
            const ent: Ent = .{ .path = path, .info = .dir_cycle, .level = level, .st = st };
            if (s.walk == .physical or (s.walk == .comfollow and level != 0)) {
                emitCycleWarning(ctx, path);
                return false;
            }
            return changeFileOwner(s, &ent);
        }
        const pre: Ent = .{ .path = path, .info = .dir_pre, .level = level, .st = st };
        if (!changeFileOwner(s, &pre)) ok = false;
        if (s.root_hit) {
            s.root_hit = false;
            return false;
        }
        if (!s.recurse) return ok;
        // Descend.
        var dir = Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch |e| {
            const emap: std.os.linux.E = switch (e) {
                error.AccessDenied => .ACCES,
                error.PermissionDenied => .PERM,
                error.FileNotFound => .NOENT,
                error.NotDir => .NOTDIR,
                else => .IO,
            };
            const ent: Ent = .{ .path = path, .info = .dir_unreadable, .level = level, .st = st, .errno = emap };
            if (!changeFileOwner(s, &ent)) ok = false;
            return ok;
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
        s.ancestors.append(ctx.gpa, key) catch {};
        for (names.items) |n| {
            const child = if (std.mem.endsWith(u8, path, "/"))
                std.fmt.allocPrint(ctx.gpa, "{s}{s}", .{ path, n }) catch continue
            else
                std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ path, n }) catch continue;
            defer ctx.gpa.free(child);
            if (!visit(s, child, level + 1)) ok = false;
        }
        _ = s.ancestors.pop();
        const post: Ent = .{ .path = path, .info = .dir_post, .level = level, .st = st };
        if (!changeFileOwner(s, &post)) ok = false;
        return ok;
    }
    const ent: Ent = .{ .path = path, .info = info, .level = level, .st = st };
    return changeFileOwner(s, &ent);
}

fn emitCycleWarning(ctx: cli.Context, path: []const u8) void {
    cli.warn(ctx, "WARNING: Circular directory structure.\nThis almost certainly means that you have a corrupted file system.\nNOTIFY YOUR SYSTEM MANAGER.\nThe following directory is part of the cycle:\n  {f}", .{cli.quoteA(path)});
}

pub fn run(ctx: cli.Context, mode: Mode) u8 {
    var s: S = .{ .ctx = ctx, .mode = mode, .db = userdb.Db.load(ctx.gpa, ctx.io), .out = cli.Out.init(ctx.io) };
    defer {
        s.db.deinit();
        s.ancestors.deinit(ctx.gpa);
    }
    const rc = realMain(&s);
    s.out.flush();
    return rc;
}

fn realMain(s: *S) u8 {
    const ctx = s.ctx;
    var dereference: i32 = -1;
    var reference_file: ?[]const u8 = null;
    var scratch: std.ArrayList([]u8) = .empty;
    defer {
        for (scratch.items) |x| ctx.gpa.free(x);
        scratch.deinit(ctx.gpa);
    }

    var p = getopt.Parser.init(ctx, "HLPRcfhv", &.{
        .{ .name = "recursive", .id = 'R' },
        .{ .name = "changes", .id = 'c' },
        .{ .name = "dereference", .id = 1100 },
        .{ .name = "from", .arg = .required, .id = 1101 },
        .{ .name = "no-dereference", .id = 'h' },
        .{ .name = "no-preserve-root", .id = 1102 },
        .{ .name = "preserve-root", .id = 1103 },
        .{ .name = "quiet", .id = 'f' },
        .{ .name = "silent", .id = 'f' },
        .{ .name = "reference", .arg = .required, .id = 1104 },
        .{ .name = "verbose", .id = 'v' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'H' => s.walk = .comfollow,
            'L' => s.walk = .logical,
            'P' => s.walk = .physical,
            'h' => dereference = 0,
            1100 => dereference = 1,
            1102 => s.preserve_root = false,
            1103 => s.preserve_root = true,
            1104 => reference_file = o.arg.?,
            1101 => {
                const sp = userspec.parse(&s.db, ctx.gpa, o.arg.?, true, &scratch);
                if (sp.err) |e| {
                    cli.warn(ctx, "{s}: {f}", .{ e, cli.quoteC(o.arg.?) });
                    return 1;
                }
                if (sp.dot_warning) cli.warn(ctx, "warning: '.' should be ':': {f}", .{cli.quoteC(o.arg.?)});
                s.required_uid = sp.uid;
                s.required_gid = sp.gid;
            },
            'R' => s.recurse = true,
            'c' => s.verbosity = .changes_only,
            'f' => s.force_silent = true,
            'v' => s.verbosity = .high,
            getopt.help_id => return if (cli.writeStdout(ctx.io, if (s.mode == .chown) help_chown ++ "\n" else help_chgrp ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };

    if (s.recurse) {
        if (s.walk == .physical) {
            if (dereference == 1) {
                cli.warn(ctx, "-R --dereference requires either -H or -L", .{});
                return 1;
            }
            dereference = 0;
        }
    } else s.walk = .physical;
    s.affect_referent = dereference != 0;

    const operands = p.operands.items;
    const need: usize = if (reference_file != null) 1 else 2;
    if (operands.len < need) {
        if (operands.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        } else cli.warn(ctx, "missing operand after {f}\nTry '{s} --help' for more information.", .{ cli.quoteC(operands[operands.len - 1]), ctx.name });
        return 1;
    }
    var first: usize = 0;
    if (reference_file) |rf| {
        var e: std.os.linux.E = .SUCCESS;
        const st = sys.fileStat(rf, true, &e) orelse {
            cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteA(rf), sys.errnoText(e) });
            return 1;
        };
        var ub: [16]u8 = undefined;
        var gb: [16]u8 = undefined;
        if (s.mode == .chown) {
            s.uid = st.uid;
            s.user_name = ctx.gpa.dupe(u8, s.uidName(st.uid, &ub)) catch null;
            if (s.user_name) |n| scratch.append(ctx.gpa, @constCast(n)) catch {};
        }
        s.gid = st.gid;
        s.group_name = ctx.gpa.dupe(u8, s.gidName(st.gid, &gb)) catch null;
        if (s.group_name) |n| scratch.append(ctx.gpa, @constCast(n)) catch {};
    } else {
        const arg = operands[0];
        var ug: []const u8 = arg;
        if (s.mode == .chgrp) {
            const t = std.fmt.allocPrint(ctx.gpa, ":{s}", .{arg}) catch return 1;
            scratch.append(ctx.gpa, t) catch {};
            ug = t;
        }
        const sp = userspec.parse(&s.db, ctx.gpa, ug, true, &scratch);
        if (sp.err) |e| {
            cli.warn(ctx, "{s}: {f}", .{ e, cli.quoteC(arg) });
            return 1;
        }
        if (sp.dot_warning) cli.warn(ctx, "warning: '.' should be ':': {f}", .{cli.quoteC(arg)});
        s.uid = sp.uid;
        s.gid = sp.gid;
        s.user_name = sp.user_name;
        s.group_name = sp.group_name;
        if (s.mode == .chown and s.user_name == null and s.group_name != null) s.user_name = "";
        first = 1;
    }

    if (s.recurse and s.preserve_root) {
        var e: std.os.linux.E = .SUCCESS;
        const st = sys.fileStat("/", true, &e) orelse {
            cli.warn(ctx, "failed to get attributes of '/': {s}", .{sys.errnoText(e)});
            return 1;
        };
        s.root_dev = devKey(st);
        s.root_ino = st.ino;
    }

    var ok = true;
    for (operands[first..]) |f| {
        if (!visit(s, f, 0)) ok = false;
        s.out.flush();
    }
    return if (ok) 0 else 1;
}

pub fn main(ctx: cli.Context) u8 {
    return run(ctx, .chown);
}
