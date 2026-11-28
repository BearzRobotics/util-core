// SPDX-License-Identifier: GPL-2.0-or-later
//! updatedb library: build the file-name database used by locate.
//! Reference: GNU findutils 4.10 (locate/updatedb.sh and frcode.c). The shell
//! pipeline `find | sort -z | frcode` is done in process: the tree is walked
//! in readdir order, pruned by path and file-system type, sorted bytewise and
//! front-coded.
//!
//! Where the script runs find through `su` for --localuser and --netuser,
//! the walk here (shell expansion of the search paths included) is done with
//! that user's effective ids and groups, so that only names the user could
//! find enter the database, which anyone may read. The calling thread alone
//! changes identity, and it changes back before the database is written. If
//! the identity cannot be assumed, nothing is written.
//!
//! The options are the values the script's variables and `--option=value`
//! flags carry (strings split on white space, with shell pathname expansion
//! of the path lists, as the script does). `run` writes the database to
//! `Options.output` (through a temporary `<output>.n`, then renames it);
//! problems are reported through the Observer and become `Result.status`.
//! `buildDatabase` returns the encoded database without touching the output.

const std = @import("std");
const numparse = @import("../numparse.zig");
const rx = @import("../regexutil.zig");
const LX = std.os.linux;
const common = @import("common.zig");
const fu = @import("fu_common.zig");
const sys = @import("../sys.zig");
const userdb = @import("../userdb.zig");
const dirat = @import("../dirat.zig");
const regex = @import("regex");
const fnmatch = @import("../fnmatch.zig");

pub const Env = common.Env;

pub const default_prunepaths = "/afs /amd /proc /sfs /tmp /usr/tmp /var/tmp";
pub const default_prunefs = "9P NFS afs autofs cifs coda devfs devpts ftpfs fuse.s3fs iso9660 mfs ncpfs nfs nfs4 proc shfs smbfs sysfs";
pub const default_output = "/usr/local/var/locatedb";

pub const Format = enum { locate02, slocate };

pub const Options = struct {
    /// Options for the file walk: -xdev -mount -depth -d -maxdepth N
    /// -mindepth N (and the ones that change nothing).
    findoptions: []const u8 = "",
    /// Space-separated directories to index (shell globs are expanded).
    searchpaths: []const u8 = "/",
    netpaths: []const u8 = "",
    prunepaths: []const u8 = default_prunepaths,
    prunefs: []const u8 = default_prunefs,
    /// Walk `searchpaths` as this user; empty: as the caller.
    localuser: []const u8 = "",
    /// Walk `netpaths` as this user when the caller is root (the script's
    /// default); it cannot be empty then.
    netuser: []const u8 = "daemon",
    output: []const u8 = default_output,
    /// The walk runs relative to this directory for relative search paths.
    changecwd: []const u8 = "/",
    format: Format = .locate02,
};

pub const Event = union(enum) {
    /// A problem while walking: stat or readdir of `path` failed.
    find_error: struct { path: []const u8, text: []const u8 },
    /// A -maxdepth/-mindepth value that is not a number; ends the walk.
    find_bad_number: struct { option: []const u8, value: []const u8 },
    /// The pruned paths do not make a regular expression; nothing is walked,
    /// as when GNU's find rejects it, so nothing that should be pruned can
    /// get into the database.
    find_bad_regex: struct { pattern: []const u8, text: []const u8 },
    /// The walk cannot be done as `user`; fatal (status 1, nothing written).
    user_failed: struct { user: []const u8, text: []const u8 },
    /// A -findoptions word that is not understood; ends the walk.
    find_unknown_predicate: []const u8,
    /// A pruned path that ends in a slash; fatal (status 1, nothing written).
    prune_trailing_slash: []const u8,
    /// The temporary database could not be created or completely written;
    /// fatal (status 1). The old database is left as it was.
    create_failed: struct { tmp: []const u8, text: []const u8 },
    /// The finished database could not be moved into place; fatal (status 1).
    move_failed: struct { from: []const u8, to: []const u8, text: []const u8 },
    /// Nothing to write: "new database would be empty" (status stays 0).
    empty_database,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// What the executable exits with.
    status: u8 = 0,
};

const Error = error{OutOfMemory};

const U = struct {
    env: Env,
    /// Per-run arena.
    gpa: std.mem.Allocator,
    observer: Observer,
    paths: std.ArrayList([]u8) = .empty,
    prune_fs: std.ArrayList([]const u8) = .empty,
    prune_re: ?*regex.Regex = null,
    mounts: ?fu.Mounts = null,
    xdev: bool = false,
    depth_first: bool = false,
    maxdepth: i64 = -1,
    mindepth: i64 = 0,
};

fn devKey(s: sys.FileStat) u64 {
    return (@as(u64, s.dev_major) << 32) | s.dev_minor;
}

fn fsType(u: *U, dev: u64) Error![]const u8 {
    if (u.mounts == null) u.mounts = try fu.Mounts.load(u.gpa);
    return u.mounts.?.fsType(dev);
}

fn pruned(u: *U, display: []const u8, s: sys.FileStat) Error!bool {
    if (u.prune_fs.items.len > 0) {
        const t = try fsType(u, devKey(s));
        for (u.prune_fs.items) |p| {
            if (std.mem.eql(u8, p, t)) return true;
        }
    }
    if (s.isDir()) {
        if (u.prune_re) |re| {
            var sr = try rx.searcher(re, u.gpa);
            defer sr.deinit();
            // A name that cannot be matched (a matching limit) is left out
            // rather than published.
            const found = sr.find(display, 0) catch return true;
            if (found != null) return true;
        }
    }
    return false;
}

/// Record the file `name` in the open directory `parent` (a search path is
/// named by its path, from the current directory) and what is below it.
/// `display` is how the database names it. The walk is descriptor-relative
/// (dirat.zig): a symbolic link put where a directory was is never followed,
/// so names from elsewhere cannot end up under this one.
fn walk(u: *U, display: []const u8, parent: ?*dirat.Level, name: []const u8, depth: i64, root_dev: u64) Error!void {
    var err: LX.E = .SUCCESS;
    const s = sys.fileStatAt(dirat.fdOf(parent), name, false, &err) orelse return findError(u, display, err);
    if (try pruned(u, display, s)) return;
    const is_dir = s.isDir();
    var descend = is_dir and (u.maxdepth < 0 or depth < u.maxdepth);
    if (u.xdev and is_dir and depth > 0 and devKey(s) != root_dev) descend = false;
    if (!u.depth_first and depth >= u.mindepth) try addPath(u, display);
    if (descend) try walkContents(u, display, parent, name, s, depth, root_dev);
    // The directory this file is in may have been lost while below it.
    if (parent) |p| if (!p.open) return;
    if (u.depth_first and depth >= u.mindepth) try addPath(u, display);
}

fn findError(u: *U, path: []const u8, errno: LX.E) void {
    u.observer.emit(.{ .find_error = .{ .path = path, .text = sys.errnoText(errno) } });
}

fn walkContents(u: *U, display: []const u8, parent: ?*dirat.Level, name: []const u8, seen: sys.FileStat, depth: i64, root_dev: u64) Error!void {
    var level: dirat.Level = undefined;
    // With -xdev the directory opened must also be on the device examined.
    if (dirat.enter(&level, parent, name, .{ .expect = seen, .same_device = u.xdev })) |e| return findError(u, display, e);
    defer if (dirat.leave(&level)) |e| findError(u, display, e);
    var err: LX.E = .SUCCESS;
    const entries = sys.readDirNamesFd(u.env.gpa, level.fd, &err) orelse return findError(u, display, err);
    defer sys.freeDirEntries(u.env.gpa, entries);
    const base = if (display.len > 1 and display[display.len - 1] == '/') display[0 .. display.len - 1] else display;
    for (entries) |x| {
        if (!level.open) break;
        const cd = if (std.mem.eql(u8, base, "/")) try std.fmt.allocPrint(u.gpa, "/{s}", .{x.name}) else try std.fmt.allocPrint(u.gpa, "{s}/{s}", .{ base, x.name });
        defer u.gpa.free(cd);
        try walk(u, cd, &level, x.name, depth + 1, root_dev);
    }
}

fn addPath(u: *U, display: []const u8) Error!void {
    try u.paths.append(u.gpa, try u.gpa.dupe(u8, display));
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Front-code the (already sorted) names as frcode does.
pub fn encode(gpa: std.mem.Allocator, paths: []const []const u8, out: *std.ArrayList(u8), format: Format) error{OutOfMemory}!void {
    const slocate = format == .slocate;
    if (slocate) {
        try out.appendSlice(gpa, "1\x00");
    } else try out.appendSlice(gpa, "\x00LOCATE02\x00");
    var old: []const u8 = "";
    var oldcount: i64 = 0;
    var first = true;
    for (paths) |path| {
        var count: usize = 0;
        while (count < old.len and count < path.len and old[count] == path[count]) count += 1;
        var diff: i64 = @as(i64, @intCast(count)) - oldcount;
        var cnt: i64 = @intCast(count);
        if (diff > 32767 or diff < -32768) {
            cnt = 0;
            diff = -oldcount;
        }
        oldcount = cnt;
        if (slocate and first) {
            // no count for the first name
        } else if (diff < -127 or diff > 127) {
            try out.append(gpa, 0x80);
            const v: i16 = @intCast(diff);
            const uv: u16 = @bitCast(v);
            try out.append(gpa, @intCast(uv >> 8));
            try out.append(gpa, @intCast(uv & 0xff));
        } else {
            const v: i8 = @intCast(diff);
            try out.append(gpa, @bitCast(v));
        }
        first = false;
        try out.appendSlice(gpa, path[@intCast(cnt)..]);
        try out.append(gpa, 0);
        old = path;
    }
}

/// Shell pathname expansion of one unquoted word, as the updatedb script gets
/// it for $SEARCHPATHS, $NETPATHS and $PRUNEPATHS.
fn globExpand(u: *U, word: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    if (std.mem.indexOfAny(u8, word, "*?[") == null) {
        try out.append(u.gpa, word);
        return;
    }
    var cur: std.ArrayList([]const u8) = .empty;
    const absolute = word.len > 0 and word[0] == '/';
    try cur.append(u.gpa, if (absolute) "/" else "");
    var comps = std.mem.tokenizeScalar(u8, word, '/');
    while (comps.next()) |comp| {
        var next: std.ArrayList([]const u8) = .empty;
        const meta = std.mem.indexOfAny(u8, comp, "*?[") != null;
        for (cur.items) |base| {
            if (!meta) {
                const joined = try std.fmt.allocPrint(u.gpa, "{s}{s}{s}", .{ base, if (base.len == 0 or base[base.len - 1] == '/') "" else "/", comp });
                var e: LX.E = .SUCCESS;
                if (sys.fileStat(joined, false, &e) != null) try next.append(u.gpa, joined);
                continue;
            }
            var err: LX.E = .SUCCESS;
            const dir = if (base.len == 0) "." else base;
            const rd = sys.readDirRaw(u.gpa, dir, &err) orelse continue;
            var names: std.ArrayList([]u8) = .empty;
            for (rd) |x| {
                if (std.mem.eql(u8, x.name, ".") or std.mem.eql(u8, x.name, "..")) {
                    u.gpa.free(x.name);
                    continue;
                }
                if (x.name[0] == '.' and comp[0] != '.') {
                    u.gpa.free(x.name);
                    continue;
                }
                if (fnmatch.match(comp, x.name, .{})) try names.append(u.gpa, x.name) else u.gpa.free(x.name);
            }
            u.gpa.free(rd);
            std.mem.sort([]u8, names.items, {}, lessThan);
            for (names.items) |nm| {
                const joined = try std.fmt.allocPrint(u.gpa, "{s}{s}{s}", .{ base, if (base.len == 0 or base[base.len - 1] == '/') "" else "/", nm });
                try next.append(u.gpa, joined);
            }
        }
        cur = next;
    }
    if (cur.items.len == 0) {
        try out.append(u.gpa, word);
    } else for (cur.items) |c| try out.append(u.gpa, c);
}

fn walkRoot(u: *U, sp: []const u8, changeto: []const u8) Error!void {
    // the script runs find after `cd $changeto`
    const fs_path = if (sp.len > 0 and sp[0] == '/')
        sp
    else
        try std.fmt.allocPrint(u.gpa, "{s}/{s}", .{ if (std.mem.eql(u8, changeto, "/")) "" else changeto, sp });
    var err: LX.E = .SUCCESS;
    var root_dev: u64 = 0;
    if (sys.fileStat(fs_path, false, &err)) |s| root_dev = devKey(s);
    try walk(u, sp, null, fs_path, 0, root_dev);
}

/// Who a walk runs as, when that is not the caller.
const Walker = struct { name: []const u8, uid: u32, gid: u32, groups: []const u32 };

/// The identity to walk as for the user `name`; `.walker` is null when that
/// is who we are. Null on a failure, which has been reported.
fn lookupWalker(u: *U, name: []const u8) Error!?struct { walker: ?Walker } {
    var db = userdb.Db.load(u.gpa, u.env.io);
    defer db.deinit();
    const user = db.userByName(name) orelse {
        u.observer.emit(.{ .user_failed = .{ .user = name, .text = "no such user" } });
        return null;
    };
    const me = sys.identity();
    if (user.uid == me.euid) return .{ .walker = null };
    if (me.euid != 0) {
        u.observer.emit(.{ .user_failed = .{ .user = name, .text = "only root can search as another user" } });
        return null;
    }
    const groups = try db.groupsOf(u.gpa, name, user.gid);
    return .{ .walker = .{ .name = name, .uid = user.uid, .gid = user.gid, .groups = groups } };
}

/// Expand the shell patterns of the word list `list` and walk each path, as
/// `walker` if given. False when the identity could not be taken or given
/// back (reported); the database must then not be written.
fn walkPaths(u: *U, list: []const u8, changecwd: []const u8, walker: ?Walker) Error!bool {
    const who = walker orelse {
        try walkList(u, list, changecwd);
        return true;
    };
    const me = sys.identity();
    const my_groups = sys.supplementaryGroups(try u.gpa.alloc(u32, 65536));
    // The groups and group id first: changing them takes root's user id.
    var failure = sys.setThreadGroups(who.groups) orelse sys.setThreadEffectiveGid(who.gid) orelse sys.setThreadEffectiveUid(who.uid);
    var walked: Error!void = {};
    if (failure == null) walked = walkList(u, list, changecwd);
    // And in the opposite order on the way back, whatever happened.
    const back_uid = sys.setThreadEffectiveUid(me.euid);
    const back_gid = sys.setThreadEffectiveGid(me.egid);
    const back_groups = sys.setThreadGroups(my_groups);
    if (failure == null) failure = back_uid orelse back_gid orelse back_groups;
    try walked;
    if (failure) |e| {
        u.observer.emit(.{ .user_failed = .{ .user = who.name, .text = sys.errnoText(e) } });
        return false;
    }
    return true;
}

fn walkList(u: *U, list: []const u8, changecwd: []const u8) Error!void {
    var paths: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeAny(u8, list, " \t\n");
    while (words.next()) |w| try globExpand(u, w, &paths);
    for (paths.items) |sp| try walkRoot(u, sp, changecwd);
}

fn hasWords(list: []const u8) bool {
    return std.mem.indexOfNone(u8, list, " \t\n") != null;
}

/// Walk the search paths and front-code the sorted names. Returns the
/// database bytes (allocated from `env.gpa`; the caller frees), or null when
/// the options are unusable (an event has been emitted and `status` is set).
pub fn buildDatabase(env: Env, options: Options, observer: Observer, status: *u8) Error!?[]u8 {
    return build(env, options, observer, status, null);
}

/// `buildDatabase`; `stale_tmp` is removed after the options are validated
/// and before the walk, the order the script has.
fn build(env: Env, options: Options, observer: Observer, status: *u8, stale_tmp: ?[]const u8) Error!?[]u8 {
    var arena = std.heap.ArenaAllocator.init(env.gpa);
    defer arena.deinit();
    var u = U{ .env = env, .gpa = arena.allocator(), .observer = observer };
    const gpa = u.gpa;

    // pruned paths must not end in a slash
    var pwords: std.ArrayList([]const u8) = .empty;
    var pgl: std.ArrayList([]const u8) = .empty;
    var pit0 = std.mem.tokenizeAny(u8, options.prunepaths, " \t\n");
    while (pit0.next()) |w| try globExpand(&u, w, &pgl);
    // the shell's `echo $PRUNEPATHS` output is split on whitespace again
    for (pgl.items) |g| {
        var rs = std.mem.tokenizeAny(u8, g, " \t\n");
        while (rs.next()) |w| try pwords.append(gpa, w);
    }
    var pre_src: std.ArrayList(u8) = .empty;
    var npaths: usize = 0;
    for (pwords.items) |pp| {
        if (pp.len > 2 and pp[0] == '/' and pp[pp.len - 1] == '/') {
            observer.emit(.{ .prune_trailing_slash = pp });
            status.* = 1;
            return null;
        }
        if (npaths > 0) try pre_src.appendSlice(gpa, "\\|");
        try pre_src.print(gpa, "\\(^{s}$\\)", .{pp});
        npaths += 1;
    }
    // An error ends the walk but, as in the script, where it comes from find,
    // the (empty) database is still written and the status is 0.
    var find_failed = false;
    if (npaths > 0) {
        var failure: fu.RegexFailure = undefined;
        u.prune_re = fu.compileRegex(gpa, pre_src.items, .emacs, false, true, &failure) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadRegex => blk: {
                observer.emit(.{ .find_bad_regex = .{ .pattern = pre_src.items, .text = failure.text } });
                find_failed = true;
                break :blk null;
            },
        };
    }
    var fit = std.mem.tokenizeAny(u8, options.prunefs, " \t\n");
    while (fit.next()) |f| try u.prune_fs.append(gpa, f);
    // find options we understand
    var oit = std.mem.tokenizeAny(u8, options.findoptions, " \t\n");
    while (oit.next()) |o| {
        const m = std.mem.eql;
        if (m(u8, o, "-xdev") or m(u8, o, "-mount")) u.xdev = true else if (m(u8, o, "-depth") or m(u8, o, "-d")) u.depth_first = true else if (m(u8, o, "-noleaf") or m(u8, o, "-ignore_readdir_race") or m(u8, o, "-noignore_readdir_race") or m(u8, o, "-nowarn") or m(u8, o, "-warn")) {} else if (m(u8, o, "-maxdepth") or m(u8, o, "-mindepth")) {
            const v = oit.next() orelse "(";
            const n = numparse.parseInt(i64, v, 10) catch {
                observer.emit(.{ .find_bad_number = .{ .option = o, .value = v } });
                find_failed = true;
                break;
            };
            if (m(u8, o, "-maxdepth")) u.maxdepth = n else u.mindepth = n;
        } else {
            observer.emit(.{ .find_unknown_predicate = o });
            find_failed = true;
            break;
        }
    }

    // Both identities are settled before anything is touched.
    var local: ?Walker = null;
    if (options.localuser.len > 0 and hasWords(options.searchpaths)) {
        const found = try lookupWalker(&u, options.localuser) orelse {
            status.* = 1;
            return null;
        };
        local = found.walker;
    }
    var net: ?Walker = null;
    if (hasWords(options.netpaths) and sys.identity().euid == 0) {
        const found = try lookupWalker(&u, options.netuser) orelse {
            status.* = 1;
            return null;
        };
        net = found.walker;
    }

    if (stale_tmp) |t| _ = sys.unlinkPath(t, false);

    if (!find_failed) {
        // Read as ourselves: another user may not be able to.
        if (u.prune_fs.items.len > 0) u.mounts = try fu.Mounts.load(u.gpa);
        if (!try walkPaths(&u, options.searchpaths, options.changecwd, local) or
            !try walkPaths(&u, options.netpaths, options.changecwd, net))
        {
            status.* = 1;
            return null;
        }
    }

    std.mem.sort([]u8, u.paths.items, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(env.gpa);
    const names: []const []const u8 = @ptrCast(u.paths.items);
    try encode(env.gpa, names, &out, options.format);
    return try out.toOwnedSlice(env.gpa);
}

/// Build the database and install it at `options.output`.
pub fn run(env: Env, options: Options, observer: Observer) Error!Result {
    const tmp_name = try std.fmt.allocPrint(env.gpa, "{s}.n", .{options.output});
    defer env.gpa.free(tmp_name);
    var status: u8 = 0;
    const data = (try build(env, options, observer, &status, tmp_name)) orelse return .{ .status = status };
    defer env.gpa.free(data);

    var err: LX.E = .SUCCESS;
    var name_buf: std.ArrayList(u8) = .empty;
    defer name_buf.deinit(env.gpa);
    const new = (try createNew(env, tmp_name, &name_buf, &err)) orelse {
        observer.emit(.{ .create_failed = .{ .tmp = tmp_name, .text = sys.errnoText(err) } });
        return .{ .status = 1 };
    };
    const write_error = sys.writeAllFd(new.fd, data);
    // Readable by all, as the script's `chmod 644`; set through the
    // descriptor, so it cannot reach any other file.
    if (write_error == null) _ = sys.fchmodFd(new.fd, 0o644);
    // Some file systems report a failed write only here.
    const close_error = sys.closeFd(new.fd);
    if (write_error orelse close_error) |e| {
        _ = sys.unlinkPath(new.name, false);
        observer.emit(.{ .create_failed = .{ .tmp = tmp_name, .text = sys.errnoText(e) } });
        return .{ .status = 1 };
    }
    // `test -s`: a header alone still makes a non-empty file
    if (data.len > 0) {
        if (sys.renamePath(new.name, options.output, 0)) |e| {
            _ = sys.unlinkPath(new.name, false);
            observer.emit(.{ .move_failed = .{ .from = tmp_name, .to = options.output, .text = sys.errnoText(e) } });
            return .{ .status = 1 };
        }
    } else {
        observer.emit(.empty_database);
        _ = sys.unlinkPath(new.name, false);
    }
    return .{ .status = 0 };
}

const NewFile = struct { fd: sys.Handle, name: []const u8 };

/// Create the file the database is written to before it takes the output's
/// place: `<tmp_name>.XXXXXXXX`, new and ours alone. The script's fixed
/// `<output>.n` could be a link planted during the walk, or the file another
/// run is still writing. `name_buf` holds the name.
fn createNew(env: Env, tmp_name: []const u8, name_buf: *std.ArrayList(u8), err: *LX.E) Error!?NewFile {
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        var random: u32 = undefined;
        env.io.random(std.mem.asBytes(&random));
        name_buf.clearRetainingCapacity();
        try name_buf.print(env.gpa, "{s}.{x:0>8}", .{ tmp_name, random });
        if (sys.openFd(name_buf.items, sys.O.WRONLY | sys.O.CREAT | sys.O.EXCL, 0o600, err)) |fd| {
            return .{ .fd = fd, .name = name_buf.items };
        }
        if (err.* != .EXIST or attempts == 100) return null;
    }
}

test "encode front-codes sorted names" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encode(gpa, &.{ "/a", "/a/b", "/c" }, &out, .locate02);
    try std.testing.expectEqualSlices(u8, "\x00LOCATE02\x00" ++ "\x00/a\x00" ++ "\x02/b\x00" ++ "\xffc\x00", out.items);
}

test "encode slocate header and first name" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encode(gpa, &.{"/a"}, &out, .slocate);
    try std.testing.expectEqualSlices(u8, "1\x00/a\x00", out.items);
}
