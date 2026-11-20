// SPDX-License-Identifier: GPL-2.0-or-later
//! The file and directory driver of diff: operand handling, binary
//! detection, directory merging, and the messages that are not hunks.

const std = @import("std");
const Io = std.Io;
const diff = @import("diff.zig");
const common = @import("common.zig");
const json = @import("../json.zig");
const tz = @import("../tz.zig");
const fnmatch = @import("../fnmatch.zig");
const diffsbs = @import("diffsbs.zig");

const Options = diff.Options;
const Env = diff.Env;
const Observer = diff.Observer;
const FileTime = diff.FileTime;

/// Largest input read into memory; larger files are refused (bounded memory).
pub const max_input: u64 = 1 << 30;

const Info = struct {
    exists: bool = true,
    kind: Io.File.Kind = .file,
    size: u64 = 0,
    inode: u64 = 0,
    mtime: FileTime = .{ .sec = 0, .nsec = 0 },
    stdin: bool = false,
};

fn kindName(i: Info) []const u8 {
    return switch (i.kind) {
        .file => if (i.size == 0) "regular empty file" else "regular file",
        .directory => "directory",
        .sym_link => "symbolic link",
        .character_device => "character special file",
        .block_device => "block special file",
        .named_pipe => "fifo",
        .unix_domain_socket => "socket",
        else => "weird file",
    };
}

fn tsToTime(ns: i96) FileTime {
    return .{ .sec = @intCast(@divFloor(ns, 1_000_000_000)), .nsec = @intCast(@mod(ns, 1_000_000_000)) };
}

fn joinPath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len > 0 and dir[dir.len - 1] == '/') return std.fmt.allocPrint(gpa, "{s}{s}", .{ dir, name });
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}

const Driver = struct {
    env: Env,
    options: Options,
    w: *Io.Writer,
    observer: Observer,
    zone: tz.Zone,
    matchers: diff.Matchers,
    status: u8 = 0,
    dir_mode: bool = false,
    json_first: bool = true,

    fn raise(d: *Driver, st: u8) void {
        if (st > d.status) d.status = st;
    }

    fn fileError(d: *Driver, name: []const u8, err: anyerror) void {
        d.observer.emit(.{ .file_error = .{ .name = name, .err = err } });
        d.raise(2);
    }

    fn fatal(d: *Driver, text: []const u8) void {
        d.observer.emit(.{ .fatal = text });
        d.raise(2);
    }

    fn statPath(d: *Driver, path: []const u8) !Info {
        const io = d.env.io;
        if (std.mem.eql(u8, path, "-")) {
            const st = try Io.File.stdin().stat(io);
            var t = tsToTime(st.mtime.nanoseconds);
            if (st.kind != .file) t = tsToTime(Io.Timestamp.now(io, .real).nanoseconds);
            return .{ .kind = st.kind, .size = st.size, .mtime = t, .stdin = true, .inode = @intCast(st.inode) };
        }
        const st = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = !d.options.no_dereference });
        return .{ .kind = st.kind, .size = st.size, .mtime = tsToTime(st.mtime.nanoseconds), .inode = @intCast(st.inode) };
    }

    fn readAll(d: *Driver, path: []const u8, info: Info) ![]u8 {
        const io = d.env.io;
        const gpa = d.env.gpa;
        if (!info.exists) return gpa.alloc(u8, 0);
        const file = if (info.stdin) Io.File.stdin() else try Io.Dir.cwd().openFile(io, path, .{});
        defer if (!info.stdin) file.close(io);
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = try common.readChunk(io, file, &buf);
            if (n == 0) break;
            if (list.items.len + n > max_input) return error.FileTooBig;
            try list.appendSlice(gpa, buf[0..n]);
        }
        return list.toOwnedSlice(gpa);
    }

    fn jsonSep(d: *Driver) Io.Writer.Error!void {
        if (!d.options.json or !d.dir_mode) return;
        try d.w.writeAll(if (d.json_first) "[\n" else ",\n");
        d.json_first = false;
    }

    fn jsonHead(d: *Driver, kind: []const u8, dn: [2][]const u8) Io.Writer.Error!void {
        try d.jsonSep();
        try d.w.print("{{\"kind\":\"{s}\",\"old\":", .{kind});
        try json.writeString(d.w, dn[0]);
        try d.w.writeAll(",\"new\":");
        try json.writeString(d.w, dn[1]);
    }

    fn identical(d: *Driver, dn: [2][]const u8) Io.Writer.Error!void {
        if (d.options.json) {
            try d.jsonHead("diff", dn);
            try d.w.writeAll(",\"equal\":true,\"binary\":false,\"hunks\":[]}");
        } else try d.w.print("Files {s} and {s} are identical\n", .{ dn[0], dn[1] });
    }

    fn typeMismatch(d: *Driver, dn: [2][]const u8, infos: [2]Info) Io.Writer.Error!void {
        if (d.options.json) {
            try d.jsonHead("type_mismatch", dn);
            try d.w.print(",\"old_type\":\"{s}\",\"new_type\":\"{s}\"}}", .{ kindName(infos[0]), kindName(infos[1]) });
        } else try d.w.print("File {s} is a {s} while file {s} is a {s}\n", .{ dn[0], kindName(infos[0]), dn[1], kindName(infos[1]) });
    }

    fn lessName(d: *Driver, a: []const u8, b: []const u8) bool {
        if (d.options.ignore_file_name_case) {
            var i: usize = 0;
            while (i < a.len and i < b.len) : (i += 1) {
                const x = std.ascii.toLower(a[i]);
                const y = std.ascii.toLower(b[i]);
                if (x != y) return x < y;
            }
            return a.len < b.len;
        }
        return std.mem.lessThan(u8, a, b);
    }

    fn sameName(d: *Driver, a: []const u8, b: []const u8) bool {
        return if (d.options.ignore_file_name_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
    }

    fn excluded(d: *Driver, name: []const u8) bool {
        for (d.options.exclude) |pat| if (fnmatch.match(pat, name, .{})) return true;
        return false;
    }

    fn readDir(d: *Driver, path: []const u8, list: *std.ArrayList([]u8), top: bool) !void {
        const gpa = d.env.gpa;
        var dir = try Io.Dir.cwd().openDir(d.env.io, path, .{ .iterate = true });
        defer dir.close(d.env.io);
        var it = dir.iterate();
        while (try it.next(d.env.io)) |e| {
            if (d.excluded(e.name)) continue;
            if (top) if (d.options.starting_file) |s| {
                if (std.mem.lessThan(u8, e.name, s)) continue;
            };
            try list.append(gpa, try gpa.dupe(u8, e.name));
        }
        const Ctx = struct {
            d: *Driver,
            fn lt(c: @This(), a: []u8, b: []u8) bool {
                return c.d.lessName(a, b);
            }
        };
        std.mem.sort([]u8, list.items, Ctx{ .d = d }, Ctx.lt);
    }

    /// Compare two operands. `real` are the paths to open, `disp` the names
    /// shown; `only` is the one side that exists for a -N comparison.
    fn compareFiles(d: *Driver, nested: bool, real_in: [2][]const u8, disp_in: [2][]const u8, only: ?usize) anyerror!void {
        const gpa = d.env.gpa;
        const o = d.options;
        var real = real_in;
        var disp = disp_in;
        var owned: [4]?[]u8 = .{ null, null, null, null };
        defer for (owned) |p| if (p) |m| gpa.free(m);
        var infos: [2]Info = .{ .{}, .{} };
        for (0..2) |f| {
            if (only != null and only.? != f) {
                infos[f] = .{ .exists = false };
                continue;
            }
            infos[f] = d.statPath(real[f]) catch |e| {
                d.fileError(real[f], e);
                return;
            };
        }
        if (!nested) {
            const d0 = infos[0].kind == .directory;
            const d1 = infos[1].kind == .directory;
            if (d0 != d1) {
                const di: usize = if (d0) 0 else 1;
                const oth = 1 - di;
                if (infos[oth].stdin) {
                    d.fatal("cannot compare '-' to a directory");
                    return;
                }
                const base = std.fs.path.basename(std.mem.trimEnd(u8, real[oth], "/"));
                owned[di] = try joinPath(gpa, real[di], base);
                real[di] = owned[di].?;
                owned[2 + di] = try joinPath(gpa, disp[di], base);
                disp[di] = owned[2 + di].?;
                infos[di] = d.statPath(real[di]) catch |e| {
                    d.fileError(real[di], e);
                    return;
                };
            }
        }
        const dn = [2][]const u8{ o.labels[0] orelse disp[0], o.labels[1] orelse disp[1] };
        const is_dir = [2]bool{ infos[0].kind == .directory, infos[1].kind == .directory };
        if (only) |ex| {
            if (is_dir[ex]) {
                // -N: a directory missing on one side is compared as an empty one.
                if (o.recursive) {
                    try d.compareDirs(nested, real, disp, only);
                } else {
                    const parent = std.fs.path.dirname(disp[ex]) orelse ".";
                    try d.w.print("Only in {s}: {s}\n", .{ parent, std.fs.path.basename(disp[ex]) });
                    d.raise(1);
                }
                return;
            }
        }
        if (is_dir[0] and is_dir[1]) {
            if (o.style == .ifdef) {
                d.fatal("-D option not supported with directories");
                return;
            }
            if (!nested or o.recursive) {
                if (!nested) d.dir_mode = true;
                try d.compareDirs(nested, real, disp, only);
            } else {
                if (o.json) {
                    try d.jsonHead("common_subdirectory", dn);
                    try d.w.writeAll("}");
                } else try d.w.print("Common subdirectories: {s} and {s}\n", .{ dn[0], dn[1] });
            }
            return;
        }
        if (is_dir[0] or is_dir[1] or (nested and infos[0].exists and infos[1].exists and infos[0].kind != infos[1].kind)) {
            try d.typeMismatch(dn, infos);
            d.raise(1);
            return;
        }
        if (infos[0].kind == .sym_link and infos[1].kind == .sym_link) {
            var b0: [4096]u8 = undefined;
            var b1: [4096]u8 = undefined;
            const n0 = Io.Dir.cwd().readLink(d.env.io, real[0], &b0) catch |e| return d.fileError(real[0], e);
            const n1 = Io.Dir.cwd().readLink(d.env.io, real[1], &b1) catch |e| return d.fileError(real[1], e);
            if (std.mem.eql(u8, b0[0..n0], b1[0..n1])) {
                if (o.report_identical or o.json) try d.identical(dn);
            } else {
                if (o.json) {
                    try d.jsonHead("symlinks_differ", dn);
                    try d.w.writeAll("}");
                } else try d.w.print("Symbolic links '{s}' -> '{s}' and '{s}' -> '{s}' differ\n", .{ dn[0], b0[0..n0], dn[1], b1[0..n1] });
                d.raise(1);
            }
            return;
        }
        if (nested and infos[0].exists and infos[1].exists and infos[0].kind != .file) {
            if (o.report_identical or o.json) try d.identical(dn);
            return;
        }
        // The very same file is identical without reading it.
        if (diffsbs.noDiffMeansNoOutput(o) and infos[0].exists and infos[1].exists and infos[0].kind == .file and infos[0].inode != 0 and infos[0].inode == infos[1].inode and
            infos[0].size == infos[1].size and infos[0].mtime.sec == infos[1].mtime.sec and infos[0].mtime.nsec == infos[1].mtime.nsec)
        {
            if (o.report_identical or o.json) try d.identical(dn);
            return;
        }
        try d.compareContents(nested, real, dn, infos);
    }

    /// `-l`: format the finished output of one file with the page formatter,
    /// titled `diff OPTIONS NAME1 NAME2`, as GNU's `pr -h` pipe does.
    fn paginate(d: *Driver, text: []const u8, title: []const u8) !void {
        const pr = @import("pr.zig");
        _ = try pr.run(d.env, .{ .custom_header = title, .stdin_data = text }, &.{}, d.w, .none);
    }

    fn compareDirs(d: *Driver, nested: bool, real: [2][]const u8, disp: [2][]const u8, only: ?usize) anyerror!void {
        const gpa = d.env.gpa;
        const o = d.options;
        var lists: [2]std.ArrayList([]u8) = .{ .empty, .empty };
        defer for (&lists) |*l| {
            for (l.items) |n| gpa.free(n);
            l.deinit(gpa);
        };
        for (0..2) |f| if (only == null or only.? == f) d.readDir(real[f], &lists[f], !nested) catch |e| {
            d.fileError(real[f], e);
            return;
        };
        var i: usize = 0;
        var j: usize = 0;
        const l0 = lists[0].items;
        const l1 = lists[1].items;
        while (i < l0.len or j < l1.len) {
            var side: i8 = 0; // -1: only in the first, 1: only in the second
            if (i >= l0.len) side = 1 else if (j >= l1.len) side = -1 else if (!d.sameName(l0[i], l1[j])) side = if (d.lessName(l0[i], l1[j])) -1 else 1;
            const name: []const u8 = if (side <= 0) l0[i] else l1[j];
            const name1: []const u8 = if (side >= 0) l1[j] else l0[i];
            const missing_ok = o.new_file or (o.unidirectional_new_file and side > 0);
            if (side != 0 and !missing_ok) {
                const sd = if (side < 0) disp[0] else disp[1];
                if (o.json) {
                    try d.jsonSep();
                    try d.w.print("{{\"kind\":\"only_in\",\"side\":\"{s}\",\"dir\":", .{if (side < 0) "old" else "new"});
                    try json.writeString(d.w, sd);
                    try d.w.writeAll(",\"name\":");
                    try json.writeString(d.w, name);
                    try d.w.writeAll("}");
                } else try d.w.print("Only in {s}: {s}\n", .{ sd, name });
                d.raise(1);
            } else {
                const p0 = try joinPath(gpa, real[0], name);
                defer gpa.free(p0);
                const p1 = try joinPath(gpa, real[1], name1);
                defer gpa.free(p1);
                const q0 = try joinPath(gpa, disp[0], name);
                defer gpa.free(q0);
                const q1 = try joinPath(gpa, disp[1], name1);
                defer gpa.free(q1);
                const child_only: ?usize = if (side < 0) 0 else if (side > 0) 1 else null;
                try d.compareFiles(true, .{ p0, p1 }, .{ q0, q1 }, child_only);
            }
            if (side <= 0) i += 1;
            if (side >= 0) j += 1;
        }
    }

    fn compareContents(d: *Driver, nested: bool, real: [2][]const u8, dn: [2][]const u8, infos: [2]Info) anyerror!void {
        const gpa = d.env.gpa;
        const o = d.options;
        var data: [2][]u8 = .{ &.{}, &.{} };
        defer for (data) |m| gpa.free(m);
        for (0..2) |f| {
            data[f] = d.readAll(real[f], infos[f]) catch |e| {
                d.fileError(real[f], e);
                return;
            };
        }
        const same_bytes = std.mem.eql(u8, data[0], data[1]);
        var binary = false;
        if (!o.text) for (data) |m| {
            if (std.mem.indexOfScalar(u8, m[0..@min(m.len, 4096)], 0) != null) binary = true;
        };
        if (binary) {
            if (same_bytes) {
                if (o.report_identical or o.json) try d.identical(dn);
                return;
            }
            if (o.json) {
                try d.jsonHead("diff", dn);
                try d.w.writeAll(",\"equal\":false,\"binary\":true,\"hunks\":[]}");
            } else if (o.brief) {
                try d.w.print("Files {s} and {s} differ\n", .{ dn[0], dn[1] });
            } else try d.w.print("Binary files {s} and {s} differ\n", .{ dn[0], dn[1] });
            d.raise(1);
            return;
        }
        if (same_bytes and o.style != .ed and o.style != .forward_ed and o.style != .ifdef and o.style != .side_by_side) {
            if (o.report_identical or o.json) try d.identical(dn);
            return;
        }
        var bufs: [2][]const u8 = .{ data[0], data[1] };
        var extra: [2]?[]u8 = .{ null, null };
        defer for (extra) |m| if (m) |x| gpa.free(x);
        if (o.style == .ed or o.style == .forward_ed) {
            for (0..2) |f| {
                const m = data[f];
                if (m.len > 0 and m[m.len - 1] != '\n') {
                    d.observer.emit(.{ .no_newline = real[f] });
                    d.raise(2);
                    extra[f] = try gpa.alloc(u8, m.len + 1);
                    @memcpy(extra[f].?[0..m.len], m);
                    extra[f].?[m.len] = '\n';
                    bufs[f] = extra[f].?;
                }
            }
            if (same_bytes) return;
        }
        var cmp = diff.compareData(gpa, bufs[0], bufs[1], o) catch |e| {
            if (e == error.OutOfMemory) return e;
            d.fileError(real[0], e);
            return;
        };
        defer cmp.deinit();
        if (!cmp.differs() and o.style != .ifdef and o.style != .side_by_side) {
            if (o.report_identical or o.json) try d.identical(dn);
            return;
        }
        if (cmp.differs()) d.raise(1);
        if (o.brief) {
            if (o.json) {
                try d.jsonHead("diff", dn);
                try d.w.writeAll(",\"equal\":false,\"binary\":false,\"hunks\":[]}");
            } else try d.w.print("Files {s} and {s} differ\n", .{ dn[0], dn[1] });
            return;
        }
        if (o.json) {
            try d.jsonHead("diff", dn);
            try d.w.writeAll(",\"equal\":false,\"binary\":false,\"hunks\":");
            const hs = try diff.hunks(gpa, &cmp, o.context);
            defer diff.freeHunks(gpa, hs);
            try diff.writeHunksJson(d.w, hs);
            try d.w.writeAll("}");
            return;
        }
        var header: ?[]u8 = null;
        defer if (header) |h| gpa.free(h);
        if (nested or d.dir_mode) {
            header = try std.fmt.allocPrint(gpa, "diff{s} {s} {s}", .{ o.switch_string, dn[0], dn[1] });
        }
        var page: Io.Writer.Allocating = .init(gpa);
        defer page.deinit();
        var pr: diff.Printer = .{
            .gpa = gpa,
            .w = if (o.paginate) &page.writer else d.w,
            .options = o,
            .c = &cmp,
            .m = &d.matchers,
            .names = dn,
            .times = .{ infos[0].mtime, infos[1].mtime },
            .zone = &d.zone,
            .header = if (o.paginate) null else header,
        };
        try pr.script();
        if (o.paginate and pr.begun) try d.paginate(page.written(), header orelse try diffName(gpa, o, dn, &header));
    }
};

fn diffName(gpa: std.mem.Allocator, o: diff.Options, dn: [2][]const u8, slot: *?[]u8) ![]const u8 {
    slot.* = try std.fmt.allocPrint(gpa, "diff{s} {s} {s}", .{ o.switch_string, dn[0], dn[1] });
    return slot.*.?;
}

pub fn run(env: Env, options: Options, name0: []const u8, name1: []const u8, w: *Io.Writer, observer: Observer) !u8 {
    const gpa = env.gpa;
    var d: Driver = .{
        .env = env,
        .options = options,
        .w = w,
        .observer = observer,
        .zone = tz.load(gpa, env.io, env.getenv("TZ")),
        .matchers = try diff.Matchers.init(gpa, options),
    };
    defer d.zone.deinit();
    defer d.matchers.deinit();
    try d.compareFiles(false, .{ name0, name1 }, .{ name0, name1 }, null);
    if (options.json) {
        if (d.dir_mode) try w.writeAll(if (d.json_first) "[]\n" else "\n]\n") else try w.writeByte('\n');
    }
    return d.status;
}
