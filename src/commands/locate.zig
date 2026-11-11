// SPDX-License-Identifier: GPL-2.0-or-later
//! locate — find files by name in a database made by updatedb. Reference: GNU
//! findutils 4.10 (locate/locate.c). Reads GNU LOCATE02 and slocate databases;
//! the old bigram format is not supported.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const posixre = @import("../posixre.zig");
const regex = @import("regex");
const fnmatch = @import("../fnmatch.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const LX = std.os.linux;
const Io = std.Io;

pub const default_db = "/usr/local/var/locatedb";

const Check = enum { either, existing, non_existing };

const Stats = struct {
    count: u64 = 0,
    length: u64 = 0,
    whitespace: u64 = 0,
    newline: u64 = 0,
    highbit: u64 = 0,
};

const L = struct {
    ctx: cli.Context,
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    check: Check = .either,
    follow: bool = true,
    ignore_case: bool = false,
    just_count: bool = false,
    basename_only: bool = false,
    use_limit: bool = false,
    limit: u64 = 0,
    items_accepted: u64 = 0,
    use_regex: bool = false,
    regextype: u8 = 'e',
    stats: bool = false,
    op_and: bool = false,
    print: bool = false,
    sep: u8 = '\n',
    warn_days: u64 = 8,
    results_filtered: bool = false,
    stat_acc: Stats = .{},
};

const Matcher = union(enum) {
    glob: []const u8,
    sub: []const u8,
    re: *regex.Regex,
};

fn oom(ctx: cli.Context) noreturn {
    cli.warn(ctx, "memory exhausted", .{});
    std.process.exit(1);
}

fn flush(l: *L) void {
    if (l.out.items.len > 0) {
        _ = sys.writeAllFd(1, l.out.items);
        l.out.clearRetainingCapacity();
    }
}

fn q(l: *L, text: []const u8) []const u8 {
    return std.fmt.allocPrint(l.gpa, "{f}", .{cli.quoteC(text)}) catch oom(l.ctx);
}

fn die(l: *L, comptime fmt: []const u8, args: anytype) noreturn {
    flush(l);
    cli.warn(l.ctx, fmt, args);
    std.process.exit(1);
}

fn usageText(ctx: cli.Context) []const u8 {
    _ = ctx;
    return
    \\Usage: %s [-d path | --database=path] [-e | -E | --[non-]existing]
    \\      [-i | --ignore-case] [-w | --wholename] [-b | --basename]
    \\      [--limit=N | -l N] [-S | --statistics] [-0 | --null] [-c | --count]
    \\      [-P | -H | --nofollow] [-L | --follow] [-m | --mmap] [-s | --stdio]
    \\      [-A | --all] [-p | --print] [-r | --regex] [--regextype=TYPE]
    \\      [--max-database-age D] [--version] [--help]
    \\      pattern...
    \\Please see also the documentation at https://www.gnu.org/software/findutils/.
    \\You can report (and track progress on fixing) bugs in the "%s"
    \\program via the GNU findutils bug-reporting page at
    \\https://savannah.gnu.org/bugs/?group=findutils or, if
    \\you have no web access, by sending email to <bug-findutils@gnu.org>.
    \\
    ;
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

fn readAll(l: *L, fd: i32, name: []const u8) ?[]u8 {
    var data: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    var err: LX.E = .SUCCESS;
    while (true) {
        const n = sys.readFd(fd, &buf, &err) orelse break;
        _ = name;
        if (n == 0) break;
        data.appendSlice(l.gpa, buf[0..n]) catch oom(l.ctx);
    }
    return data.items;
}

const RegexType = struct { code: u8 };

fn regexTypeCode(name: []const u8) ?u8 {
    const eq = std.mem.eql;
    if (eq(u8, name, "posix-basic") or eq(u8, name, "ed") or eq(u8, name, "sed")) return 'b';
    if (eq(u8, name, "grep")) return 'r';
    if (eq(u8, name, "posix-minimal-basic")) return 'm';
    if (eq(u8, name, "posix-extended")) return 'x';
    if (eq(u8, name, "posix-egrep") or eq(u8, name, "egrep")) return 'g';
    if (eq(u8, name, "awk")) return 'a';
    if (eq(u8, name, "gnu-awk")) return 'p';
    if (eq(u8, name, "posix-awk")) return 'x';
    if (eq(u8, name, "emacs")) return 'e';
    if (eq(u8, name, "findutils-default")) return 'd';
    return null;
}

fn compileRegex(l: *L, pat: []const u8) *regex.Regex {
    var conv: []const u8 = pat;
    var ere = false;
    var lenient = false;
    switch (l.regextype) {
        'b' => ere = false,
        'r' => {
            ere = false;
            lenient = true;
        },
        'm' => {
            ere = false;
            lenient = true;
            conv = posixre.minimalBasic(l.gpa, pat);
        },
        'x' => ere = true,
        'g' => {
            ere = true;
            lenient = true;
        },
        'a', 'p' => {
            ere = true;
            conv = posixre.awkEre(l.gpa, pat, l.regextype == 'a');
        },
        else => {
            conv = posixre.emacsToEre(l.gpa, pat, l.regextype == 'e');
            ere = true;
        },
    }
    const body = posixre.translateOpts(l.gpa, conv, ere, .{ .icase = l.ignore_case, .lenient_brace = lenient }) catch die(l, "{s}", .{posixre.diagnoseMode(conv, ere)});
    const src = std.fmt.allocPrint(l.gpa, "(?s){s}", .{body}) catch oom(l.ctx);
    const re = l.gpa.create(regex.Regex) catch oom(l.ctx);
    re.* = regex.Regex.compile(l.gpa, src, .{ .dialect = .perl, .ignore_case = l.ignore_case, .limits = posixre.big_limits }, null) catch die(l, "{s}", .{posixre.diagnoseMode(conv, ere)});
    return re;
}

fn matchOne(l: *L, m: Matcher, name: []const u8) bool {
    switch (m) {
        .glob => |g| return fnmatch.match(g, name, .{ .casefold = l.ignore_case }),
        .sub => |s| return if (l.ignore_case) containsCase(name, s) else std.mem.indexOf(u8, name, s) != null,
        .re => |re| {
            var sr = re.searcher(l.gpa) catch oom(l.ctx);
            defer sr.deinit();
            return (sr.find(name, 0) catch null) != null;
        },
    }
}

/// Search one database image. Returns false to stop searching altogether.
fn searchDb(l: *L, data: []const u8, dbname: []const u8, patterns: []const []const u8, size: u64, mtime: ?[2]i64) void {
    var pos: usize = 0;
    var slocate = false;
    var seclevel: u8 = 0;
    if (data.len >= 2 and data[1] == 0 and std.ascii.isDigit(data[0])) {
        seclevel = data[0] - '0';
        if (seclevel > 1) {
            flush(l);
            cli.warn(l.ctx, "{s} is an slocate database of unsupported security level {d}; skipping it.", .{ q(l, dbname), seclevel });
            return;
        }
        slocate = true;
        pos = 2;
    }
    var check = l.check;
    if (slocate and seclevel > 0) {
        if (l.check == .non_existing) {
            flush(l);
            cli.warn(l.ctx, "You specified the -E option, but that option cannot be used with slocate-format databases with a non-zero security level.  No results will be generated for this database.\n", .{});
            return;
        }
        if (check != .existing) {
            if (l.print or l.stats) {
                flush(l);
                cli.warn(l.ctx, "{s} is an slocate database.  Turning on the '-e' option.", .{q(l, dbname)});
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
        if (data.len < 256) die(l, "Old-format locate database {s} is too short to be valid", .{q(l, dbname)});
        die(l, "old-format locate database {s} is not supported", .{q(l, dbname)});
    }

    var matchers: std.ArrayList(Matcher) = .empty;
    l.results_filtered = false;
    for (patterns) |pat| {
        l.results_filtered = true;
        if (l.use_regex) {
            matchers.append(l.gpa, .{ .re = compileRegex(l, pat) }) catch oom(l.ctx);
        } else if (hasMeta(pat)) {
            matchers.append(l.gpa, .{ .glob = pat }) catch oom(l.ctx);
        } else matchers.append(l.gpa, .{ .sub = pat }) catch oom(l.ctx);
    }
    if (check != .either) l.results_filtered = true;
    l.stat_acc = .{};

    if (l.stats) {
        const s = std.fmt.allocPrint(l.gpa, "Database {s} is in the {s} format.\n", .{ dbname, format_name }) catch oom(l.ctx);
        l.out.appendSlice(l.gpa, s) catch oom(l.ctx);
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
        if (count > len or count < 0) die(l, "locate database {s} is corrupt or invalid", .{q(l, dbname)});
        // read the suffix up to NUL
        var e = pos;
        while (e < data.len and data[e] != 0) e += 1;
        if (e >= data.len) break;
        path.shrinkRetainingCapacity(@intCast(count));
        path.appendSlice(l.gpa, data[pos..e]) catch oom(l.ctx);
        pos = e + 1;
        len = @intCast(path.items.len);
        if (len < 1) die(l, "locate database {s} is corrupt or invalid", .{q(l, dbname)});
        c_opt = if (pos < data.len) data[pos] else null;
        if (c_opt != null) pos += 1;

        // evaluate
        const original = path.items;
        const munged = if (l.basename_only) lastComponent(original) else original;
        var ok = true;
        if (matchers.items.len > 0) {
            if (l.op_and) {
                for (matchers.items) |m| {
                    if (!matchOne(l, m, munged)) {
                        ok = false;
                        break;
                    }
                }
            } else {
                ok = false;
                for (matchers.items) |m| {
                    if (matchOne(l, m, munged)) {
                        ok = true;
                        break;
                    }
                }
            }
        }
        if (!ok) continue;
        if (check != .either) {
            var err: LX.E = .SUCCESS;
            const exists = sys.fileStat(original, l.follow, &err) != null;
            if (check == .existing and !exists) continue;
            if (check == .non_existing and exists) continue;
        }
        if (l.stats) {
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
        if (l.print) {
            l.out.appendSlice(l.gpa, original) catch oom(l.ctx);
            l.out.append(l.gpa, l.sep) catch oom(l.ctx);
            if (l.out.items.len > 65536) flush(l);
        }
        l.items_accepted += 1;
        if (l.use_limit and l.items_accepted >= l.limit) break;
    }
    if (l.stats and (size != 0 or mtime != null)) printStats(l, patterns.len, size, mtime);
}

fn printStats(l: *L, argc: usize, size: u64, mtime: ?[2]i64) void {
    const w = &l.out;
    if (mtime) |mt| {
        const zone = tzmod.load(l.gpa, l.ctx.io, cli.getenv(l.ctx, "TZ"));
        const tm = tzmod.localtime(&zone, mt[0]);
        var tb: std.ArrayList(u8) = .empty;
        defer tb.deinit(l.gpa);
        strftime.format(&tb, l.gpa, "%Y:%m:%d %H:%M:%S", &tm, mt[0], 0) catch oom(l.ctx);
        const s1 = std.fmt.allocPrint(l.gpa, "Database was last modified at {s}.{d:0>9}", .{ tb.items, @as(u64, @intCast(mt[1])) }) catch oom(l.ctx);
        w.appendSlice(l.gpa, s1) catch oom(l.ctx);
        tb.clearRetainingCapacity();
        strftime.format(&tb, l.gpa, "%z", &tm, mt[0], 0) catch oom(l.ctx);
        const s2 = std.fmt.allocPrint(l.gpa, " {s}\n", .{tb.items}) catch oom(l.ctx);
        w.appendSlice(l.gpa, s2) catch oom(l.ctx);
    }
    const st = l.stat_acc;
    const a = std.fmt.allocPrint(l.gpa, "Locate database size: {d} byte{s}\n", .{ size, if (size == 1) "" else "s" }) catch oom(l.ctx);
    w.appendSlice(l.gpa, a) catch oom(l.ctx);
    const b = std.fmt.allocPrint(l.gpa, "{s}: {d}\n", .{ if (l.results_filtered) "Matching Filenames" else "All Filenames", st.count }) catch oom(l.ctx);
    w.appendSlice(l.gpa, b) catch oom(l.ctx);
    const c = std.fmt.allocPrint(l.gpa, "File names have a cumulative length of {d} bytes.\nOf those file names,\n\n\t{d} contain whitespace, \n\t{d} contain newline characters, \n\tand {d} contain characters with the high bit set.\n", .{ st.length, st.whitespace, st.newline, st.highbit }) catch oom(l.ctx);
    w.appendSlice(l.gpa, c) catch oom(l.ctx);
    if (argc == 0) {
        if (l.results_filtered) {
            w.appendSlice(l.gpa, "Some filenames may have been filtered out, so we cannot compute the compression ratio.\n") catch oom(l.ctx);
        } else if (st.length != 0) {
            const ratio = 100.0 * (@as(f64, @floatFromInt(st.length)) - @as(f64, @floatFromInt(size))) / @as(f64, @floatFromInt(st.length));
            const d = std.fmt.allocPrint(l.gpa, "Compression ratio {d:.2}% (higher is better)\n", .{ratio}) catch oom(l.ctx);
            w.appendSlice(l.gpa, d) catch oom(l.ctx);
        } else w.appendSlice(l.gpa, "Compression ratio is undefined\n") catch oom(l.ctx);
    }
    w.append(l.gpa, '\n') catch oom(l.ctx);
}

pub fn main(ctx: cli.Context) u8 {
    var l = L{ .ctx = ctx, .gpa = std.heap.smp_allocator };
    var p = getopt.Parser.init(ctx, "Abcd:eEil:prsm0SwHPL", &.{
        .{ .name = "database", .arg = .required, .id = 'd' },
        .{ .name = "existing", .id = 'e' },
        .{ .name = "non-existing", .id = 'E' },
        .{ .name = "ignore-case", .id = 'i' },
        .{ .name = "all", .id = 'A' },
        .{ .name = "null", .id = '0' },
        .{ .name = "count", .id = 'c' },
        .{ .name = "wholename", .id = 'w' },
        .{ .name = "wholepath", .id = 'w' },
        .{ .name = "basename", .id = 'b' },
        .{ .name = "print", .id = 'p' },
        .{ .name = "stdio", .id = 's' },
        .{ .name = "mmap", .id = 'm' },
        .{ .name = "limit", .arg = .required, .id = 'l' },
        .{ .name = "regex", .id = 'r' },
        .{ .name = "regextype", .arg = .required, .id = 2000 },
        .{ .name = "statistics", .id = 'S' },
        .{ .name = "follow", .id = 'L' },
        .{ .name = "nofollow", .id = 'P' },
        .{ .name = "max-database-age", .arg = .required, .id = 2001 },
    });
    defer p.deinit();
    var db_path: ?[]const u8 = cli.getenv(ctx, "LOCATE_PATH");
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            '0' => {
                l.sep = 0;
            },
            'A' => l.op_and = true,
            'b' => l.basename_only = true,
            'c' => l.just_count = true,
            'd' => db_path = o.arg.?,
            'e' => l.check = .existing,
            'E' => l.check = .non_existing,
            'i' => l.ignore_case = true,
            'p' => l.print = true,
            'w' => l.basename_only = false,
            'r' => l.use_regex = true,
            'S' => l.stats = true,
            'L' => l.follow = true,
            'P', 'H' => l.follow = false,
            's', 'm' => {},
            'l' => {
                const a = o.arg.?;
                var dend: usize = 0;
                while (dend < a.len and std.ascii.isDigit(a[dend])) dend += 1;
                if (dend == 0) {
                    if (o.is_long) cli.warn(ctx, "invalid --limit argument {s}", .{q(&l, a)}) else cli.warn(ctx, "invalid -l argument {s}", .{q(&l, a)});
                    return 1;
                }
                const v = std.fmt.parseInt(u64, a[0..dend], 10) catch {
                    if (o.is_long) cli.warn(ctx, "--limit argument {s} too large", .{q(&l, a)}) else cli.warn(ctx, "-l argument {s} too large", .{q(&l, a)});
                    return 1;
                };
                l.limit = v;
                l.use_limit = true;
            },
            2000 => {
                l.regextype = regexTypeCode(o.arg.?) orelse {
                    cli.warn(ctx, "Unknown regular expression type {s}; valid types are 'findutils-default', 'ed', 'emacs', 'gnu-awk', 'grep', 'posix-awk', 'awk', 'posix-basic', 'posix-egrep', 'egrep', 'posix-extended', 'posix-minimal-basic', 'sed'.", .{q(&l, o.arg.?)});
                    return 1;
                };
            },
            2001 => {
                const a = o.arg.?;
                if (a.len == 0) {
                    cli.warn(ctx, "The argument for option --max-database-age must not be empty", .{});
                    return 1;
                }
                l.warn_days = std.fmt.parseInt(u64, a, 10) catch {
                    cli.warn(ctx, "Invalid argument {s} for option --max-database-age", .{q(&l, a)});
                    return 1;
                };
            },
            getopt.help_id => {
                const t = usageText(ctx);
                const a1 = std.mem.replaceOwned(u8, l.gpa, t, "%s", ctx.name) catch return 1;
                return if (cli.writeStdout(ctx.io, a1)) 0 else 1;
            },
            getopt.version_id => {
                const v =
                    \\locate (GNU findutils) 4.10.0
                    \\Copyright (C) 2024 Free Software Foundation, Inc.
                    \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
                    \\This is free software: you are free to change and redistribute it.
                    \\There is NO WARRANTY, to the extent permitted by law.
                    \\
                    \\Written by Eric B. Decker, James Youngman, and Kevin Dalley.
                    \\
                ;
                return if (cli.writeStdout(ctx.io, v)) 0 else 1;
            },
            else => return 1,
        },
    };
    const patterns = p.operands.items;
    if (!l.just_count and !l.stats) l.print = true;
    if (l.stats) {
        if (patterns.len == 0) l.use_limit = false;
    } else if (!l.just_count and patterns.len == 0) {
        cli.warn(ctx, "pattern argument expected", .{});
        cli.warn(ctx, "Try '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var found: u64 = 0;
    var did_stdin = false;
    var dbs: std.ArrayList([]const u8) = .empty;
    if (db_path) |dp| {
        var it = std.mem.splitScalar(u8, dp, ':');
        while (it.next()) |e| dbs.append(l.gpa, e) catch oom(ctx);
    } else {
        // the system database; a missing one is not an error
        dbs.append(l.gpa, "\x00default") catch oom(ctx);
    }
    for (dbs.items) |elt| {
        if (l.use_limit and l.limit <= l.items_accepted) break;
        var fd: i32 = -1;
        var dbname: []const u8 = elt;
        if (std.mem.eql(u8, elt, "\x00default")) {
            var err: LX.E = .SUCCESS;
            fd = sys.openFd(default_db, sys.O.RDONLY, 0, &err) orelse blk: {
                break :blk sys.openFd("/var/lib/slocate/slocate.db", sys.O.RDONLY, 0, &err) orelse break;
            };
            dbname = default_db;
        } else if (std.mem.eql(u8, elt, "-")) {
            if (did_stdin) {
                flush(&l);
                cli.warn(ctx, "warning: the locate database can only be read from stdin once.", .{});
                return 0;
            }
            did_stdin = true;
            fd = 0;
            dbname = "<stdin>";
        } else {
            if (elt.len == 0 or std.mem.eql(u8, elt, ".")) dbname = default_db;
            var err: LX.E = .SUCCESS;
            fd = sys.openFd(dbname, sys.O.RDONLY, 0, &err) orelse {
                flush(&l);
                cli.warn(ctx, "{s}: {s}", .{ q(&l, dbname), sys.errnoText(err) });
                return 0;
            };
        }
        var size: u64 = 0;
        var mtime: ?[2]i64 = null;
        {
            var serr: LX.E = .SUCCESS;
            if (sys.fstatFd(fd, &serr)) |st| {
                size = st.size;
                mtime = .{ st.mtime_s, st.mtime_ns };
                const now = Io.Timestamp.now(ctx.io, .real);
                const now_s: i64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
                const age: f64 = @floatFromInt(now_s - st.mtime_s);
                const warn_s: f64 = @floatFromInt(@as(u32, 86400) *% @as(u32, @truncate(l.warn_days)));
                if (age > warn_s) {
                    flush(&l);
                    cli.warn(ctx, "warning: database {s} is more than {d} days old (actual age is {d:.1} days)", .{ q(&l, dbname), l.warn_days, age / 86400.0 });
                }
            } else {
                flush(&l);
                cli.warn(ctx, "{s}: {s}", .{ q(&l, dbname), sys.errnoText(serr) });
            }
        }
        const data = readAll(&l, fd, dbname) orelse break;
        if (fd != 0) _ = sys.closeFd(fd);
        searchDb(&l, data, dbname, patterns, size, mtime);
        found = l.items_accepted;
    }
    if (l.just_count) {
        const s = std.fmt.allocPrint(l.gpa, "{d}\n", .{found}) catch oom(ctx);
        l.out.appendSlice(l.gpa, s) catch oom(ctx);
    }
    flush(&l);
    if (found > 0 or (l.use_limit and l.limit == 0) or l.stats) return 0;
    return 1;
}
