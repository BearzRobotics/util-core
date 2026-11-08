//! tree — list directory contents in a tree-like format. Reference: tree 2.3.1
//! (Steve Baker et al.). Supported: the listing, sorting, filtering and
//! information options, -C colours, -A/-S line drawing, -X/-J output. Not
//! supported: -H HTML, --fromfile, --gitignore, --info, hyperlinks.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const fnmatch = @import("../fnmatch.zig");
const filevercmp = @import("../filevercmp.zig");
const unicode = @import("../unicode.zig");
const userdb = @import("../userdb.zig");
const strftime = @import("../strftime.zig");
const tzmod = @import("../tz.zig");
const LX = std.os.linux;
const Io = std.Io;

const help_text = @embedFile("../help/tree.txt");

const Sort = enum { name, version, mtime, ctime, size, none };
const Mode = enum { text, xml, json };

const Opts = struct {
    all: bool = false,
    dirs_only: bool = false,
    follow: bool = false,
    full_path: bool = false,
    xdev: bool = false,
    max_level: i64 = -1,
    patterns: std.ArrayList([]const u8) = .empty,
    ignores: std.ArrayList([]const u8) = .empty,
    icase: bool = false,
    matchdirs: bool = false,
    prune: bool = false,
    noreport: bool = false,
    charset: ?[]const u8 = null,
    filelimit: i64 = -1,
    out_file: ?[]const u8 = null,
    q: bool = false,
    raw: bool = false,
    quote: bool = false,
    perms: bool = false,
    user: bool = false,
    group: bool = false,
    size: bool = false,
    human: bool = false,
    si: bool = false,
    du: bool = false,
    date: bool = false,
    timefmt: ?[]const u8 = null,
    classify: bool = false,
    inodes: bool = false,
    device: bool = false,
    sort: Sort = .name,
    reverse: bool = false,
    dirsfirst: bool = false,
    filesfirst: bool = false,
    no_indent: bool = false,
    ansi: bool = false,
    cp437: bool = false,
    color: bool = false,
    mode: Mode = .text,
    utf8_locale: bool = false,
    use_utf8_lines: bool = false,
    entity_lines: bool = false,
};

const Entry = struct {
    name: []const u8,
    path: []const u8,
    lst: sys.FileStat,
    st: ?sys.FileStat, // followed stat, null when dangling
    is_dir: bool, // directory (or link to one)
    target: ?[]const u8 = null,
    du: u64 = 0,
};

const T = struct {
    ctx: cli.Context,
    gpa: std.mem.Allocator,
    o: Opts = .{},
    out: std.ArrayList(u8) = .empty,
    dirs: u64 = 0,
    files: u64 = 0,
    db: userdb.Db = undefined,
    db_loaded: bool = false,
    zone: tzmod.Zone = undefined,
    zone_loaded: bool = false,
    now: i64 = 0,
    colors: Colors = .{},
    root_dev: u64 = 0,
    exit_code: u8 = 0,
    total_du: u64 = 0,
    json_err: bool = false,
    visited: std.ArrayList(struct { dev: u64, ino: u64 }) = .empty,
};

const Colors = struct {
    di: []const u8 = "01;34",
    ln: []const u8 = "01;36",
    pi: []const u8 = "40;33",
    so: []const u8 = "01;35",
    bd: []const u8 = "40;33;01",
    cd: []const u8 = "40;33;01",
    or_: []const u8 = "40;31;01",
    mi: []const u8 = "00",
    su: []const u8 = "37;41",
    sg: []const u8 = "30;43",
    tw: []const u8 = "30;42",
    ow: []const u8 = "34;42",
    st: []const u8 = "37;44",
    ex: []const u8 = "01;32",
    fi: []const u8 = "",
    ext: std.ArrayList(struct { suffix: []const u8, code: []const u8 }) = .empty,
};

fn oom(ctx: cli.Context) noreturn {
    cli.warn(ctx, "memory exhausted", .{});
    std.process.exit(2);
}

fn put(t: *T, s: []const u8) void {
    t.out.appendSlice(t.gpa, s) catch oom(t.ctx);
}

fn putFmt(t: *T, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(t.gpa, fmt, args) catch oom(t.ctx);
    defer t.gpa.free(s);
    put(t, s);
}

fn flush(t: *T) void {
    if (t.out.items.len == 0) return;
    if (t.o.out_file == null) {
        _ = sys.writeAllFd(1, t.out.items);
    }
    t.out.clearRetainingCapacity();
}

// ----------------------------------------------------------------- names

fn escapeName(t: *T, name: []const u8, buf: *std.ArrayList(u8)) void {
    const o = &t.o;
    if (o.raw) {
        buf.appendSlice(t.gpa, name) catch oom(t.ctx);
        return;
    }
    var i: usize = 0;
    const utf8 = o.utf8_locale;
    while (i < name.len) {
        const c = name[i];
        if (utf8 and c >= 0x80) {
            const d = unicode.decode(name, i);
            if (d.valid) {
                buf.appendSlice(t.gpa, name[i .. i + d.len]) catch oom(t.ctx);
                i += d.len;
                continue;
            }
        }
        i += 1;
        if (o.q) {
            if (utf8) {
                if (c < 0x20 or c == 0x7f) buf.append(t.gpa, '?') catch oom(t.ctx) else buf.append(t.gpa, c) catch oom(t.ctx);
            } else {
                switch (c) {
                    '\\' => buf.appendSlice(t.gpa, "\\\\") catch oom(t.ctx),
                    ' ' => buf.appendSlice(t.gpa, "\\ ") catch oom(t.ctx),
                    '\n' => buf.appendSlice(t.gpa, "\\n") catch oom(t.ctx),
                    '\t' => buf.appendSlice(t.gpa, "\\t") catch oom(t.ctx),
                    else => if (c < 0x20 or c >= 0x7f) buf.append(t.gpa, '?') catch oom(t.ctx) else buf.append(t.gpa, c) catch oom(t.ctx),
                }
            }
            continue;
        }
        if (utf8) {
            if (c < 0x20 or c == 0x7f or c >= 0x80) {
                var b: [8]u8 = undefined;
                buf.appendSlice(t.gpa, std.fmt.bufPrint(&b, "\\{o:0>3}", .{c}) catch unreachable) catch oom(t.ctx);
            } else buf.append(t.gpa, c) catch oom(t.ctx);
        } else {
            switch (c) {
                '\\' => buf.appendSlice(t.gpa, "\\\\") catch oom(t.ctx),
                ' ' => if (o.quote) buf.append(t.gpa, ' ') catch oom(t.ctx) else buf.appendSlice(t.gpa, "\\ ") catch oom(t.ctx),
                '\n' => buf.appendSlice(t.gpa, "\\n") catch oom(t.ctx),
                '\t' => buf.appendSlice(t.gpa, "\\t") catch oom(t.ctx),
                '"' => if (o.quote) buf.appendSlice(t.gpa, "\\\"") catch oom(t.ctx) else buf.append(t.gpa, c) catch oom(t.ctx),
                else => if (c < 0x20 or c >= 0x7f) {
                    var b: [8]u8 = undefined;
                    buf.appendSlice(t.gpa, std.fmt.bufPrint(&b, "\\{o:0>3}", .{c}) catch unreachable) catch oom(t.ctx);
                } else buf.append(t.gpa, c) catch oom(t.ctx),
            }
        }
    }
}

fn typeCode(t: *T, e: *const Entry) []const u8 {
    const c = &t.colors;
    const m = e.lst.mode;
    switch (m & 0o170000) {
        0o120000 => {
            if (e.st == null and c.or_.len > 0) return c.or_;
            return c.ln;
        },
        0o040000 => {
            if (m & 0o1000 != 0 and m & 0o002 != 0 and c.tw.len > 0) return c.tw;
            if (m & 0o002 != 0 and c.ow.len > 0) return c.ow;
            if (m & 0o1000 != 0 and c.st.len > 0) return c.st;
            return c.di;
        },
        0o010000 => return c.pi,
        0o140000 => return c.so,
        0o060000 => return c.bd,
        0o020000 => return c.cd,
        else => {
            if (m & 0o4000 != 0 and c.su.len > 0) return c.su;
            if (m & 0o2000 != 0 and c.sg.len > 0) return c.sg;
            if (m & 0o111 != 0 and c.ex.len > 0) return c.ex;
            for (c.ext.items) |x| {
                if (std.mem.endsWith(u8, e.name, x.suffix)) return x.code;
            }
            return c.fi;
        },
    }
}

fn putName(t: *T, e: *const Entry, shown: []const u8, code: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.gpa);
    escapeName(t, shown, &buf);
    if (t.o.quote) put(t, "\"");
    if (t.o.color and code.len > 0) {
        put(t, "\x1b[");
        put(t, code);
        put(t, "m");
        put(t, buf.items);
        put(t, "\x1b[0m");
    } else put(t, buf.items);
    if (t.o.quote) put(t, "\"");
    _ = e;
}

// ----------------------------------------------------------------- info

fn modeStr(mode: u32, buf: *[10]u8) void {
    buf[0] = switch (mode & 0o170000) {
        0o100000 => '-',
        0o040000 => 'd',
        0o060000 => 'b',
        0o020000 => 'c',
        0o120000 => 'l',
        0o010000 => 'p',
        0o140000 => 's',
        else => '?',
    };
    buf[1] = if (mode & 0o400 != 0) 'r' else '-';
    buf[2] = if (mode & 0o200 != 0) 'w' else '-';
    buf[3] = if (mode & 0o4000 != 0) (if (mode & 0o100 != 0) @as(u8, 's') else 'S') else if (mode & 0o100 != 0) 'x' else '-';
    buf[4] = if (mode & 0o040 != 0) 'r' else '-';
    buf[5] = if (mode & 0o020 != 0) 'w' else '-';
    buf[6] = if (mode & 0o2000 != 0) (if (mode & 0o010 != 0) @as(u8, 's') else 'S') else if (mode & 0o010 != 0) 'x' else '-';
    buf[7] = if (mode & 0o004 != 0) 'r' else '-';
    buf[8] = if (mode & 0o002 != 0) 'w' else '-';
    buf[9] = if (mode & 0o1000 != 0) (if (mode & 0o001 != 0) @as(u8, 't') else 'T') else if (mode & 0o001 != 0) 'x' else '-';
}

fn humanSize(t: *T, n: u64, out: *std.ArrayList(u8)) void {
    const base: f64 = if (t.o.si) 1000.0 else 1024.0;
    const units = if (t.o.si) "kMGTPEZY" else "KMGTPEZY";
    if (n < @as(u64, @intFromFloat(base))) {
        out.print(t.gpa, "{d: >4}", .{n}) catch oom(t.ctx);
        return;
    }
    var v: f64 = @floatFromInt(n);
    var idx: usize = 0;
    while (v >= base and idx < units.len) {
        v /= base;
        idx += 1;
    }
    if (v >= 9.95) {
        out.print(t.gpa, "{d: >3.0}{c}", .{ @round(v), units[idx - 1] }) catch oom(t.ctx);
    } else out.print(t.gpa, "{d:.1}{c}", .{ v, units[idx - 1] }) catch oom(t.ctx);
}

fn ensureZone(t: *T) void {
    if (!t.zone_loaded) {
        t.zone = tzmod.load(t.gpa, t.ctx.io, cli.getenv(t.ctx, "TZ"));
        t.zone_loaded = true;
    }
}

fn infoFields(t: *T, e: *const Entry) bool {
    const o = &t.o;
    _ = e;
    return o.inodes or o.device or o.perms or o.user or o.group or o.size or o.human or o.date;
}

fn putInfo(t: *T, e: *const Entry) void {
    const o = &t.o;
    if (!infoFields(t, e)) return;
    const s = e.lst;
    var first = true;
    put(t, "[");
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(t.gpa);
    const sep = struct {
        fn go(tt: *T, f: *bool) void {
            if (!f.*) put(tt, " ");
            f.* = false;
        }
    }.go;
    if (o.inodes) {
        sep(t, &first);
        putFmt(t, "{d}", .{s.ino});
    }
    if (o.device) {
        sep(t, &first);
        putFmt(t, "{d}", .{(@as(u64, s.dev_major) << 8) | s.dev_minor});
    }
    if (o.perms) {
        sep(t, &first);
        var ms: [10]u8 = undefined;
        modeStr(s.mode, &ms);
        put(t, &ms);
    }
    if (o.user) {
        sep(t, &first);
        if (!t.db_loaded) {
            t.db = userdb.Db.load(t.gpa, t.ctx.io);
            t.db_loaded = true;
        }
        if (t.db.userByUid(s.uid)) |u| putFmt(t, "{s: <8}", .{u.name}) else putFmt(t, "{d: <8}", .{s.uid});
    }
    if (o.group) {
        sep(t, &first);
        if (!t.db_loaded) {
            t.db = userdb.Db.load(t.gpa, t.ctx.io);
            t.db_loaded = true;
        }
        if (t.db.groupByGid(s.gid)) |g| putFmt(t, "{s: <8}", .{g.name}) else putFmt(t, "{d: <8}", .{s.gid});
    }
    if (o.size or o.human) {
        sep(t, &first);
        const sz: u64 = if (o.du and e.is_dir and !e.lst.isLink()) e.du else s.size;
        if (o.human) {
            humanSize(t, sz, &tmp);
            put(t, tmp.items);
        } else putFmt(t, "{d: >11}", .{sz});
    }
    if (o.date) {
        sep(t, &first);
        ensureZone(t);
        const tm = tzmod.localtime(&t.zone, s.mtime_s);
        var tb: std.ArrayList(u8) = .empty;
        defer tb.deinit(t.gpa);
        if (o.timefmt) |f| {
            strftime.format(&tb, t.gpa, f, &tm, s.mtime_s, s.mtime_ns) catch oom(t.ctx);
        } else {
            const old = t.now - s.mtime_s > 182 * 86400 or s.mtime_s > t.now;
            strftime.format(&tb, t.gpa, if (old) "%b %e  %Y" else "%b %e %H:%M", &tm, s.mtime_s, s.mtime_ns) catch oom(t.ctx);
        }
        put(t, tb.items);
    }
    put(t, "]  ");
}

// --------------------------------------------------------------- listing

fn matchList(t: *T, list: []const []const u8, name: []const u8) bool {
    for (list) |pat| {
        var it = std.mem.splitScalar(u8, pat, '|');
        while (it.next()) |p| {
            if (p.len == 0) continue;
            if (fnmatch.match(p, name, .{ .casefold = t.o.icase })) return true;
        }
    }
    return false;
}

fn lessThan(t: *T, a: Entry, b: Entry) bool {
    const o = &t.o;
    if (o.dirsfirst and a.is_dir != b.is_dir) return a.is_dir;
    if (o.filesfirst and a.is_dir != b.is_dir) return !a.is_dir;
    var r: std.math.Order = .eq;
    switch (o.sort) {
        .name => r = std.mem.order(u8, a.name, b.name),
        .version => r = std.math.order(filevercmp.cmp(a.name, b.name), 0),
        .mtime => {
            r = std.math.order(a.lst.mtime_s, b.lst.mtime_s);
            if (r == .eq) r = std.mem.order(u8, a.name, b.name);
        },
        .ctime => {
            r = std.math.order(a.lst.ctime_s, b.lst.ctime_s);
            if (r == .eq) r = std.mem.order(u8, a.name, b.name);
        },
        .size => {
            r = std.math.order(b.lst.size, a.lst.size);
            if (r == .eq) r = std.mem.order(u8, a.name, b.name);
        },
        .none => return false,
    }
    if (o.reverse) return r == .gt;
    return r == .lt;
}

fn listDir(t: *T, path: []const u8, err: *LX.E) ?[]Entry {
    const raw = sys.readDirRaw(t.gpa, path, err) orelse return null;
    defer {
        for (raw) |x| t.gpa.free(x.name);
        t.gpa.free(raw);
    }
    var list: std.ArrayList(Entry) = .empty;
    for (raw) |r| {
        if (std.mem.eql(u8, r.name, ".") or std.mem.eql(u8, r.name, "..")) continue;
        if (!t.o.all and r.name.len > 0 and r.name[0] == '.') continue;
        const base = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
        const child = if (std.mem.eql(u8, base, "/"))
            std.fmt.allocPrint(t.gpa, "/{s}", .{r.name}) catch oom(t.ctx)
        else
            std.fmt.allocPrint(t.gpa, "{s}/{s}", .{ base, r.name }) catch oom(t.ctx);
        var e2: LX.E = .SUCCESS;
        const lst = sys.fileStat(child, false, &e2) orelse continue;
        var st: ?sys.FileStat = lst;
        var is_dir = lst.isDir();
        var target: ?[]const u8 = null;
        if (lst.isLink()) {
            var buf: [4096]u8 = undefined;
            var e3: LX.E = .SUCCESS;
            if (sys.readlinkPath(child, &buf, &e3)) |k| target = t.gpa.dupe(u8, buf[0..k]) catch oom(t.ctx);
            st = sys.fileStat(child, true, &e3);
            is_dir = if (st) |s| s.isDir() else false;
        }
        const name = t.gpa.dupe(u8, r.name) catch oom(t.ctx);
        list.append(t.gpa, .{ .name = name, .path = child, .lst = lst, .st = st, .is_dir = is_dir, .target = target }) catch oom(t.ctx);
    }
    const items = list.toOwnedSlice(t.gpa) catch oom(t.ctx);
    if (t.o.sort != .none or t.o.dirsfirst or t.o.filesfirst) {
        std.mem.sort(Entry, items, t, struct {
            fn lt(tt: *T, a: Entry, b: Entry) bool {
                return lessThan(tt, a, b);
            }
        }.lt);
    }
    return items;
}

/// Is the entry listed? `unf` disables -P (inside a directory that matched
/// under --matchdirs).
fn visibleEntry(t: *T, e: *const Entry, level: i64, unf: bool) bool {
    const o = &t.o;
    if (matchList(t, o.ignores.items, e.name)) return false;
    if (e.lst.isDir()) {
        if (o.prune and !o.dirs_only) return hasVisible(t, e.path, level + 1, unf);
        return true;
    }
    if (o.dirs_only) {
        return e.is_dir;
    }
    if (o.prune and e.is_dir and !o.follow) return false;
    if (o.patterns.items.len > 0 and !unf and !matchList(t, o.patterns.items, e.name)) return false;
    return true;
}

fn passes(t: *T, e: *const Entry) bool {
    return visibleEntry(t, e, 0, false);
}

fn hasVisible(t: *T, path: []const u8, level: i64, unf: bool) bool {
    var err: LX.E = .SUCCESS;
    const items = listDir(t, path, &err) orelse return false;
    defer freeEntries(t, items);
    for (items) |*e| {
        if (!visibleEntry(t, e, level, unf)) continue;
        if (!e.lst.isDir()) return true;
        if (t.o.max_level >= 0 and level >= t.o.max_level) return true;
        return true;
    }
    return false;
}

const Frame = struct { last: bool };

fn putIndent(t: *T, frames: []const Frame) void {
    const o = &t.o;
    if (o.no_indent) return;
    for (frames) |f| {
        if (o.ansi) {
            if (f.last) put(t, "    ") else put(t, "\x1b(0x  \x1b(B ");
        } else if (o.cp437) {
            if (f.last) put(t, "    ") else put(t, "\xb3   ");
        } else if (o.use_utf8_lines) {
            if (f.last) put(t, "    ") else put(t, "\xe2\x94\x82\xc2\xa0\xc2\xa0 ");
        } else {
            if (f.last) put(t, "    ") else put(t, "|   ");
        }
    }
}

fn putConnector(t: *T, last: bool) void {
    const o = &t.o;
    if (o.no_indent) return;
    if (o.ansi) {
        put(t, if (last) "\x1b(0mqq\x1b(B " else "\x1b(0tqq\x1b(B ");
    } else if (o.cp437) {
        put(t, if (last) "\xc0\xc4\xc4 " else "\xc3\xc4\xc4 ");
    } else if (o.use_utf8_lines) {
        put(t, if (last) "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 " else "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ");
    } else if (o.entity_lines) {
        put(t, if (last) "&middot;-- " else "|-- ");
    } else put(t, if (last) "`-- " else "|-- ");
}

fn classifyChar(e: *const Entry) u8 {
    if (e.lst.isLink()) {
        const s = e.st orelse return 0;
        const tm = s.mode;
        return switch (tm & 0o170000) {
            0o040000 => '/',
            0o010000 => '|',
            0o140000 => '=',
            0o100000 => if (tm & 0o111 != 0) '*' else 0,
            else => 0,
        };
    }
    const m = e.lst.mode;
    return switch (m & 0o170000) {
        0o040000 => '/',
        0o120000 => '@',
        0o010000 => '|',
        0o140000 => '=',
        0o100000 => if (m & 0o111 != 0) '*' else 0,
        else => 0,
    };
}

/// Size of `e` with everything listed below it (--du).
fn duOf(t: *T, e: *Entry, level: i64, unf: bool) u64 {
    var total: u64 = e.lst.size;
    if (!e.is_dir or (e.lst.isLink() and !t.o.follow)) return total;
    if (t.o.max_level >= 0 and level + 1 >= t.o.max_level) return total;
    var err: LX.E = .SUCCESS;
    const items = listDir(t, e.path, &err) orelse return total;
    defer freeEntries(t, items);
    var child_unf = unf;
    if (t.o.matchdirs and t.o.patterns.items.len > 0 and matchList(t, t.o.patterns.items, e.name)) child_unf = true;
    for (items) |*c| {
        if (!visibleEntry(t, c, level + 1, child_unf)) continue;
        total += duOf(t, c, level + 1, child_unf);
    }
    return total;
}

fn freeEntries(t: *T, items: []Entry) void {
    for (items) |e| {
        t.gpa.free(e.name);
        t.gpa.free(e.path);
        if (e.target) |tg| t.gpa.free(tg);
    }
    t.gpa.free(items);
}

fn emitEntryText(t: *T, e: *const Entry, frames: []const Frame, last: bool, shown_name: []const u8, note: ?[]const u8) void {
    putIndent(t, frames);
    putConnector(t, last);
    putInfo(t, e);
    const code = if (t.o.color) typeCode(t, e) else "";
    putName(t, e, shown_name, code);
    if (e.target) |tg| {
        put(t, " -> ");
        var tcode: []const u8 = "";
        if (t.o.color) {
            if (t.o.follow or true) {
                var tmp = e.*;
                if (e.st) |s| {
                    tmp.lst = s;
                    tmp.name = tg;
                    tcode = typeCode(t, &tmp);
                } else tcode = t.colors.mi;
            }
        }
        putName(t, e, tg, tcode);
    }
    if (t.o.classify) {
        const c = classifyChar(e);
        if (c != 0) put(t, &[_]u8{c});
    }
    if (note) |n| {
        put(t, "  ");
        put(t, n);
    }
    put(t, "\n");
}

fn jsonEsc(t: *T, s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => put(t, "\\\""),
        '\\' => put(t, "\\\\"),
        '\n' => put(t, "\\n"),
        '\t' => put(t, "\\t"),
        '\r' => put(t, "\\r"),
        8 => put(t, "\\b"),
        12 => put(t, "\\f"),
        else => if (c < 0x20) putFmt(t, "\\u{x:0>4}", .{c}) else put(t, &[_]u8{c}),
    };
}

fn xmlEsc(t: *T, s: []const u8) void {
    for (s) |c| switch (c) {
        '"' => put(t, "&quot;"),
        '&' => put(t, "&amp;"),
        '<' => put(t, "&lt;"),
        '>' => put(t, "&gt;"),
        else => put(t, &[_]u8{c}),
    };
}

fn typeName(e: *const Entry) []const u8 {
    return switch (e.lst.mode & 0o170000) {
        0o040000 => "directory",
        0o120000 => "link",
        0o010000 => "fifo",
        0o140000 => "socket",
        0o060000 => "block",
        0o020000 => "char",
        else => "file",
    };
}

fn putAttrs(t: *T, e: *const Entry, json: bool) void {
    const o = &t.o;
    const s = e.lst;
    var ms: [10]u8 = undefined;
    modeStr(s.mode, &ms);
    if (json) {
        if (o.inodes) putFmt(t, ",\"inode\":{d}", .{s.ino});
        if (o.device) putFmt(t, ",\"dev\":{d}", .{(@as(u64, s.dev_major) << 8) | s.dev_minor});
        if (o.perms) putFmt(t, ",\"mode\":\"{o:0>4}\",\"prot\":\"{s}\"", .{ s.mode & 0o7777, ms[0..] });
        if (o.user) {
            loadDb(t);
            if (t.db.userByUid(s.uid)) |u| putFmt(t, ",\"user\":\"{s}\"", .{u.name}) else putFmt(t, ",\"user\":{d}", .{s.uid});
        }
        if (o.group) {
            loadDb(t);
            if (t.db.groupByGid(s.gid)) |g| putFmt(t, ",\"group\":\"{s}\"", .{g.name}) else putFmt(t, ",\"group\":{d}", .{s.gid});
        }
        if (o.size or o.human) putFmt(t, ",\"size\":{d}", .{if (o.du and e.is_dir) e.du else s.size});
        if (o.date) {
            ensureZone(t);
            const tm = tzmod.localtime(&t.zone, s.mtime_s);
            var tb: std.ArrayList(u8) = .empty;
            defer tb.deinit(t.gpa);
            strftime.format(&tb, t.gpa, "%FT%T%z", &tm, s.mtime_s, 0) catch {};
            putFmt(t, ",\"time\":\"{s}\"", .{tb.items});
        }
    } else {
        if (o.inodes) putFmt(t, " inode=\"{d}\"", .{s.ino});
        if (o.device) putFmt(t, " dev=\"{d}\"", .{(@as(u64, s.dev_major) << 8) | s.dev_minor});
        if (o.perms) putFmt(t, " mode=\"{o:0>4}\" prot=\"{s}\"", .{ s.mode & 0o7777, ms[0..] });
        if (o.user) {
            loadDb(t);
            if (t.db.userByUid(s.uid)) |u| putFmt(t, " user=\"{s}\"", .{u.name}) else putFmt(t, " user=\"{d}\"", .{s.uid});
        }
        if (o.group) {
            loadDb(t);
            if (t.db.groupByGid(s.gid)) |g| putFmt(t, " group=\"{s}\"", .{g.name}) else putFmt(t, " group=\"{d}\"", .{s.gid});
        }
        if (o.size or o.human) putFmt(t, " size=\"{d}\"", .{if (o.du and e.is_dir) e.du else s.size});
        if (o.date) {
            ensureZone(t);
            const tm = tzmod.localtime(&t.zone, s.mtime_s);
            var tb: std.ArrayList(u8) = .empty;
            defer tb.deinit(t.gpa);
            const old = t.now - s.mtime_s > 182 * 86400 or s.mtime_s > t.now;
            strftime.format(&tb, t.gpa, if (old) "%b %e  %Y" else "%b %e %H:%M", &tm, s.mtime_s, 0) catch {};
            putFmt(t, " time=\"{s}\"", .{tb.items});
        }
    }
}

fn loadDb(t: *T) void {
    if (!t.db_loaded) {
        t.db = userdb.Db.load(t.gpa, t.ctx.io);
        t.db_loaded = true;
    }
}

fn canOpen(path: []const u8) bool {
    var err: LX.E = .SUCCESS;
    const fd = sys.openFd(path, sys.O.RDONLY | sys.O.DIRECTORY, 0, &err) orelse return false;
    _ = sys.closeFd(fd);
    return true;
}

fn countVisible(t: *T, path: []const u8) i64 {
    var err: LX.E = .SUCCESS;
    const rd = sys.readDirRaw(t.gpa, path, &err) orelse return 0;
    var n: i64 = 0;
    for (rd) |x| {
        if (!std.mem.eql(u8, x.name, ".") and !std.mem.eql(u8, x.name, "..") and (t.o.all or x.name[0] != '.')) n += 1;
        t.gpa.free(x.name);
    }
    t.gpa.free(rd);
    return n;
}

fn seen(t: *T, s: sys.FileStat) bool {
    const key = (@as(u64, s.dev_major) << 32) | s.dev_minor;
    for (t.visited.items) |v| {
        if (v.ino == s.ino and v.dev == key) return true;
    }
    return false;
}

fn walk(t: *T, path: []const u8, level: i64, frames: *std.ArrayList(Frame), dev: u64, unf: bool) void {
    const o = &t.o;
    var err: LX.E = .SUCCESS;
    const items = listDir(t, path, &err) orelse return;
    defer freeEntries(t, items);
    var shown: std.ArrayList(*Entry) = .empty;
    defer shown.deinit(t.gpa);
    for (items) |*e| {
        if (!visibleEntry(t, e, level, unf)) continue;
        shown.append(t.gpa, e) catch oom(t.ctx);
    }
    for (shown.items, 0..) |e, idx| {
        const last = idx + 1 == shown.items.len;
        if (o.du and e.is_dir) e.du = duOf(t, e, level, unf);
        const display: []const u8 = if (o.full_path) e.path else e.name;
        const into_dir = e.is_dir and (!e.lst.isLink() or o.follow);
        if (e.is_dir) t.dirs += 1 else t.files += 1;
        var note: ?[]const u8 = null;
        var descend = into_dir;
        if (descend and o.max_level >= 0 and level + 1 >= o.max_level) descend = false;
        if (descend and o.xdev) {
            const sx = e.st orelse e.lst;
            if ((@as(u64, sx.dev_major) << 32 | sx.dev_minor) != dev) descend = false;
        }
        if (descend and e.lst.isLink()) {
            if (seen(t, e.st.?)) {
                note = "[recursive, not followed]";
                descend = false;
            }
        }
        var note_buf: [96]u8 = undefined;
        if (descend and !canOpen(e.path)) {
            note = "[error opening dir]";
            descend = false;
            if (!o.du and !(o.matchdirs and o.patterns.items.len > 0)) t.exit_code = 2;
        }
        if (descend and o.filelimit > 0) {
            const n = countVisible(t, e.path);
            if (n > o.filelimit) {
                note = std.fmt.bufPrint(&note_buf, "[{d} entries exceeds filelimit, not opening dir]", .{n}) catch null;
                descend = false;
            }
        }
        if (e.lst.isDir()) t.visited.append(t.gpa, .{ .dev = (@as(u64, e.lst.dev_major) << 32) | e.lst.dev_minor, .ino = e.lst.ino }) catch {};
        emitEntryText(t, e, frames.items, last, display, note);
        if (!descend) continue;
        const sx = e.st orelse e.lst;
        if (e.lst.isLink()) t.visited.append(t.gpa, .{ .dev = @as(u64, sx.dev_major) << 32 | sx.dev_minor, .ino = sx.ino }) catch {};
        frames.append(t.gpa, .{ .last = last }) catch oom(t.ctx);
        var child_unf = unf;
        if (o.matchdirs and o.patterns.items.len > 0 and matchList(t, o.patterns.items, e.name)) child_unf = true;
        walk(t, e.path, level + 1, frames, dev, child_unf);
        _ = frames.pop();
    }
}

// ---- structured output

fn walkStruct(t: *T, path: []const u8, level: i64, indent: usize, json: bool, dev: u64) void {
    const o = &t.o;
    var err: LX.E = .SUCCESS;
    const items = listDir(t, path, &err) orelse return;
    defer freeEntries(t, items);
    var shown: std.ArrayList(*Entry) = .empty;
    defer shown.deinit(t.gpa);
    for (items) |*e| {
        if (!passes(t, e)) continue;
        if (o.prune and e.is_dir and !(e.lst.isLink() and !o.follow)) {
            if (!hasVisible(t, e.path, level, false)) continue;
        }
        shown.append(t.gpa, e) catch oom(t.ctx);
    }
    for (shown.items, 0..) |e, idx| {
        const last = idx + 1 == shown.items.len;
        if (o.du and e.is_dir) e.du = duOf(t, e, level, false);
        const into_dir = e.is_dir and (!e.lst.isLink() or o.follow);
        if (e.is_dir) t.dirs += 1 else t.files += 1;
        const descend = into_dir and !(o.max_level >= 0 and level + 1 >= o.max_level) and !(o.xdev and (@as(u64, (e.st orelse e.lst).dev_major) << 32 | (e.st orelse e.lst).dev_minor) != dev);
        structEntry(t, e, indent, json, last, descend, level, dev);
    }
}

fn pad(t: *T, n: usize) void {
    t.out.appendNTimes(t.gpa, ' ', n * 4) catch oom(t.ctx);
}

fn structEntry(t: *T, e: *Entry, indent: usize, json: bool, last: bool, descend: bool, level: i64, dev: u64) void {
    const tn = typeName(e);
    pad(t, indent);
    var has_children = false;
    var unreadable = false;
    if (descend and !canOpen(e.path)) {
        unreadable = true;
        t.exit_code = 2;
    }
    if (descend and !unreadable) {
        var err: LX.E = .SUCCESS;
        if (listDir(t, e.path, &err)) |ch| {
            defer freeEntries(t, ch);
            for (ch) |*c| {
                if (passes(t, c)) has_children = true;
            }
        }
    }
    if (json) {
        put(t, "{\"type\":\"");
        put(t, tn);
        put(t, "\",\"name\":\"");
        jsonEsc(t, e.name);
        put(t, "\"");
        if (e.target) |tg| {
            put(t, ",\"target\":\"");
            jsonEsc(t, tg);
            put(t, "\"");
        }
        putAttrs(t, e, true);
        if (unreadable) {
            put(t, ",\"contents\":[{\"error\": \"error opening dir\"}    ]}");
            t.json_err = true;
        } else if (descend and has_children) {
            put(t, ",\"contents\":[\n");
            walkStruct(t, e.path, level + 1, indent + 1, true, dev);
            pad(t, indent);
            put(t, "]}");
        } else if (t.json_err and !e.lst.isDir()) {
            put(t, ",\"contents\":[    ]}");
        } else put(t, "}");
        put(t, if (last) "\n" else ",\n");
    } else {
        put(t, "<");
        put(t, tn);
        put(t, " name=\"");
        xmlEsc(t, e.name);
        put(t, "\"");
        if (e.target) |tg| {
            put(t, " target=\"");
            xmlEsc(t, tg);
            put(t, "\"");
        }
        putAttrs(t, e, false);
        put(t, ">");
        if (unreadable) {
            put(t, "<error>error opening dir</error>");
        } else if (descend and has_children) {
            put(t, "\n");
            walkStruct(t, e.path, level + 1, indent + 1, false, dev);
            pad(t, indent);
        }
        put(t, "</");
        put(t, tn);
        put(t, ">\n");
    }
}

// --------------------------------------------------------------- options

fn parseColors(t: *T) void {
    const env = cli.getenv(t.ctx, "LS_COLORS") orelse return;
    if (env.len == 0) {
        t.colors.fi = "00";
        t.colors.tw = "";
        t.colors.ow = "";
        t.colors.st = "";
        t.colors.su = "";
        t.colors.sg = "";
        return;
    }
    t.colors = .{ .di = "", .ln = "", .pi = "", .so = "", .bd = "", .cd = "", .or_ = "", .mi = "", .su = "", .sg = "", .tw = "", .ow = "", .st = "", .ex = "" };
    var it = std.mem.splitScalar(u8, env, ':');
    while (it.next()) |item| {
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        const k = item[0..eq];
        const v = item[eq + 1 ..];
        const c = &t.colors;
        var plain = v.len > 0;
        for (v) |ch| {
            if (!std.ascii.isDigit(ch) and ch != ';') plain = false;
        }
        if (!plain) continue;
        if (std.mem.eql(u8, k, "fi")) c.fi = v else if (std.mem.eql(u8, k, "di")) c.di = v else if (std.mem.eql(u8, k, "ln")) c.ln = v else if (std.mem.eql(u8, k, "pi")) c.pi = v else if (std.mem.eql(u8, k, "so")) c.so = v else if (std.mem.eql(u8, k, "bd")) c.bd = v else if (std.mem.eql(u8, k, "cd")) c.cd = v else if (std.mem.eql(u8, k, "or")) c.or_ = v else if (std.mem.eql(u8, k, "mi")) c.mi = v else if (std.mem.eql(u8, k, "su")) c.su = v else if (std.mem.eql(u8, k, "sg")) c.sg = v else if (std.mem.eql(u8, k, "tw")) c.tw = v else if (std.mem.eql(u8, k, "ow")) c.ow = v else if (std.mem.eql(u8, k, "st")) c.st = v else if (std.mem.eql(u8, k, "ex")) c.ex = v else if (k.len > 1 and k[0] == '*') {
            c.ext.append(t.gpa, .{ .suffix = k[1..], .code = v }) catch {};
        }
    }
}

fn localeIsUtf8(ctx: cli.Context) bool {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |k| {
        const v = cli.getenv(ctx, k) orelse continue;
        if (v.len == 0) continue;
        return std.ascii.findIgnoreCase(v, "utf-8") != null or std.ascii.findIgnoreCase(v, "utf8") != null;
    }
    return false;
}

pub fn main(ctx: cli.Context) u8 {
    var t = T{ .ctx = ctx, .gpa = std.heap.smp_allocator };
    t.o.utf8_locale = localeIsUtf8(ctx);
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
    var force_no_color = false;
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
            return usageErr(&t);
        },
        .opt => |opt| switch (opt.id) {
            'a' => t.o.all = true,
            'd' => t.o.dirs_only = true,
            'l' => t.o.follow = true,
            'f' => t.o.full_path = true,
            'x' => t.o.xdev = true,
            'L' => {
                const v = std.fmt.parseInt(i64, opt.arg.?, 10) catch {
                    cli.warn(ctx, "Invalid level, must be greater than 0.", .{});
                    return 1;
                };
                if (v < 1) {
                    cli.warn(ctx, "Invalid level, must be greater than 0.", .{});
                    return 1;
                }
                t.o.max_level = v;
            },
            'P' => t.o.patterns.append(t.gpa, opt.arg.?) catch oom(ctx),
            'I' => t.o.ignores.append(t.gpa, opt.arg.?) catch oom(ctx),
            'o' => t.o.out_file = opt.arg.?,
            'q' => t.o.q = true,
            'N' => t.o.raw = true,
            'Q' => t.o.quote = true,
            'p' => t.o.perms = true,
            'u' => t.o.user = true,
            'g' => t.o.group = true,
            's' => t.o.size = true,
            'h' => {
                t.o.human = true;
                t.o.size = true;
            },
            'D' => t.o.date = true,
            'F' => t.o.classify = true,
            'v' => t.o.sort = .version,
            't' => t.o.sort = .mtime,
            'c' => t.o.sort = .ctime,
            'U' => t.o.sort = .none,
            'r' => t.o.reverse = true,
            'i' => t.o.no_indent = true,
            'A' => t.o.ansi = true,
            'S' => t.o.cp437 = true,
            'n' => force_no_color = true,
            'C' => t.o.color = true,
            'X' => t.o.mode = .xml,
            'J' => t.o.mode = .json,
            'T', 'H', 'R' => {},
            2000 => {
                const v = if (t.o.utf8_locale) "tree v2.3.1 \u{a9} 1996 - 2026 by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser, Kyosuke Tokoro\n" else "tree v2.3.1 (c) 1996 - 2026 by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser, Kyosuke Tokoro\n";
                return if (cli.writeStdout(ctx.io, v)) 0 else 1;
            },
            2001 => {
                if (t.o.utf8_locale) {
                    const h = std.mem.replaceOwned(u8, t.gpa, help_text, "(c)", "\u{a9}") catch return 1;
                    return if (cli.writeStdout(ctx.io, h)) 0 else 1;
                }
                return if (cli.writeStdout(ctx.io, help_text)) 0 else 1;
            },
            2002 => t.o.inodes = true,
            2003 => t.o.device = true,
            2004 => t.o.noreport = true,
            2006 => t.o.dirsfirst = true,
            2007 => t.o.filesfirst = true,
            2008 => t.o.matchdirs = true,
            2010 => t.o.prune = true,
            2011 => {
                t.o.si = true;
                t.o.human = true;
                t.o.size = true;
            },
            2012 => {
                t.o.du = true;
                t.o.size = true;
            },
            2013 => t.o.icase = true,
            2014 => t.o.charset = opt.arg.?,
            2015 => t.o.filelimit = std.fmt.parseInt(i64, opt.arg.?, 10) catch -1,
            2016 => {
                t.o.timefmt = opt.arg.?;
                t.o.date = true;
            },
            2017 => {
                const a = opt.arg.?;
                if (std.mem.eql(u8, a, "name")) t.o.sort = .name else if (std.mem.eql(u8, a, "version")) t.o.sort = .version else if (std.mem.eql(u8, a, "size")) t.o.sort = .size else if (std.mem.eql(u8, a, "mtime")) t.o.sort = .mtime else if (std.mem.eql(u8, a, "ctime")) t.o.sort = .ctime else if (std.mem.eql(u8, a, "none")) t.o.sort = .none else {
                    cli.writeStderrNoNl(ctx, "tree: Sort type '{s}' not valid, should be one of: ", .{a});
                    _ = cli.writeStdout(ctx.io, "name,version,size,mtime,ctime,none\n");
                    return 1;
                }
            },
            else => {},
        },
    };
    t.o.use_utf8_lines = t.o.utf8_locale;
    if (t.o.charset) |cs| {
        t.o.use_utf8_lines = std.ascii.eqlIgnoreCase(cs, "utf-8") or std.ascii.eqlIgnoreCase(cs, "utf8");
        t.o.entity_lines = !t.o.use_utf8_lines and !std.ascii.eqlIgnoreCase(cs, "ascii") and !std.ascii.eqlIgnoreCase(cs, "us-ascii");
    }
    if (force_no_color) t.o.color = false;
    if (t.o.color) parseColors(&t);
    const now = Io.Timestamp.now(ctx.io, .real);
    t.now = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));

    var roots = p.operands.items;
    const dot = [_][]const u8{"."};
    if (roots.len == 0) roots = @constCast(&dot);

    var out_fd: i32 = 1;
    if (t.o.out_file) |f| {
        var err: LX.E = .SUCCESS;
        out_fd = sys.openFd(f, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, 0o666, &err) orelse {
            cli.warn(ctx, "invalid filename '{s}'", .{f});
            return 1;
        };
    }

    if (t.o.mode == .xml) put(&t, if (t.o.utf8_locale) "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tree>\n" else "<?xml version=\"1.0\"?>\n<tree>\n");
    if (t.o.mode == .json) put(&t, "[\n");
    for (roots, 0..) |root, ri| {
        var err: LX.E = .SUCCESS;
        const lst = sys.fileStat(root, false, &err) orelse {
            t.exit_code = 2;
            switch (t.o.mode) {
                .text => {
                    var nb: std.ArrayList(u8) = .empty;
                    defer nb.deinit(t.gpa);
                    escapeName(&t, root, &nb);
                    putFmt(&t, "{s}  [error opening dir]\n", .{nb.items});
                },
                .json => {
                    put(&t, "    {\"type\":\"unknown\",\"name\":\"");
                    jsonEsc(&t, root);
                    put(&t, "\",\"contents\":[{\"error\": \"error opening dir\"}\n    ]}\n");
                },
                .xml => {
                    put(&t, "    <unknown name=\"");
                    xmlEsc(&t, root);
                    put(&t, "\"><error>error opening dir</error>\n    </unknown>\n");
                },
            }
            continue;
        };
        var st: ?sys.FileStat = lst;
        if (lst.isLink()) st = sys.fileStat(root, true, &err);
        const is_dir = if (st) |s| s.isDir() else false;
        var target: ?[]const u8 = null;
        _ = &target;
        var e = Entry{ .name = root, .path = root, .lst = if (st) |s| s else lst, .st = st, .is_dir = is_dir };
        const dev: u64 = (@as(u64, e.lst.dev_major) << 32) | e.lst.dev_minor;
        if (t.o.du and is_dir) {
            e.du = duOf(&t, &e, -1, false);
            t.total_du += e.du;
        }
        var root_unreadable = !is_dir;
        if (is_dir and !canOpen(root)) root_unreadable = true;
        if (root_unreadable) t.files += 1;
        const before_count = t.dirs + t.files;
        t.visited.clearRetainingCapacity();
        if (is_dir) t.visited.append(t.gpa, .{ .dev = (@as(u64, lst.dev_major) << 32) | lst.dev_minor, .ino = lst.ino }) catch {};
        switch (t.o.mode) {
            .text => {
                var frames: std.ArrayList(Frame) = .empty;
                defer frames.deinit(t.gpa);
                // root line
                putInfo(&t, &e);
                const code = if (t.o.color) typeCode(&t, &e) else "";
                putName(&t, &e, root, code);
                if (t.o.classify) {
                    const c = classifyChar(&e);
                    if (c != 0) put(&t, &[_]u8{c});
                }
                var skip_root = false;
                if (root_unreadable) {
                    put(&t, "  [error opening dir]");
                    skip_root = true;
                }
                if (is_dir and !skip_root and t.o.filelimit > 0) {
                    const n = countVisible(&t, root);
                    if (n > t.o.filelimit) {
                        putFmt(&t, "  [{d} entries exceeds filelimit, not opening dir]", .{n});
                        skip_root = true;
                        t.dirs += 1;
                    }
                }
                put(&t, "\n");
                if (is_dir and !skip_root) walk(&t, root, 0, &frames, dev, t.o.matchdirs and t.o.patterns.items.len > 0 and matchList(&t, t.o.patterns.items, root));
                if (is_dir and !skip_root and !root_unreadable and t.dirs + t.files > before_count) t.dirs += 1;
            },
            .json, .xml => {
                const json = t.o.mode == .json;
                const descend = is_dir;
                pad(&t, 1);
                const last = ri + 1 == roots.len;
                var has_children = false;
                if (descend) {
                    var e2: LX.E = .SUCCESS;
                    if (listDir(&t, root, &e2)) |ch| {
                        defer freeEntries(&t, ch);
                        for (ch) |*c| {
                            if (passes(&t, c)) has_children = true;
                        }
                    }
                }
                const tn = typeName(&e);
                if (json) {
                    put(&t, "{\"type\":\"");
                    put(&t, tn);
                    put(&t, "\",\"name\":\"");
                    jsonEsc(&t, root);
                    put(&t, "\"");
                    putAttrs(&t, &e, true);
                    if (root_unreadable) {
                        put(&t, if (last) ",\"contents\":[{\"error\": \"error opening dir\"}\n    ]}\n" else ",\"contents\":[{\"error\": \"error opening dir\"},\n    ]},\n");
                    } else if (descend and has_children) {
                        put(&t, ",\"contents\":[\n");
                        walkStruct(&t, root, 1, 2, true, dev);
                        pad(&t, 1);
                        put(&t, if (last) "]}\n" else "]},\n");
                    } else put(&t, "}\n");
                } else {
                    put(&t, "<");
                    put(&t, tn);
                    put(&t, " name=\"");
                    xmlEsc(&t, root);
                    put(&t, "\"");
                    putAttrs(&t, &e, false);
                    put(&t, ">");
                    if (root_unreadable) {
                        put(&t, "<error>error opening dir</error>\n    ");
                    } else if (descend) {
                        put(&t, "\n");
                        if (has_children) walkStruct(&t, root, 1, 2, false, dev);
                        pad(&t, 1);
                    }
                    put(&t, "</");
                    put(&t, tn);
                    put(&t, ">\n");
                }
                if (is_dir and !root_unreadable and t.dirs + t.files > before_count) t.dirs += 1;
            },
        }
    }
    // report
    switch (t.o.mode) {
        .text => if (!t.o.noreport) {
            put(&t, "\n");
            if (t.o.du) {
                var hb: std.ArrayList(u8) = .empty;
                defer hb.deinit(t.gpa);
                var total: u64 = 0;
                _ = &total;
                if (t.o.human) {
                    humanSize(&t, t.total_du, &hb);
                    putFmt(&t, "{s: >5} used in ", .{hb.items});
                } else putFmt(&t, "{d: >12} bytes used in ", .{t.total_du});
                if (t.o.dirs_only) putFmt(&t, "{d} director{s}\n", .{ t.dirs, if (t.dirs == 1) "y" else "ies" }) else putFmt(&t, "{d} director{s}, {d} file{s}\n", .{ t.dirs, if (t.dirs == 1) "y" else "ies", t.files, if (t.files == 1) "" else "s" });
            } else if (t.o.dirs_only) {
                putFmt(&t, "{d} director{s}\n", .{ t.dirs, if (t.dirs == 1) "y" else "ies" });
            } else putFmt(&t, "{d} director{s}, {d} file{s}\n", .{ t.dirs, if (t.dirs == 1) "y" else "ies", t.files, if (t.files == 1) "" else "s" });
        },
        .xml => {
            if (!t.o.noreport) {
                if (t.o.dirs_only) putFmt(&t, "    <report>\n        <directories>{d}</directories>\n    </report>\n", .{t.dirs}) else putFmt(&t, "    <report>\n        <directories>{d}</directories>\n        <files>{d}</files>\n    </report>\n", .{ t.dirs, t.files });
            }
            put(&t, "</tree>\n");
        },
        .json => {
            if (!t.o.noreport) {
                if (t.o.dirs_only) putFmt(&t, ",    {{\"type\":\"report\",\"directories\":{d}}}\n", .{t.dirs}) else putFmt(&t, ",    {{\"type\":\"report\",\"directories\":{d},\"files\":{d}}}\n", .{ t.dirs, t.files });
            } else put(&t, "\n");
            put(&t, "]\n");
        },
    }
    if (out_fd != 1) {
        _ = sys.writeAllFd(out_fd, t.out.items);
        _ = sys.closeFd(out_fd);
        t.out.clearRetainingCapacity();
    }
    flush(&t);
    return t.exit_code;
}

fn usageErr(t: *T) u8 {
    _ = t;
    const cut = std.mem.indexOf(u8, help_text, "  ------- Listing options") orelse help_text.len;
    _ = sys.writeAllFd(2, help_text[0..cut]);
    return 1;
}
