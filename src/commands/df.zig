//! df — report file system space usage.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "df invocation"
//! (9.7), POSIX.1-2024 df, and GNU coreutils 9.6 src/df.c, lib/mountlist.c
//! and lib/fsusage.c (the mount table filtering, the column layout and the
//! percentage arithmetic were studied there and rewritten). The mount table
//! comes from /proc/self/mountinfo and usage from statfs(2).

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const human = @import("../human.zig");
const paths = @import("../paths.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const help_text = @embedFile("../help/df.txt");

const UMAX = std.math.maxInt(u64);

const Mount = struct {
    devname: []const u8,
    mountdir: []const u8,
    mntroot: ?[]const u8,
    fstype: []const u8,
    dev: u64,
    dummy: bool,
    remote: bool,
};

const Fsu = struct {
    blocksize: u64 = 0,
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    bavail_top_bit_set: bool = false,
    files: u64 = 0,
    ffree: u64 = 0,
};

const HeaderMode = enum { default, inodes, human, posix, output };

const Field = enum(u8) { source, fstype, size, used, avail, pcent, itotal, iused, iavail, ipcent, target, file };
const FieldType = enum { block, inode, other };

const FieldData = struct {
    arg: []const u8,
    ftype: FieldType,
    caption: []const u8,
    width: usize,
    align_right: bool,
    used: bool = false,
};

const all_args = "source,fstype,itotal,iused,iavail,ipcent,size,used,avail,pcent,file,target";

const DevKeyed = struct { me: usize, dev: u64 };

const S = struct {
    ctx: cli.Context,
    out: cli.Out,
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    show_all: bool = false,
    show_local: bool = false,
    show_listed: bool = false,
    human_opts: i32 = -1,
    block_size: u64 = 0,
    file_systems_processed: bool = false,
    require_sync: bool = false,
    exit_status: u8 = 0,
    select_types: std.ArrayList([]const u8) = .empty,
    exclude_types: std.ArrayList([]const u8) = .empty,
    mounts: std.ArrayList(Mount) = .empty,
    mounts_read: bool = false,
    print_type: bool = false,
    print_grand_total: bool = false,
    grand: Fsu = .{ .blocksize = 1 },
    header_mode: HeaderMode = .default,
    fields: [12]FieldData = .{
        .{ .arg = "source", .ftype = .other, .caption = "Filesystem", .width = 14, .align_right = false },
        .{ .arg = "fstype", .ftype = .other, .caption = "Type", .width = 4, .align_right = false },
        .{ .arg = "size", .ftype = .block, .caption = "blocks", .width = 5, .align_right = true },
        .{ .arg = "used", .ftype = .block, .caption = "Used", .width = 5, .align_right = true },
        .{ .arg = "avail", .ftype = .block, .caption = "Available", .width = 5, .align_right = true },
        .{ .arg = "pcent", .ftype = .block, .caption = "Use%", .width = 4, .align_right = true },
        .{ .arg = "itotal", .ftype = .inode, .caption = "Inodes", .width = 5, .align_right = true },
        .{ .arg = "iused", .ftype = .inode, .caption = "IUsed", .width = 5, .align_right = true },
        .{ .arg = "iavail", .ftype = .inode, .caption = "IFree", .width = 5, .align_right = true },
        .{ .arg = "ipcent", .ftype = .inode, .caption = "IUse%", .width = 4, .align_right = true },
        .{ .arg = "target", .ftype = .other, .caption = "Mounted on", .width = 0, .align_right = false },
        .{ .arg = "file", .ftype = .other, .caption = "File", .width = 0, .align_right = false },
    },
    columns: std.ArrayList(Field) = .empty,
    table: std.ArrayList([][]const u8) = .empty,
    kept: std.ArrayList(DevKeyed) = .empty,
    last_for_dev: std.AutoHashMap(u64, usize),

    fn alloc(s: *S) Allocator {
        return s.arena.allocator();
    }
};

fn devKey(st: sys.FileStat) u64 {
    return (@as(u64, st.dev_major) << 32) | st.dev_minor;
}

fn makedev(maj: u64, min: u64) u64 {
    return (maj << 32) | min;
}

fn isDummy(fstype: []const u8) bool {
    const dummies = [_][]const u8{ "autofs", "devtmpfs", "fuse.portal", "proc", "squashfs", "subfs", "debugfs", "devpts", "fusectl", "mqueue", "rpc_pipefs", "sysfs", "devfs", "kernfs", "ignore", "none" };
    for (dummies) |d| if (std.mem.eql(u8, fstype, d)) return true;
    return false;
}

fn isRemote(devname: []const u8, fstype: []const u8) bool {
    if (std.mem.indexOfScalar(u8, devname, ':') != null) return true;
    if (devname.len >= 2 and devname[0] == '/' and devname[1] == '/' and
        (std.mem.eql(u8, fstype, "smbfs") or std.mem.eql(u8, fstype, "smb3") or std.mem.eql(u8, fstype, "cifs"))) return true;
    const remotes = [_][]const u8{ "acfs", "afs", "coda", "auristorfs", "fhgfs", "gpfs", "ibrix", "ocfs2", "vxfs" };
    for (remotes) |r| if (std.mem.eql(u8, fstype, r)) return true;
    return std.mem.eql(u8, devname, "-hosts");
}

/// \ooo escapes in mountinfo fields.
fn unescapeTab(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 3 < text.len and
            text[i + 1] >= '0' and text[i + 1] <= '7' and text[i + 2] >= '0' and text[i + 2] <= '7' and
            text[i + 3] >= '0' and text[i + 3] <= '7')
        {
            const v: u8 = @truncate((@as(u16, text[i + 1] - '0') << 6) | (@as(u16, text[i + 2] - '0') << 3) | (text[i + 3] - '0'));
            try out.append(a, v);
            i += 4;
        } else {
            try out.append(a, text[i]);
            i += 1;
        }
    }
    return out.items;
}

fn readMounts(s: *S) bool {
    const ctx = s.ctx;
    const a = s.alloc();
    const f = Io.Dir.cwd().openFile(ctx.io, "/proc/self/mountinfo", .{}) catch return false;
    defer f.close(ctx.io);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.gpa);
    while (true) {
        data.ensureUnusedCapacity(ctx.gpa, 8192) catch return false;
        const n = cli.readChunk(ctx.io, f, data.unusedCapacitySlice()) catch return false;
        if (n == 0) break;
        data.items.len += n;
    }
    var lines = std.mem.splitScalar(u8, data.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // id parent maj:min root target opts... - fstype source superopts
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        const majmin = it.next() orelse continue;
        const colon = std.mem.indexOfScalar(u8, majmin, ':') orelse continue;
        const maj = std.fmt.parseInt(u64, majmin[0..colon], 10) catch continue;
        const min = std.fmt.parseInt(u64, majmin[colon + 1 ..], 10) catch continue;
        const root = it.next() orelse continue;
        const target = it.next() orelse continue;
        // Skip optional fields up to the lone "-".
        var found_dash = false;
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "-")) {
                found_dash = true;
                break;
            }
        }
        if (!found_dash) continue;
        const fstype = it.next() orelse continue;
        const source = it.next() orelse continue;
        const m: Mount = .{
            .devname = unescapeTab(a, source) catch continue,
            .mountdir = unescapeTab(a, target) catch continue,
            .mntroot = unescapeTab(a, root) catch continue,
            .fstype = unescapeTab(a, fstype) catch continue,
            .dev = makedev(maj, min),
            .dummy = false,
            .remote = false,
        };
        var mm = m;
        mm.dummy = isDummy(mm.fstype);
        mm.remote = isRemote(mm.devname, mm.fstype);
        s.mounts.append(ctx.gpa, mm) catch return false;
    }
    return true;
}

fn selected(s: *const S, fstype: ?[]const u8) bool {
    if (s.select_types.items.len == 0 or fstype == null) return true;
    for (s.select_types.items) |t| if (std.mem.eql(u8, t, fstype.?)) return true;
    return false;
}

fn excludedType(s: *const S, fstype: ?[]const u8) bool {
    if (s.exclude_types.items.len == 0 or fstype == null) return false;
    for (s.exclude_types.items) |t| if (std.mem.eql(u8, t, fstype.?)) return true;
    return false;
}

fn statPath(path: []const u8) ?sys.FileStat {
    var e: std.os.linux.E = .SUCCESS;
    return sys.fileStat(path, true, &e);
}

/// df.c filter_mount_list: drop duplicate devices, keeping the better entry.
/// With `devices_only` only the device table is built.
fn filterMountList(s: *S, devices_only: bool) void {
    const gpa = s.gpa;
    s.kept.clearRetainingCapacity();
    s.last_for_dev.clearRetainingCapacity();
    var mounts = &s.mounts;
    var me_i: usize = 0;
    // Entries of `mounts` stay in place; `kept.me` points into them. With
    // replacement the kept slot refers to the newer entry.
    while (me_i < mounts.items.len) : (me_i += 1) {
        const me = mounts.items[me_i];
        var key_dev: u64 = undefined;
        var skip_dedupe = false;
        if ((me.remote and s.show_local) or (me.dummy and !s.show_all and !s.show_listed) or
            !selected(s, me.fstype) or excludedType(s, me.fstype))
        {
            key_dev = me.dev;
            skip_dedupe = true;
        } else if (statPath(me.mountdir)) |st| {
            key_dev = devKey(st);
        } else {
            key_dev = me.dev;
            skip_dedupe = true;
        }
        var discard_current = false;
        var replaced = false;
        if (!skip_dedupe) {
            if (s.last_for_dev.get(key_dev)) |ki| {
                const seen = mounts.items[s.kept.items[ki].me];
                const target_nearer_root = seen.mountdir.len > me.mountdir.len;
                const source_below_root = seen.mntroot != null and me.mntroot != null and seen.mntroot.?.len < me.mntroot.?.len;
                if (!s.print_grand_total and me.remote and seen.remote and !std.mem.eql(u8, seen.devname, me.devname)) {
                    // Keep remote entries with different locations.
                    discard_current = false;
                    replaced = false;
                    // falls through to "add" below
                    skip_dedupe = true;
                } else if ((std.mem.indexOfScalar(u8, me.devname, '/') != null and std.mem.indexOfScalar(u8, seen.devname, '/') == null) or
                    (target_nearer_root and !source_below_root) or
                    (!std.mem.eql(u8, seen.devname, me.devname) and std.mem.eql(u8, me.mountdir, seen.mountdir)))
                {
                    s.kept.items[ki].me = me_i;
                    replaced = true;
                } else discard_current = true;
            }
        }
        if (replaced or discard_current) continue;
        s.kept.append(gpa, .{ .me = me_i, .dev = key_dev }) catch return;
        s.last_for_dev.put(key_dev, s.kept.items.len - 1) catch {};
    }
    if (!devices_only) {
        var new_list: std.ArrayList(Mount) = .empty;
        for (s.kept.items, 0..) |k, idx| {
            new_list.append(gpa, mounts.items[k.me]) catch break;
            s.kept.items[idx].me = idx;
        }
        mounts.deinit(gpa);
        mounts.* = new_list;
    }
}

fn meForDev(s: *S, dev: u64) ?Mount {
    const ki = s.last_for_dev.get(dev) orelse return null;
    return s.mounts.items[s.kept.items[ki].me];
}

fn knownValue(n: u64) bool {
    return n < UMAX - 1;
}

fn dfReadable(s: *S, negative: bool, n: u64, buf: []u8, input_units: u64, output_units: u64) []const u8 {
    if (!knownValue(n) and !negative) return "-";
    var tmp: [human.longest]u8 = undefined;
    const t = human.readable(if (negative) 0 -% n else n, &tmp, @intCast(s.human_opts), input_units, output_units);
    if (negative) {
        buf[0] = '-';
        @memcpy(buf[1..][0..t.len], t);
        return buf[0 .. t.len + 1];
    }
    @memcpy(buf[0..t.len], t);
    return buf[0..t.len];
}

const FieldValues = struct {
    input_units: u64 = 1,
    output_units: u64 = 1,
    total: u64 = 0,
    available: u64 = 0,
    negate_available: bool = false,
    available_to_root: u64 = 0,
    used: u64 = UMAX,
    negate_used: bool = false,
};

fn getFieldValues(s: *S, fsu: Fsu, bv: *FieldValues, iv: *FieldValues) void {
    iv.* = .{};
    iv.total = fsu.files;
    iv.available = fsu.ffree;
    iv.available_to_root = fsu.ffree;
    if (knownValue(iv.total) and knownValue(iv.available_to_root)) {
        iv.used = iv.total -% iv.available_to_root;
        iv.negate_used = iv.total < iv.available_to_root;
    }
    bv.* = .{};
    bv.input_units = fsu.blocksize;
    bv.output_units = s.block_size;
    bv.total = fsu.blocks;
    bv.available = fsu.bavail;
    bv.available_to_root = fsu.bfree;
    bv.negate_available = fsu.bavail_top_bit_set and knownValue(fsu.bavail);
    if (knownValue(bv.total) and knownValue(bv.available_to_root)) {
        bv.used = bv.total -% bv.available_to_root;
        bv.negate_used = bv.total < bv.available_to_root;
    }
}

fn addUintWithNegFlag(dest: *u64, dest_neg: *bool, src_in: u64, src_neg: bool) void {
    var src = src_in;
    if (dest_neg.* == src_neg) {
        dest.* +%= src;
        return;
    }
    if (dest_neg.*) dest.* = 0 -% dest.*;
    if (src_neg) src = 0 -% src;
    if (src < dest.*) {
        dest.* -= src;
    } else {
        dest.* = src - dest.*;
        dest_neg.* = src_neg;
    }
    if (dest_neg.*) dest.* = 0 -% dest.*;
}

fn addToGrandTotal(s: *S, bv: FieldValues, iv: FieldValues) void {
    if (knownValue(iv.total)) s.grand.files +%= iv.total;
    if (knownValue(iv.available)) s.grand.ffree +%= iv.available;
    if (knownValue(bv.total)) s.grand.blocks +%= bv.input_units *% bv.total;
    if (knownValue(bv.available_to_root)) s.grand.bfree +%= bv.input_units *% bv.available_to_root;
    if (knownValue(bv.available)) addUintWithNegFlag(&s.grand.bavail, &s.grand.bavail_top_bit_set, bv.input_units *% bv.available, bv.negate_available);
}

fn hasUuidSuffix(str: []const u8) bool {
    if (str.len <= 36) return false;
    for (str[str.len - 36 ..]) |c| {
        if (!(c == '-' or std.ascii.isHex(c))) return false;
    }
    return true;
}

fn replaceControl(cell: []u8) void {
    for (cell) |*c| {
        if (c.* < 0x20 or c.* == 0x7f) c.* = '?';
    }
}

fn percent(v: FieldValues) ?u64 {
    if (!knownValue(v.used) or !knownValue(v.available)) return null;
    var pct: f64 = -1;
    if (!v.negate_used and v.used <= UMAX / 100 and (v.used +% v.available) != 0 and
        ((v.used +% v.available) < v.used) == v.negate_available)
    {
        const pct100 = v.used * 100;
        const nonroot_total = v.used +% v.available;
        pct = @floatFromInt(pct100 / nonroot_total + @intFromBool(pct100 % nonroot_total != 0));
    } else {
        const u: f64 = if (v.negate_used) -@as(f64, @floatFromInt(0 -% v.used)) else @floatFromInt(v.used);
        const a: f64 = if (v.negate_available) -@as(f64, @floatFromInt(0 -% v.available)) else @floatFromInt(v.available);
        const nonroot_total = u + a;
        if (nonroot_total != 0) {
            pct = u * 100 / nonroot_total;
            const lipct: i64 = @intFromFloat(pct);
            const ipct: f64 = @floatFromInt(lipct);
            if (ipct - 1 < pct and pct <= ipct + 1) pct = ipct + @as(f64, @floatFromInt(@intFromBool(ipct < pct)));
        }
    }
    if (pct < 0) return null;
    return @intFromFloat(pct);
}

fn allocRow(s: *S) ?[][]const u8 {
    const a = s.alloc();
    const row = a.alloc([]const u8, s.columns.items.len) catch return null;
    @memset(row, "");
    s.table.append(s.gpa, row) catch return null;
    return row;
}

/// df.c get_dev.
fn getDev(s: *S, device_in: ?[]const u8, mount_point: ?[]const u8, file_in: ?[]const u8, stat_file_in: ?[]const u8, fstype_in: ?[]const u8, me_dummy: bool, me_remote: bool, force_fsu: ?Fsu, process_all: bool) void {
    const ctx = s.ctx;
    const a = s.alloc();
    var fstype = fstype_in;
    if (me_remote and s.show_local) return;
    if (me_dummy and !s.show_all and !s.show_listed) return;
    if (!selected(s, fstype) or excludedType(s, fstype)) return;
    if (force_fsu == null and mount_point != null and (mount_point.?.len == 0 or mount_point.?[0] != '/')) return;
    const stat_file: []const u8 = stat_file_in orelse (mount_point orelse device_in orelse "");
    var fsu: Fsu = .{};
    if (force_fsu) |f| {
        fsu = f;
    } else {
        var e: std.os.linux.E = .SUCCESS;
        if (sys.statfs(stat_file, &e)) |st| {
            fsu.blocksize = if (st.frsize != 0) st.frsize else st.bsize;
            fsu.blocks = st.blocks;
            fsu.bfree = st.bfree;
            fsu.bavail = st.bavail;
            fsu.bavail_top_bit_set = (st.bavail >> 63) != 0;
            fsu.files = st.files;
            fsu.ffree = st.ffree;
        } else {
            if (process_all and (e == .ACCES or e == .NOENT)) {
                if (!s.show_all) return;
                fstype = "-";
                fsu = .{ .blocksize = UMAX, .blocks = UMAX, .bfree = UMAX, .bavail = UMAX, .files = UMAX, .ffree = UMAX };
            } else {
                cli.warn(ctx, "{f}: {s}", .{ cli.quote(stat_file), sys.errnoText(e) });
                s.exit_status = 1;
                return;
            }
        }
        if (fsu.blocks != UMAX or true) {
            if (process_all and s.show_all) {
                if (statPath(stat_file)) |sb| {
                    if (meForDev(s, devKey(sb))) |dev_me| {
                        if (device_in != null and !std.mem.eql(u8, dev_me.devname, device_in.?) and (!dev_me.remote or !me_remote)) {
                            fstype = "-";
                            fsu = .{ .blocksize = UMAX, .blocks = UMAX, .bfree = UMAX, .bavail = UMAX, .files = UMAX, .ffree = UMAX };
                        }
                    }
                }
            }
        }
    }
    if (fsu.blocks == 0 and !s.show_all and !s.show_listed) return;
    if (force_fsu == null) s.file_systems_processed = true;

    const row = allocRow(s) orelse return;
    var dev_name: []const u8 = device_in orelse "-";
    const file: []const u8 = file_in orelse "-";
    if (process_all and hasUuidSuffix(dev_name)) {
        if (paths.resolve(ctx, dev_name, .existing)) |r| {
            defer ctx.gpa.free(r);
            dev_name = a.dupe(u8, r) catch dev_name;
        } else |_| {}
    }
    const ftype: []const u8 = fstype orelse "-";

    var bv: FieldValues = undefined;
    var iv: FieldValues = undefined;
    getFieldValues(s, fsu, &bv, &iv);
    if (s.print_grand_total and force_fsu == null) addToGrandTotal(s, bv, iv);

    for (s.columns.items, 0..) |col, ci| {
        const fd = &s.fields[@intFromEnum(col)];
        const v: *FieldValues = if (fd.ftype == .block) &bv else &iv;
        var buf: [human.longest + 2]u8 = undefined;
        var cell: []u8 = undefined;
        switch (col) {
            .source => cell = a.dupe(u8, dev_name) catch return,
            .fstype => cell = a.dupe(u8, ftype) catch return,
            .size, .itotal => cell = a.dupe(u8, dfReadable(s, false, v.total, &buf, v.input_units, v.output_units)) catch return,
            .used, .iused => cell = a.dupe(u8, dfReadable(s, v.negate_used, v.used, &buf, v.input_units, v.output_units)) catch return,
            .avail, .iavail => cell = a.dupe(u8, dfReadable(s, v.negate_available, v.available, &buf, v.input_units, v.output_units)) catch return,
            .pcent, .ipcent => {
                if (percent(v.*)) |p| {
                    cell = std.fmt.allocPrint(a, "{d}%", .{p}) catch return;
                } else cell = a.dupe(u8, "-") catch return;
            },
            .file => cell = a.dupe(u8, file) catch return,
            .target => cell = a.dupe(u8, mount_point orelse "") catch return,
        }
        replaceControl(cell);
        if (cell.len > fd.width) fd.width = cell.len;
        row[ci] = cell;
    }
}

fn canonical(s: *S, path: []const u8) ?[]u8 {
    return paths.resolve(s.ctx, path, .existing) catch null;
}

fn lastDeviceForMount(s: *S, mount: []const u8) ?[]u8 {
    var le: ?Mount = null;
    for (s.mounts.items) |me| {
        if (std.mem.eql(u8, me.mountdir, mount)) le = me;
    }
    if (le) |m| {
        if (canonical(s, m.devname)) |c| {
            if (c.len > 0 and c[0] == '/') return c;
            s.gpa.free(c);
        }
        return s.gpa.dupe(u8, m.devname) catch null;
    }
    return null;
}

fn getDevice(s: *S, device_in: []const u8) bool {
    const ctx = s.ctx;
    var best_match: ?Mount = null;
    var best_match_accessible = false;
    var eclipsed_device = false;
    const file = device_in;
    var device: []const u8 = device_in;
    const resolved = canonical(s, device_in);
    defer if (resolved) |r| s.gpa.free(r);
    if (resolved) |r| {
        if (r.len > 0 and r[0] == '/') device = r;
    }
    var best_match_len: usize = std.math.maxInt(usize);
    for (s.mounts.items) |me| {
        var devname: []const u8 = me.devname;
        const canon_dev = canonical(s, me.devname);
        defer if (canon_dev) |c| s.gpa.free(c);
        if (canon_dev) |c| {
            if (c.len > 0 and c[0] == '/') devname = c;
        }
        if (std.mem.eql(u8, device, devname)) {
            const last_device = lastDeviceForMount(s, me.mountdir);
            defer if (last_device) |l| s.gpa.free(l);
            eclipsed_device = last_device != null and !std.mem.eql(u8, last_device.?, devname);
            const len = me.mountdir.len;
            if (!eclipsed_device and (!best_match_accessible or len < best_match_len)) {
                var this_match_accessible = false;
                if (statPath(me.mountdir) != null) {
                    best_match_accessible = true;
                    this_match_accessible = true;
                }
                if (this_match_accessible or (!best_match_accessible and len < best_match_len)) {
                    best_match = me;
                    if (len == 1) break;
                    best_match_len = len;
                }
            }
        }
    }
    if (best_match) |m| {
        getDev(s, m.devname, m.mountdir, file, null, m.fstype, m.dummy, m.remote, null, false);
        return true;
    } else if (eclipsed_device) {
        cli.warn(ctx, "cannot access {f}: over-mounted by another device", .{cli.quoteA(file)});
        s.exit_status = 1;
        return true;
    }
    return false;
}

fn findMountPoint(s: *S, point: []const u8, st: sys.FileStat) ?[]u8 {
    const resolved = canonical(s, point) orelse return null;
    defer s.gpa.free(resolved);
    var cur: []const u8 = resolved;
    // Walk up while the parent is on the same device.
    while (true) {
        if (std.mem.eql(u8, cur, "/")) break;
        const slash = std.mem.lastIndexOfScalar(u8, cur, '/') orelse break;
        const parent = if (slash == 0) "/" else cur[0..slash];
        const pst = statPath(parent) orelse break;
        if (devKey(pst) != devKey(st)) break;
        cur = parent;
    }
    return s.gpa.dupe(u8, cur) catch null;
}

fn getPoint(s: *S, point: []const u8, statp: sys.FileStat) void {
    var best: ?usize = null;
    const resolved = canonical(s, point);
    defer if (resolved) |r| s.gpa.free(r);
    if (resolved) |r| {
        if (r.len > 0 and r[0] == '/') {
            var best_len: usize = 0;
            for (s.mounts.items, 0..) |me, i| {
                if (!std.mem.eql(u8, me.fstype, "lofs") and (best == null or s.mounts.items[best.?].dummy or !me.dummy)) {
                    const len = me.mountdir.len;
                    if (best_len <= len and len <= r.len and
                        (len == 1 or ((len == r.len or r[len] == '/') and std.mem.eql(u8, me.mountdir, r[0..len]))))
                    {
                        best = i;
                        best_len = len;
                    }
                }
            }
        }
    }
    if (best) |bi| {
        const ok = if (statPath(s.mounts.items[bi].mountdir)) |ds| devKey(ds) == devKey(statp) else false;
        if (!ok) best = null;
    }
    if (best == null) {
        for (s.mounts.items, 0..) |*me, i| {
            if (me.dev == UMAX) {
                if (statPath(me.mountdir)) |ds| {
                    me.dev = devKey(ds);
                } else me.dev = UMAX - 1;
            }
            if (devKey(statp) == me.dev and !std.mem.eql(u8, me.fstype, "lofs") and
                (best == null or s.mounts.items[best.?].dummy or !me.dummy))
            {
                if (statPath(me.mountdir)) |ds| {
                    if (devKey(ds) != me.dev) {
                        me.dev = UMAX - 1;
                    } else best = i;
                } else me.dev = UMAX - 1;
            }
        }
    }
    if (best) |bi| {
        const m = s.mounts.items[bi];
        getDev(s, m.devname, m.mountdir, point, point, m.fstype, m.dummy, m.remote, null, false);
    } else if (findMountPoint(s, point, statp)) |mp| {
        defer s.gpa.free(mp);
        getDev(s, null, mp, point, null, null, false, false, null, false);
    }
}

fn getEntry(s: *S, name: []const u8, st: sys.FileStat) void {
    const t = st.mode & 0o170000;
    if ((t == 0o060000 or t == 0o020000) and getDevice(s, name)) return;
    getPoint(s, name, st);
}

fn decodeOutputArg(s: *S, arg: []const u8) bool {
    const ctx = s.ctx;
    var it = std.mem.splitScalar(u8, arg, ',');
    while (it.next()) |tok| {
        var idx: ?usize = null;
        for (s.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.arg, tok)) {
                idx = i;
                break;
            }
        }
        if (idx == null) {
            cli.warn(ctx, "option --output: field {f} unknown", .{cli.quoteC(tok)});
            return false;
        }
        const fi = idx.?;
        if (s.fields[fi].used) {
            cli.warn(ctx, "option --output: field {f} used more than once", .{cli.quoteC(s.fields[fi].arg)});
            return false;
        }
        allocField(s, @enumFromInt(fi), switch (@as(Field, @enumFromInt(fi))) {
            .size => "Size",
            .avail => "Avail",
            else => null,
        });
    }
    return true;
}

fn allocField(s: *S, f: Field, caption: ?[]const u8) void {
    s.columns.append(s.gpa, f) catch return;
    if (caption) |c| s.fields[@intFromEnum(f)].caption = c;
    s.fields[@intFromEnum(f)].used = true;
}

fn getFieldList(s: *S) bool {
    switch (s.header_mode) {
        .default => {
            allocField(s, .source, null);
            if (s.print_type) allocField(s, .fstype, null);
            allocField(s, .size, null);
            allocField(s, .used, null);
            allocField(s, .avail, null);
            allocField(s, .pcent, null);
            allocField(s, .target, null);
        },
        .human => {
            allocField(s, .source, null);
            if (s.print_type) allocField(s, .fstype, null);
            allocField(s, .size, "Size");
            allocField(s, .used, null);
            allocField(s, .avail, "Avail");
            allocField(s, .pcent, null);
            allocField(s, .target, null);
        },
        .inodes => {
            allocField(s, .source, null);
            if (s.print_type) allocField(s, .fstype, null);
            allocField(s, .itotal, null);
            allocField(s, .iused, null);
            allocField(s, .iavail, null);
            allocField(s, .ipcent, null);
            allocField(s, .target, null);
        },
        .posix => {
            allocField(s, .source, null);
            if (s.print_type) allocField(s, .fstype, null);
            allocField(s, .size, null);
            allocField(s, .used, null);
            allocField(s, .avail, null);
            allocField(s, .pcent, "Capacity");
            allocField(s, .target, null);
        },
        .output => if (s.columns.items.len == 0) {
            if (!decodeOutputArg(s, all_args)) return false;
        },
    }
    return true;
}

fn getHeader(s: *S) void {
    const a = s.alloc();
    const row = allocRow(s) orelse return;
    for (s.columns.items, 0..) |col, ci| {
        const fd = &s.fields[@intFromEnum(col)];
        var header: []const u8 = fd.caption;
        var cell: []u8 = undefined;
        if (col == .size and (s.header_mode == .default or (s.header_mode == .output and (@as(u32, @intCast(s.human_opts)) & human.autoscale) == 0))) {
            var buf: [human.longest]u8 = undefined;
            const ho: u32 = @intCast(s.human_opts);
            var opts: u32 = human.suppress_point_zero | human.autoscale | human.si | (ho & (human.group_digits | human.base_1024 | human.b_suffix));
            var q1000 = s.block_size;
            var q1024 = s.block_size;
            var div1000: bool = undefined;
            var div1024: bool = undefined;
            while (true) {
                div1000 = q1000 % 1000 == 0;
                q1000 /= 1000;
                div1024 = q1024 % 1024 == 0;
                q1024 /= 1024;
                if (!(div1000 and div1024)) break;
            }
            if (@intFromBool(div1000) < @intFromBool(div1024)) opts |= human.base_1024;
            if (@intFromBool(div1024) < @intFromBool(div1000)) opts &= ~human.base_1024;
            if (opts & human.base_1024 == 0) opts |= human.b_suffix;
            const num = human.readable(s.block_size, &buf, opts, 1, 1);
            header = "blocks";
            cell = std.fmt.allocPrint(a, "{s}-{s}", .{ num, header }) catch return;
        } else if (s.header_mode == .posix and col == .size) {
            cell = std.fmt.allocPrint(a, "{d}-{s}", .{ s.block_size, header }) catch return;
        } else cell = a.dupe(u8, header) catch return;
        replaceControl(cell);
        row[ci] = cell;
        if (cell.len > fd.width) fd.width = cell.len;
    }
}

fn printTable(s: *S) void {
    for (s.table.items) |row| {
        for (s.columns.items, 0..) |col, ci| {
            const fd = s.fields[@intFromEnum(col)];
            const cell = row[ci];
            if (ci != 0) s.out.writeByte(' ');
            const fill = if (fd.width > cell.len) fd.width - cell.len else 0;
            if (fd.align_right) {
                var k = fill;
                while (k > 0) : (k -= 1) s.out.writeByte(' ');
            }
            s.out.write(cell);
            if (ci + 1 < s.columns.items.len) {
                var k = if (fd.align_right) @as(usize, 0) else fill;
                while (k > 0) : (k -= 1) s.out.writeByte(' ');
            }
        }
        s.out.writeByte('\n');
    }
}

fn xstrtolFatal(ctx: cli.Context, e: human.StrtolError, o: getopt.Opt, arg: []const u8) void {
    const name: []const u8 = if (o.is_long) "--block-size" else "-B";
    switch (e) {
        .invalid => cli.warn(ctx, "invalid {s} argument {f}", .{ name, cli.quoteC(arg) }),
        .invalid_suffix_char, .invalid_suffix_char_with_overflow => cli.warn(ctx, "invalid suffix in {s} argument {f}", .{ name, cli.quoteC(arg) }),
        .overflow => cli.warn(ctx, "{s} argument {f} too large", .{ name, cli.quoteC(arg) }),
        .ok => {},
    }
}

pub fn main(ctx: cli.Context) u8 {
    var s: S = .{
        .ctx = ctx,
        .out = cli.Out.init(ctx.io),
        .arena = std.heap.ArenaAllocator.init(ctx.gpa),
        .gpa = ctx.gpa,
        .last_for_dev = std.AutoHashMap(u64, usize).init(ctx.gpa),
    };
    defer {
        s.arena.deinit();
        s.select_types.deinit(ctx.gpa);
        s.exclude_types.deinit(ctx.gpa);
        s.mounts.deinit(ctx.gpa);
        s.columns.deinit(ctx.gpa);
        s.table.deinit(ctx.gpa);
        s.kept.deinit(ctx.gpa);
        s.last_for_dev.deinit();
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
    var posix_format = false;
    var p = getopt.Parser.init(ctx, "aB:iF:hHklmPTt:vx:", &.{
        .{ .name = "all", .id = 'a' },
        .{ .name = "block-size", .arg = .required, .id = 'B' },
        .{ .name = "inodes", .id = 'i' },
        .{ .name = "human-readable", .id = 'h' },
        .{ .name = "si", .id = 'H' },
        .{ .name = "local", .id = 'l' },
        .{ .name = "output", .arg = .optional, .id = 1100 },
        .{ .name = "portability", .id = 'P' },
        .{ .name = "print-type", .id = 'T' },
        .{ .name = "sync", .id = 1101 },
        .{ .name = "no-sync", .id = 1102 },
        .{ .name = "total", .id = 1103 },
        .{ .name = "type", .arg = .required, .id = 't' },
        .{ .name = "exclude-type", .arg = .required, .id = 'x' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'a' => s.show_all = true,
            'B' => {
                const bs = human.options(o.arg.?, null, false);
                if (bs.err != .ok) {
                    xstrtolFatal(ctx, bs.err, o, o.arg.?);
                    return 1;
                }
                s.human_opts = @intCast(bs.opts);
                s.block_size = bs.size;
            },
            'i' => {
                if (s.header_mode == .output) {
                    cli.warn(ctx, "options -i and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                s.header_mode = .inodes;
            },
            'h' => {
                s.human_opts = @intCast(human.autoscale | human.si | human.base_1024);
                s.block_size = 1;
            },
            'H' => {
                s.human_opts = @intCast(human.autoscale | human.si);
                s.block_size = 1;
            },
            'k' => {
                s.human_opts = 0;
                s.block_size = 1024;
            },
            'l' => s.show_local = true,
            'm' => {
                s.human_opts = 0;
                s.block_size = 1024 * 1024;
            },
            'T' => {
                if (s.header_mode == .output) {
                    cli.warn(ctx, "options -T and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                s.print_type = true;
            },
            'P' => {
                if (s.header_mode == .output) {
                    cli.warn(ctx, "options -P and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                posix_format = true;
            },
            1101 => s.require_sync = true,
            1102 => s.require_sync = false,
            'F', 't' => s.select_types.insert(ctx.gpa, 0, o.arg.?) catch {},
            'v' => {},
            'x' => s.exclude_types.insert(ctx.gpa, 0, o.arg.?) catch {},
            1100 => {
                if (s.header_mode == .inodes) {
                    cli.warn(ctx, "options -i and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                if (posix_format and s.header_mode == .default) {
                    cli.warn(ctx, "options -P and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                if (s.print_type) {
                    cli.warn(ctx, "options -T and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                s.header_mode = .output;
                if (o.arg) |a| if (!decodeOutputArg(s, a)) return usageFail(ctx);
            },
            1103 => s.print_grand_total = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };

    if (s.human_opts == -1) {
        if (posix_format) {
            s.human_opts = 0;
            s.block_size = if (cli.getenv(ctx, "POSIXLY_CORRECT") != null) 512 else 1024;
        } else {
            const env_bs = cli.getenv(ctx, "BLOCK_SIZE") orelse cli.getenv(ctx, "BLOCKSIZE");
            const bs = human.options(cli.getenv(ctx, "DF_BLOCK_SIZE"), env_bs, cli.getenv(ctx, "POSIXLY_CORRECT") != null);
            s.human_opts = @intCast(bs.opts);
            s.block_size = bs.size;
        }
    }
    if (s.header_mode == .inodes or s.header_mode == .output) {
        // keep
    } else if ((@as(u32, @intCast(s.human_opts)) & human.autoscale) != 0) {
        s.header_mode = .human;
    } else if (posix_format) s.header_mode = .posix;

    {
        var matched = false;
        for (s.select_types.items) |inc| {
            for (s.exclude_types.items) |exc| {
                if (std.mem.eql(u8, inc, exc)) {
                    cli.warn(ctx, "file system type {f} both selected and excluded", .{cli.quoteC(inc)});
                    matched = true;
                    break;
                }
            }
        }
        if (matched) return 1;
    }

    const operands = p.operands.items;
    var stats: std.ArrayList(?sys.FileStat) = .empty;
    defer stats.deinit(ctx.gpa);
    if (operands.len > 0) {
        for (operands) |name| {
            var e: std.os.linux.E = .SUCCESS;
            if (sys.fileStat(name, true, &e)) |st| {
                stats.append(ctx.gpa, st) catch {};
            } else {
                cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), sys.errnoText(e) });
                s.exit_status = 1;
                stats.append(ctx.gpa, null) catch {};
            }
        }
    }

    if (!getFieldList(s)) return usageFail(ctx);
    s.mounts_read = readMounts(s);
    if (!s.mounts_read) {
        var status: u8 = 0;
        if (operands.len == 0 or s.show_all or s.show_local or s.select_types.items.len > 0 or s.exclude_types.items.len > 0) status = 1;
        cli.warn(ctx, "{s}cannot read table of mounted file systems: {s}", .{ if (status == 0) "Warning: " else "", "No such file or directory" });
        if (status != 0) return status;
    }
    if (s.require_sync) {
        // sync(2) is a global flush; nothing to report.
    }
    getHeader(s);

    if (operands.len > 0) {
        s.show_listed = true;
        for (operands, 0..) |name, i| {
            if (stats.items[i]) |st| getEntry(s, name, st);
        }
    } else {
        filterMountList(s, s.show_all);
        // Iterate over a snapshot: getDev does not modify the list.
        for (s.mounts.items) |me| {
            getDev(s, me.devname, me.mountdir, null, null, me.fstype, me.dummy, me.remote, null, true);
        }
    }

    if (s.file_systems_processed) {
        if (s.print_grand_total) {
            getDev(s, "total", if (s.fields[@intFromEnum(Field.source)].used) "-" else "total", null, null, null, false, false, s.grand, false);
        }
        printTable(s);
    } else {
        if (s.exit_status == 0) {
            cli.warn(ctx, "no file systems processed", .{});
            return 1;
        }
    }
    return s.exit_status;
}
