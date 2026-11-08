//! updatedb — build the file-name database used by locate. Reference: GNU
//! findutils 4.10 (locate/updatedb.sh and frcode.c). The shell pipeline
//! `find | sort -z | frcode` is done in process: the tree is walked in
//! readdir order, pruned by path and file-system type, sorted bytewise and
//! front-coded. The -localuser/-netuser options (su) are not supported.

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const posixre = @import("../posixre.zig");
const regex = @import("regex");
const fnmatch = @import("../fnmatch.zig");
const LX = std.os.linux;
const Io = std.Io;

const default_prunepaths = "/afs /amd /proc /sfs /tmp /usr/tmp /var/tmp";
const default_prunefs = "9P NFS afs autofs cifs coda devfs devpts ftpfs fuse.s3fs iso9660 mfs ncpfs nfs nfs4 proc shfs smbfs sysfs";

const U = struct {
    ctx: cli.Context,
    gpa: std.mem.Allocator,
    paths: std.ArrayList([]u8) = .empty,
    prune_fs: std.ArrayList([]const u8) = .empty,
    prune_re: ?*regex.Regex = null,
    mounts: ?[]Mount = null,
    xdev: bool = false,
    depth_first: bool = false,
    maxdepth: i64 = -1,
    mindepth: i64 = 0,
    rc: u8 = 0,
};

const Mount = struct { dev: u64, fstype: []const u8 };

fn oom(ctx: cli.Context) noreturn {
    cli.warn(ctx, "memory exhausted", .{});
    std.process.exit(1);
}

fn devKey(s: sys.FileStat) u64 {
    return (@as(u64, s.dev_major) << 32) | s.dev_minor;
}

fn fsType(u: *U, dev: u64) []const u8 {
    if (u.mounts == null) {
        var list: std.ArrayList(Mount) = .empty;
        var err: LX.E = .SUCCESS;
        if (sys.openFd("/proc/self/mountinfo", sys.O.RDONLY, 0, &err)) |fd| {
            var data: std.ArrayList(u8) = .empty;
            var buf: [8192]u8 = undefined;
            while (true) {
                const k = sys.readFd(fd, &buf, &err) orelse break;
                if (k == 0) break;
                data.appendSlice(u.gpa, buf[0..k]) catch oom(u.ctx);
            }
            _ = sys.closeFd(fd);
            var lines = std.mem.splitScalar(u8, data.items, '\n');
            while (lines.next()) |ln| {
                var f = std.mem.tokenizeScalar(u8, ln, ' ');
                _ = f.next();
                _ = f.next();
                const mm = f.next() orelse continue;
                var seen_dash = false;
                var typ: []const u8 = "";
                while (f.next()) |tok| {
                    if (seen_dash) {
                        typ = tok;
                        break;
                    }
                    if (std.mem.eql(u8, tok, "-")) seen_dash = true;
                }
                const colon = std.mem.indexOfScalar(u8, mm, ':') orelse continue;
                const maj = std.fmt.parseInt(u32, mm[0..colon], 10) catch continue;
                const min = std.fmt.parseInt(u32, mm[colon + 1 ..], 10) catch continue;
                list.append(u.gpa, .{ .dev = (@as(u64, maj) << 32) | min, .fstype = u.gpa.dupe(u8, typ) catch oom(u.ctx) }) catch oom(u.ctx);
            }
        }
        u.mounts = list.items;
    }
    for (u.mounts.?) |m| {
        if (m.dev == dev) return m.fstype;
    }
    return "unknown";
}

fn findErr(u: *U, path: []const u8, text: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(u.gpa);
    buf.print(u.gpa, "find: '{s}': {s}\n", .{ path, text }) catch return;
    _ = sys.writeAllFd(2, buf.items);
}

fn pruned(u: *U, display: []const u8, s: sys.FileStat) bool {
    if (u.prune_fs.items.len > 0) {
        const t = fsType(u, devKey(s));
        for (u.prune_fs.items) |p| {
            if (std.mem.eql(u8, p, t)) return true;
        }
    }
    if (s.isDir()) {
        if (u.prune_re) |re| {
            var sr = re.searcher(u.gpa) catch oom(u.ctx);
            defer sr.deinit();
            if ((sr.find(display, 0) catch null) != null) return true;
        }
    }
    return false;
}

fn walk(u: *U, display: []const u8, fs_path: []const u8, depth: i64, root_dev: u64) void {
    var err: LX.E = .SUCCESS;
    const s = sys.fileStat(fs_path, false, &err) orelse {
        findErr(u, display, sys.errnoText(err));
        u.rc = 1;
        return;
    };
    if (pruned(u, display, s)) return;
    const is_dir = s.isDir();
    var descend = is_dir and (u.maxdepth < 0 or depth < u.maxdepth);
    if (u.xdev and is_dir and depth > 0 and devKey(s) != root_dev) descend = false;
    if (!u.depth_first and depth >= u.mindepth) addPath(u, display);
    if (descend) {
        if (sys.readDirRaw(u.gpa, fs_path, &err)) |rd| {
            defer {
                for (rd) |x| u.gpa.free(x.name);
                u.gpa.free(rd);
            }
            const base = if (display.len > 1 and display[display.len - 1] == '/') display[0 .. display.len - 1] else display;
            const fbase = if (fs_path.len > 1 and fs_path[fs_path.len - 1] == '/') fs_path[0 .. fs_path.len - 1] else fs_path;
            for (rd) |x| {
                if (std.mem.eql(u8, x.name, ".") or std.mem.eql(u8, x.name, "..")) continue;
                const cd = if (std.mem.eql(u8, base, "/")) std.fmt.allocPrint(u.gpa, "/{s}", .{x.name}) catch oom(u.ctx) else std.fmt.allocPrint(u.gpa, "{s}/{s}", .{ base, x.name }) catch oom(u.ctx);
                defer u.gpa.free(cd);
                const cf = if (std.mem.eql(u8, fbase, "/")) std.fmt.allocPrint(u.gpa, "/{s}", .{x.name}) catch oom(u.ctx) else std.fmt.allocPrint(u.gpa, "{s}/{s}", .{ fbase, x.name }) catch oom(u.ctx);
                defer u.gpa.free(cf);
                walk(u, cd, cf, depth + 1, root_dev);
            }
        } else {
            findErr(u, display, sys.errnoText(err));
            u.rc = 1;
        }
    }
    if (u.depth_first and depth >= u.mindepth) addPath(u, display);
}

fn addPath(u: *U, display: []const u8) void {
    u.paths.append(u.gpa, u.gpa.dupe(u8, display) catch oom(u.ctx)) catch oom(u.ctx);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn encode(u: *U, out: *std.ArrayList(u8), slocate: bool) void {
    if (slocate) {
        out.appendSlice(u.gpa, "1\x00") catch oom(u.ctx);
    } else out.appendSlice(u.gpa, "\x00LOCATE02\x00") catch oom(u.ctx);
    var old: []const u8 = "";
    var oldcount: i64 = 0;
    var first = true;
    for (u.paths.items) |path| {
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
            out.append(u.gpa, 0x80) catch oom(u.ctx);
            const v: i16 = @intCast(diff);
            const uv: u16 = @bitCast(v);
            out.append(u.gpa, @intCast(uv >> 8)) catch oom(u.ctx);
            out.append(u.gpa, @intCast(uv & 0xff)) catch oom(u.ctx);
        } else {
            const v: i8 = @intCast(diff);
            out.append(u.gpa, @bitCast(v)) catch oom(u.ctx);
        }
        first = false;
        out.appendSlice(u.gpa, path[@intCast(cnt)..]) catch oom(u.ctx);
        out.append(u.gpa, 0) catch oom(u.ctx);
        old = path;
    }
}

/// Shell pathname expansion of one unquoted word, as the updatedb script gets
/// it for $SEARCHPATHS, $NETPATHS and $PRUNEPATHS.
fn globExpand(u: *U, word: []const u8, out: *std.ArrayList([]const u8)) void {
    if (std.mem.indexOfAny(u8, word, "*?[") == null) {
        out.append(u.gpa, word) catch oom(u.ctx);
        return;
    }
    var cur: std.ArrayList([]const u8) = .empty;
    const absolute = word.len > 0 and word[0] == '/';
    cur.append(u.gpa, if (absolute) "/" else "") catch oom(u.ctx);
    var comps = std.mem.tokenizeScalar(u8, word, '/');
    while (comps.next()) |comp| {
        var next: std.ArrayList([]const u8) = .empty;
        const meta = std.mem.indexOfAny(u8, comp, "*?[") != null;
        for (cur.items) |base| {
            if (!meta) {
                const joined = std.fmt.allocPrint(u.gpa, "{s}{s}{s}", .{ base, if (base.len == 0 or base[base.len - 1] == '/') "" else "/", comp }) catch oom(u.ctx);
                var e: LX.E = .SUCCESS;
                if (sys.fileStat(joined, false, &e) != null) next.append(u.gpa, joined) catch oom(u.ctx);
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
                if (fnmatch.match(comp, x.name, .{})) names.append(u.gpa, x.name) catch oom(u.ctx) else u.gpa.free(x.name);
            }
            u.gpa.free(rd);
            std.mem.sort([]u8, names.items, {}, lessThan);
            for (names.items) |nm| {
                const joined = std.fmt.allocPrint(u.gpa, "{s}{s}{s}", .{ base, if (base.len == 0 or base[base.len - 1] == '/') "" else "/", nm }) catch oom(u.ctx);
                next.append(u.gpa, joined) catch oom(u.ctx);
            }
        }
        cur = next;
    }
    if (cur.items.len == 0) {
        out.append(u.gpa, word) catch oom(u.ctx);
    } else for (cur.items) |c| out.append(u.gpa, c) catch oom(u.ctx);
}

fn envOr(ctx: cli.Context, name: []const u8, default: []const u8) []const u8 {
    return cli.getenv(ctx, name) orelse default;
}

pub fn main(ctx: cli.Context) u8 {
    var u = U{ .ctx = ctx, .gpa = std.heap.smp_allocator };
    var findoptions = envOr(ctx, "FINDOPTIONS", "");
    var searchpaths = envOr(ctx, "SEARCHPATHS", "/");
    var netpaths = envOr(ctx, "NETPATHS", "");
    var prunepaths = envOr(ctx, "PRUNEPATHS", default_prunepaths);
    var prunefs = envOr(ctx, "PRUNEFS", default_prunefs);
    var locate_db = envOr(ctx, "LOCATE_DB", "/usr/local/var/locatedb");
    var changeto: []const u8 = "/";
    var dbformat: []const u8 = "";
    for (ctx.args) |arg| {
        const a: []const u8 = arg;
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const opt = if (eq) |k| a[0..k] else a;
        const val = if (eq) |k| a[k + 1 ..] else a;
        const m = std.mem.eql;
        if (m(u8, opt, "--findoptions")) findoptions = val else if (m(u8, opt, "--localpaths")) searchpaths = val else if (m(u8, opt, "--netpaths")) netpaths = val else if (m(u8, opt, "--prunepaths")) prunepaths = val else if (m(u8, opt, "--prunefs")) prunefs = val else if (m(u8, opt, "--output")) locate_db = val else if (m(u8, opt, "--netuser") or m(u8, opt, "--localuser")) {} else if (m(u8, opt, "--changecwd")) changeto = val else if (m(u8, opt, "--dbformat")) dbformat = val else if (m(u8, opt, "--version")) {
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
            const out = std.mem.replaceOwned(u8, u.gpa, t, "%s", ctx.name) catch return 1;
            return if (cli.writeStdout(ctx.io, out)) 0 else 1;
        } else {
            const msg = std.fmt.allocPrint(u.gpa, "updatedb: invalid option {s}\nTry '{s} --help' for more information.\n", .{ opt, ctx.name }) catch return 1;
            _ = sys.writeAllFd(2, msg);
            return 1;
        }
    }
    var slocate = false;
    if (dbformat.len > 0 and !std.mem.eql(u8, dbformat, "LOCATE02")) {
        if (std.mem.eql(u8, dbformat, "slocate")) slocate = true else {
            const msg = std.fmt.allocPrint(u.gpa, "Unsupported locate database format {s}: Supported formats are:\nLOCATE02, slocate\n", .{dbformat}) catch return 1;
            _ = sys.writeAllFd(2, msg);
            return 1;
        }
    }
    // pruned paths must not end in a slash
    var pwords: std.ArrayList([]const u8) = .empty;
    var pgl: std.ArrayList([]const u8) = .empty;
    var pit0 = std.mem.tokenizeAny(u8, prunepaths, " \t\n");
    while (pit0.next()) |w| globExpand(&u, w, &pgl);
    // the shell's `echo $PRUNEPATHS` output is split on whitespace again
    for (pgl.items) |g| {
        var rs = std.mem.tokenizeAny(u8, g, " \t\n");
        while (rs.next()) |w| pwords.append(u.gpa, w) catch oom(ctx);
    }
    var pre_src: std.ArrayList(u8) = .empty;
    var npaths: usize = 0;
    for (pwords.items) |pp| {
        if (pp.len > 2 and pp[0] == '/' and pp[pp.len - 1] == '/') {
            const msg = std.fmt.allocPrint(u.gpa, "{s}: {s}: pruned paths should not contain trailing slashes\n", .{ ctx.name, pp }) catch return 1;
            _ = sys.writeAllFd(2, msg);
            return 1;
        }
        if (npaths > 0) pre_src.appendSlice(u.gpa, "\\|") catch oom(ctx);
        pre_src.print(u.gpa, "\\(^{s}$\\)", .{pp}) catch oom(ctx);
        npaths += 1;
    }
    if (npaths > 0) {
        const conv = posixre.emacsToEre(u.gpa, pre_src.items, true);
        if (posixre.translateOpts(u.gpa, conv, true, .{})) |body| {
            const src = std.fmt.allocPrint(u.gpa, "(?s)\\A(?:{s})\\z", .{body}) catch oom(ctx);
            const re = u.gpa.create(regex.Regex) catch oom(ctx);
            if (regex.Regex.compile(u.gpa, src, .{ .dialect = .perl, .limits = posixre.big_limits }, null)) |r| {
                re.* = r;
                u.prune_re = re;
            } else |_| {}
        } else |_| {}
    }
    var fit = std.mem.tokenizeAny(u8, prunefs, " \t\n");
    while (fit.next()) |f| u.prune_fs.append(u.gpa, f) catch oom(ctx);
    // find options we understand; an error ends the walk but, as in the
    // script, the (empty) database is still written and the status is 0
    var find_failed = false;
    var oit = std.mem.tokenizeAny(u8, findoptions, " \t\n");
    while (oit.next()) |o| {
        const m = std.mem.eql;
        if (m(u8, o, "-xdev") or m(u8, o, "-mount")) u.xdev = true else if (m(u8, o, "-depth") or m(u8, o, "-d")) u.depth_first = true else if (m(u8, o, "-noleaf") or m(u8, o, "-ignore_readdir_race") or m(u8, o, "-noignore_readdir_race") or m(u8, o, "-nowarn") or m(u8, o, "-warn")) {} else if (m(u8, o, "-maxdepth") or m(u8, o, "-mindepth")) {
            const v = oit.next() orelse "(";
            const n = std.fmt.parseInt(i64, v, 10) catch {
                const msg = std.fmt.allocPrint(u.gpa, "find: Expected a positive decimal integer argument to {s}, but got '{s}'\n", .{ o, v }) catch return 1;
                _ = sys.writeAllFd(2, msg);
                find_failed = true;
                break;
            };
            if (m(u8, o, "-maxdepth")) u.maxdepth = n else u.mindepth = n;
        } else {
            const msg = std.fmt.allocPrint(u.gpa, "find: unknown predicate `{s}'\n", .{o}) catch return 1;
            _ = sys.writeAllFd(2, msg);
            find_failed = true;
            break;
        }
    }

    const tmp_name = std.fmt.allocPrint(u.gpa, "{s}.n", .{locate_db}) catch return 1;
    _ = sys.unlinkPath(tmp_name, false);

    if (!find_failed) {
        var sw: std.ArrayList([]const u8) = .empty;
        var sit = std.mem.tokenizeAny(u8, searchpaths, " \t\n");
        while (sit.next()) |w| globExpand(&u, w, &sw);
        for (sw.items) |sp| walkRoot(&u, sp, changeto);
        var nw: std.ArrayList([]const u8) = .empty;
        var nit = std.mem.tokenizeAny(u8, netpaths, " \t\n");
        while (nit.next()) |w| globExpand(&u, w, &nw);
        for (nw.items) |sp| walkRoot(&u, sp, changeto);
    }

    std.mem.sort([]u8, u.paths.items, {}, lessThan);
    var out: std.ArrayList(u8) = .empty;
    encode(&u, &out, slocate);
    var err: LX.E = .SUCCESS;
    const fd = sys.openFd(tmp_name, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, 0o644, &err) orelse {
        const msg = std.fmt.allocPrint(u.gpa, "{s}: {s}: {s}\nFailed to generate {s}\n", .{ ctx.name, tmp_name, sys.errnoText(err), tmp_name }) catch return 1;
        _ = sys.writeAllFd(2, msg);
        return 1;
    };
    _ = sys.writeAllFd(fd, out.items);
    _ = sys.closeFd(fd);
    // `test -s`: a header alone still makes a non-empty file
    if (out.items.len > 0) {
        _ = sys.chmodPath(tmp_name, 0o644, false);
        if (sys.renamePath(tmp_name, locate_db, 0)) |e| {
            const msg = std.fmt.allocPrint(u.gpa, "mv: cannot move '{s}' to '{s}': {s}\n", .{ tmp_name, locate_db, sys.errnoText(e) }) catch return 1;
            _ = sys.writeAllFd(2, msg);
            return 1;
        }
    } else {
        _ = sys.writeAllFd(2, "updatedb: new database would be empty\n");
        _ = sys.unlinkPath(tmp_name, false);
    }
    return 0;
}

fn walkRoot(u: *U, sp: []const u8, changeto: []const u8) void {
    // the script runs find after `cd $changeto`
    const fs_path = if (sp.len > 0 and sp[0] == '/')
        sp
    else
        std.fmt.allocPrint(u.gpa, "{s}/{s}", .{ if (std.mem.eql(u8, changeto, "/")) "" else changeto, sp }) catch oom(u.ctx);
    var err: LX.E = .SUCCESS;
    var root_dev: u64 = 0;
    if (sys.fileStat(fs_path, false, &err)) |s| root_dev = devKey(s);
    walk(u, sp, fs_path, 0, root_dev);
}
