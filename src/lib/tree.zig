// SPDX-License-Identifier: GPL-2.0-or-later
//! tree library: list directory contents in a tree-like format. Reference:
//! tree 2.3.1 (Steve Baker et al.). Supported: the listing, sorting,
//! filtering and information options, -C colours, -A/-S line drawing, -X/-J
//! output. Not supported: -H HTML, --fromfile, --gitignore, --info,
//! hyperlinks.
//!
//! `run` walks the given roots and writes the listing (or the XML/JSON form)
//! to a caller-supplied writer. Unreadable directories are listed in the
//! output the way tree shows them, and also reported through the Observer.
//! The whole listing is built in memory and written when the walk is done, as
//! the executable always did.

const std = @import("std");
const common = @import("common.zig");
const fu = @import("fu_common.zig");
const sys = @import("../sys.zig");
const dirat = @import("../dirat.zig");
const fnmatch = @import("../fnmatch.zig");
const filevercmp = @import("../filevercmp.zig");
const unicode = @import("../unicode.zig");
const userdb = @import("../userdb.zig");
const strftime = @import("../strftime.zig");
const tzmod = @import("../tz.zig");
const LX = std.os.linux;
const Io = std.Io;

pub const Env = common.Env;

pub const Event = union(enum) {
    /// A directory (or start point) could not be opened; the listing shows
    /// "[error opening dir]" and the run's exit status is 2 (unless --du).
    unreadable: []const u8,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    directories: u64 = 0,
    files: u64 = 0,
    /// The --du total over the start points.
    total_size: u64 = 0,
    /// What the executable exits with (0, or 2 when something was unreadable).
    exit_status: u8 = 0,
};

pub const Sort = enum { name, version, mtime, ctime, size, none };
pub const Mode = enum { text, xml, json };

pub const Options = struct {
    all: bool = false,
    dirs_only: bool = false,
    follow: bool = false,
    full_path: bool = false,
    xdev: bool = false,
    max_level: i64 = -1,
    /// -P patterns (a pattern may hold alternatives separated by '|').
    patterns: []const []const u8 = &.{},
    /// -I patterns.
    ignores: []const []const u8 = &.{},
    icase: bool = false,
    matchdirs: bool = false,
    prune: bool = false,
    noreport: bool = false,
    filelimit: i64 = -1,
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

pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    lst: sys.FileStat,
    st: ?sys.FileStat, // followed stat, null when dangling
    is_dir: bool, // directory (or link to one)
    target: ?[]const u8 = null,
    du: u64 = 0,
    /// The directory it was listed in, held open; null for an operand.
    /// `name` is relative to it.
    at: ?*dirat.Level = null,
};

/// Open the directory `e` as `level`, from the directory it was listed in and
/// only if it is still what was examined there: a name that someone has since
/// made to lead elsewhere is refused, so that the listing stays in the tree
/// that was named. `path` is only a name for messages, but one too long to
/// name a file is not entered, as in tree.
noinline fn openDirectory(level: *dirat.Level, e: *const Entry) ?LX.E {
    if (e.path.len >= std.fs.max_path_bytes) return .NAMETOOLONG;
    // An operand may be a link; below it, only what was listed as one.
    const follow = e.at == null or e.lst.isLink();
    return dirat.enter(level, e.at, e.name, .{ .follow = follow, .expect = if (follow) e.st orelse e.lst else e.lst });
}

/// Give back a directory opened by `openDirectory`. When its parent cannot be
/// had back (moved meanwhile), what is left of the parent shows as unreadable.
fn closeDirectory(t: *T, level: *dirat.Level) void {
    if (dirat.leave(level) != null) t.exit_code = 2;
}

const T = struct {
    env: Env,
    gpa: std.mem.Allocator,
    observer: Observer,
    o: Options = .{},
    out: std.ArrayList(u8) = .empty,
    /// Set when an allocation failed; the run then returns error.OutOfMemory.
    oom: bool = false,
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

    fn nomem(t: *T) void {
        t.oom = true;
    }
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


fn put(t: *T, s: []const u8) void {
    t.out.appendSlice(t.gpa, s) catch t.nomem();
}

fn putFmt(t: *T, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(t.gpa, fmt, args) catch return t.nomem();
    defer t.gpa.free(s);
    put(t, s);
}


// ----------------------------------------------------------------- names

fn escapeName(t: *T, name: []const u8, buf: *std.ArrayList(u8)) void {
    const o = &t.o;
    if (o.raw) {
        buf.appendSlice(t.gpa, name) catch t.nomem();
        return;
    }
    var i: usize = 0;
    const utf8 = o.utf8_locale;
    while (i < name.len) {
        const c = name[i];
        if (utf8 and c >= 0x80) {
            const d = unicode.decode(name, i);
            if (d.valid) {
                // As tree 2.3.1: a character that is not printable (the C1
                // controls among them) is '?' with -q, else its number in octal.
                if (unicode.isPrint(d.cp)) {
                    buf.appendSlice(t.gpa, name[i .. i + d.len]) catch t.nomem();
                } else if (o.q) {
                    buf.append(t.gpa, '?') catch t.nomem();
                } else buf.print(t.gpa, "\\{o:0>3}", .{d.cp}) catch t.nomem();
                i += d.len;
                continue;
            }
        }
        i += 1;
        if (o.q) {
            if (utf8) {
                if (c < 0x20 or c == 0x7f) buf.append(t.gpa, '?') catch t.nomem() else buf.append(t.gpa, c) catch t.nomem();
            } else {
                switch (c) {
                    '\\' => buf.appendSlice(t.gpa, "\\\\") catch t.nomem(),
                    ' ' => buf.appendSlice(t.gpa, "\\ ") catch t.nomem(),
                    '\n' => buf.appendSlice(t.gpa, "\\n") catch t.nomem(),
                    '\t' => buf.appendSlice(t.gpa, "\\t") catch t.nomem(),
                    else => if (c < 0x20 or c >= 0x7f) buf.append(t.gpa, '?') catch t.nomem() else buf.append(t.gpa, c) catch t.nomem(),
                }
            }
            continue;
        }
        if (utf8) {
            if (c < 0x20 or c == 0x7f or c >= 0x80) {
                var b: [8]u8 = undefined;
                buf.appendSlice(t.gpa, std.fmt.bufPrint(&b, "\\{o:0>3}", .{c}) catch unreachable) catch t.nomem();
            } else buf.append(t.gpa, c) catch t.nomem();
        } else {
            switch (c) {
                '\\' => buf.appendSlice(t.gpa, "\\\\") catch t.nomem(),
                ' ' => if (o.quote) buf.append(t.gpa, ' ') catch t.nomem() else buf.appendSlice(t.gpa, "\\ ") catch t.nomem(),
                '\n' => buf.appendSlice(t.gpa, "\\n") catch t.nomem(),
                '\t' => buf.appendSlice(t.gpa, "\\t") catch t.nomem(),
                '"' => if (o.quote) buf.appendSlice(t.gpa, "\\\"") catch t.nomem() else buf.append(t.gpa, c) catch t.nomem(),
                else => if (c < 0x20 or c >= 0x7f) {
                    var b: [8]u8 = undefined;
                    buf.appendSlice(t.gpa, std.fmt.bufPrint(&b, "\\{o:0>3}", .{c}) catch unreachable) catch t.nomem();
                } else buf.append(t.gpa, c) catch t.nomem(),
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
        out.print(t.gpa, "{d: >4}", .{n}) catch t.nomem();
        return;
    }
    var v: f64 = @floatFromInt(n);
    var idx: usize = 0;
    while (v >= base and idx < units.len) {
        v /= base;
        idx += 1;
    }
    if (v >= 9.95) {
        out.print(t.gpa, "{d: >3.0}{c}", .{ @round(v), units[idx - 1] }) catch t.nomem();
    } else out.print(t.gpa, "{d:.1}{c}", .{ v, units[idx - 1] }) catch t.nomem();
}

fn ensureZone(t: *T) void {
    if (!t.zone_loaded) {
        t.zone = tzmod.load(t.gpa, t.env.io, t.env.getenv("TZ"));
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
        putFmt(t, "{d: >7}", .{s.ino});
    }
    if (o.device) {
        sep(t, &first);
        putFmt(t, "{d: >3}", .{(@as(u64, s.dev_major) << 8) | s.dev_minor});
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
            t.db = userdb.Db.load(t.gpa, t.env.io);
            t.db_loaded = true;
        }
        if (t.db.userByUid(s.uid)) |u| putFmt(t, "{s: <8}", .{u.name}) else putFmt(t, "{d: <8}", .{s.uid});
    }
    if (o.group) {
        sep(t, &first);
        if (!t.db_loaded) {
            t.db = userdb.Db.load(t.gpa, t.env.io);
            t.db_loaded = true;
        }
        if (t.db.groupByGid(s.gid)) |g| putFmt(t, "{s: <8}", .{g.name}) else putFmt(t, "{d: <8}", .{s.gid});
    }
    if (o.size or o.human) {
        sep(t, &first);
        const sz: u64 = if (o.du and e.is_dir) e.du else s.size;
        if (o.human) {
            humanSize(t, sz, &tmp);
            put(t, tmp.items);
        } else putFmt(t, "{d: >11}", .{sz});
    }
    if (o.date) {
        sep(t, &first);
        var tb: std.ArrayList(u8) = .empty;
        defer tb.deinit(t.gpa);
        formatMtime(t, s, &tb);
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

noinline fn listDir(t: *T, level: *dirat.Level, path: []const u8, err: *LX.E) ?[]Entry {
    const raw = sys.readDirNamesFd(t.gpa, level.fd, err) orelse return null;
    defer {
        for (raw) |x| t.gpa.free(x.name);
        t.gpa.free(raw);
    }
    var list: std.ArrayList(Entry) = .empty;
    for (raw) |r| {
        if (std.mem.eql(u8, r.name, ".") or std.mem.eql(u8, r.name, "..")) continue;
        if (!t.o.all and r.name.len > 0 and r.name[0] == '.') continue;
        const base = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
        const child = (if (std.mem.eql(u8, base, "/"))
            std.fmt.allocPrint(t.gpa, "/{s}", .{r.name})
        else
            std.fmt.allocPrint(t.gpa, "{s}/{s}", .{ base, r.name })) catch {
            t.nomem();
            continue;
        };
        // An entry whose path is too long to name a file is left out, as
        // tree leaves it out.
        if (child.len >= std.fs.max_path_bytes) {
            t.gpa.free(child);
            continue;
        }
        var e2: LX.E = .SUCCESS;
        const lst = sys.fileStatAt(level.fd, r.name, false, &e2) orelse {
            t.gpa.free(child);
            continue;
        };
        var st: ?sys.FileStat = lst;
        var is_dir = lst.isDir();
        var target: ?[]const u8 = null;
        if (lst.isLink()) {
            var buf: [4096]u8 = undefined;
            var e3: LX.E = .SUCCESS;
            if (sys.readlinkAt(level.fd, r.name, &buf, &e3)) |k| {
                target = t.gpa.dupe(u8, buf[0..k]) catch null;
                if (target == null) t.nomem();
            }
            st = sys.fileStatAt(level.fd, r.name, true, &e3);
            is_dir = if (st) |s| s.isDir() else false;
        }
        const name = t.gpa.dupe(u8, r.name) catch {
            t.nomem();
            t.gpa.free(child);
            if (target) |tg| t.gpa.free(tg);
            continue;
        };
        list.append(t.gpa, .{ .name = name, .path = child, .lst = lst, .st = st, .is_dir = is_dir, .target = target, .at = level }) catch t.nomem();
    }
    const items = list.toOwnedSlice(t.gpa) catch {
        t.nomem();
        return null;
    };
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
    if (matchList(t, o.ignores, e.name)) return false;
    if (e.lst.isDir()) {
        if (o.prune and !o.dirs_only) return hasVisible(t, e, level + 1, unf);
        return true;
    }
    if (o.dirs_only) {
        return e.is_dir;
    }
    if (o.prune and e.is_dir and !o.follow) return false;
    if (o.patterns.len > 0 and !unf and !matchList(t, o.patterns, e.name)) return false;
    return true;
}

fn passes(t: *T, e: *const Entry) bool {
    return visibleEntry(t, e, 0, false);
}

fn hasVisible(t: *T, dir: *const Entry, level: i64, unf: bool) bool {
    var below: dirat.Level = undefined;
    if (openDirectory(&below, dir) != null) return false;
    defer closeDirectory(t, &below);
    var err: LX.E = .SUCCESS;
    const items = listDir(t, &below, dir.path, &err) orelse return false;
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

/// Size of `e` with everything listed below it (--du). It runs ahead of the
/// listing, so the directories it passes count as visited only until it
/// returns; the listing then meets them in the same order.
fn duOf(t: *T, e: *Entry, level: i64, unf: bool) u64 {
    const mark = t.visited.items.len;
    defer t.visited.shrinkRetainingCapacity(mark);
    return sizeBelow(t, e, level, unf);
}

fn sizeBelow(t: *T, e: *Entry, level: i64, unf: bool) u64 {
    var total: u64 = e.lst.size;
    if (!e.is_dir or (e.lst.isLink() and !t.o.follow)) return total;
    if (t.o.max_level >= 0 and level + 1 >= t.o.max_level) return total;
    // As in the listing, a link back into what has been seen is not followed.
    if (e.lst.isLink() and seen(t, e.st.?)) return total;
    visit(t, e.lst, e.st);
    var below: dirat.Level = undefined;
    if (openDirectory(&below, e) != null) return total;
    defer closeDirectory(t, &below);
    var err: LX.E = .SUCCESS;
    const items = listDir(t, &below, e.path, &err) orelse return total;
    defer freeEntries(t, items);
    var child_unf = unf;
    if (t.o.matchdirs and t.o.patterns.len > 0 and matchList(t, t.o.patterns, e.name)) child_unf = true;
    for (items) |*c| {
        if (!visibleEntry(t, c, level + 1, child_unf)) continue;
        total += sizeBelow(t, c, level + 1, child_unf);
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

/// The modification time as JSON and XML show it, which is the text listing's
/// format: `--timefmt` when given, else "%b %e %H:%M" (or "%b %e  %Y" for a file
/// older than about six months).
fn formatMtime(t: *T, s: sys.FileStat, tb: *std.ArrayList(u8)) void {
    ensureZone(t);
    const tm = tzmod.localtime(&t.zone, s.mtime_s);
    // A year beyond struct tm has no calendar form: the seconds are shown.
    if (!tzmod.fitsStructTm(&tm)) {
        tb.print(t.gpa, "{d}", .{s.mtime_s}) catch t.nomem();
    } else if (t.o.timefmt) |f| {
        strftime.format(tb, t.gpa, f, &tm, s.mtime_s, s.mtime_ns) catch t.nomem();
    } else {
        const old = t.now -| s.mtime_s > 182 * 86400 or s.mtime_s > t.now;
        strftime.format(tb, t.gpa, if (old) "%b %e  %Y" else "%b %e %H:%M", &tm, s.mtime_s, s.mtime_ns) catch t.nomem();
    }
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
        if (o.size or o.human) {
            const n = if (o.du and e.is_dir) e.du else s.size;
            if (o.human) {
                // tree writes a human-readable size as a string ("1.9M").
                var hb: std.ArrayList(u8) = .empty;
                defer hb.deinit(t.gpa);
                humanSize(t, n, &hb);
                putFmt(t, ",\"size\":\"{s}\"", .{std.mem.trim(u8, hb.items, " ")});
            } else putFmt(t, ",\"size\":{d}", .{n});
        }
        if (o.date) {
            var tb: std.ArrayList(u8) = .empty;
            defer tb.deinit(t.gpa);
            formatMtime(t, s, &tb);
            put(t, ",\"time\":\"");
            jsonEsc(t, tb.items);
            put(t, "\"");
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
            var tb: std.ArrayList(u8) = .empty;
            defer tb.deinit(t.gpa);
            formatMtime(t, s, &tb);
            put(t, " time=\"");
            xmlEsc(t, tb.items);
            put(t, "\"");
        }
    }
}

fn loadDb(t: *T) void {
    if (!t.db_loaded) {
        t.db = userdb.Db.load(t.gpa, t.env.io);
        t.db_loaded = true;
    }
}

fn canOpen(t: *T, e: *const Entry) bool {
    var below: dirat.Level = undefined;
    if (openDirectory(&below, e) != null) return false;
    closeDirectory(t, &below);
    return true;
}

fn countVisible(t: *T, e: *const Entry) i64 {
    var below: dirat.Level = undefined;
    if (openDirectory(&below, e) != null) return 0;
    defer closeDirectory(t, &below);
    var err: LX.E = .SUCCESS;
    const rd = sys.readDirNamesFd(t.gpa, below.fd, &err) orelse return 0;
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

/// Remember the directory a descent goes into: the entry itself, or what the
/// link `lst` leads to.
fn visit(t: *T, lst: sys.FileStat, target: ?sys.FileStat) void {
    const s = if (lst.isLink()) target.? else lst;
    t.visited.append(t.gpa, .{ .dev = (@as(u64, s.dev_major) << 32) | s.dev_minor, .ino = s.ino }) catch t.nomem();
}

fn walk(t: *T, dir: *const Entry, level: i64, frames: *std.ArrayList(Frame), dev: u64, unf: bool) void {
    const o = &t.o;
    var below: dirat.Level = undefined;
    if (openDirectory(&below, dir) != null) return;
    defer closeDirectory(t, &below);
    var err: LX.E = .SUCCESS;
    const items = listDir(t, &below, dir.path, &err) orelse return;
    defer freeEntries(t, items);
    var shown: std.ArrayList(*Entry) = .empty;
    defer shown.deinit(t.gpa);
    for (items) |*e| {
        if (!visibleEntry(t, e, level, unf)) continue;
        shown.append(t.gpa, e) catch t.nomem();
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
        if (descend and !canOpen(t, e)) {
            t.observer.emit(.{ .unreadable = e.path });
            note = "[error opening dir]";
            descend = false;
            if (!o.du and !(o.matchdirs and o.patterns.len > 0)) t.exit_code = 2;
        }
        if (descend and o.filelimit > 0) {
            const n = countVisible(t, e);
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
        frames.append(t.gpa, .{ .last = last }) catch t.nomem();
        var child_unf = unf;
        if (o.matchdirs and o.patterns.len > 0 and matchList(t, o.patterns, e.name)) child_unf = true;
        walk(t, e, level + 1, frames, dev, child_unf);
        _ = frames.pop();
    }
}

// ---- structured output

fn walkStruct(t: *T, dir: *const Entry, level: i64, indent: usize, json: bool, dev: u64) void {
    const o = &t.o;
    var below: dirat.Level = undefined;
    if (openDirectory(&below, dir) != null) return;
    defer closeDirectory(t, &below);
    var err: LX.E = .SUCCESS;
    const items = listDir(t, &below, dir.path, &err) orelse return;
    defer freeEntries(t, items);
    var shown: std.ArrayList(*Entry) = .empty;
    defer shown.deinit(t.gpa);
    for (items) |*e| {
        if (!passes(t, e)) continue;
        if (o.prune and e.is_dir and !(e.lst.isLink() and !o.follow)) {
            if (!hasVisible(t, e, level, false)) continue;
        }
        shown.append(t.gpa, e) catch t.nomem();
    }
    for (shown.items, 0..) |e, idx| {
        const last = idx + 1 == shown.items.len;
        if (o.du and e.is_dir) e.du = duOf(t, e, level, false);
        const into_dir = e.is_dir and (!e.lst.isLink() or o.follow);
        if (e.is_dir) t.dirs += 1 else t.files += 1;
        var descend = into_dir and !(o.max_level >= 0 and level + 1 >= o.max_level) and !(o.xdev and (@as(u64, (e.st orelse e.lst).dev_major) << 32 | (e.st orelse e.lst).dev_minor) != dev);
        // The same loop rule as the text listing: every directory counts as
        // visited when listed, and a link to a visited one is not followed.
        const recursive = descend and e.lst.isLink() and seen(t, e.st.?);
        if (recursive) descend = false;
        if (e.lst.isDir() or descend) visit(t, e.lst, e.st);
        structEntry(t, e, indent, json, last, descend, recursive, level, dev);
    }
}

/// Whether the directory `dir` holds anything that would be listed.
noinline fn anyListed(t: *T, dir: *const Entry) bool {
    var below: dirat.Level = undefined;
    if (openDirectory(&below, dir) != null) return false;
    defer closeDirectory(t, &below);
    var err: LX.E = .SUCCESS;
    const items = listDir(t, &below, dir.path, &err) orelse return false;
    defer freeEntries(t, items);
    for (items) |*c| {
        if (passes(t, c)) return true;
    }
    return false;
}

fn pad(t: *T, n: usize) void {
    t.out.appendNTimes(t.gpa, ' ', n * 4) catch t.nomem();
}

fn structEntry(t: *T, e: *Entry, indent: usize, json: bool, last: bool, descend: bool, recursive: bool, level: i64, dev: u64) void {
    const tn = typeName(e);
    pad(t, indent);
    var has_children = false;
    var unreadable = false;
    if (descend and !canOpen(t, e)) {
        t.observer.emit(.{ .unreadable = e.path });
        unreadable = true;
        // With --du tree reports the unreadable directory but exits 0 (as the text listing does).
        if (!t.o.du) t.exit_code = 2;
    }
    if (descend and !unreadable) {
        has_children = anyListed(t, e);
    }
    if (json) {
        put(t, "{\"type\":\"");
        put(t, tn);
        put(t, "\",\"name\":\"");
        jsonEsc(t, if (t.o.full_path) e.path else e.name);
        put(t, "\"");
        if (e.target) |tg| {
            put(t, ",\"target\":\"");
            jsonEsc(t, tg);
            put(t, "\"");
        }
        putAttrs(t, e, true);
        if (recursive) {
            put(t, ",\"contents\":[{\"error\": \"recursive, not followed\"}");
            // tree pads by depth here, except with --du.
            if (t.o.du) pad(t, 1) else pad(t, indent);
            put(t, "]}");
        } else if (unreadable) {
            put(t, ",\"contents\":[{\"error\": \"error opening dir\"}    ]}");
            t.json_err = true;
        } else if (descend and has_children) {
            put(t, ",\"contents\":[\n");
            walkStruct(t, e, level + 1, indent + 1, true, dev);
            pad(t, indent);
            put(t, "]}");
        } else if (t.json_err and !t.o.du and !e.lst.isDir()) {
            put(t, ",\"contents\":[    ]}");
        } else put(t, "}");
        put(t, if (last) "\n" else ",\n");
    } else {
        put(t, "<");
        put(t, tn);
        put(t, " name=\"");
        xmlEsc(t, if (t.o.full_path) e.path else e.name);
        put(t, "\"");
        if (e.target) |tg| {
            put(t, " target=\"");
            xmlEsc(t, tg);
            put(t, "\"");
        }
        putAttrs(t, e, false);
        put(t, ">");
        if (recursive) {
            put(t, "<error>recursive, not followed</error>");
            if (!t.o.du) pad(t, indent);
        } else if (unreadable) {
            put(t, "<error>error opening dir</error>");
        } else if (descend and has_children) {
            put(t, "\n");
            walkStruct(t, e, level + 1, indent + 1, false, dev);
            pad(t, indent);
        }
        put(t, "</");
        put(t, tn);
        put(t, ">\n");
    }
}

// --------------------------------------------------------------- options

/// The table of the environment: $TREE_COLORS when set, else $LS_COLORS; null
/// when that is unset or empty.
pub fn colorSpec(env: Env) ?[]const u8 {
    const spec = env.getenv("TREE_COLORS") orelse env.getenv("LS_COLORS") orelse return null;
    return if (spec.len > 0) spec else null;
}

/// GNU tree's own table, used when colour is wanted and the environment has
/// none. In pieces: the plain entries, then the extensions by colour.
const builtin_colors = ":no=00:rs=0:fi=00:di=01;34:ln=01;36:pi=40;33:so=01;35:bd=40;33;01:cd=40;33;01:or=40;31;01:ex=01;32" ++
    extensionColors("01;32", "bat BAT btm BTM cmd CMD com COM dll DLL exe EXE") ++
    extensionColors("01;31", "arj bz2 deb gz lzh rpm tar taz tb2 tbz2 tbz tgz tz2 z Z zip ZIP zoo") ++
    extensionColors("01;35", "asf ASF avi AVI bmp BMP flac FLAC gif GIF jpg JPG jpeg JPEG m2a M2a m2v M2V mov MOV mp3 MP3 mpeg MPEG mpg MPG ogg OGG ppm rm RM tga TGA tif TIF wav WAV wmv WMV xbm xpm");

fn extensionColors(comptime code: []const u8, comptime names: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(20000);
        var out: []const u8 = "";
        var it = std.mem.tokenizeScalar(u8, names, ' ');
        while (it.next()) |name| out = out ++ ":*." ++ name ++ "=" ++ code;
        return out;
    }
}

fn parseColors(t: *T) void {
    const ls_colors = colorSpec(t.env) orelse builtin_colors;
    t.colors = .{ .di = "", .ln = "", .pi = "", .so = "", .bd = "", .cd = "", .or_ = "", .mi = "", .su = "", .sg = "", .tw = "", .ow = "", .st = "", .ex = "" };
    var it = std.mem.splitScalar(u8, ls_colors, ':');
    // The target of a broken link takes "mi", else "no".
    var no: []const u8 = "";
    defer if (t.colors.mi.len == 0) {
        t.colors.mi = no;
    };
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
        if (std.mem.eql(u8, k, "no")) no = v else if (std.mem.eql(u8, k, "fi")) c.fi = v else if (std.mem.eql(u8, k, "di")) c.di = v else if (std.mem.eql(u8, k, "ln")) c.ln = v else if (std.mem.eql(u8, k, "pi")) c.pi = v else if (std.mem.eql(u8, k, "so")) c.so = v else if (std.mem.eql(u8, k, "bd")) c.bd = v else if (std.mem.eql(u8, k, "cd")) c.cd = v else if (std.mem.eql(u8, k, "or")) c.or_ = v else if (std.mem.eql(u8, k, "mi")) c.mi = v else if (std.mem.eql(u8, k, "su")) c.su = v else if (std.mem.eql(u8, k, "sg")) c.sg = v else if (std.mem.eql(u8, k, "tw")) c.tw = v else if (std.mem.eql(u8, k, "ow")) c.ow = v else if (std.mem.eql(u8, k, "st")) c.st = v else if (std.mem.eql(u8, k, "ex")) c.ex = v else if (k.len > 1 and k[0] == '*') {
            c.ext.append(t.gpa, .{ .suffix = k[1..], .code = v }) catch {};
        }
    }
}

/// Does the locale in the environment name a UTF-8 charset?
pub fn localeIsUtf8(env: Env) bool {
    return fu.localeIsUtf8(env);
}

/// List `roots` (the current directory when empty) to `writer`.
pub fn run(env: Env, options: Options, roots_in: []const []const u8, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    var t = T{ .env = env, .gpa = env.gpa, .observer = observer, .o = options };
    defer {
        t.out.deinit(env.gpa);
        t.visited.deinit(env.gpa);
        if (t.db_loaded) t.db.deinit();
        if (t.zone_loaded) t.zone.deinit();
        t.colors.ext.deinit(env.gpa);
    }
    if (t.o.color) parseColors(&t);
    const now = Io.Timestamp.now(env.io, .real);
    t.now = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));

    const dot = [_][]const u8{"."};
    const roots: []const []const u8 = if (roots_in.len == 0) &dot else roots_in;

    if (t.o.mode == .xml) put(&t, if (t.o.utf8_locale) "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tree>\n" else "<?xml version=\"1.0\"?>\n<tree>\n");
    if (t.o.mode == .json) put(&t, "[\n");
    for (roots, 0..) |root, ri| {
        var err: LX.E = .SUCCESS;
        const lst = sys.fileStat(root, false, &err) orelse {
            t.exit_code = 2;
            t.observer.emit(.{ .unreadable = root });
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
        t.visited.clearRetainingCapacity();
        if (is_dir) t.visited.append(t.gpa, .{ .dev = (@as(u64, lst.dev_major) << 32) | lst.dev_minor, .ino = lst.ino }) catch {};
        if (t.o.du and is_dir) {
            e.du = duOf(&t, &e, -1, false);
            t.total_du += e.du;
        }
        var root_unreadable = !is_dir;
        if (is_dir and !canOpen(&t, &e)) {
            root_unreadable = true;
            t.observer.emit(.{ .unreadable = root });
        }
        if (root_unreadable) t.files += 1;
        const before_count = t.dirs + t.files;
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
                    const n = countVisible(&t, &e);
                    if (n > t.o.filelimit) {
                        putFmt(&t, "  [{d} entries exceeds filelimit, not opening dir]", .{n});
                        skip_root = true;
                        t.dirs += 1;
                    }
                }
                put(&t, "\n");
                if (is_dir and !skip_root) walk(&t, &e, 0, &frames, dev, t.o.matchdirs and t.o.patterns.len > 0 and matchList(&t, t.o.patterns, root));
                if (is_dir and !skip_root and !root_unreadable and t.dirs + t.files > before_count) t.dirs += 1;
            },
            .json, .xml => {
                const json = t.o.mode == .json;
                const descend = is_dir;
                pad(&t, 1);
                const last = ri + 1 == roots.len;
                var has_children = false;
                if (descend) has_children = anyListed(&t, &e);
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
                        walkStruct(&t, &e, 1, 2, true, dev);
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
                        if (has_children) walkStruct(&t, &e, 1, 2, false, dev);
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
                put(&t, "    <report>\n");
                if (t.o.du) putFmt(&t, "        <size>{d}</size>\n", .{t.total_du});
                putFmt(&t, "        <directories>{d}</directories>\n", .{t.dirs});
                if (!t.o.dirs_only) putFmt(&t, "        <files>{d}</files>\n", .{t.files});
                put(&t, "    </report>\n");
            }
            put(&t, "</tree>\n");
        },
        .json => {
            if (!t.o.noreport) {
                put(&t, ",    {\"type\":\"report\"");
                if (t.o.du) putFmt(&t, ",\"size\":{d}", .{t.total_du});
                putFmt(&t, ",\"directories\":{d}", .{t.dirs});
                if (!t.o.dirs_only) putFmt(&t, ",\"files\":{d}", .{t.files});
                put(&t, "}\n");
            } else put(&t, "\n");
            put(&t, "]\n");
        },
    }
    if (t.oom) return error.OutOfMemory;
    try writer.writeAll(t.out.items);
    return .{ .directories = t.dirs, .files = t.files, .total_size = t.total_du, .exit_status = t.exit_code };
}
