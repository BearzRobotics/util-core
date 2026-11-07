//! stat — display file or file system status.
//! Reference: GNU coreutils manual "stat invocation" (9.7); POSIX does not
//! specify stat. Format directives, printf flag handling and the default and
//! terse formats follow GNU stat.c (coreutils 9.6 sources, consulted
//! 2026-11-07). File data comes from statx(2) via src/sys.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const userdb = @import("../userdb.zig");
const Io = std.Io;

const help_text = @embedFile("../help/stat.txt");

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

const FsName = struct { magic: u64, name: []const u8 };
const fs_names = [_]FsName{
    .{ .magic = 0x5A3C69F0, .name = "aafs" },      .{ .magic = 0x61636673, .name = "acfs" },      .{ .magic = 0xADF5, .name = "adfs" },
    .{ .magic = 0xADFF, .name = "affs" },          .{ .magic = 0x5346414F, .name = "afs" },       .{ .magic = 0x09041934, .name = "anon-inode FS" },
    .{ .magic = 0x61756673, .name = "aufs" },      .{ .magic = 0x0187, .name = "autofs" },        .{ .magic = 0x13661366, .name = "balloon-kvm-fs" },
    .{ .magic = 0xCA451A4E, .name = "bcachefs" },  .{ .magic = 0x42465331, .name = "befs" },      .{ .magic = 0x62646576, .name = "bdevfs" },
    .{ .magic = 0x1BADFACE, .name = "bfs" },       .{ .magic = 0x6C6F6F70, .name = "binderfs" },  .{ .magic = 0xCAFE4A11, .name = "bpf_fs" },
    .{ .magic = 0x42494E4D, .name = "binfmt_misc" }, .{ .magic = 0x9123683E, .name = "btrfs" },   .{ .magic = 0x73727279, .name = "btrfs_test" },
    .{ .magic = 0x00C36400, .name = "ceph" },      .{ .magic = 0x0027E0EB, .name = "cgroupfs" },  .{ .magic = 0x63677270, .name = "cgroup2fs" },
    .{ .magic = 0xFF534D42, .name = "cifs" },      .{ .magic = 0x73757245, .name = "coda" },      .{ .magic = 0x012FF7B7, .name = "coh" },
    .{ .magic = 0x62656570, .name = "configfs" },  .{ .magic = 0x28CD3D45, .name = "cramfs" },    .{ .magic = 0x453DCD28, .name = "cramfs-wend" },
    .{ .magic = 0x64646178, .name = "daxfs" },     .{ .magic = 0x64626720, .name = "debugfs" },   .{ .magic = 0x1373, .name = "devfs" },
    .{ .magic = 0x454D444D, .name = "devmem" },    .{ .magic = 0x1CD1, .name = "devpts" },        .{ .magic = 0x444D4142, .name = "dma-buf-fs" },
    .{ .magic = 0xF15F, .name = "ecryptfs" },      .{ .magic = 0xDE5E81E4, .name = "efivarfs" },  .{ .magic = 0x00414A53, .name = "efs" },
    .{ .magic = 0xE0F5E1E2, .name = "erofs" },     .{ .magic = 0x2011BAB0, .name = "exfat" },     .{ .magic = 0x45584653, .name = "exfs" },
    .{ .magic = 0x5DF5, .name = "exofs" },         .{ .magic = 0x137D, .name = "ext" },           .{ .magic = 0xEF53, .name = "ext2/ext3" },
    .{ .magic = 0xEF51, .name = "ext2" },          .{ .magic = 0xF2F52010, .name = "f2fs" },      .{ .magic = 0x4006, .name = "fat" },
    .{ .magic = 0x19830326, .name = "fhgfs" },     .{ .magic = 0x65735546, .name = "fuse" },      .{ .magic = 0x65735543, .name = "fusectl" },
    .{ .magic = 0x0BAD1DEA, .name = "futexfs" },   .{ .magic = 0x01161970, .name = "gfs/gfs2" },  .{ .magic = 0x47504653, .name = "gpfs" },
    .{ .magic = 0x4244, .name = "hfs" },           .{ .magic = 0x482B, .name = "hfs+" },          .{ .magic = 0x4858, .name = "hfsx" },
    .{ .magic = 0x00C0FFEE, .name = "hostfs" },    .{ .magic = 0xF995E849, .name = "hpfs" },      .{ .magic = 0x958458F6, .name = "hugetlbfs" },
    .{ .magic = 0x11307854, .name = "inodefs" },   .{ .magic = 0x013111A8, .name = "ibrix" },     .{ .magic = 0x2BAD1DEA, .name = "inotifyfs" },
    .{ .magic = 0x9660, .name = "isofs" },         .{ .magic = 0x4004, .name = "isofs" },         .{ .magic = 0x4000, .name = "isofs" },
    .{ .magic = 0x07C0, .name = "jffs" },          .{ .magic = 0x72B6, .name = "jffs2" },         .{ .magic = 0x3153464A, .name = "jfs" },
    .{ .magic = 0x6B414653, .name = "k-afs" },     .{ .magic = 0xC97E8168, .name = "logfs" },     .{ .magic = 0x0BD00BD0, .name = "lustre" },
    .{ .magic = 0x5346314D, .name = "m1fs" },      .{ .magic = 0x137F, .name = "minix" },         .{ .magic = 0x138F, .name = "minix (30 char.)" },
    .{ .magic = 0x2468, .name = "minix v2" },      .{ .magic = 0x2478, .name = "minix v2 (30 char.)" }, .{ .magic = 0x4D5A, .name = "minix3" },
    .{ .magic = 0x19800202, .name = "mqueue" },    .{ .magic = 0x4D44, .name = "msdos" },         .{ .magic = 0x564C, .name = "novell" },
    .{ .magic = 0x6969, .name = "nfs" },           .{ .magic = 0x6E667364, .name = "nfsd" },      .{ .magic = 0x3434, .name = "nilfs" },
    .{ .magic = 0x6E736673, .name = "nsfs" },      .{ .magic = 0x5346544E, .name = "ntfs" },      .{ .magic = 0x9FA1, .name = "openprom" },
    .{ .magic = 0x7461636F, .name = "ocfs2" },     .{ .magic = 0x794C7630, .name = "overlayfs" }, .{ .magic = 0xAAD7AAEA, .name = "panfs" },
    .{ .magic = 0x50494446, .name = "pidfs" },     .{ .magic = 0x50495045, .name = "pipefs" },    .{ .magic = 0xC7571590, .name = "ppc-cmm-fs" },
    .{ .magic = 0x7C7C6673, .name = "prl_fs" },    .{ .magic = 0x9FA0, .name = "proc" },          .{ .magic = 0x6165676C, .name = "pstorefs" },
    .{ .magic = 0x002F, .name = "qnx4" },          .{ .magic = 0x68191122, .name = "qnx6" },      .{ .magic = 0x858458F6, .name = "ramfs" },
    .{ .magic = 0x07655821, .name = "rdt" },       .{ .magic = 0x52654973, .name = "reiserfs" },  .{ .magic = 0x7275, .name = "romfs" },
    .{ .magic = 0x67596969, .name = "rpc_pipefs" }, .{ .magic = 0x5DCA2DF5, .name = "sdcardfs" }, .{ .magic = 0x5345434D, .name = "secretmem" },
    .{ .magic = 0x73636673, .name = "securityfs" }, .{ .magic = 0xF97CFF8C, .name = "selinux" },   .{ .magic = 0x43415D53, .name = "smackfs" },
    .{ .magic = 0x517B, .name = "smb" },           .{ .magic = 0xFE534D42, .name = "smb2" },      .{ .magic = 0xBEEFDEAD, .name = "snfs" },
    .{ .magic = 0x534F434B, .name = "sockfs" },    .{ .magic = 0x73717368, .name = "squashfs" },  .{ .magic = 0x62656572, .name = "sysfs" },
    .{ .magic = 0x012FF7B6, .name = "sysv2" },     .{ .magic = 0x012FF7B5, .name = "sysv4" },     .{ .magic = 0x01021994, .name = "tmpfs" },
    .{ .magic = 0x74726163, .name = "tracefs" },   .{ .magic = 0x24051905, .name = "ubifs" },     .{ .magic = 0x15013346, .name = "udf" },
    .{ .magic = 0x00011954, .name = "ufs" },       .{ .magic = 0x54190100, .name = "ufs" },       .{ .magic = 0x9FA2, .name = "usbdevfs" },
    .{ .magic = 0x01021997, .name = "v9fs" },      .{ .magic = 0x786F4256, .name = "vboxsf" },    .{ .magic = 0xBACBACBC, .name = "vmhgfs" },
    .{ .magic = 0xA501FCF5, .name = "vxfs" },      .{ .magic = 0x565A4653, .name = "vzfs" },      .{ .magic = 0x53464846, .name = "wslfs" },
    .{ .magic = 0xABBA1974, .name = "xenfs" },     .{ .magic = 0x012FF7B4, .name = "xenix" },     .{ .magic = 0x58465342, .name = "xfs" },
    .{ .magic = 0x012FD16D, .name = "xia" },       .{ .magic = 0x0033, .name = "z3fold" },        .{ .magic = 0x2FC12FC1, .name = "zfs" },
    .{ .magic = 0x5A4F4653, .name = "zonefs" },    .{ .magic = 0x58295829, .name = "zsmallocfs" },
};

const Flags = struct {
    quote: bool = false, // '
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    prec: ?usize = null,
};

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
    while (i < spec.len and std.ascii.isDigit(spec[i])) : (i += 1) f.width = f.width * 10 + (spec[i] - '0');
    if (i < spec.len and spec[i] == '.') {
        i += 1;
        var p: usize = 0;
        while (i < spec.len and std.ascii.isDigit(spec[i])) : (i += 1) p = p * 10 + (spec[i] - '0');
        f.prec = p;
    }
    return f;
}

const Ctx = struct {
    c: cli.Context,
    out: cli.Out,
    zone: tzmod.Zone,
    db: ?userdb.Db = null,
    follow: bool = false,
    printf_mode: bool = false,
    ok: bool = true,
    quote_always: bool = false,
    quoting: []const u8 = "literal",
};

fn padStr(out: *cli.Out, f: Flags, text: []const u8) void {
    var t = text;
    if (f.prec) |p| if (p < t.len) {
        t = t[0..p];
    };
    if (t.len < f.width) {
        if (f.minus) {
            out.write(t);
            var n = f.width - t.len;
            while (n > 0) : (n -= 1) out.writeByte(' ');
            return;
        }
        var n = f.width - t.len;
        while (n > 0) : (n -= 1) out.writeByte(' ');
    }
    out.write(t);
}

/// printf %ju / %jd / %jo / %jx with the allowed flags.
fn outNum(out: *cli.Out, f: Flags, value: i128, base: u8, signed: bool) void {
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
    if (!f.minus and total2 < f.width) {
        var n = f.width - total2;
        while (n > 0) : (n -= 1) out.writeByte(' ');
    }
    out.write(sign);
    out.write(prefix);
    var z = zeros;
    while (z > 0) : (z -= 1) out.writeByte('0');
    out.write(digits);
    if (f.minus and total2 < f.width) {
        var n = f.width - total2;
        while (n > 0) : (n -= 1) out.writeByte(' ');
    }
}

fn humanTime(s: *Ctx, sec: i64, nsec: u32, buf: *std.ArrayList(u8)) void {
    const tm = tzmod.localtime(&s.zone, sec);
    strftime.format(buf, s.c.gpa, "%Y-%m-%d %H:%M:%S.%N %z", &tm, sec, nsec) catch {};
}

fn fileType(mode: u32, size: u64) []const u8 {
    return switch (mode & 0o170000) {
        0o100000 => if (size == 0) "regular empty file" else "regular file",
        0o040000 => "directory",
        0o120000 => "symbolic link",
        0o060000 => "block special file",
        0o020000 => "character special file",
        0o010000 => "fifo",
        0o140000 => "socket",
        else => "weird file",
    };
}

fn modeString(mode: u32, buf: *[10]u8) []const u8 {
    buf[0] = switch (mode & 0o170000) {
        0o100000 => '-',
        0o040000 => 'd',
        0o120000 => 'l',
        0o060000 => 'b',
        0o020000 => 'c',
        0o010000 => 'p',
        0o140000 => 's',
        else => '?',
    };
    const bits = "rwxrwxrwx";
    for (0..9) |i| buf[1 + i] = if (mode & (@as(u32, 0o400) >> @intCast(i)) != 0) bits[i] else '-';
    if (mode & 0o4000 != 0) buf[3] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) buf[6] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) buf[9] = if (mode & 0o001 != 0) 't' else 'T';
    return buf[0..10];
}

fn major(dev: u64) u64 {
    return ((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(u64, 0xfff));
}
fn minor(dev: u64) u64 {
    return (dev & 0xff) | ((dev >> 12) & ~@as(u64, 0xff));
}

/// out_epoch_sec: seconds since the Epoch formatted like a printf %f with an
/// optional ".N" digits of nanoseconds, including GNU's width arithmetic.
fn epochSec(out: *cli.Out, spec: []const u8, sec: i64, nsec: i64) void {
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
            precision = pv;
        } else precision = 9;
        if (precision != 0 and d > 0 and std.ascii.isDigit(spec[d - 1])) {
            var p = d;
            while (p > 0 and std.ascii.isDigit(spec[p - 1])) p -= 1;
            var wv: usize = 0;
            for (spec[p..d]) |c| wv = wv *| 10 +| (c - '0');
            width = wv;
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
        const before = out.len;
        _ = before;
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
            var z = precision - 9;
            while (z > 0) : (z -= 1) out.writeByte('0');
            pad = 0;
        }
        while (pad > 0) : (pad -= 1) out.writeByte(' ');
    }
}

fn outStrPad(out: *cli.Out, f: Flags, text: []const u8) void {
    var ff = f;
    ff.prec = null;
    padStr(out, ff, text);
}

fn quoteName(s: *Ctx, name: []const u8, buf: *std.ArrayList(u8)) void {
    var tmp: [8192]u8 = undefined;
    var w: Io.Writer = .fixed(&tmp);
    const st = s.quoting;
    if (std.mem.eql(u8, st, "literal")) {
        buf.appendSlice(s.c.gpa, name) catch {};
        return;
    }
    if (std.mem.eql(u8, st, "c") or std.mem.eql(u8, st, "clocale") or std.mem.eql(u8, st, "escape")) {
        const quoted = !std.mem.eql(u8, st, "escape");
        if (quoted) w.writeByte('"') catch {};
        for (name) |ch| switch (ch) {
            '\\' => w.writeAll("\\\\") catch {},
            '"' => if (quoted) w.writeAll("\\\"") catch {} else w.writeByte('"') catch {},
            7 => w.writeAll("\\a") catch {},
            8 => w.writeAll("\\b") catch {},
            9 => w.writeAll("\\t") catch {},
            10 => w.writeAll("\\n") catch {},
            11 => w.writeAll("\\v") catch {},
            12 => w.writeAll("\\f") catch {},
            13 => w.writeAll("\\r") catch {},
            ' ' => if (quoted) w.writeByte(' ') catch {} else w.writeAll("\\ ") catch {},
            else => if (ch < 0x20 or ch >= 0x7f) w.print("\\{o:0>3}", .{ch}) catch {} else w.writeByte(ch) catch {},
        };
        if (quoted) w.writeByte('"') catch {};
    } else if (std.mem.eql(u8, st, "shell") or std.mem.eql(u8, st, "shell-always") or std.mem.eql(u8, st, "locale")) {
        const needs = std.mem.eql(u8, st, "shell-always") or std.mem.eql(u8, st, "locale") or std.mem.indexOfAny(u8, name, " \t\n'\"\\$`!&|;<>()*?[]{}~#^=") != null or name.len == 0;
        if (needs) {
            w.writeByte('\'') catch {};
            for (name) |ch| if (ch == '\'') w.writeAll("'\\''") catch {} else w.writeByte(ch) catch {};
            w.writeByte('\'') catch {};
        } else w.writeAll(name) catch {};
    } else {
        (if (std.mem.eql(u8, st, "shell-escape-always")) cli.quoteA(name) else cli.quote(name)).format(&w) catch {};
    }
    buf.appendSlice(s.c.gpa, w.buffered()) catch {};
}

fn printStat(s: *Ctx, spec: []const u8, mod: u8, m: u8, filename: []const u8, st: *const sys.FileStat, follow: bool) bool {
    const f = parseFlags(spec);
    const out = &s.out;
    var fail = false;
    const gpa = s.c.gpa;
    switch (m) {
        'n' => padStr(out, f, filename),
        'N' => {
            var q: std.ArrayList(u8) = .empty;
            defer q.deinit(gpa);
            quoteName(s, filename, &q);
            if (st.isLink()) {
                var lbuf: [4096]u8 = undefined;
                const target = Io.Dir.cwd().readLink(s.c.io, filename, &lbuf) catch |e| {
                    cli.warn(s.c, "cannot read symbolic link {f}: {s}", .{ cli.quoteA(filename), cli.errText(e) });
                    return true;
                };
                var lq: std.ArrayList(u8) = .empty;
                defer lq.deinit(gpa);
                quoteName(s, lbuf[0..target], &lq);
                q.appendSlice(gpa, " -> ") catch {};
                q.appendSlice(gpa, lq.items) catch {};
                // GNU prints the two quoted names separately, each padded by the format.
                var first: std.ArrayList(u8) = .empty;
                defer first.deinit(gpa);
                quoteName(s, filename, &first);
                padStr(out, f, first.items);
                out.write(" -> ");
                padStr(out, f, lq.items);
                return false;
            }
            padStr(out, f, q.items);
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
            if (s.db == null) s.db = userdb.Db.load(gpa, s.c.io);
            const u = s.db.?.userByUid(st.uid);
            padStr(out, f, if (u) |x| x.name else "UNKNOWN");
        },
        'g' => outNum(out, f, st.gid, 10, false),
        'G' => {
            if (s.db == null) s.db = userdb.Db.load(gpa, s.c.io);
            const g = s.db.?.groupByGid(st.gid);
            padStr(out, f, if (g) |x| x.name else "UNKNOWN");
        },
        'm' => fail = outMountPoint(s, f, filename, st, follow),
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
                cli.warn(s.c, "failed to get security context of {f}: {s}", .{ cli.quoteA(filename), sys.errnoText(err) });
                padStr(out, f, "?");
                fail = true;
            }
        },
        else => out.writeByte('?'),
    }
    return fail;
}

fn outMountPoint(s: *Ctx, f: Flags, filename: []const u8, st: *const sys.FileStat, follow: bool) bool {
    _ = follow;
    const gpa = s.c.gpa;
    // Canonicalise, then walk up while the device number stays the same.
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    var real_buf: [4096]u8 = undefined;
    const real_len = Io.Dir.cwd().realPathFile(s.c.io, filename, &real_buf) catch {
        cli.warn(s.c, "failed to canonicalize {f}: No such file or directory", .{cli.quoteA(filename)});
        padStr(&s.out, f, "?");
        return true;
    };
    path.appendSlice(gpa, real_buf[0..real_len]) catch return true;
    var dev_major = st.dev_major;
    var dev_minor = st.dev_minor;
    if (st.isLink()) {
        // lstat of the link itself: use the device of its directory.
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
        else => cli.warn(s.c, "warning: unrecognized escape '\\{c}'", .{c}),
    }
    s.out.writeByte(ch);
}

fn isFlagChar(c: u8) bool {
    return std.mem.indexOfScalar(u8, "'-+ #0I", c) != null;
}

/// print_it: expand FORMAT for one file. `is_stat` selects the directive set.
fn printIt(s: *Ctx, format: []const u8, filename: []const u8, st: ?*const sys.FileStat, fs: ?*const sys.StatFs, follow: bool, trailing: []const u8) bool {
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
                    cli.warn(s.c, "{f}: invalid directive", .{cli.quoteC(format[i .. @min(j + 1, format.len)])});
                    s.out.flush();
                    std.process.exit(1);
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
                cli.warn(s.c, "warning: backslash at end of format", .{});
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

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var fs_mode = false;
    var terse = false;
    var format: ?[]const u8 = null;
    var printf_mode = false;
    var follow = false;

    var tz_env: ?[]const u8 = null;
    if (ctx.environ) |m| tz_env = m.get("TZ");
    var s: Ctx = .{ .c = ctx, .out = cli.Out.init(ctx.io), .zone = tzmod.load(gpa, ctx.io, tz_env) };
    defer s.zone.deinit();
    defer if (s.db) |*d| d.deinit();

    var p = getopt.Parser.init(ctx, "c:fLt", &.{
        .{ .name = "dereference", .id = 'L' },
        .{ .name = "file-system", .id = 'f' },
        .{ .name = "format", .arg = .required, .id = 'c' },
        .{ .name = "printf", .arg = .required, .id = 1100 },
        .{ .name = "terse", .id = 't' },
        .{ .name = "cached", .arg = .required, .id = 1101 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            1100 => {
                format = o.arg;
                printf_mode = true;
            },
            'c' => {
                format = o.arg;
                printf_mode = false;
            },
            'L' => follow = true,
            'f' => fs_mode = true,
            't' => terse = true,
            1101 => {
                const names = [_][]const u8{ "default", "never", "always" };
                var found = false;
                for (names) |n| if (std.mem.startsWith(u8, n, o.arg.?)) {
                    found = true;
                };
                if (!found) {
                    cli.warn(ctx, "invalid argument {f} for '--cached'\nValid arguments are:\n  - 'default'\n  - 'never'\n  - 'always'\nTry '{s} --help' for more information.", .{ cli.quoteC(o.arg.?), ctx.name });
                    return 1;
                }
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    s.printf_mode = printf_mode;
    // %N quotes with shell-escape-always only when the user gave a format.
    s.quote_always = format != null and std.mem.indexOf(u8, format.?, "%N") != null;
    if (s.quote_always) {
        s.quoting = "shell-escape-always";
        if (cli.getenv(ctx, "QUOTING_STYLE")) |qs| {
            const valid = [_][]const u8{ "literal", "shell", "shell-always", "shell-escape", "shell-escape-always", "c", "c-maybe", "escape", "locale", "clocale" };
            var ok_style = false;
            for (valid) |v| if (std.mem.eql(u8, v, qs)) {
                ok_style = true;
            };
            if (ok_style) {
                s.quoting = qs;
                s.quote_always = std.mem.eql(u8, qs, "shell-escape-always");
            } else {
                cli.warn(ctx, "ignoring invalid value of environment variable QUOTING_STYLE: {f}", .{cli.quoteC(qs)});
            }
        }
    }
    s.follow = follow;
    const files = p.operands.items;
    if (files.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 1;
    }
    const trailing: []const u8 = if (format != null and printf_mode) "" else "\n";
    var fmt1: []const u8 = undefined;
    var fmt2: []const u8 = undefined;
    if (format) |f| {
        fmt1 = f;
        fmt2 = f;
    } else if (fs_mode) {
        fmt1 = if (terse) fmt_terse_fs else default_fs;
        fmt2 = fmt1;
    } else if (terse) {
        fmt1 = fmt_terse_regular;
        fmt2 = fmt_terse_regular;
    } else {
        fmt1 = default_plain;
        fmt2 = default_device;
    }
    // Default formats carry their own trailing newline.
    const has_own_nl = format == null;

    var ok = true;
    for (files) |name| {
        if (fs_mode) {
            if (std.mem.eql(u8, name, "-")) {
                cli.warn(ctx, "using {f} to denote standard input does not work in file system mode", .{cli.quoteA(name)});
                ok = false;
                continue;
            }
            var err: std.os.linux.E = .SUCCESS;
            const sf = sys.statfs(name, &err) orelse {
                s.out.flush();
                cli.warn(ctx, "cannot read file system information for {f}: {s}", .{ cli.quoteA(name), sys.errnoText(err) });
                ok = false;
                continue;
            };
            if (printIt(&s, fmt1, name, null, &sf, follow, if (has_own_nl) "" else trailing)) ok = false;
        } else {
            var st: sys.FileStat = undefined;
            var err: std.os.linux.E = .SUCCESS;
            if (std.mem.eql(u8, name, "-")) {
                const fst = Io.File.stdin().stat(ctx.io) catch {
                    s.out.flush();
                    cli.warn(ctx, "cannot stat standard input", .{});
                    ok = false;
                    continue;
                };
                _ = fst;
                st = sys.fileStat("/proc/self/fd/0", true, &err) orelse {
                    s.out.flush();
                    cli.warn(ctx, "cannot stat standard input", .{});
                    ok = false;
                    continue;
                };
            } else st = sys.fileStat(name, follow, &err) orelse {
                s.out.flush();
                cli.warn(ctx, "cannot statx {f}: {s}", .{ cli.quoteA(name), sys.errnoText(err) });
                ok = false;
                continue;
            };
            const is_dev = (st.mode & 0o170000) == 0o060000 or (st.mode & 0o170000) == 0o020000;
            const fmt = if (is_dev) fmt2 else fmt1;
            if (printIt(&s, fmt, name, &st, null, follow, if (has_own_nl) "" else trailing)) ok = false;
        }
    }
    s.out.flush();
    if (s.out.failed) return 1;
    return if (ok) 0 else 1;
}
