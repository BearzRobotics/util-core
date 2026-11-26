// SPDX-License-Identifier: GPL-2.0-or-later
//! locate library: find files by name in databases made by updatedb.
//! Reference: GNU findutils 4.10 (locate/locate.c). Reads GNU LOCATE02 and
//! slocate databases; the old bigram format is not supported.
//!
//! `run` searches the databases named by `Options.database_path` for the
//! patterns, writes the matching names (or the count, or the statistics) to a
//! caller-supplied writer and reports database problems through the Observer.
//! Fatal conditions (a corrupt database, a bad regular expression) are
//! reported as an event and returned as `error.Fatal`; the executable exits 1.
//!
//! Deviations (also in docs/compatibility/locate.md): a failed write to the
//! output writer is dropped silently, as the executable always did, and
//! `Result.write_failed` tells the caller.

const std = @import("std");
const rx = @import("../regexutil.zig");
const Io = std.Io;
const LX = std.os.linux;
const common = @import("common.zig");
const fu = @import("fu_common.zig");
const sys = @import("../sys.zig");
const regex = @import("regex");
const fnmatch = @import("../fnmatch.zig");
const quote = @import("../quote.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");

pub const Env = common.Env;
pub const RegexSyntax = fu.RegexSyntax;

pub const default_db = "/usr/local/var/locatedb";

pub const Check = enum { either, existing, non_existing };

pub const Options = struct {
    /// Colon-separated database list as -d / LOCATE_PATH give it: "-" is
    /// standard input, an empty element or "." is the default database. Null
    /// searches the system database (a missing one is not an error).
    database_path: ?[]const u8 = null,
    /// Standard input for a "-" database element.
    stdin: ?Io.File = null,
    check: Check = .either,
    /// Follow symbolic links when checking existence (-L).
    follow: bool = true,
    ignore_case: bool = false,
    /// -c: print only the number of matches.
    count_only: bool = false,
    basename_only: bool = false,
    /// Stop after this many matches.
    limit: ?u64 = null,
    use_regex: bool = false,
    regex_syntax: RegexSyntax = .emacs,
    statistics: bool = false,
    /// -A: every pattern must match (default: any).
    match_all: bool = false,
    /// Print the matching names.
    print: bool = true,
    /// Terminator after each name (0 for -0).
    separator: u8 = '\n',
    /// The writer is a terminal: as GNU locate does, show the unprintable
    /// characters of names as '?' (not with a NUL separator). The names in a
    /// database were chosen by whoever created the files.
    terminal: bool = false,
    /// UTF-8 locale: which characters `terminal` takes for printable.
    utf8: bool = false,
    /// --max-database-age in days.
    max_age_days: u64 = 8,
};

pub const Event = union(enum) {
    /// The database could not be opened; the run ends successfully (GNU).
    open_failed: struct { name: []const u8, text: []const u8 },
    stat_failed: struct { name: []const u8, text: []const u8 },
    /// "-" given twice; the run ends successfully.
    stdin_twice,
    database_old: struct { name: []const u8, max_days: u64, age_days: f64 },
    unsupported_slocate_level: struct { name: []const u8, level: u8 },
    /// -E with a slocate database of non-zero security level.
    slocate_non_existing_unsupported,
    /// slocate database: -e turned on (only reported with output or -S).
    slocate_existing_forced: []const u8,
    // Fatal (the run returns error.Fatal):
    old_format_too_short: []const u8,
    old_format: []const u8,
    corrupt: []const u8,
    /// A pattern is not a valid regular expression; the text is the diagnostic.
    bad_regex: []const u8,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    found: u64 = 0,
    /// A database could not be opened (or stdin was named twice): the run
    /// ended early with status 0 and no count line.
    ended_early: bool = false,
    write_failed: bool = false,
    /// The executable's exit status (0 when something matched).
    exit_status: u8 = 1,
};

const Stats = struct {
    count: u64 = 0,
    length: u64 = 0,
    whitespace: u64 = 0,
    newline: u64 = 0,
    highbit: u64 = 0,
};

const Error = error{ OutOfMemory, Fatal };

const Matcher = union(enum) {
    glob: []const u8,
    sub: []const u8,
    re: *regex.Regex,
};

const L = struct {
    env: Env,
    /// Per-run arena.
    gpa: std.mem.Allocator,
    o: Options,
    observer: Observer,
    writer: *Io.Writer,
    out: std.ArrayList(u8) = .empty,
    items_accepted: u64 = 0,
    results_filtered: bool = false,
    stat_acc: Stats = .{},
    write_failed: bool = false,
};

fn flush(l: *L) void {
    if (l.out.items.len > 0) {
        l.writer.writeAll(l.out.items) catch {
            l.write_failed = true;
        };
        l.out.clearRetainingCapacity();
    }
    l.writer.flush() catch {
        l.write_failed = true;
    };
}

fn fatal(l: *L, ev: Event) error{Fatal} {
    flush(l);
    l.observer.emit(ev);
    return error.Fatal;
}

fn lastComponent(path: []const u8) []const u8 {
    // gnulib last_component: skip leading slashes, then take what follows
    // the last slash that is followed by a non-slash
    var base: usize = 0;
    while (base < path.len and path[base] == '/') base += 1;
    var last_slash = false;
    var p = base;
    while (p < path.len) : (p += 1) {
        if (path[p] == '/') {
            last_slash = true;
        } else if (last_slash) {
            base = p;
            last_slash = false;
        }
    }
    return path[base..];
}

fn hasMeta(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?[]\\") != null;
}

fn containsCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

fn readAll(l: *L, fd: sys.Handle) Error![]u8 {
    var data: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    var err: LX.E = .SUCCESS;
    while (true) {
        const n = sys.readFd(fd, &buf, &err) orelse break;
        if (n == 0) break;
        try data.appendSlice(l.gpa, buf[0..n]);
    }
    return data.items;
}

fn matchOne(l: *L, m: Matcher, name: []const u8) Error!bool {
    switch (m) {
        .glob => |g| return fnmatch.match(g, name, .{ .casefold = l.o.ignore_case }),
        .sub => |s| return if (l.o.ignore_case) containsCase(name, s) else std.mem.indexOf(u8, name, s) != null,
        .re => |re| {
            var sr = try rx.searcher(re, l.gpa);
            defer sr.deinit();
            return (sr.find(name, 0) catch null) != null;
        },
    }
}

/// Search one database image. Stops early when the limit is reached.
fn searchDb(l: *L, data: []const u8, dbname: []const u8, patterns: []const []const u8, size: u64, mtime: ?[2]i64) Error!void {
    var pos: usize = 0;
    var slocate = false;
    var seclevel: u8 = 0;
    if (data.len >= 2 and data[1] == 0 and std.ascii.isDigit(data[0])) {
        seclevel = data[0] - '0';
        if (seclevel > 1) {
            flush(l);
            l.observer.emit(.{ .unsupported_slocate_level = .{ .name = dbname, .level = seclevel } });
            return;
        }
        slocate = true;
        pos = 2;
    }
    var check = l.o.check;
    if (slocate and seclevel > 0) {
        if (l.o.check == .non_existing) {
            flush(l);
            l.observer.emit(.slocate_non_existing_unsupported);
            return;
        }
        if (check != .existing) {
            if (l.o.print or l.o.statistics) {
                flush(l);
                l.observer.emit(.{ .slocate_existing_forced = dbname });
            }
            check = .existing;
        }
    }
    var format_name: []const u8 = "GNU LOCATE02";
    if (slocate) {
        format_name = "slocate";
    } else if (data.len >= 10 and std.mem.eql(u8, data[0..10], "\x00LOCATE02\x00")) {
        pos = 10;
    } else {
        if (data.len < 256) return fatal(l, .{ .old_format_too_short = dbname });
        return fatal(l, .{ .old_format = dbname });
    }

    var matchers: std.ArrayList(Matcher) = .empty;
    l.results_filtered = false;
    for (patterns) |pat| {
        l.results_filtered = true;
        if (l.o.use_regex) {
            var failure: fu.RegexFailure = undefined;
            const re = fu.compileRegex(l.gpa, pat, l.o.regex_syntax, l.o.ignore_case, false, &failure) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadRegex => return fatal(l, .{ .bad_regex = failure.text }),
            };
            try matchers.append(l.gpa, .{ .re = re });
        } else if (hasMeta(pat)) {
            try matchers.append(l.gpa, .{ .glob = pat });
        } else try matchers.append(l.gpa, .{ .sub = pat });
    }
    if (check != .either) l.results_filtered = true;
    l.stat_acc = .{};

    if (l.o.statistics) {
        try l.out.print(l.gpa, "Database {s} is in the {s} format.\n", .{ dbname, format_name });
    }

    var path: std.ArrayList(u8) = .empty;
    var count: i64 = 0;
    var len: i64 = 0;
    var c_opt: ?u8 = null;
    if (slocate) {
        c_opt = if (pos < data.len) 0 else null;
    } else c_opt = if (pos < data.len) data[pos] else null;
    if (!slocate and c_opt != null) pos += 1;
    while (c_opt) |c| {
        // decode the offset
        var delta: i64 = undefined;
        if (c == 0x80) {
            if (pos + 1 >= data.len) break;
            const hi: i8 = @bitCast(data[pos]);
            const v: i16 = (@as(i16, hi) << 8) | data[pos + 1];
            pos += 2;
            delta = v;
        } else if (c > 127) {
            delta = @as(i64, c) - 256;
        } else delta = c;
        count += delta;
        if (count > len or count < 0) return fatal(l, .{ .corrupt = dbname });
        // read the suffix up to NUL
        var e = pos;
        while (e < data.len and data[e] != 0) e += 1;
        if (e >= data.len) break;
        path.shrinkRetainingCapacity(@intCast(count));
        try path.appendSlice(l.gpa, data[pos..e]);
        pos = e + 1;
        len = @intCast(path.items.len);
        if (len < 1) return fatal(l, .{ .corrupt = dbname });
        c_opt = if (pos < data.len) data[pos] else null;
        if (c_opt != null) pos += 1;

        // evaluate
        const original = path.items;
        const munged = if (l.o.basename_only) lastComponent(original) else original;
        var ok = true;
        if (matchers.items.len > 0) {
            if (l.o.match_all) {
                for (matchers.items) |m| {
                    if (!try matchOne(l, m, munged)) {
                        ok = false;
                        break;
                    }
                }
            } else {
                ok = false;
                for (matchers.items) |m| {
                    if (try matchOne(l, m, munged)) {
                        ok = true;
                        break;
                    }
                }
            }
        }
        if (!ok) continue;
        if (check != .either) {
            var err: LX.E = .SUCCESS;
            const exists = sys.fileStat(original, l.o.follow, &err) != null;
            if (check == .existing and !exists) continue;
            if (check == .non_existing and exists) continue;
        }
        if (l.o.statistics) {
            const st = &l.stat_acc;
            st.count += 1;
            st.length += original.len;
            var hb = false;
            var ws = false;
            var nl = false;
            for (original) |ch| {
                if (ch & 128 != 0) hb = true;
                if (ch == '\n') {
                    nl = true;
                    ws = true;
                } else if (std.ascii.isWhitespace(ch)) ws = true;
            }
            if (hb) st.highbit += 1;
            if (ws) st.whitespace += 1;
            if (nl) st.newline += 1;
        }
        if (l.o.print) {
            if (l.o.terminal and l.o.separator != 0) {
                try quote.appendForTerminal(&l.out, l.gpa, original, l.o.utf8);
            } else try l.out.appendSlice(l.gpa, original);
            try l.out.append(l.gpa, l.o.separator);
            if (l.out.items.len > 65536) flush(l);
        }
        l.items_accepted += 1;
        if (l.o.limit) |lim| if (l.items_accepted >= lim) break;
    }
    if (l.o.statistics and (size != 0 or mtime != null)) try printStats(l, patterns.len, size, mtime);
}

fn printStats(l: *L, argc: usize, size: u64, mtime: ?[2]i64) Error!void {
    const w = &l.out;
    const gpa = l.gpa;
    if (mtime) |mt| {
        const zone = tzmod.load(gpa, l.env.io, l.env.getenv("TZ"));
        const tm = tzmod.localtime(&zone, mt[0]);
        var tb: std.ArrayList(u8) = .empty;
        defer tb.deinit(gpa);
        try strftime.format(&tb, gpa, "%Y:%m:%d %H:%M:%S", &tm, mt[0], 0);
        try w.print(gpa, "Database was last modified at {s}.{d:0>9}", .{ tb.items, @as(u64, @intCast(mt[1])) });
        tb.clearRetainingCapacity();
        try strftime.format(&tb, gpa, "%z", &tm, mt[0], 0);
        try w.print(gpa, " {s}\n", .{tb.items});
    }
    const st = l.stat_acc;
    try w.print(gpa, "Locate database size: {d} byte{s}\n", .{ size, if (size == 1) "" else "s" });
    try w.print(gpa, "{s}: {d}\n", .{ if (l.results_filtered) "Matching Filenames" else "All Filenames", st.count });
    try w.print(gpa, "File names have a cumulative length of {d} bytes.\nOf those file names,\n\n\t{d} contain whitespace, \n\t{d} contain newline characters, \n\tand {d} contain characters with the high bit set.\n", .{ st.length, st.whitespace, st.newline, st.highbit });
    if (argc == 0) {
        if (l.results_filtered) {
            try w.appendSlice(gpa, "Some filenames may have been filtered out, so we cannot compute the compression ratio.\n");
        } else if (st.length != 0) {
            const ratio = 100.0 * (@as(f64, @floatFromInt(st.length)) - @as(f64, @floatFromInt(size))) / @as(f64, @floatFromInt(st.length));
            try w.print(gpa, "Compression ratio {d:.2}% (higher is better)\n", .{ratio});
        } else try w.appendSlice(gpa, "Compression ratio is undefined\n");
    }
    try w.append(gpa, '\n');
}

/// Search the databases for `patterns` (no patterns: every name matches).
pub fn run(env: Env, options: Options, patterns: []const []const u8, writer: *Io.Writer, observer: Observer) Error!Result {
    var arena = std.heap.ArenaAllocator.init(env.gpa);
    defer arena.deinit();
    var l = L{ .env = env, .gpa = arena.allocator(), .o = options, .observer = observer, .writer = writer };
    const o = &l.o;

    var found: u64 = 0;
    var did_stdin = false;
    var dbs: std.ArrayList([]const u8) = .empty;
    if (o.database_path) |dp| {
        var it = std.mem.splitScalar(u8, dp, ':');
        while (it.next()) |e| try dbs.append(l.gpa, e);
    } else {
        // the system database; a missing one is not an error
        try dbs.append(l.gpa, "\x00default");
    }
    for (dbs.items) |elt| {
        if (o.limit) |lim| if (lim <= l.items_accepted) break;
        var fd: sys.Handle = sys.invalid_handle;
        var dbname: []const u8 = elt;
        if (std.mem.eql(u8, elt, "\x00default")) {
            var err: LX.E = .SUCCESS;
            fd = sys.openFd(default_db, sys.O.RDONLY, 0, &err) orelse blk: {
                break :blk sys.openFd("/var/lib/slocate/slocate.db", sys.O.RDONLY, 0, &err) orelse break;
            };
            dbname = default_db;
        } else if (std.mem.eql(u8, elt, "-")) {
            if (did_stdin or o.stdin == null) {
                flush(&l);
                observer.emit(.stdin_twice);
                return endedEarly(&l);
            }
            did_stdin = true;
            fd = o.stdin.?.handle;
            dbname = "<stdin>";
        } else {
            if (elt.len == 0 or std.mem.eql(u8, elt, ".")) dbname = default_db;
            var err: LX.E = .SUCCESS;
            fd = sys.openFd(dbname, sys.O.RDONLY, 0, &err) orelse {
                flush(&l);
                observer.emit(.{ .open_failed = .{ .name = dbname, .text = sys.errnoText(err) } });
                return endedEarly(&l);
            };
        }
        var size: u64 = 0;
        var mtime: ?[2]i64 = null;
        {
            var serr: LX.E = .SUCCESS;
            if (sys.fstatFd(fd, &serr)) |st| {
                size = st.size;
                mtime = .{ st.mtime_s, st.mtime_ns };
                const now = Io.Timestamp.now(env.io, .real);
                const now_s: i64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
                const age: f64 = @floatFromInt(now_s -| st.mtime_s);
                const warn_s: f64 = @floatFromInt(@as(u32, 86400) *% @as(u32, @truncate(o.max_age_days)));
                if (age > warn_s) {
                    flush(&l);
                    observer.emit(.{ .database_old = .{ .name = dbname, .max_days = o.max_age_days, .age_days = age / 86400.0 } });
                }
            } else {
                flush(&l);
                observer.emit(.{ .stat_failed = .{ .name = dbname, .text = sys.errnoText(serr) } });
            }
        }
        const data = try readAll(&l, fd);
        if (fd != Io.File.stdin().handle and !(o.stdin != null and fd == o.stdin.?.handle)) _ = sys.closeFd(fd);
        try searchDb(&l, data, dbname, patterns, size, mtime);
        found = l.items_accepted;
    }
    if (o.count_only) try l.out.print(l.gpa, "{d}\n", .{found});
    flush(&l);
    const ok = found > 0 or (o.limit != null and o.limit.? == 0) or o.statistics;
    return .{ .found = found, .write_failed = l.write_failed, .exit_status = if (ok) 0 else 1 };
}

fn endedEarly(l: *L) Result {
    return .{ .found = l.items_accepted, .ended_early = true, .write_failed = l.write_failed, .exit_status = 0 };
}

test "lastComponent follows gnulib" {
    try std.testing.expectEqualStrings("c", lastComponent("/a/b/c"));
    try std.testing.expectEqualStrings("c/", lastComponent("/a/b/c/"));
    try std.testing.expectEqualStrings("", lastComponent("/"));
}

test "hasMeta and containsCase" {
    try std.testing.expect(hasMeta("a*b"));
    try std.testing.expect(!hasMeta("abc"));
    try std.testing.expect(containsCase("Hello", "ELL"));
}
