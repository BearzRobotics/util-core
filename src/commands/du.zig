// SPDX-License-Identifier: GPL-2.0-or-later
//! du — estimate file space usage.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "du invocation"
//! (9.7), POSIX.1-2024 du, and GNU coreutils 9.6 src/du.c and lib/exclude.c
//! (the per-level accumulation, the skipped hard links and the exclude rules
//! were studied there and rewritten as a recursive walk).

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const human = @import("../human.zig");
const argmatch = @import("../argmatch.zig");
const fnmatch = @import("../fnmatch.zig");
const Io = std.Io;

const help_text = @embedFile("../help/du.txt");

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

const TimeType = enum { mtime, ctime, atime };

const Pattern = struct { text: []const u8, wildcard: bool };

const DevIno = struct { dev: u64, ino: u64 };

const S = struct {
    ctx: cli.Context,
    out: cli.Out,
    opt_all: bool = false,
    apparent_size: bool = false,
    count_all: bool = false,
    hash_all: bool = false,
    nul_terminate: bool = false,
    print_grand_total: bool = false,
    separate_dirs: bool = false,
    max_depth: u64 = std.math.maxInt(u64),
    threshold: i64 = 0,
    human_opts: u32 = 0,
    block_size: u64 = 1024,
    inodes: bool = false,
    show_time: bool = false,
    time_type: TimeType = .mtime,
    time_format: []const u8 = "",
    zone: tzmod.Zone = undefined,
    zone_loaded: bool = false,
    deref: enum { physical, comfollow, logical } = .physical,
    xdev: bool = false,
    patterns: std.ArrayList(Pattern) = .empty,
    seen: std.AutoHashMap(DevIno, void),
    total: Dui = .{},
    ancestors: std.ArrayList(DevIno) = .empty,

    fn printSize(s: *S, d: Dui, name: []const u8) void {
        var hb: [human.longest]u8 = undefined;
        const n = if (s.inodes) d.inodes else d.size;
        if (n == std.math.maxInt(u64)) {
            s.out.write("Infinity");
        } else s.out.write(human.readable(n, &hb, s.human_opts, 1, s.block_size));
        if (s.show_time) {
            s.out.writeByte('\t');
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(s.ctx.gpa);
            var ok = false;
            if (!s.zone_loaded) {
                s.zone = tzmod.load(s.ctx.gpa, s.ctx.io, cli.getenv(s.ctx, "TZ"));
                s.zone_loaded = true;
            }
            const tm = tzmod.localtime(&s.zone, d.tmax_sec);
            if (tm.year - 1900 <= std.math.maxInt(i32) and tm.year - 1900 >= std.math.minInt(i32)) {
                if (strftime.format(&text, s.ctx.gpa, s.time_format, &tm, d.tmax_sec, @intCast(@max(0, d.tmax_nsec)))) |_| {
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

    fn excluded(s: *S, f: []const u8) bool {
        for (s.patterns.items) |p| {
            if (p.wildcard) {
                if (fnmatch.match(p.text, f, .{})) return true;
                var i: usize = 0;
                while (i < f.len) : (i += 1) {
                    if (f[i] == '/' and i + 1 < f.len and f[i + 1] != '/') {
                        if (fnmatch.match(p.text, f[i + 1 ..], .{})) return true;
                    }
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

    fn addPattern(s: *S, text: []const u8) void {
        const gpa = s.ctx.gpa;
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

/// du.c process_file for one entry and (recursively) its children. `parent`
/// is the accumulator for the group of entries this one belongs to.
fn visit(s: *S, path: []const u8, level: u64, parent: *Level, root_dev: u64) bool {
    const ctx = s.ctx;
    var ok = true;
    const follow = switch (s.deref) {
        .logical => true,
        .comfollow => level == 0,
        .physical => false,
    };
    var err: std.os.linux.E = .SUCCESS;
    const st_opt = sys.fileStat(path, follow, &err);
    var dangling = false;
    if (st_opt == null and follow and err == .NOENT) {
        if (sys.fileStat(path, false, &err)) |_| {
            dangling = true;
        }
    }
    const is_excluded0 = s.excluded(path);
    var is_excluded = is_excluded0;
    if (!is_excluded0) {
        if (st_opt == null or dangling) {
            // fts reports a dangling symlink without an errno.
            if (dangling) {
                cli.warn(ctx, "cannot access {f}", .{cli.quoteA(path)});
            } else cli.warn(ctx, "cannot access {f}: {s}", .{ cli.quoteA(path), sys.errnoText(err) });
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
            cli.warn(ctx, "WARNING: Circular directory structure.\nThis almost certainly means that you have a corrupted file system.\nNOTIFY YOUR SYSTEM MANAGER.\nThe following directory is part of the cycle:\n  {f}", .{cli.quoteA(path)});
            return false;
        }
        return true;
    }

    var children: Level = .{};
    if (is_dir) {
        if (Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true })) |d| {
            var dir = d;
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
            s.ancestors.append(ctx.gpa, .{ .dev = devKey(st), .ino = st.ino }) catch {};
            for (names.items) |n| {
                // fts: one trailing slash of the parent is replaced.
                const base = if (path.len > 0 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
                const child = std.fmt.allocPrint(ctx.gpa, "{s}/{s}", .{ base, n }) catch continue;
                defer ctx.gpa.free(child);
                if (!visit(s, child, level + 1, &children, root_dev)) ok = false;
            }
            _ = s.ancestors.pop();
        } else |e| {
            const emap: std.os.linux.E = switch (e) {
                error.AccessDenied => .ACCES,
                error.PermissionDenied => .PERM,
                else => .IO,
            };
            cli.warn(ctx, "cannot read directory {f}: {s}", .{ cli.quoteA(path), sys.errnoText(emap) });
            ok = false;
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
        const keep = if (s.threshold < 0) v <= @as(u64, @intCast(-s.threshold)) else v >= @as(u64, @intCast(s.threshold));
        if (keep) s.printSize(to_print, path);
    }
    return ok;
}

fn parseThreshold(arg: []const u8) struct { err: human.StrtolError, value: i64 } {
    var i: usize = 0;
    while (i < arg.len and isSpace(arg[i])) i += 1;
    var neg = false;
    var rest = arg;
    if (i < arg.len and arg[i] == '-') {
        neg = true;
        rest = arg[i + 1 ..];
    } else if (i < arg.len and arg[i] == '+') {
        rest = arg[i + 1 ..];
    }
    // A second sign is not a number.
    if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) return .{ .err = .invalid, .value = 0 };
    const r = human.strtoumax(rest, "kKmMGTPEZYRQ0");
    if (r.err == .invalid) return .{ .err = .invalid, .value = 0 };
    var err = r.err;
    var v: i64 = undefined;
    if (neg) {
        if (r.value > @as(u64, 1) << 63) {
            v = std.math.minInt(i64);
            err = if (err == .ok) .overflow else err;
        } else v = if (r.value == @as(u64, 1) << 63) std.math.minInt(i64) else -@as(i64, @intCast(r.value));
    } else {
        if (r.value > std.math.maxInt(i64)) {
            v = std.math.maxInt(i64);
            err = if (err == .ok) .overflow else err;
        } else v = @intCast(r.value);
    }
    return .{ .err = err, .value = v };
}

fn xstrtolFatal(ctx: cli.Context, e: human.StrtolError, o: getopt.Opt, long: []const u8, short: u8, arg: []const u8) void {
    var nb: [48]u8 = undefined;
    const name = if (o.is_long) (std.fmt.bufPrint(&nb, "--{s}", .{long}) catch long) else (std.fmt.bufPrint(&nb, "-{c}", .{short}) catch "-?");
    switch (e) {
        .invalid => cli.warn(ctx, "invalid {s} argument {f}", .{ name, cli.quoteC(arg) }),
        .invalid_suffix_char, .invalid_suffix_char_with_overflow => cli.warn(ctx, "invalid suffix in {s} argument {f}", .{ name, cli.quoteC(arg) }),
        .overflow => cli.warn(ctx, "{s} argument {f} too large", .{ name, cli.quoteC(arg) }),
        .ok => {},
    }
}

const time_args = [_]argmatch.Entry{
    .{ .name = "atime", .value = 2 }, .{ .name = "access", .value = 2 }, .{ .name = "use", .value = 2 },
    .{ .name = "ctime", .value = 1 }, .{ .name = "status", .value = 1 },
};
const time_style_args = [_]argmatch.Entry{
    .{ .name = "full-iso", .value = 0 }, .{ .name = "long-iso", .value = 1 }, .{ .name = "iso", .value = 2 },
};

pub fn main(ctx: cli.Context) u8 {
    var s: S = .{ .ctx = ctx, .out = cli.Out.init(ctx.io), .seen = std.AutoHashMap(DevIno, void).init(ctx.gpa) };
    defer {
        for (s.patterns.items) |p| ctx.gpa.free(p.text);
        s.patterns.deinit(ctx.gpa);
        s.seen.deinit();
        s.ancestors.deinit(ctx.gpa);
        if (s.zone_loaded) s.zone.deinit();
    }
    const rc = realMain(&s);
    s.out.flush();
    return rc;
}

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

fn realMain(s: *S) u8 {
    const ctx = s.ctx;
    var ok = true;
    var max_depth_specified = false;
    var depth_negative = false;
    var depth_text: u64 = 0;
    var summarize_only = false;
    var files_from: ?[]const u8 = null;
    var time_style: ?[]const u8 = null;
    var scratch: std.ArrayList([]u8) = .empty;
    defer {
        for (scratch.items) |x| ctx.gpa.free(x);
        scratch.deinit(ctx.gpa);
    }

    const env_bs = cli.getenv(ctx, "BLOCK_SIZE") orelse cli.getenv(ctx, "BLOCKSIZE");
    {
        const bs = human.options(cli.getenv(ctx, "DU_BLOCK_SIZE"), env_bs, cli.getenv(ctx, "POSIXLY_CORRECT") != null);
        s.human_opts = bs.opts;
        s.block_size = bs.size;
    }

    var p = getopt.Parser.init(ctx, "0abd:chHklmst:xB:DLPSX:", &.{
        .{ .name = "all", .id = 'a' },
        .{ .name = "apparent-size", .id = 1100 },
        .{ .name = "block-size", .arg = .required, .id = 'B' },
        .{ .name = "bytes", .id = 'b' },
        .{ .name = "count-links", .id = 'l' },
        .{ .name = "dereference", .id = 'L' },
        .{ .name = "dereference-args", .id = 'D' },
        .{ .name = "exclude", .arg = .required, .id = 1101 },
        .{ .name = "exclude-from", .arg = .required, .id = 'X' },
        .{ .name = "files0-from", .arg = .required, .id = 1102 },
        .{ .name = "human-readable", .id = 'h' },
        .{ .name = "inodes", .id = 1105 },
        .{ .name = "si", .id = 1103 },
        .{ .name = "max-depth", .arg = .required, .id = 'd' },
        .{ .name = "null", .id = '0' },
        .{ .name = "no-dereference", .id = 'P' },
        .{ .name = "one-file-system", .id = 'x' },
        .{ .name = "separate-dirs", .id = 'S' },
        .{ .name = "summarize", .id = 's' },
        .{ .name = "total", .id = 'c' },
        .{ .name = "threshold", .arg = .required, .id = 't' },
        .{ .name = "time", .arg = .optional, .id = 1104 },
        .{ .name = "time-style", .arg = .required, .id = 1106 },
    });
    defer p.deinit();

    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            '0' => s.nul_terminate = true,
            'a' => s.opt_all = true,
            1100 => s.apparent_size = true,
            'b' => {
                s.apparent_size = true;
                s.human_opts = 0;
                s.block_size = 1;
            },
            'c' => s.print_grand_total = true,
            'h' => {
                s.human_opts = human.autoscale | human.si | human.base_1024;
                s.block_size = 1;
            },
            1103 => {
                s.human_opts = human.autoscale | human.si;
                s.block_size = 1;
            },
            'k' => {
                s.human_opts = 0;
                s.block_size = 1024;
            },
            'd' => {
                // xstrtoimax accepts negative numbers; such a depth shows
                // only the root (the root is always listed).
                const arg = o.arg.?;
                const trimmed = std.mem.trimStart(u8, arg, " \t\n\r\x0b\x0c");
                const neg = trimmed.len > 0 and trimmed[0] == '-';
                const r = human.strtoumax(if (neg) trimmed[1..] else arg, "");
                if (r.err == .ok and r.value <= std.math.maxInt(i64) and !(neg and trimmed.len > 1 and (trimmed[1] == '-' or trimmed[1] == '+'))) {
                    max_depth_specified = true;
                    depth_negative = neg and r.value != 0;
                    s.max_depth = if (neg) 0 else r.value;
                    depth_text = r.value;
                } else {
                    cli.warn(ctx, "invalid maximum depth {f}", .{cli.quoteC(arg)});
                    ok = false;
                }
            },
            'm' => {
                s.human_opts = 0;
                s.block_size = 1024 * 1024;
            },
            'l' => s.count_all = true,
            's' => summarize_only = true,
            't' => {
                const r = parseThreshold(o.arg.?);
                if (r.err != .ok) {
                    xstrtolFatal(ctx, r.err, o, "threshold", 't', o.arg.?);
                    return 1;
                }
                s.threshold = r.value;
                if (r.value == 0 and o.arg.?.len > 0 and o.arg.?[0] == '-') {
                    cli.warn(ctx, "invalid --threshold argument '-0'", .{});
                    return 1;
                }
            },
            'x' => s.xdev = true,
            'B' => {
                const bs = human.options(o.arg.?, null, false);
                if (bs.err != .ok) {
                    xstrtolFatal(ctx, bs.err, o, "block-size", 'B', o.arg.?);
                    return 1;
                }
                s.human_opts = bs.opts;
                s.block_size = bs.size;
            },
            'H', 'D' => s.deref = .comfollow,
            'L' => s.deref = .logical,
            'P' => s.deref = .physical,
            'S' => s.separate_dirs = true,
            'X' => {
                const f = Io.Dir.cwd().openFile(ctx.io, o.arg.?, .{}) catch |e| {
                    cli.warn(ctx, "{f}: {s}", .{ cli.quote(o.arg.?), cli.errText(e) });
                    ok = false;
                    continue;
                };
                defer f.close(ctx.io);
                var data: std.ArrayList(u8) = .empty;
                defer data.deinit(ctx.gpa);
                while (true) {
                    data.ensureUnusedCapacity(ctx.gpa, 8192) catch break;
                    const n = cli.readChunk(ctx.io, f, data.unusedCapacitySlice()) catch break;
                    if (n == 0) break;
                    data.items.len += n;
                }
                var start: usize = 0;
                var i: usize = 0;
                while (i < data.items.len) : (i += 1) {
                    if (data.items[i] == '\n') {
                        var end = i;
                        while (end > start and isSpace(data.items[end - 1])) end -= 1;
                        if (end > start) s.addPattern(data.items[start..end]);
                        start = i + 1;
                    }
                }
                if (start < data.items.len) {
                    var end = data.items.len;
                    while (end > start and isSpace(data.items[end - 1])) end -= 1;
                    if (end > start) s.addPattern(data.items[start..end]);
                }
            },
            1102 => files_from = o.arg.?,
            1101 => s.addPattern(o.arg.?),
            1105 => s.inodes = true,
            1104 => {
                s.show_time = true;
                s.time_type = .mtime;
                if (o.arg) |a| {
                    const v = argmatch.match(a, &time_args);
                    switch (v) {
                        .ok => |x| s.time_type = if (x == 2) .atime else .ctime,
                        else => {
                            argmatch.die(ctx, a, "--time", &time_args, v);
                            return 1;
                        },
                    }
                }
            },
            1106 => time_style = o.arg.?,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (!ok) return usageFail(ctx);

    if (s.opt_all and summarize_only) {
        cli.warn(ctx, "cannot both summarize and show all entries", .{});
        return usageFail(ctx);
    }
    if (summarize_only and max_depth_specified and s.max_depth == 0 and !depth_negative) {
        cli.warn(ctx, "warning: summarizing is the same as using --max-depth=0", .{});
    }
    if (summarize_only and max_depth_specified and (s.max_depth != 0 or depth_negative)) {
        if (depth_negative) {
            cli.warn(ctx, "warning: summarizing conflicts with --max-depth=-{d}", .{depth_text});
        } else cli.warn(ctx, "warning: summarizing conflicts with --max-depth={d}", .{s.max_depth});
        return usageFail(ctx);
    }
    if (summarize_only) s.max_depth = 0;
    if (s.inodes) {
        if (s.apparent_size) cli.warn(ctx, "warning: options --apparent-size and -b are ineffective with --inodes", .{});
        s.block_size = 1;
    }

    if (s.show_time) {
        var style: []const u8 = undefined;
        if (time_style) |t| {
            style = t;
        } else {
            const env = cli.getenv(ctx, "TIME_STYLE");
            if (env == null or std.mem.eql(u8, env.?, "locale")) {
                style = "long-iso";
            } else if (env.?.len > 0 and env.?[0] == '+') {
                style = if (std.mem.indexOfScalar(u8, env.?, '\n')) |nl| env.?[0..nl] else env.?;
            } else {
                var t = env.?;
                while (std.mem.startsWith(u8, t, "posix-")) t = t["posix-".len..];
                style = t;
            }
        }
        if (style.len > 0 and style[0] == '+') {
            s.time_format = style[1..];
        } else {
            const v = argmatch.match(style, &time_style_args);
            switch (v) {
                .ok => |x| s.time_format = switch (x) {
                    0 => "%Y-%m-%d %H:%M:%S.%N %z",
                    1 => "%Y-%m-%d %H:%M",
                    else => "%Y-%m-%d",
                },
                else => {
                    argmatch.die(ctx, style, "time style", &time_style_args, v);
                    return 1;
                },
            }
        }
    }

    const operands = p.operands.items;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    var files0_data: ?[]u8 = null;
    defer if (files0_data) |d| ctx.gpa.free(d);
    if (files_from) |ff| {
        if (operands.len > 0) {
            cli.warn(ctx, "extra operand {f}", .{cli.quoteC(operands[0])});
            cli.writeStderr(ctx, "file operands cannot be combined with --files0-from", .{});
            return usageFail(ctx);
        }
        const f: Io.File = if (std.mem.eql(u8, ff, "-")) Io.File.stdin() else Io.Dir.cwd().openFile(ctx.io, ff, .{}) catch |e| {
            cli.warn(ctx, "cannot open {f} for reading: {s}", .{ cli.quoteA(ff), cli.errText(e) });
            return 1;
        };
        var data: std.ArrayList(u8) = .empty;
        while (true) {
            data.ensureUnusedCapacity(ctx.gpa, 8192) catch break;
            const n = cli.readChunk(ctx.io, f, data.unusedCapacitySlice()) catch {
                cli.warn(ctx, "{f}: read error", .{cli.quote(ff)});
                ok = false;
                break;
            };
            if (n == 0) break;
            data.items.len += n;
        }
        if (!std.mem.eql(u8, ff, "-")) f.close(ctx.io);
        files0_data = data.toOwnedSlice(ctx.gpa) catch null;
        s.hash_all = true;
    } else {
        s.hash_all = operands.len > 1 or s.deref == .logical;
    }

    var n_args: usize = 0;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(ctx.gpa);
    if (files0_data) |d| {
        var start: usize = 0;
        var i: usize = 0;
        while (i < d.len) : (i += 1) {
            if (d[i] == 0) {
                queue.append(ctx.gpa, d[start..i]) catch {};
                start = i + 1;
            }
        }
        if (start < d.len) queue.append(ctx.gpa, d[start..]) catch {};
    } else if (files_from == null) {
        if (operands.len == 0) {
            queue.append(ctx.gpa, ".") catch {};
        } else queue.appendSlice(ctx.gpa, operands) catch {};
    }

    for (queue.items) |name| {
        n_args += 1;
        var skip = false;
        if (files_from != null and std.mem.eql(u8, files_from.?, "-") and std.mem.eql(u8, name, "-")) {
            cli.warn(ctx, "when reading file names from stdin, no file name of {f} allowed", .{cli.quoteA(name)});
            skip = true;
        }
        if (name.len == 0) {
            if (files_from == null) {
                cli.warn(ctx, "invalid zero-length file name", .{});
            } else cli.warn(ctx, "{f}:{d}: invalid zero-length file name", .{ cli.quote(files_from.?), n_args });
            skip = true;
        }
        if (skip) {
            ok = false;
            continue;
        }
        var top: Level = .{};
        var dev: u64 = 0;
        if (s.xdev) {
            var e: std.os.linux.E = .SUCCESS;
            if (sys.fileStat(name, s.deref != .physical, &e)) |st| dev = devKey(st);
        }
        if (!visit(s, name, 0, &top, dev)) ok = false;
    }

    if (s.print_grand_total) s.printSize(s.total, "total");
    return if (ok) 0 else 1;
}
