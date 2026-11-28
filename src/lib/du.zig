// SPDX-License-Identifier: GPL-2.0-or-later
//! du library: estimate file space usage.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "du invocation"
//! (9.7), POSIX.1-2024 du, and GNU coreutils 9.6 src/du.c and lib/exclude.c
//! (the per-level accumulation, the skipped hard links and the exclude rules
//! were studied there and rewritten as a recursive walk).
//!
//! The walk is descriptor-relative (dirat.zig): every entry is examined and
//! every directory opened by its own name in the open directory above it, so
//! depth is not limited by PATH_MAX and a directory replaced by a link while
//! du runs is not followed. Path strings (one shared buffer) are for the
//! report, the messages and the exclude patterns.
//!
//! Use: `var d = Du.init(env, options, writer, observer); defer d.deinit();`,
//! `walk` each argument, then `finish`. Argument parsing, option validation and
//! the wording of diagnostics are in src/commands/du.zig.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const Sink = @import("sink.zig").Sink;
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const human = @import("../human.zig");
const diskusage = @import("../diskusage.zig");
const dirat = @import("../dirat.zig");
const fnmatch = @import("../fnmatch.zig");

pub const Env = common.Env;
pub const TimeType = enum { mtime, ctime, atime };
pub const Deref = enum { physical, comfollow, logical };

pub const Options = struct {
    /// -a: report files as well as directories.
    all: bool = false,
    /// --apparent-size (-b): file lengths instead of disk blocks.
    apparent_size: bool = false,
    /// -l: count hard links every time.
    count_links: bool = false,
    /// -S: a directory's size excludes its subdirectories.
    separate_dirs: bool = false,
    /// -d N / -s (0): deepest level reported.
    max_depth: u64 = std.math.maxInt(u64),
    /// -t: report only entries at least (positive) or at most (negative) this big.
    threshold: i64 = 0,
    /// human.zig option bits and the output block size (-h, -k, -m, -B ...).
    human_opts: u32 = 0,
    block_size: u64 = 1024,
    /// --inodes: count inodes instead of space.
    inodes: bool = false,
    /// --time: add a time column of `time_type`, formatted with `time_format`
    /// (strftime).
    show_time: bool = false,
    time_type: TimeType = .mtime,
    time_format: []const u8 = "",
    /// -P / -D (-H) / -L.
    deref: Deref = .physical,
    /// -x: do not leave the file system of each argument.
    one_file_system: bool = false,
    /// -c: add a "total" line.
    grand_total: bool = false,
    /// -0: end lines with NUL.
    nul_terminate: bool = false,
    /// GNU tracks hard links across arguments when several are given (or
    /// -L / --files0-from): remember every file, not only multiply linked
    /// ones. The caller sets it when it knows how many arguments follow.
    hash_all: bool = false,
    /// --exclude / --exclude-from patterns (shell wildcards; copied).
    excludes: []const []const u8 = &.{},
    /// Extension (decision 0003): the report as a JSON array.
    json: bool = false,
};

pub const Event = union(enum) {
    /// `errno` null: a dangling symbolic link (fts gives no errno).
    cannot_access: struct { path: []const u8, errno: ?std.os.linux.E },
    /// A directory that contains itself.
    circular: []const u8,
    cannot_read_dir: struct { path: []const u8, errno: std.os.linux.E },
};

const Dui = struct {
    size: u64 = 0,
    inodes: u64 = 0,
    tmax_sec: i64 = std.math.minInt(i64),
    tmax_nsec: i64 = -1,

    fn add(a: *Dui, b: Dui) void {
        const sum = @addWithOverflow(a.size, b.size);
        a.size = if (sum[1] == 0) sum[0] else std.math.maxInt(u64);
        a.inodes +%= b.inodes;
        if (a.tmax_sec < b.tmax_sec or (a.tmax_sec == b.tmax_sec and a.tmax_nsec < b.tmax_nsec)) {
            a.tmax_sec = b.tmax_sec;
            a.tmax_nsec = b.tmax_nsec;
        }
    }
};

const Level = struct { ent: Dui = .{}, subdir: Dui = .{} };

const Pattern = struct { text: []const u8, wildcard: bool };

const DevIno = struct { dev: u64, ino: u64 };

/// One `du` run: feed it the command-line arguments with `walk`, then call
/// `finish`. Created by `init`; release with `deinit`.
pub const Du = struct {
    env: Env,
    out: Sink,
    observer: common.Observer(Event),
    opt_all: bool,
    apparent_size: bool,
    count_all: bool,
    hash_all: bool,
    nul_terminate: bool,
    print_grand_total: bool,
    separate_dirs: bool,
    max_depth: u64,
    threshold: i64,
    human_opts: u32,
    block_size: u64,
    inodes: bool,
    show_time: bool,
    time_type: TimeType,
    time_format: []const u8,
    zone: tzmod.Zone = undefined,
    zone_loaded: bool = false,
    deref: Deref,
    xdev: bool,
    patterns: std.ArrayList(Pattern) = .empty,
    seen: std.AutoHashMap(DevIno, void),
    total: Dui = .{},
    /// --json: entries are serialized as they are produced (the path passed to
    /// printSize is a temporary), one object per line.
    json: ?std.Io.Writer.Allocating = null,
    json_count: usize = 0,
    json_total: bool = false,
    ancestors: std.ArrayList(DevIno) = .empty,
    /// The path of the entry being visited.
    path: std.ArrayList(u8) = .empty,

    /// Start a run. `writer` receives the report; nothing is written until
    /// the first `walk`.
    pub fn init(env: Env, options: Options, writer: *Io.Writer, observer: common.Observer(Event)) Du {
        var s: Du = .{
            .env = env,
            .out = Sink.init(writer),
            .observer = observer,
            .opt_all = options.all,
            .apparent_size = options.apparent_size,
            .count_all = options.count_links,
            .hash_all = options.hash_all,
            .nul_terminate = options.nul_terminate,
            .print_grand_total = options.grand_total,
            .separate_dirs = options.separate_dirs,
            .max_depth = options.max_depth,
            .threshold = options.threshold,
            .human_opts = options.human_opts,
            .block_size = options.block_size,
            .inodes = options.inodes,
            .show_time = options.show_time,
            .time_type = options.time_type,
            .time_format = options.time_format,
            .deref = options.deref,
            .xdev = options.one_file_system,
            .seen = std.AutoHashMap(DevIno, void).init(env.gpa),
        };
        if (options.json) s.json = .init(env.gpa);
        for (options.excludes) |text| s.addPattern(text);
        return s;
    }

    pub fn deinit(s: *Du) void {
        for (s.patterns.items) |p| s.env.gpa.free(p.text);
        s.patterns.deinit(s.env.gpa);
        s.seen.deinit();
        s.ancestors.deinit(s.env.gpa);
        s.path.deinit(s.env.gpa);
        if (s.zone_loaded) s.zone.deinit();
        if (s.json) |*aw| aw.deinit();
    }

    /// Process one command-line argument (du.c process_file on a root).
    /// False when a problem was reported for it or something below it.
    pub fn walk(s: *Du, name: []const u8) bool {
        var top: Level = .{};
        var dev: u64 = 0;
        if (s.xdev) {
            var e: std.os.linux.E = .SUCCESS;
            if (sys.fileStat(name, s.deref != .physical, &e)) |st| dev = devKey(st);
        }
        s.path.clearRetainingCapacity();
        s.path.appendSlice(s.env.gpa, name) catch return false;
        return visit(s, null, name, 0, &top, dev);
    }

    /// Print the grand total (`--total`), close the JSON array and flush.
    pub fn finish(s: *Du) error{WriteFailed}!void {
        if (s.print_grand_total) {
            s.json_total = true;
            s.printSize(s.total, "total");
        }
        if (s.json) |*aw| {
            aw.writer.writeAll(if (s.json_count == 0) "]\n" else "\n]\n") catch {};
            s.out.write("[");
            s.out.write(aw.written());
        }
        s.out.flush();
        try s.out.check();
    }

    fn printSize(s: *Du, d: Dui, name: []const u8) void {
        if (s.json) |*aw| {
            const unknown_time = d.tmax_sec == std.math.minInt(i64);
            aw.writer.writeAll(if (s.json_count == 0) "\n" else ",\n") catch return;
            diskusage.writeEntry(&aw.writer, .{
                .path = name,
                .size = if (d.size == std.math.maxInt(u64)) null else d.size,
                .inodes = d.inodes,
                .time = if (unknown_time) null else d.tmax_sec,
                .time_nsec = if (unknown_time) null else @intCast(@max(0, d.tmax_nsec)),
                .time_kind = @tagName(s.time_type),
                .total = std.mem.eql(u8, name, "total") and s.json_total,
            }) catch return;
            s.json_count += 1;
            return;
        }
        var hb: [human.longest]u8 = undefined;
        const n = if (s.inodes) d.inodes else d.size;
        if (n == std.math.maxInt(u64)) {
            s.out.write("Infinity");
        } else s.out.write(human.readable(n, &hb, s.human_opts, 1, s.block_size));
        if (s.show_time) {
            s.out.writeByte('\t');
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(s.env.gpa);
            var ok = false;
            if (!s.zone_loaded) {
                s.zone = tzmod.load(s.env.gpa, s.env.io, s.env.getenv("TZ"));
                s.zone_loaded = true;
            }
            const tm = tzmod.localtime(&s.zone, d.tmax_sec);
            if (tm.year - 1900 <= std.math.maxInt(i32) and tm.year - 1900 >= std.math.minInt(i32)) {
                if (strftime.format(&text, s.env.gpa, s.time_format, &tm, d.tmax_sec, @intCast(@max(0, d.tmax_nsec)))) |_| {
                    ok = true;
                } else |_| {}
            }
            if (ok) {
                s.out.write(text.items);
            } else {
                var tb: [24]u8 = undefined;
                s.out.write(std.fmt.bufPrint(&tb, "{d}", .{d.tmax_sec}) catch "");
            }
        }
        s.out.writeByte('\t');
        s.out.write(name);
        s.out.writeByte(if (s.nul_terminate) 0 else '\n');
        s.out.flush();
    }

    /// The start of `pattern` up to and with its first '*', when what comes
    /// before is plain enough to tell that this '*' is one.
    fn headThroughStar(pattern: []const u8) ?[]const u8 {
        const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return null;
        if (std.mem.indexOfAny(u8, pattern[0..star], "[\\") != null) return null;
        return pattern[0 .. star + 1];
    }

    fn excluded(s: *Du, f: []const u8) bool {
        for (s.patterns.items) |p| {
            if (p.wildcard) {
                // The pattern may match the path or what follows any slash.
                // With a '*' (which takes slashes too) only the first of those
                // places where the part before it matches need be tried: if
                // not from there, then not from a later one with less text.
                const head = headThroughStar(p.text);
                var i: usize = 0;
                while (i <= f.len) : (i += 1) {
                    if (i > 0 and !(f[i - 1] == '/' and i < f.len and f[i] != '/')) continue;
                    if (head) |h| {
                        if (!fnmatch.match(h, f[i..], .{})) continue;
                        if (fnmatch.match(p.text, f[i..], .{})) return true;
                        break;
                    }
                    if (fnmatch.match(p.text, f[i..], .{})) return true;
                }
            } else {
                if (std.mem.eql(u8, p.text, f)) return true;
                var rest = f;
                while (std.mem.indexOfScalar(u8, rest, '/')) |i| {
                    rest = rest[i + 1 ..];
                    if (std.mem.eql(u8, p.text, rest)) return true;
                }
            }
        }
        return false;
    }

    fn addPattern(s: *Du, text: []const u8) void {
        const gpa = s.env.gpa;
        var wildcard = false;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            switch (text[i]) {
                '\\' => i += 1,
                '?', '*', '[' => {
                    wildcard = true;
                    break;
                },
                else => {},
            }
        }
        if (wildcard) {
            const d = gpa.dupe(u8, text) catch return;
            s.patterns.append(gpa, .{ .text = d, .wildcard = true }) catch gpa.free(d);
        } else {
            // Unescape backslashes for exact patterns.
            var out: std.ArrayList(u8) = .empty;
            var k: usize = 0;
            while (k < text.len) : (k += 1) {
                if (text[k] == '\\' and k + 1 < text.len) k += 1;
                out.append(gpa, text[k]) catch {};
            }
            const d = out.toOwnedSlice(gpa) catch return;
            s.patterns.append(gpa, .{ .text = d, .wildcard = false }) catch gpa.free(d);
        }
    }
};

fn devKey(st: sys.FileStat) u64 {
    return (@as(u64, st.dev_major) << 32) | st.dev_minor;
}

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// du.c process_file for one entry and (recursively) its children. The entry
/// is `name` in the open directory `dir` (null: an argument, relative to the
/// current directory) and `s.path` holds its path. `parent` is the accumulator
/// for the group of entries this one belongs to.
fn visit(s: *Du, dir: ?*dirat.Level, name: []const u8, level: u64, parent: *Level, root_dev: u64) bool {
    const ctx = s.env;
    // Both are taken again after anything that may grow the buffer.
    const path_len = s.path.items.len;
    var path: []const u8 = s.path.items;
    var ok = true;
    const follow = switch (s.deref) {
        .logical => true,
        .comfollow => level == 0,
        .physical => false,
    };
    var err: std.os.linux.E = .SUCCESS;
    const st_opt = sys.fileStatAt(dirat.fdOf(dir), name, follow, &err);
    var dangling = false;
    if (st_opt == null and follow and err == .NOENT) {
        if (sys.fileStatAt(dirat.fdOf(dir), name, false, &err)) |_| {
            dangling = true;
        }
    }
    const is_excluded0 = s.excluded(path);
    var is_excluded = is_excluded0;
    if (!is_excluded0) {
        if (st_opt == null or dangling) {
            // fts reports a dangling symlink without an errno.
            s.observer.emit(.{ .cannot_access = .{ .path = path, .errno = if (dangling) null else err } });
            return false;
        }
        if (s.xdev and level > 0 and root_dev != devKey(st_opt.?)) is_excluded = true;
    }
    if (st_opt == null) return true; // excluded and unreadable: nothing to do
    const st = st_opt.?;
    const is_dir = st.isDir();

    // Hard links and repeated arguments.
    if (is_excluded or (!s.count_all and (s.hash_all or (!is_dir and st.nlink > 1)) and !blk: {
        const r = s.seen.getOrPut(.{ .dev = devKey(st), .ino = st.ino }) catch break :blk true;
        break :blk !r.found_existing;
    })) {
        return true;
    }

    var cycle = false;
    if (is_dir) {
        const key = DevIno{ .dev = devKey(st), .ino = st.ino };
        for (s.ancestors.items) |a| {
            if (a.dev == key.dev and a.ino == key.ino) cycle = true;
        }
    }
    if (cycle) {
        if (s.deref == .physical or (s.deref == .comfollow and level != 0)) {
            s.observer.emit(.{ .circular = path });
            return false;
        }
        return true;
    }

    var children: Level = .{};
    if (is_dir) {
        var below: dirat.Level = undefined;
        if (dirat.enter(&below, dir, name, .{ .follow = follow, .expect = st })) |e| {
            s.observer.emit(.{ .cannot_read_dir = .{ .path = path, .errno = e } });
            ok = false;
        } else {
            // A failure to get back to the directory above is seen there.
            defer _ = dirat.leave(&below);
            // The whole listing is taken before anything is visited.
            var read_err: std.os.linux.E = .SUCCESS;
            const entries: []sys.RawEntry = sys.readDirFd(ctx.gpa, below.fd, &read_err) orelse blk: {
                s.observer.emit(.{ .cannot_read_dir = .{ .path = path, .errno = read_err } });
                ok = false;
                break :blk &.{};
            };
            defer {
                for (entries) |entry| ctx.gpa.free(entry.name);
                ctx.gpa.free(entries);
            }
            s.ancestors.append(ctx.gpa, .{ .dev = devKey(st), .ino = st.ino }) catch {};
            // fts: one trailing slash of the parent is replaced.
            const trailing_slash = path_len > 0 and s.path.items[path_len - 1] == '/';
            const base_len = path_len - @intFromBool(trailing_slash);
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
                s.path.shrinkRetainingCapacity(base_len);
                s.path.ensureUnusedCapacity(ctx.gpa, entry.name.len + 1) catch {
                    // The totals would be short without a word.
                    s.observer.emit(.{ .cannot_read_dir = .{ .path = s.path.items[0..base_len], .errno = .NOMEM } });
                    ok = false;
                    break;
                };
                s.path.appendAssumeCapacity('/');
                s.path.appendSliceAssumeCapacity(entry.name);
                if (!visit(s, &below, entry.name, level + 1, &children, root_dev)) ok = false;
                // Deep trees close the directories far above; this one was
                // moved while below it, so its other entries are out of reach.
                if (!below.open) {
                    s.observer.emit(.{ .cannot_read_dir = .{ .path = s.path.items[0..base_len], .errno = .NOENT } });
                    ok = false;
                    break;
                }
            }
            s.path.shrinkRetainingCapacity(base_len);
            if (trailing_slash) s.path.appendAssumeCapacity('/');
            path = s.path.items;
            _ = s.ancestors.pop();
        }
    }

    var dui: Dui = .{
        .size = if (s.apparent_size)
            (if (st.isReg() or st.isLink()) @as(u64, @intCast(@max(@as(i64, 0), @as(i64, @bitCast(st.size))))) else 0)
        else
            st.blocks * 512,
        .inodes = 1,
    };
    switch (s.time_type) {
        .mtime => {
            dui.tmax_sec = st.mtime_s;
            dui.tmax_nsec = st.mtime_ns;
        },
        .atime => {
            dui.tmax_sec = st.atime_s;
            dui.tmax_nsec = st.atime_ns;
        },
        .ctime => {
            dui.tmax_sec = st.ctime_s;
            dui.tmax_nsec = st.ctime_ns;
        },
    }
    var to_print = dui;
    if (is_dir) {
        to_print.add(children.ent);
        if (!s.separate_dirs) to_print.add(children.subdir);
        parent.subdir.add(children.ent);
        parent.subdir.add(children.subdir);
    }
    if (!(s.separate_dirs and is_dir)) parent.ent.add(dui);
    s.total.add(dui);

    if ((is_dir and level <= s.max_depth) or (s.opt_all and level <= s.max_depth) or level == 0) {
        const v: u64 = if (s.inodes) to_print.inodes else to_print.size;
        // (The smallest threshold has no positive i64.)
        const keep = if (s.threshold < 0) v <= @abs(s.threshold) else v >= @as(u64, @intCast(s.threshold));
        if (keep) s.printSize(to_print, path);
    }
    return ok;
}

test "exclude patterns match whole names and trailing components" {
    const env: Env = .{ .io = std.testing.io, .gpa = std.testing.allocator };
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var d = Du.init(env, .{ .excludes = &.{ "*.o", "skip" } }, &aw.writer, .none);
    defer d.deinit();
    try std.testing.expect(d.excluded("a/b.o"));
    try std.testing.expect(d.excluded("x/skip"));
    try std.testing.expect(!d.excluded("x/skipper"));
}
