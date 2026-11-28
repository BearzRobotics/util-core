// SPDX-License-Identifier: GPL-2.0-or-later
//! stat library: display file or file system status. Format directives,
//! printf flag handling and the default and terse formats follow GNU stat.c
//! (coreutils 9.6 sources, consulted 2026-11-07). File data comes from
//! statx(2) via src/sys.zig. Reference: GNU coreutils manual "stat
//! invocation" (9.7); POSIX does not specify stat.
//!
//! `run` expands a format (or the default/terse ones, or `--json`) for each
//! name and writes it to a caller-supplied writer; problems with one name are
//! reported through the observer. Argument parsing and the diagnostics' wording
//! are in src/commands/stat.zig.

const std = @import("std");
const quotearg = @import("../quotearg.zig");
const Io = std.Io;
const common = @import("common.zig");
const Sink = @import("sink.zig").Sink;
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const userdb = @import("../userdb.zig");
const fileinfo = @import("../fileinfo.zig");

pub const Env = common.Env;

const fileType = fileinfo.fileType;
const modeString = fileinfo.modeString;
const fs_names = fileinfo.fs_names;

const fmt_terse_fs = "%n %i %l %t %s %S %b %f %a %c %d\n";
const fmt_terse_regular = "%n %s %b %f %u %g %D %i %h %t %T %X %Y %Z %W %o\n";
const default_fs =
    "  File: \"%n\"\n" ++
    "    ID: %-8i Namelen: %-7l Type: %T\n" ++
    "Block size: %-10s Fundamental block size: %S\n" ++
    "Blocks: Total: %-10b Free: %-10f Available: %a\n" ++
    "Inodes: Total: %-10c Free: %d\n";
const default_head = "  File: %N\n  Size: %-10s\tBlocks: %-10b IO Block: %-6o %F\n";
const default_tail = "Access: (%04a/%10.10A)  Uid: (%5u/%8U)   Gid: (%5g/%8G)\n" ++
    "Access: %x\nModify: %y\nChange: %z\n Birth: %w\n";
const default_plain = default_head ++ "Device: %Hd,%Ld\tInode: %-10i  Links: %h\n" ++ default_tail;
const default_device = default_head ++ "Device: %Hd,%Ld\tInode: %-10i  Links: %-5h Device type: %Hr,%Lr\n" ++ default_tail;


const Flags = struct {
    quote: bool = false, // '
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    prec: ?usize = null,

    /// C's printf cannot take a width or precision past INT_MAX; GNU then
    /// prints nothing for the directive.
    fn unprintable(f: Flags) bool {
        return f.width > max_field or (f.prec orelse 0) > max_field;
    }
};

const max_field = std.math.maxInt(i32);

/// `n` times `byte`, however many that is, giving up when output fails.
fn repeat(out: *Sink, byte: u8, n: usize) void {
    var block: [4096]u8 = undefined;
    @memset(&block, byte);
    var left = n;
    while (left > 0 and !out.failed) {
        const k = @min(left, block.len);
        out.write(block[0..k]);
        left -= k;
    }
}

fn parseFlags(spec: []const u8) Flags {
    var f: Flags = .{};
    var i: usize = 0;
    while (i < spec.len) : (i += 1) {
        switch (spec[i]) {
            '\'' => f.quote = true,
            '-' => f.minus = true,
            '+' => f.plus = true,
            ' ' => f.space = true,
            '#' => f.alt = true,
            '0' => f.zero = true,
            'I' => {},
            else => break,
        }
    }
    while (i < spec.len and std.ascii.isDigit(spec[i])) : (i += 1) f.width = f.width *| 10 +| (spec[i] - '0');
    if (i < spec.len and spec[i] == '.') {
        i += 1;
        var p: usize = 0;
        while (i < spec.len and std.ascii.isDigit(spec[i])) : (i += 1) p = p *| 10 +| (spec[i] - '0');
        f.prec = p;
    }
    return f;
}

const Ctx = struct {
    env: Env,
    out: Sink,
    observer: common.Observer(Event),
    zone: tzmod.Zone,
    db: ?userdb.Db = null,
    follow: bool = false,
    printf_mode: bool = false,
    quoting: []const u8 = "literal",

    fn emit(s: *const Ctx, ev: Event) void {
        s.observer.emit(ev);
    }

    /// Report that a field could not be built; true: the file failed.
    fn outOfMemory(s: *const Ctx) bool {
        s.emit(.out_of_memory);
        return true;
    }
};

fn padStr(out: *Sink, f: Flags, text: []const u8) void {
    if (f.unprintable()) return;
    var t = text;
    if (f.prec) |p| if (p < t.len) {
        t = t[0..p];
    };
    if (t.len < f.width) {
        if (f.minus) {
            out.write(t);
            repeat(out, ' ', f.width - t.len);
            return;
        }
        repeat(out, ' ', f.width - t.len);
    }
    out.write(t);
}

/// printf %ju / %jd / %jo / %jx with the allowed flags.
fn outNum(out: *Sink, f: Flags, value: i128, base: u8, signed: bool) void {
    if (f.unprintable()) return;
    var buf: [48]u8 = undefined;
    const neg = value < 0;
    const mag: u128 = @intCast(if (neg) -value else value);
    var digits: []const u8 = switch (base) {
        8 => std.fmt.bufPrint(&buf, "{o}", .{mag}) catch unreachable,
        16 => std.fmt.bufPrint(&buf, "{x}", .{mag}) catch unreachable,
        else => std.fmt.bufPrint(&buf, "{d}", .{mag}) catch unreachable,
    };
    var prefix: []const u8 = "";
    if (f.alt and mag != 0) {
        if (base == 8) prefix = "0" else if (base == 16) prefix = "0x";
    }
    var zeros: usize = 0;
    if (f.prec) |p| {
        if (p == 0 and mag == 0) digits = "";
        if (digits.len < p) zeros = p - digits.len;
    }
    const sign: []const u8 = if (neg) "-" else if (signed and f.plus) "+" else if (signed and f.space) " " else "";
    if (base == 8 and f.alt and zeros == 0 and prefix.len > 0) {
        // '#' on octal: ensure a leading zero only when not already present
        if (digits.len > 0 and digits[0] == '0') prefix = "";
    }
    const total = sign.len + prefix.len + zeros + digits.len;
    if (f.zero and !f.minus and f.prec == null and total < f.width) zeros += f.width - total;
    const total2 = sign.len + prefix.len + zeros + digits.len;
    if (!f.minus and total2 < f.width) repeat(out, ' ', f.width - total2);
    out.write(sign);
    out.write(prefix);
    repeat(out, '0', zeros);
    out.write(digits);
    if (f.minus and total2 < f.width) repeat(out, ' ', f.width - total2);
}

fn humanTime(s: *Ctx, sec: i64, nsec: u32, buf: *std.ArrayList(u8)) void {
    const tm = tzmod.localtime(&s.zone, sec);
    // GNU shows the seconds when the year does not fit.
    if (!tzmod.fitsStructTm(&tm)) {
        buf.print(s.env.gpa, "{d}.{d:0>9}", .{ sec, nsec }) catch {};
        return;
    }
    strftime.format(buf, s.env.gpa, "%Y-%m-%d %H:%M:%S.%N %z", &tm, sec, nsec) catch {};
}

fn major(dev: u64) u64 {
    return ((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(u64, 0xfff));
}
fn minor(dev: u64) u64 {
    return (dev & 0xff) | ((dev >> 12) & ~@as(u64, 0xff));
}

/// out_epoch_sec: seconds since the Epoch formatted like a printf %f with an
/// optional ".N" digits of nanoseconds, including GNU's width arithmetic.
fn epochSec(out: *Sink, spec: []const u8, sec: i64, nsec: i64) void {
    const dot = std.mem.indexOfScalar(u8, spec, '.');
    var precision: usize = 0;
    var width: usize = 0;
    var sec_spec: []const u8 = spec;
    var left_adjust = false;
    var tmp: [64]u8 = undefined;
    if (dot) |d| {
        sec_spec = spec[0..d];
        var pv: usize = 0;
        var k = d + 1;
        if (k < spec.len and std.ascii.isDigit(spec[k])) {
            while (k < spec.len and std.ascii.isDigit(spec[k])) : (k += 1) pv = pv *| 10 +| (spec[k] - '0');
            // A longer fraction than this is cut to it, as in GNU.
            precision = @min(pv, max_field);
        } else precision = 9;
        if (precision != 0 and d > 0 and std.ascii.isDigit(spec[d - 1])) {
            var p = d;
            while (p > 0 and std.ascii.isDigit(spec[p - 1])) p -= 1;
            var wv: usize = 0;
            for (spec[p..d]) |c| wv = wv *| 10 +| (c - '0');
            // With a fraction, a longer width than this is cut to it.
            width = @min(wv, max_field);
            if (width > 1) {
                if (p < d and spec[p] == '0') p += 1;
                sec_spec = spec[0..p];
                const w_d: usize = if (1 < width) width - 1 else 0;
                if (w_d > 1) {
                    const w: isize = @as(isize, @intCast(w_d)) - @as(isize, @intCast(precision));
                    if (w > 1) {
                        var n: usize = 0;
                        for (spec[0..p]) |c| {
                            if (c == '-') left_adjust = true else {
                                tmp[n] = c;
                                n += 1;
                            }
                        }
                        if (!left_adjust) {
                            const ws = std.fmt.bufPrint(tmp[n..], "{d}", .{w}) catch "";
                            n += ws.len;
                        }
                        sec_spec = tmp[0..n];
                    }
                }
            }
        }
    }
    var divisor: i64 = 1;
    var i: usize = precision;
    while (i < 9) : (i += 1) divisor *= 10;
    var ns = nsec;
    if (ns < 0) ns = 0;
    var frac = @divTrunc(ns, divisor);
    var s = sec;
    var minus_zero = false;
    if (s < 0 and ns != 0) {
        const modulus = @divTrunc(@as(i64, 1000000000), divisor);
        frac = modulus - frac - @intFromBool(@mod(ns, divisor) != 0);
        s += @intFromBool(frac != 0);
        minus_zero = s == 0;
    }
    var f = parseFlags(sec_spec);
    f.prec = null;
    var int_len: usize = 0;
    if (minus_zero) {
        var tb: [16]u8 = undefined;
        const txt = std.fmt.bufPrint(&tb, "-0", .{}) catch "-0";
        int_len = @max(txt.len, f.width);
        outStrPad(out, f, txt);
    } else {
        var cnt: usize = 0;
        var sb: [32]u8 = undefined;
        const digits = std.fmt.bufPrint(&sb, "{d}", .{@abs(s)}) catch "";
        cnt = digits.len + @intFromBool(s < 0 or f.plus or f.space);
        int_len = @max(cnt, f.width);
        outNum(out, f, s, 10, true);
    }
    if (precision > 0) {
        const prec = @min(precision, 9);
        const trailing_prec = precision - prec;
        _ = trailing_prec;
        out.writeByte('.');
        var buf: [16]u8 = undefined;
        const fr = std.fmt.bufPrint(&buf, "{d:0>[1]}", .{ @as(u64, @intCast(frac)), prec }) catch "";
        out.write(fr);
        // printf("%-*.*d", trailing_width, trailing_prec, 0): a negative width
        // still pads (to its absolute value); precision 0 prints no digits.
        const tw: i64 = if (int_len < width and 1 < width - int_len) @as(i64, @intCast(width)) - @as(i64, @intCast(int_len)) - 1 - @as(i64, @intCast(prec)) else 0;
        var pad: usize = @intCast(@abs(tw));
        if (precision > 9) {
            repeat(out, '0', precision - 9);
            pad = 0;
        }
        repeat(out, ' ', pad);
    }
}

fn outStrPad(out: *Sink, f: Flags, text: []const u8) void {
    var ff = f;
    ff.prec = null;
    padStr(out, ff, text);
}

/// Write `name` in the QUOTING_STYLE in use, as gnulib quotearg (the port ls
/// uses, which knows the C locale only). Escaping can make a name several
/// times as long, so the writer must not have a fixed size.
fn quoteName(s: *Ctx, name: []const u8, w: *Io.Writer) (Io.Writer.Error || std.mem.Allocator.Error)!void {
    var style: quotearg.Style = .shell_escape_always;
    for (quotearg.style_names, quotearg.style_values) |known, value| {
        if (std.mem.eql(u8, known, s.quoting)) style = value;
    }
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(s.env.gpa);
    try quotearg.quote(&quoted, s.env.gpa, name, style, null);
    try w.writeAll(quoted.items);
}

fn printStat(s: *Ctx, spec: []const u8, mod: u8, m: u8, filename: []const u8, st: *const sys.FileStat, follow: bool) bool {
    const f = parseFlags(spec);
    const out = &s.out;
    var fail = false;
    const gpa = s.env.gpa;
    switch (m) {
        'n' => padStr(out, f, filename),
        'N' => {
            var q: Io.Writer.Allocating = .init(gpa);
            defer q.deinit();
            quoteName(s, filename, &q.writer) catch return s.outOfMemory();
            if (st.isLink()) {
                var lbuf: [4096]u8 = undefined;
                const target = Io.Dir.cwd().readLink(s.env.io, filename, &lbuf) catch |e| {
                    s.emit(.{ .cannot_read_link = .{ .name = filename, .err = e } });
                    return true;
                };
                var lq: Io.Writer.Allocating = .init(gpa);
                defer lq.deinit();
                quoteName(s, lbuf[0..target], &lq.writer) catch return s.outOfMemory();
                // GNU prints the two quoted names separately, each padded by the format.
                padStr(out, f, q.written());
                out.write(" -> ");
                padStr(out, f, lq.written());
                return false;
            }
            padStr(out, f, q.written());
        },
        'd' => {
            const dev: u64 = (@as(u64, st.dev_major) << 8) | (st.dev_minor & 0xff) | ((@as(u64, st.dev_minor) & ~@as(u64, 0xff)) << 12);
            if (mod == 'H') outNum(out, f, st.dev_major, 10, false) else if (mod == 'L') outNum(out, f, st.dev_minor, 10, false) else outNum(out, f, dev, 10, false);
        },
        'D' => outNum(out, f, (@as(u64, st.dev_major) << 8) | (st.dev_minor & 0xff) | ((@as(u64, st.dev_minor) & ~@as(u64, 0xff)) << 12), 16, false),
        'i' => outNum(out, f, st.ino, 10, false),
        'a' => outNum(out, f, st.mode & 0o7777, 8, false),
        'A' => {
            var mb: [10]u8 = undefined;
            padStr(out, f, modeString(st.mode, &mb));
        },
        'f' => outNum(out, f, st.mode, 16, false),
        'F' => padStr(out, f, fileType(st.mode, st.size)),
        'h' => outNum(out, f, st.nlink, 10, false),
        'u' => outNum(out, f, st.uid, 10, false),
        'U' => {
            if (s.db == null) s.db = userdb.Db.load(gpa, s.env.io);
            const u = s.db.?.userByUid(st.uid);
            padStr(out, f, if (u) |x| x.name else "UNKNOWN");
        },
        'g' => outNum(out, f, st.gid, 10, false),
        'G' => {
            if (s.db == null) s.db = userdb.Db.load(gpa, s.env.io);
            const g = s.db.?.groupByGid(st.gid);
            padStr(out, f, if (g) |x| x.name else "UNKNOWN");
        },
        'm' => fail = outMountPoint(s, f, filename, st),
        's' => outNum(out, f, st.size, 10, false),
        'r' => {
            if (mod == 'H') outNum(out, f, st.rdev_major, 10, false) else if (mod == 'L') outNum(out, f, st.rdev_minor, 10, false) else outNum(out, f, (@as(u64, st.rdev_major) << 8) | (st.rdev_minor & 0xff) | ((@as(u64, st.rdev_minor) & ~@as(u64, 0xff)) << 12), 10, false);
        },
        'R' => outNum(out, f, (@as(u64, st.rdev_major) << 8) | (st.rdev_minor & 0xff) | ((@as(u64, st.rdev_minor) & ~@as(u64, 0xff)) << 12), 16, false),
        't' => outNum(out, f, st.rdev_major, 16, false),
        'T' => outNum(out, f, st.rdev_minor, 16, false),
        'B' => outNum(out, f, 512, 10, false),
        'b' => outNum(out, f, st.blocks, 10, false),
        'o' => outNum(out, f, st.blksize, 10, false),
        'w' => {
            if (!st.has_btime) {
                padStr(out, f, "-");
            } else {
                var tb: std.ArrayList(u8) = .empty;
                defer tb.deinit(gpa);
                humanTime(s, st.btime_s, st.btime_ns, &tb);
                padStr(out, f, tb.items);
            }
        },
        'W' => epochSec(out, spec, if (st.has_btime) st.btime_s else 0, if (st.has_btime) st.btime_ns else 0),
        'x', 'y', 'z' => {
            var tb: std.ArrayList(u8) = .empty;
            defer tb.deinit(gpa);
            const sec = if (m == 'x') st.atime_s else if (m == 'y') st.mtime_s else st.ctime_s;
            const ns = if (m == 'x') st.atime_ns else if (m == 'y') st.mtime_ns else st.ctime_ns;
            humanTime(s, sec, ns, &tb);
            padStr(out, f, tb.items);
        },
        'X' => epochSec(out, spec, st.atime_s, st.atime_ns),
        'Y' => epochSec(out, spec, st.mtime_s, st.mtime_ns),
        'Z' => epochSec(out, spec, st.ctime_s, st.ctime_ns),
        'C' => {
            var buf: [256]u8 = undefined;
            var err: std.os.linux.E = .SUCCESS;
            if (sys.getXattr(filename, "security.selinux", follow, &buf, &err)) |n| {
                const v = std.mem.sliceTo(buf[0..n], 0);
                padStr(out, f, v);
            } else {
                s.emit(.{ .cannot_get_context = .{ .name = filename, .errno = err } });
                padStr(out, f, "?");
                fail = true;
            }
        },
        else => out.writeByte('?'),
    }
    return fail;
}

fn outMountPoint(s: *Ctx, f: Flags, filename: []const u8, st: *const sys.FileStat) bool {
    const gpa = s.env.gpa;
    // Canonicalise, then walk up while the device number stays the same.
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    // A link that was not followed is where its directory is; its target
    // may be on another file system, or missing. (As GNU's find_mount_point.)
    const is_link = st.isLink();
    const start = if (is_link) std.fs.path.dirname(filename) orelse "." else filename;
    var real_buf: [4096]u8 = undefined;
    const real_len = Io.Dir.cwd().realPathFile(s.env.io, start, &real_buf) catch {
        s.emit(.{ .cannot_canonicalize = filename });
        padStr(&s.out, f, "?");
        return true;
    };
    path.appendSlice(gpa, real_buf[0..real_len]) catch return true;
    var dev_major = st.dev_major;
    var dev_minor = st.dev_minor;
    if (is_link) {
        var err: std.os.linux.E = .SUCCESS;
        const dir = sys.fileStat(path.items, true, &err) orelse {
            s.emit(.{ .cannot_canonicalize = filename });
            padStr(&s.out, f, "?");
            return true;
        };
        dev_major = dir.dev_major;
        dev_minor = dir.dev_minor;
    }
    while (path.items.len > 1) {
        const slash = std.mem.lastIndexOfScalar(u8, path.items, '/') orelse break;
        const parent_len = if (slash == 0) 1 else slash;
        var err: std.os.linux.E = .SUCCESS;
        const pst = sys.fileStat(path.items[0..parent_len], true, &err) orelse break;
        if (pst.dev_major != dev_major or pst.dev_minor != dev_minor) break;
        path.shrinkRetainingCapacity(parent_len);
        dev_major = pst.dev_major;
        dev_minor = pst.dev_minor;
    }
    padStr(&s.out, f, path.items);
    return false;
}

fn printStatfs(s: *Ctx, spec: []const u8, m: u8, filename: []const u8, fs: *const sys.StatFs) bool {
    const f = parseFlags(spec);
    const out = &s.out;
    switch (m) {
        'n' => padStr(out, f, filename),
        'i' => outNum(out, f, fs.fsid, 16, false),
        'l' => outNum(out, f, fs.namelen, 10, true),
        't' => outNum(out, f, fs.type, 16, false),
        'T' => {
            for (fs_names) |e| if (e.magic == fs.type) {
                padStr(out, f, e.name);
                return false;
            };
            var b: [40]u8 = undefined;
            padStr(out, f, std.fmt.bufPrint(&b, "UNKNOWN (0x{x})", .{fs.type}) catch "UNKNOWN");
        },
        'b' => outNum(out, f, fs.blocks, 10, true),
        'f' => outNum(out, f, fs.bfree, 10, true),
        'a' => outNum(out, f, fs.bavail, 10, true),
        's' => outNum(out, f, fs.bsize, 10, false),
        'S' => outNum(out, f, if (fs.frsize != 0) fs.frsize else fs.bsize, 10, false),
        'c' => outNum(out, f, fs.files, 10, false),
        'd' => outNum(out, f, fs.ffree, 10, true),
        else => out.writeByte('?'),
    }
    return false;
}

fn escChar(s: *Ctx, c: u8) void {
    var ch = c;
    switch (c) {
        'a' => ch = 7,
        'b' => ch = 8,
        'e' => ch = 27,
        'f' => ch = 12,
        'n' => ch = 10,
        'r' => ch = 13,
        't' => ch = 9,
        'v' => ch = 11,
        '"', '\\' => {},
        else => s.emit(.{ .unrecognized_escape = c }),
    }
    s.out.writeByte(ch);
}

fn isFlagChar(c: u8) bool {
    return std.mem.indexOfScalar(u8, "'-+ #0I", c) != null;
}

/// print_it: expand FORMAT for one file. `is_stat` selects the directive set.
fn printIt(s: *Ctx, format: []const u8, filename: []const u8, st: ?*const sys.FileStat, fs: ?*const sys.StatFs, follow: bool, trailing: []const u8) error{InvalidDirective}!bool {
    var fail = false;
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        const c = format[i];
        if (c == '%') {
            // flags, width, precision
            var j = i + 1;
            while (j < format.len and isFlagChar(format[j])) j += 1;
            while (j < format.len and std.ascii.isDigit(format[j])) j += 1;
            if (j < format.len and format[j] == '.') {
                j += 1;
                while (j < format.len and std.ascii.isDigit(format[j])) j += 1;
            }
            const spec = format[i + 1 .. j];
            const fmt_char: u8 = if (j < format.len) format[j] else 0;
            if (fmt_char == 0 or fmt_char == '%') {
                if (spec.len > 0) {
                    s.emit(.{ .invalid_directive = format[i .. @min(j + 1, format.len)] });
                    return error.InvalidDirective;
                }
                s.out.writeByte('%');
                if (fmt_char == 0) i = format.len else i = j;
                continue;
            }
            var m = fmt_char;
            var mod: u8 = 0;
            var consumed = j;
            if ((fmt_char == 'H' or fmt_char == 'L') and st != null and j + 1 < format.len and (format[j + 1] == 'd' or format[j + 1] == 'r')) {
                mod = fmt_char;
                m = format[j + 1];
                consumed = j + 1;
            }
            if (st) |sp| {
                if (printStat(s, spec, mod, m, filename, sp, follow)) fail = true;
            } else if (fs) |fp| {
                if (printStatfs(s, spec, fmt_char, filename, fp)) fail = true;
            }
            i = consumed;
        } else if (c == '\\') {
            if (!s.printf_mode) {
                s.out.writeByte('\\');
                continue;
            }
            i += 1;
            if (i >= format.len) {
                s.emit(.backslash_at_end);
                s.out.writeByte('\\');
                break;
            }
            const e = format[i];
            if (e >= '0' and e <= '7') {
                var v: u32 = e - '0';
                var n: usize = 1;
                while (n < 3 and i + 1 < format.len and format[i + 1] >= '0' and format[i + 1] <= '7') : (n += 1) {
                    i += 1;
                    v = v * 8 + (format[i] - '0');
                }
                s.out.writeByte(@truncate(v));
            } else if (e == 'x' and i + 1 < format.len and std.ascii.isHex(format[i + 1])) {
                i += 1;
                var v: u32 = std.fmt.charToDigit(format[i], 16) catch 0;
                if (i + 1 < format.len and std.ascii.isHex(format[i + 1])) {
                    i += 1;
                    v = v * 16 + (std.fmt.charToDigit(format[i], 16) catch 0);
                }
                s.out.writeByte(@truncate(v));
            } else escChar(s, e);
        } else s.out.writeByte(c);
    }
    s.out.write(trailing);
    return fail;
}

/// --json: one object per operand (decision 0007 in util-unix, which sets the
/// rules for every --json command). `link_of` names the symlink whose target
/// to read. Failures to resolve names or links only make those fields null.
fn writeJsonLine(s: *Ctx, name: []const u8, st: ?*const sys.FileStat, fs: ?*const sys.StatFs, link_of: ?[]const u8) void {
    var aw: Io.Writer.Allocating = .init(s.env.gpa);
    defer aw.deinit();
    if (fs) |f| {
        fileinfo.writeFsJson(&aw.writer, name, f) catch return;
    } else if (st) |sp| {
        if (s.db == null) s.db = userdb.Db.load(s.env.gpa, s.env.io);
        var lbuf: [4096]u8 = undefined;
        var target: ?[]const u8 = null;
        if (link_of) |l| {
            if (Io.Dir.cwd().readLink(s.env.io, l, &lbuf)) |n| target = lbuf[0..n] else |_| {}
        }
        const user = if (s.db.?.userByUid(sp.uid)) |u| u.name else null;
        const group = if (s.db.?.groupByGid(sp.gid)) |g| g.name else null;
        fileinfo.writeJson(&aw.writer, name, sp, target, user, group) catch return;
    }
    s.out.write(aw.written());
}

pub const Options = struct {
    /// -f: report on the file system holding each name.
    fs_mode: bool = false,
    /// -L: follow symbolic links.
    follow: bool = false,
    /// -t: the terse format.
    terse: bool = false,
    /// --format (`printf_mode` false: a newline is added) or --printf
    /// (`printf_mode` true: backslash escapes are interpreted, no newline).
    /// Null selects the default (or terse) format.
    format: ?[]const u8 = null,
    printf_mode: bool = false,
    /// Extension (decision 0003): one JSON object per name.
    json: bool = false,
    /// How `%N` quotes names: one of `quoting_styles`. GNU uses
    /// "shell-escape-always" when the user gave a format containing `%N` and
    /// QUOTING_STYLE does not say otherwise, "literal" otherwise (the default
    /// formats quote themselves); the caller decides.
    quoting: []const u8 = "literal",
};

pub const quoting_styles = [_][]const u8{ "literal", "shell", "shell-always", "shell-escape", "shell-escape-always", "c", "c-maybe", "escape", "locale", "clocale" };

pub const Event = union(enum) {
    /// `-` given in file system mode.
    stdin_in_fs_mode: []const u8,
    cannot_statfs: NameErrno,
    cannot_stat_stdin,
    cannot_stat: NameErrno,
    cannot_read_link: struct { name: []const u8, err: anyerror },
    cannot_get_context: NameErrno,
    cannot_canonicalize: []const u8,
    out_of_memory,
    /// A printf escape that GNU does not know (warning only).
    unrecognized_escape: u8,
    backslash_at_end,
    /// The text of a malformed `%` directive; `run` then fails with
    /// `error.InvalidDirective`.
    invalid_directive: []const u8,

    pub const NameErrno = struct { name: []const u8, errno: std.os.linux.E };

    /// Events that GNU prints after the output produced so far has been
    /// flushed (the file could not be examined at all).
    pub fn isStatFailure(ev: Event) bool {
        return switch (ev) {
            .cannot_statfs, .cannot_stat_stdin, .cannot_stat => true,
            else => false,
        };
    }
};

pub const Result = struct { failed: bool };

pub const Error = error{ OutOfMemory, WriteFailed, InvalidDirective };

/// Display the status of each of `names` (as GNU stat does for its operands).
/// The writer is flushed when done.
pub fn run(env: Env, options: Options, names: []const []const u8, writer: *Io.Writer, observer: common.Observer(Event)) Error!Result {
    var s: Ctx = .{
        .env = env,
        .out = Sink.init(writer),
        .observer = observer,
        .zone = tzmod.load(env.gpa, env.io, env.getenv("TZ")),
    };
    defer s.zone.deinit();
    defer if (s.db) |*d| d.deinit();
    s.printf_mode = options.printf_mode;
    s.follow = options.follow;
    s.quoting = options.quoting;

    const format = options.format;
    const trailing: []const u8 = if (format != null and options.printf_mode) "" else "\n";
    var fmt1: []const u8 = undefined;
    var fmt2: []const u8 = undefined;
    if (format) |f| {
        fmt1 = f;
        fmt2 = f;
    } else if (options.fs_mode) {
        fmt1 = if (options.terse) fmt_terse_fs else default_fs;
        fmt2 = fmt1;
    } else if (options.terse) {
        fmt1 = fmt_terse_regular;
        fmt2 = fmt_terse_regular;
    } else {
        fmt1 = default_plain;
        fmt2 = default_device;
    }
    // Default formats carry their own trailing newline.
    const has_own_nl = format == null;

    var ok = true;
    for (names) |name| {
        if (options.fs_mode) {
            if (std.mem.eql(u8, name, "-")) {
                s.emit(.{ .stdin_in_fs_mode = name });
                ok = false;
                continue;
            }
            var err: std.os.linux.E = .SUCCESS;
            const sf = sys.statfs(name, &err) orelse {
                s.emit(.{ .cannot_statfs = .{ .name = name, .errno = err } });
                ok = false;
                continue;
            };
            if (options.json) {
                writeJsonLine(&s, name, null, &sf, null);
                continue;
            }
            if (try printIt(&s, fmt1, name, null, &sf, options.follow, if (has_own_nl) "" else trailing)) ok = false;
        } else {
            var st: sys.FileStat = undefined;
            var err: std.os.linux.E = .SUCCESS;
            if (std.mem.eql(u8, name, "-")) {
                const fst = Io.File.stdin().stat(env.io) catch {
                    s.emit(.cannot_stat_stdin);
                    ok = false;
                    continue;
                };
                _ = fst;
                st = sys.fileStat("/proc/self/fd/0", true, &err) orelse {
                    s.emit(.cannot_stat_stdin);
                    ok = false;
                    continue;
                };
            } else st = sys.fileStat(name, options.follow, &err) orelse {
                s.emit(.{ .cannot_stat = .{ .name = name, .errno = err } });
                ok = false;
                continue;
            };
            if (options.json) {
                writeJsonLine(&s, name, &st, null, if (st.isLink()) name else null);
                continue;
            }
            const is_dev = (st.mode & 0o170000) == 0o060000 or (st.mode & 0o170000) == 0o020000;
            const fmt = if (is_dev) fmt2 else fmt1;
            if (try printIt(&s, fmt, name, &st, null, options.follow, if (has_own_nl) "" else trailing)) ok = false;
        }
    }
    s.out.flush();
    try s.out.check();
    return .{ .failed = !ok };
}

test "numeric directives honour width, zero padding and radix" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var out = Sink.init(&aw.writer);
    outNum(&out, parseFlags("08"), 255, 16, false);
    out.writeByte('|');
    outNum(&out, parseFlags("-5"), 42, 10, false);
    out.writeByte('|');
    try std.testing.expectEqualStrings("000000ff|42   |", aw.written());
}
