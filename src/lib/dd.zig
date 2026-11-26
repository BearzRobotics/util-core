// SPDX-License-Identifier: GPL-2.0-or-later
//! dd library: convert and copy a file.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "dd invocation"
//! (9.7) and GNU coreutils 9.6 src/dd.c.
//!
//! The caller parses the operands into a `Job` (`Job.init`, then the option
//! fields) and calls `run`. The job reads from `in_fd` and writes to
//! `out_fd` (or opens `input_file` / `output_file` itself) and closes both
//! when it is done. Diagnostics and the statistics go through the observer:
//! `diag` is the GNU message text without the program-name prefix, `raw`
//! is text for standard error exactly as it is (statistics, progress).
//!
//! A caller that owns the process may call `catchSignals`, so that SIGUSR1
//! prints the statistics during a run and SIGINT prints them before ending
//! the process, as with GNU dd.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const quote = @import("../quote.zig");
const sys = @import("../sys.zig");
const human = @import("../human.zig");
const fmt_float = @import("../fmt_float.zig");
const E = std.os.linux.E;

pub const Env = common.Env;

pub const Event = union(enum) {
    diag: []const u8,
    raw: []const u8,
};
pub const Observer = common.Observer(Event);

/// Why a copy stopped early: `Quit` after the usual clean-up (GNU's quit()),
/// `Abort` at once.
const Fail = error{ Quit, Abort };

const ascii_to_ebcdic = [256]u8{
    0x00, 0x01, 0x02, 0x03, 0x37, 0x2d, 0x2e, 0x2f, 0x16, 0x05, 0x25, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x3c, 0x3d, 0x32, 0x26, 0x18, 0x19, 0x3f, 0x27, 0x1c, 0x1d, 0x1e, 0x1f,
    0x40, 0x5a, 0x7f, 0x7b, 0x5b, 0x6c, 0x50, 0x7d, 0x4d, 0x5d, 0x5c, 0x4e, 0x6b, 0x60, 0x4b, 0x61,
    0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0x7a, 0x5e, 0x4c, 0x7e, 0x6e, 0x6f,
    0x7c, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6,
    0xd7, 0xd8, 0xd9, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xad, 0xe0, 0xbd, 0x9a, 0x6d,
    0x79, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xc0, 0x4f, 0xd0, 0x5f, 0x07,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x15, 0x06, 0x17, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x09, 0x0a, 0x1b,
    0x30, 0x31, 0x1a, 0x33, 0x34, 0x35, 0x36, 0x08, 0x38, 0x39, 0x3a, 0x3b, 0x04, 0x14, 0x3e, 0xe1,
    0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57,
    0x58, 0x59, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x80, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x6a, 0x9b, 0x9c, 0x9d, 0x9e,
    0x9f, 0xa0, 0xaa, 0xab, 0xac, 0x4a, 0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7,
    0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xa1, 0xbe, 0xbf, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf, 0xda, 0xdb,
    0xdc, 0xdd, 0xde, 0xdf, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
};

const ebcdic_to_ascii = [256]u8{
    0x00, 0x01, 0x02, 0x03, 0x9c, 0x09, 0x86, 0x7f, 0x97, 0x8d, 0x8e, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x9d, 0x85, 0x08, 0x87, 0x18, 0x19, 0x92, 0x8f, 0x1c, 0x1d, 0x1e, 0x1f,
    0x80, 0x81, 0x82, 0x83, 0x84, 0x0a, 0x17, 0x1b, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x05, 0x06, 0x07,
    0x90, 0x91, 0x16, 0x93, 0x94, 0x95, 0x96, 0x04, 0x98, 0x99, 0x9a, 0x9b, 0x14, 0x15, 0x9e, 0x1a,
    0x20, 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xd5, 0x2e, 0x3c, 0x28, 0x2b, 0x7c,
    0x26, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1, 0x21, 0x24, 0x2a, 0x29, 0x3b, 0x7e,
    0x2d, 0x2f, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xcb, 0x2c, 0x25, 0x5f, 0x3e, 0x3f,
    0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0, 0xc1, 0xc2, 0x60, 0x3a, 0x23, 0x40, 0x27, 0x3d, 0x22,
    0xc3, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
    0xca, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x5e, 0xcc, 0xcd, 0xce, 0xcf, 0xd0,
    0xd1, 0xe5, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0xd2, 0xd3, 0xd4, 0x5b, 0xd6, 0xd7,
    0xd8, 0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0x5d, 0xe6, 0xe7,
    0x7b, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed,
    0x7d, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52, 0xee, 0xef, 0xf0, 0xf1, 0xf2, 0xf3,
    0x5c, 0x9f, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9,
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
};

const ascii_to_ibm = [256]u8{
    0x00, 0x01, 0x02, 0x03, 0x37, 0x2d, 0x2e, 0x2f, 0x16, 0x05, 0x25, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x3c, 0x3d, 0x32, 0x26, 0x18, 0x19, 0x3f, 0x27, 0x1c, 0x1d, 0x1e, 0x1f,
    0x40, 0x5a, 0x7f, 0x7b, 0x5b, 0x6c, 0x50, 0x7d, 0x4d, 0x5d, 0x5c, 0x4e, 0x6b, 0x60, 0x4b, 0x61,
    0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0x7a, 0x5e, 0x4c, 0x7e, 0x6e, 0x6f,
    0x7c, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6,
    0xd7, 0xd8, 0xd9, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xad, 0xe0, 0xbd, 0x5f, 0x6d,
    0x79, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xc0, 0x4f, 0xd0, 0xa1, 0x07,
    0x20, 0x21, 0x22, 0x23, 0x24, 0x15, 0x06, 0x17, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x09, 0x0a, 0x1b,
    0x30, 0x31, 0x1a, 0x33, 0x34, 0x35, 0x36, 0x08, 0x38, 0x39, 0x3a, 0x3b, 0x04, 0x14, 0x3e, 0xe1,
    0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57,
    0x58, 0x59, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75,
    0x76, 0x77, 0x78, 0x80, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e,
    0x9f, 0xa0, 0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7,
    0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd, 0xbe, 0xbf, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf, 0xda, 0xdb,
    0xdc, 0xdd, 0xde, 0xdf, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
};

pub const C_ASCII: u32 = 1 << 0;
pub const C_EBCDIC: u32 = 1 << 1;
pub const C_IBM: u32 = 1 << 2;
pub const C_BLOCK: u32 = 1 << 3;
pub const C_UNBLOCK: u32 = 1 << 4;
pub const C_LCASE: u32 = 1 << 5;
pub const C_UCASE: u32 = 1 << 6;
pub const C_SWAB: u32 = 1 << 7;
pub const C_SYNC: u32 = 1 << 8;
pub const C_NOERROR: u32 = 1 << 9;
pub const C_NOTRUNC: u32 = 1 << 10;
pub const C_FDATASYNC: u32 = 1 << 11;
pub const C_FSYNC: u32 = 1 << 12;
pub const C_EXCL: u32 = 1 << 13;
pub const C_NOCREAT: u32 = 1 << 14;
pub const C_SPARSE: u32 = 1 << 15;
pub const C_TWOBUFS: u32 = 1 << 16;

pub const Sym = struct { name: []const u8, value: u32 };

pub const conversions = [_]Sym{
    .{ .name = "ascii", .value = C_ASCII | C_UNBLOCK | C_TWOBUFS },
    .{ .name = "ebcdic", .value = C_EBCDIC | C_BLOCK | C_TWOBUFS },
    .{ .name = "ibm", .value = C_IBM | C_BLOCK | C_TWOBUFS },
    .{ .name = "block", .value = C_BLOCK | C_TWOBUFS },
    .{ .name = "unblock", .value = C_UNBLOCK | C_TWOBUFS },
    .{ .name = "lcase", .value = C_LCASE | C_TWOBUFS },
    .{ .name = "ucase", .value = C_UCASE | C_TWOBUFS },
    .{ .name = "sparse", .value = C_SPARSE },
    .{ .name = "swab", .value = C_SWAB | C_TWOBUFS },
    .{ .name = "noerror", .value = C_NOERROR },
    .{ .name = "nocreat", .value = C_NOCREAT },
    .{ .name = "excl", .value = C_EXCL },
    .{ .name = "notrunc", .value = C_NOTRUNC },
    .{ .name = "sync", .value = C_SYNC },
    .{ .name = "fdatasync", .value = C_FDATASYNC },
    .{ .name = "fsync", .value = C_FSYNC },
};

// O_* values for the target (sys.O), plus private bits for the dd-only flags.
pub const O_APPEND = sys.O.APPEND;
pub const O_DIRECT = sys.O.DIRECT;
pub const O_DIRECTORY = sys.O.DIRECTORY;
pub const O_DSYNC = sys.O.DSYNC;
pub const O_NOATIME = sys.O.NOATIME;
pub const O_NOCTTY = sys.O.NOCTTY;
pub const O_NOFOLLOW = sys.O.NOFOLLOW;
pub const O_NONBLOCK = sys.O.NONBLOCK;
pub const O_SYNC = sys.O.SYNC;
pub const O_RSYNC = sys.O.SYNC;
pub const O_FULLBLOCK: u32 = 1 << 28;
pub const O_NOCACHE: u32 = 1 << 29;
pub const O_COUNT_BYTES: u32 = 1 << 30;
pub const O_SKIP_BYTES: u32 = 1 << 31;
pub const O_SEEK_BYTES: u32 = 1 << 27;

pub const flag_syms = [_]Sym{
    .{ .name = "append", .value = O_APPEND },
    .{ .name = "direct", .value = O_DIRECT },
    .{ .name = "directory", .value = O_DIRECTORY },
    .{ .name = "dsync", .value = O_DSYNC },
    .{ .name = "noatime", .value = O_NOATIME },
    .{ .name = "nocache", .value = O_NOCACHE },
    .{ .name = "noctty", .value = O_NOCTTY },
    .{ .name = "nofollow", .value = O_NOFOLLOW },
    .{ .name = "nonblock", .value = O_NONBLOCK },
    .{ .name = "sync", .value = O_SYNC },
    .{ .name = "fullblock", .value = O_FULLBLOCK },
    .{ .name = "count_bytes", .value = O_COUNT_BYTES },
    .{ .name = "skip_bytes", .value = O_SKIP_BYTES },
    .{ .name = "seek_bytes", .value = O_SEEK_BYTES },
};

pub const STATUS_DEFAULT = 0;
pub const STATUS_NONE = 1;
pub const STATUS_NOXFER = 2;
pub const STATUS_PROGRESS = 3;
pub const status_syms = [_]Sym{
    .{ .name = "none", .value = STATUS_NONE },
    .{ .name = "noxfer", .value = STATUS_NOXFER },
    .{ .name = "progress", .value = STATUS_PROGRESS },
};

const human_opts: u32 = human.autoscale | human.round_to_nearest | human.space_before_unit | human.si | human.b_suffix;

pub const Job = struct {
    env: common.Env,
    observer: Observer,
    /// Descriptors the job reads from and writes to; it closes both when done.
    /// Standard input / output unless `input_file` / `output_file` is set.
    in_fd: sys.Handle = sys.invalid_handle,
    out_fd: sys.Handle = sys.invalid_handle,
    last_errno: E = .SUCCESS,
    input_file: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    input_blocksize: usize = 0,
    output_blocksize: usize = 0,
    conversion_blocksize: usize = 0,
    skip_records: i64 = 0,
    skip_bytes: i64 = 0,
    seek_records: i64 = 0,
    seek_bytes: i64 = 0,
    max_records: i64 = std.math.maxInt(i64),
    max_bytes: usize = 0,
    conv: u32 = 0,
    iflags: u32 = 0,
    oflags: u32 = 0,
    status: u32 = STATUS_DEFAULT,
    translation_needed: bool = false,
    trans: [256]u8 = undefined,
    w_partial: i64 = 0,
    w_full: i64 = 0,
    r_partial: i64 = 0,
    r_full: i64 = 0,
    w_bytes: i64 = 0,
    r_truncate: i64 = 0,
    newline_char: u8 = '\n',
    space_char: u8 = ' ',
    oc: usize = 0,
    col: usize = 0,
    ibuf: []u8 = &.{},
    obuf: []u8 = &.{},
    separate_obuf: bool = false,
    final_op_was_seek: bool = false,
    start_ns: i96 = 0,
    progress_len: usize = 0,
    warn_partial_read: bool = false,
    prev_nread: isize = 0,
    fullblock: bool = false,
    input_seekable: bool = false,
    input_offset: i64 = 0,
    pending_spaces: usize = 0,

    fn raw(d: *Job, bytes: []const u8) void {
        d.observer.emit(.{ .raw = bytes });
    }

    pub fn init(env: common.Env, observer: Observer) Job {
        var j: Job = .{ .env = env, .observer = observer };
        for (0..256) |i| j.trans[i] = @intCast(i);
        return j;
    }
};


fn nowNs(d: *Job) i96 {
    return Io.Timestamp.now(d.env.io, .awake).toNanoseconds();
}


fn translateCharset(d: *Job, table: *const [256]u8) void {
    for (0..256) |i| d.trans[i] = table[d.trans[i]];
    d.translation_needed = true;
}

fn applyTranslations(d: *Job) void {
    if (d.conv & C_ASCII != 0) translateCharset(d, &ebcdic_to_ascii);
    if (d.conv & C_UCASE != 0) {
        for (0..256) |i| d.trans[i] = std.ascii.toUpper(d.trans[i]);
        d.translation_needed = true;
    } else if (d.conv & C_LCASE != 0) {
        for (0..256) |i| d.trans[i] = std.ascii.toLower(d.trans[i]);
        d.translation_needed = true;
    }
    if (d.conv & C_EBCDIC != 0) {
        translateCharset(d, &ascii_to_ebcdic);
        d.newline_char = ascii_to_ebcdic['\n'];
        d.space_char = ascii_to_ebcdic[' '];
    } else if (d.conv & C_IBM != 0) {
        translateCharset(d, &ascii_to_ibm);
        d.newline_char = ascii_to_ibm['\n'];
        d.space_char = ascii_to_ibm[' '];
    }
}

// ---------------------------------------------------------------- statistics

fn pluralBytes(n: i64) bool {
    return n == 1;
}

fn printXferStats(d: *Job, progress: bool) void {
    const ctx = d.env;
    const now = nowNs(d);
    var hb0: [human.longest]u8 = undefined;
    var hb1: [human.longest]u8 = undefined;
    var hb2: [human.longest + 4]u8 = undefined;
    const wb: u64 = @intCast(d.w_bytes);
    const si = human.readable(wb, &hb0, human_opts, 1, 1);
    const iec = human.readable(wb, &hb1, human_opts | human.base_1024, 1, 1);
    var bps: []const u8 = undefined;
    var delta_s: f64 = 0;
    if (d.start_ns < now) {
        const delta: u64 = @intCast(now - d.start_ns);
        delta_s = @as(f64, @floatFromInt(delta)) / 1e9;
        const r = human.readable(wb, hb2[0 .. human.longest], human_opts, 1_000_000_000, delta);
        hb2[r.len] = '/';
        hb2[r.len + 1] = 's';
        bps = hb2[0 .. r.len + 2];
    } else {
        bps = "Infinity B/s";
    }
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.gpa);
    if (progress) line.append(ctx.gpa, '\r') catch {};
    // dd.c prints "%.0f s" in a progress line and "%g s" at the end.
    var dbuf: [64]u8 = undefined;
    var dstr: []const u8 = "? s";
    if (progress) {
        dstr = std.fmt.bufPrint(&dbuf, "{d:.0} s", .{delta_s}) catch dstr;
    } else if (fmt_float.formatAlloc(ctx.gpa, .{ .conv = 'g' }, delta_s)) |g| {
        defer ctx.gpa.free(g);
        dstr = std.fmt.bufPrint(&dbuf, "{s} s", .{g}) catch dstr;
    } else |_| {}
    var tmp: [512]u8 = undefined;
    const lacks = struct {
        fn f(m: []const u8) bool {
            return m.len >= 2 and m[m.len - 2] == ' ';
        }
    }.f;
    const text = if (lacks(si))
        std.fmt.bufPrint(&tmp, "{d} {s} copied, {s}, {s}", .{ d.w_bytes, if (pluralBytes(d.w_bytes)) "byte" else "bytes", dstr, bps }) catch ""
    else if (lacks(iec))
        std.fmt.bufPrint(&tmp, "{d} bytes ({s}) copied, {s}, {s}", .{ d.w_bytes, si, dstr, bps }) catch ""
    else
        std.fmt.bufPrint(&tmp, "{d} bytes ({s}, {s}) copied, {s}, {s}", .{ d.w_bytes, si, iec, dstr, bps }) catch "";
    line.appendSlice(ctx.gpa, text) catch {};
    if (progress) {
        if (text.len < d.progress_len) {
            var k = d.progress_len - text.len;
            while (k > 0) : (k -= 1) line.append(ctx.gpa, ' ') catch {};
        }
        d.progress_len = text.len;
    } else line.append(ctx.gpa, '\n') catch {};
    d.raw(line.items);
}

fn printStats(d: *Job) void {
    if (d.status == STATUS_NONE) return;
    if (d.progress_len > 0) {
        d.raw("\n");
        d.progress_len = 0;
    }
    var buf: [256]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d}+{d} records in\n{d}+{d} records out\n", .{ d.r_full, d.r_partial, d.w_full, d.w_partial }) catch "";
    d.raw(t);
    if (d.r_truncate != 0) {
        const t2 = std.fmt.bufPrint(&buf, "{d} truncated record{s}\n", .{ d.r_truncate, if (d.r_truncate == 1) "" else "s" }) catch "";
        d.raw(t2);
    }
    if (d.status == STATUS_NOXFER) return;
    printXferStats(d, false);
}

fn warn(d: *Job, comptime fmt: []const u8, args: anytype) void {
    const t = std.fmt.allocPrint(d.env.gpa, fmt, args) catch return;
    defer d.env.gpa.free(t);
    d.observer.emit(.{ .diag = t });
}

fn diagnose(d: *Job, e: E, comptime fmt: []const u8, args: anytype) void {
    warn(d, fmt ++ ": {s}", args ++ .{sys.errnoText(e)});
}

// ------------------------------------------------------------------ signals

/// Install the handlers. This changes process-wide state, so `run` does not do
/// it by itself. GNU dd leaves SIGUSR1 alone when POSIXLY_CORRECT is set.
pub fn catchSignals(posixly_correct: bool) void {
    sys.catchStatisticsSignals(!posixly_correct);
}

/// Act on caught signals; called wherever the copy can be waiting or repeating.
fn processSignals(d: *Job) void {
    if (sys.interruptReceived()) {
        printStats(d);
        sys.dieOfInterrupt();
    }
    if (sys.takeStatisticsRequest()) printStats(d);
}

/// open(2), again after a signal (opening a FIFO waits for the other end).
fn openSignalled(d: *Job, path: []const u8, flags: u32, e: *E) ?sys.Handle {
    while (true) {
        processSignals(d);
        if (sys.openFd(path, flags, 0o666, e)) |fd| return fd;
        if (e.* != .INTR) return null;
    }
}

fn syncSignalled(d: *Job, kind: sys.SyncKind) ?E {
    while (true) {
        processSignals(d);
        const result = sys.syncFile(d.out_fd, kind);
        if (result == null or result.? != .INTR) return result;
    }
}

fn truncateSignalled(d: *Job, len: u64) ?E {
    while (true) {
        processSignals(d);
        const result = sys.ftruncateFd(d.out_fd, len);
        if (result == null or result.? != .INTR) return result;
    }
}

/// close(2). An interrupted close has still closed the descriptor.
fn closeSignalled(fd: sys.Handle) ?E {
    const result = sys.closeFd(fd) orelse return null;
    return if (result == .INTR) null else result;
}

// ------------------------------------------------------------------ I/O

fn iread(d: *Job, buf: []u8, e: *E) ?usize {
    const n = while (true) {
        processSignals(d);
        if (sys.readFdInterruptible(d.in_fd, buf, e)) |n| break n;
        if (e.* != .INTR) return null;
    };
    // A short read may be the result of a signal.
    if (n > 0 and n < buf.len) processSignals(d);
    if (n > 0 and d.warn_partial_read) {
        if (d.prev_nread > 0 and @as(usize, @intCast(d.prev_nread)) < buf.len) {
            if (d.status != STATUS_NONE) {
                warn(d, "warning: partial read ({d} byte{s}); suggest iflag=fullblock", .{ d.prev_nread, if (d.prev_nread == 1) "" else "s" });
            }
            d.warn_partial_read = false;
        }
    }
    d.prev_nread = @intCast(n);
    return n;
}

fn ireadFull(d: *Job, buf: []u8, e: *E) ?usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = iread(d, buf[total..], e) orelse return null;
        if (n == 0) break;
        total += n;
    }
    return total;
}

fn isNul(buf: []const u8) bool {
    return std.mem.allEqual(u8, buf, 0);
}

fn iwrite(d: *Job, buf: []const u8) usize {
    var total: usize = 0;
    // A partial final block cannot be written with O_DIRECT: drop the flag (as GNU does).
    if (d.oflags & O_DIRECT != 0 and buf.len > 0 and buf.len < d.output_blocksize) {
        var fe: E = .SUCCESS;
        if (sys.getStatusFlags(d.out_fd, &fe)) |old| _ = sys.setStatusFlags(d.out_fd, old & ~@as(usize, O_DIRECT));
        d.oflags &= ~@as(@TypeOf(d.oflags), O_DIRECT);
    }
    while (total < buf.len) {
        processSignals(d);
        d.final_op_was_seek = false;
        var nwritten: usize = 0;
        if (d.conv & C_SPARSE != 0 and isNul(buf)) {
            var se: E = .SUCCESS;
            if (sys.seekFd(d.out_fd, @intCast(buf.len), 1, &se) == null) {
                d.conv &= ~C_SPARSE;
            } else {
                d.final_op_was_seek = true;
                nwritten = buf.len;
            }
        }
        if (nwritten == 0) {
            var e: E = .SUCCESS;
            const rc = sys.writeFdInterruptible(d.out_fd, buf[total..], &e) orelse {
                if (e == .INTR) continue;
                d.last_errno = e;
                break;
            };
            if (rc == 0) {
                d.last_errno = .NOSPC;
                break;
            }
            nwritten = rc;
        }
        total += nwritten;
    }
    return total;
}

/// Finish up (sync, close, statistics) and stop with exit status 1.
fn quit(d: *Job) Fail {
    finishUp(d);
    return error.Quit;
}

fn finishUp(d: *Job) void {
    _ = synchronizeOutput(d);
    _ = sys.closeFd(d.in_fd);
    _ = sys.closeFd(d.out_fd);
    printStats(d);
}

fn synchronizeOutput(d: *Job) u8 {
    var status: u8 = 0;
    const mask = d.conv;
    d.conv &= ~(C_FDATASYNC | C_FSYNC);
    var need_fsync = mask & C_FSYNC != 0;
    if (mask & C_FDATASYNC != 0) {
        if (syncSignalled(d, .data)) |e| {
            if (e != .NOSYS and e != .INVAL) {
                diagnose(d, e, "fdatasync failed for {f}", .{quote.quoteA(d.output_file orelse "standard output")});
                status = 1;
            }
            need_fsync = true;
        }
    }
    if (need_fsync) {
        if (syncSignalled(d, .file)) |e| {
            diagnose(d, e, "fsync failed for {f}", .{quote.quoteA(d.output_file orelse "standard output")});
            return 1;
        }
    }
    return status;
}

fn writeOutput(d: *Job) Fail!void {
    const n = iwrite(d, d.obuf[0..d.output_blocksize]);
    d.w_bytes += @intCast(n);
    if (n != d.output_blocksize) {
        diagnose(d, d.last_errno, "writing to {f}", .{quote.quoteA(d.output_file orelse "standard output")});
        if (n != 0) d.w_partial += 1;
        return quit(d);
    } else d.w_full += 1;
    d.oc = 0;
}

fn outputChar(d: *Job, c: u8) Fail!void {
    d.obuf[d.oc] = c;
    d.oc += 1;
    if (d.oc >= d.output_blocksize) try writeOutput(d);
}

fn copySimple(d: *Job, buf: []const u8) Fail!void {
    var start: usize = 0;
    var nread = buf.len;
    while (true) {
        const nfree = @min(nread, d.output_blocksize - d.oc);
        @memcpy(d.obuf[d.oc..][0..nfree], buf[start..][0..nfree]);
        nread -= nfree;
        start += nfree;
        d.oc += nfree;
        if (d.oc >= d.output_blocksize) try writeOutput(d);
        if (nread == 0) break;
    }
}

fn copyWithBlock(d: *Job, buf: []const u8) Fail!void {
    for (buf) |ch| {
        if (ch == d.newline_char) {
            if (d.col < d.conversion_blocksize) {
                var j = d.col;
                while (j < d.conversion_blocksize) : (j += 1) try outputChar(d, d.space_char);
            }
            d.col = 0;
        } else {
            if (d.col == d.conversion_blocksize) {
                d.r_truncate += 1;
            } else if (d.col < d.conversion_blocksize) try outputChar(d, ch);
            d.col += 1;
        }
    }
}

fn copyWithUnblock(d: *Job, buf: []const u8) Fail!void {
    var i: usize = 0;
    while (i < buf.len) {
        const ch = buf[i];
        const was = d.col;
        d.col += 1;
        if (was >= d.conversion_blocksize) {
            // End of a record: emit a newline and look at this byte again.
            d.col = 0;
            d.pending_spaces = 0;
            try outputChar(d, d.newline_char);
            continue;
        } else if (ch == d.space_char) {
            d.pending_spaces += 1;
        } else {
            while (d.pending_spaces > 0) {
                try outputChar(d, d.space_char);
                d.pending_spaces -= 1;
            }
            try outputChar(d, ch);
        }
        i += 1;
    }
}

/// swab_buffer: returns the slice to copy; may grow `buf` by one byte.
fn swabBuffer(buf: []u8, nread: *usize, saved: *i32) []u8 {
    if (nread.* == 0) return buf[0..0];
    const prev_saved = saved.*;
    if ((prev_saved < 0) == ((nread.* & 1) != 0)) {
        nread.* -= 1;
        saved.* = buf[nread.*];
    } else saved.* = -1;
    var i = nread.*;
    while (i > 1) : (i -= 2) buf[i] = buf[i - 2];
    if (prev_saved < 0) return buf[1 .. nread.* + 1];
    buf[1] = @intCast(prev_saved);
    nread.* += 1;
    return buf[0..nread.*];
}

/// The size in bytes of `records` blocks plus `bytes`, or null when that is
/// more than a file offset can hold.
fn byteOffset(records: i64, blocksize: usize, bytes: i64) ?i64 {
    const whole = std.math.mul(i64, records, @intCast(blocksize)) catch return null;
    return std.math.add(i64, whole, bytes) catch null;
}

/// `input_offset` is negative once it is no longer known.
fn advanceInputOffset(d: *Job, n: i64) void {
    if (d.input_offset < 0) return;
    d.input_offset = std.math.add(i64, d.input_offset, n) catch -1;
}

fn skipInput(d: *Job, records_in: i64, bytes: *i64) Fail!i64 {
    // Try lseek first.
    var records = records_in;
    var e: E = .SUCCESS;
    var seek_error: E = .OVERFLOW;
    if (byteOffset(records, d.input_blocksize, bytes.*)) |offset| {
        if (sys.seekFd(d.in_fd, offset, 1, &e) != null) {
            if (sys.fstatFd(d.in_fd, &e)) |st| {
                if (st.isReg() and st.size > 0 and d.input_offset >= 0 and @as(i64, @intCast(st.size)) - d.input_offset < offset) {
                    records = @divTrunc(offset - @as(i64, @intCast(st.size)), @as(i64, @intCast(d.input_blocksize)));
                    d.input_offset = @intCast(st.size);
                } else {
                    records = 0;
                    advanceInputOffset(d, offset);
                }
            }
            return records;
        }
        seek_error = e;
    }
    // A file that can seek, but not that far, cannot be skipped by reading.
    if (sys.seekFd(d.in_fd, 0, 2, &e) != null) {
        diagnose(d, seek_error, "{f}: cannot skip", .{quote.quote(d.input_file orelse "standard input")});
        return quit(d);
    }
    // Read and discard.
    var remaining = records;
    while (remaining > 0 or bytes.* > 0) {
        const want = if (remaining > 0) d.input_blocksize else @as(usize, @intCast(bytes.*));
        const n = (if (d.fullblock) ireadFull(d, d.ibuf[0..want], &e) else iread(d, d.ibuf[0..want], &e)) orelse {
            if (d.conv & C_NOERROR == 0 or d.status != STATUS_NONE) diagnose(d, e, "error reading {f}", .{quote.quoteA(d.input_file orelse "standard input")});
            if (d.conv & C_NOERROR != 0) {
                printStats(d);
                continue;
            }
            return quit(d);
        };
        if (n == 0) break;
        if (remaining > 0) {
            if (n == d.input_blocksize) remaining -= 1;
        } else bytes.* -= @intCast(n);
        advanceInputOffset(d, @intCast(n));
        if (remaining == 0 and bytes.* == 0) break;
    }
    return remaining;
}

fn setFdFlags(d: *Job, fd: sys.Handle, add: u32, name: []const u8) Fail!void {
    const flags = add & ~(O_NOCTTY | O_NOFOLLOW);
    if (flags == 0) return;
    var ge: E = .SUCCESS;
    const old = sys.getStatusFlags(fd, &ge) orelse {
        diagnose(d, ge, "setting flags for {f}", .{quote.quoteA(name)});
        return error.Abort;
    };
    var new: usize = old | flags;
    if (new != old) {
        if (new & O_DIRECTORY != 0) {
            var fe: E = .SUCCESS;
            const st = sys.fstatFd(fd, &fe);
            if (st == null) {
                diagnose(d, fe, "setting flags for {f}", .{quote.quoteA(name)});
                return error.Abort;
            } else if (!st.?.isDir()) {
                diagnose(d, .NOTDIR, "setting flags for {f}", .{quote.quoteA(name)});
                return error.Abort;
            }
            new &= ~@as(usize, O_DIRECTORY);
        }
        if (sys.setStatusFlags(fd, new)) |se| {
            diagnose(d, se, "setting flags for {f}", .{quote.quoteA(name)});
            return error.Abort;
        }
    }
}

fn memExhausted(d: *Job, which: []const u8, size: usize) Fail {
    var hb: [human.longest]u8 = undefined;
    const h = human.readable(size, &hb, human_opts | human.base_1024, 1, 1);
    warn(d, "memory exhausted by {s} buffer of size {d} bytes ({s})", .{ which, size, h });
    return error.Abort;
}

fn ddCopy(d: *Job) Fail!u8 {
    var exit_status: u8 = 0;
    var e: E = .SUCCESS;
    const in_name = d.input_file orelse "standard input";
    const out_name = d.output_file orelse "standard output";

    // Buffers.
    const extra: usize = @intFromBool(d.conv & C_SWAB != 0);
    d.ibuf = d.env.gpa.alloc(u8, d.input_blocksize + extra) catch {
        return memExhausted(d, "input", d.input_blocksize);
    };
    if (d.conv & C_TWOBUFS != 0) {
        d.obuf = d.env.gpa.alloc(u8, d.output_blocksize) catch {
            return memExhausted(d, "output", d.output_blocksize);
        };
        d.separate_obuf = true;
    } else d.obuf = d.ibuf;
    defer {
        d.env.gpa.free(d.ibuf);
        if (d.separate_obuf) d.env.gpa.free(d.obuf);
    }

    if (d.skip_records != 0 or d.skip_bytes != 0) {
        const us_bytes = byteOffset(d.skip_records, d.input_blocksize, d.skip_bytes);
        const off0 = d.input_offset;
        var sb = d.skip_bytes;
        const us_blocks = try skipInput(d, d.skip_records, &sb);
        const short = d.input_offset >= 0 and (us_bytes == null or us_bytes.? != d.input_offset - off0);
        if ((us_blocks != 0 or short) and d.status != STATUS_NONE) {
            warn(d, "{f}: cannot skip to specified offset", .{quote.quote(in_name)});
        }
    }
    if (d.seek_records != 0 or d.seek_bytes != 0) {
        const wanted = byteOffset(d.seek_records, d.output_blocksize, d.seek_bytes);
        var se: E = .OVERFLOW;
        if (wanted == null or sys.seekFd(d.out_fd, wanted.?, 1, &se) == null) {
            var end_error: E = .SUCCESS;
            if (sys.seekFd(d.out_fd, 0, 2, &end_error) != null) {
                diagnose(d, se, "{f}: cannot seek", .{quote.quote(out_name)});
                return quit(d);
            }
            const off = wanted orelse {
                warn(d, "{f}: cannot seek", .{quote.quote(out_name)});
                return quit(d);
            };
            // Not seekable: write zeros instead.
            const zeros = d.env.gpa.alloc(u8, d.output_blocksize) catch return 1;
            defer d.env.gpa.free(zeros);
            @memset(zeros, 0);
            var remaining = off;
            while (remaining > 0) {
                processSignals(d);
                const n: usize = @intCast(@min(remaining, @as(i64, @intCast(zeros.len))));
                if (sys.writeAllFd(d.out_fd, zeros[0..n])) |we| {
                    diagnose(d, we, "writing to {f}", .{quote.quoteA(out_name)});
                    return quit(d);
                }
                remaining -= @intCast(n);
            }
        }
    }
    if (d.max_records == 0 and d.max_bytes == 0) return exit_status;

    var saved_byte: i32 = -1;
    var partread: usize = 0;
    while (true) {
        if (d.status == STATUS_PROGRESS) {
            const now = nowNs(d);
            if (now - d.start_ns >= 1_000_000_000 and @mod(@divTrunc(now - d.start_ns, 1_000_000), 1000) < 5) printXferStats(d, true);
        }
        if (d.r_partial + d.r_full >= d.max_records + @as(i64, @intFromBool(d.max_bytes != 0))) break;
        if (d.conv & C_SYNC != 0 and d.conv & C_NOERROR != 0) {
            @memset(d.ibuf[0..d.input_blocksize], if (d.conv & (C_BLOCK | C_UNBLOCK) != 0) ' ' else 0);
        }
        const want = if (d.r_partial + d.r_full >= d.max_records) d.max_bytes else d.input_blocksize;
        var nread: usize = 0;
        const rd = if (d.fullblock) ireadFull(d, d.ibuf[0..want], &e) else iread(d, d.ibuf[0..want], &e);
        if (rd) |n| {
            if (n > 0) {
                advanceInputOffset(d, @intCast(n));
            } else break;
            nread = n;
        } else {
            if (d.conv & C_NOERROR == 0 or d.status != STATUS_NONE) diagnose(d, e, "error reading {f}", .{quote.quoteA(in_name)});
            if (d.conv & C_NOERROR != 0) {
                printStats(d);
                const bad = d.input_blocksize - partread;
                var se: E = .SUCCESS;
                if (sys.seekFd(d.in_fd, @intCast(bad), 1, &se) == null) {
                    diagnose(d, se, "{f}: cannot seek", .{quote.quote(in_name)});
                    exit_status = 1;
                }
                advanceInputOffset(d, @intCast(bad));
                if (d.conv & C_SYNC != 0 and partread == 0) {
                    nread = 0;
                } else continue;
            } else {
                exit_status = 1;
                break;
            }
        }
        var n_bytes_read = nread;
        if (n_bytes_read < d.input_blocksize) {
            d.r_partial += 1;
            partread = n_bytes_read;
            if (d.conv & C_SYNC != 0) {
                if (d.conv & C_NOERROR == 0) {
                    @memset(d.ibuf[n_bytes_read..d.input_blocksize], if (d.conv & (C_BLOCK | C_UNBLOCK) != 0) ' ' else 0);
                }
                n_bytes_read = d.input_blocksize;
            }
        } else {
            d.r_full += 1;
            partread = 0;
        }
        if (!d.separate_obuf) {
            const nw = iwrite(d, d.obuf[0..n_bytes_read]);
            d.w_bytes += @intCast(nw);
            if (nw != n_bytes_read) {
                diagnose(d, d.last_errno, "error writing {f}", .{quote.quoteA(out_name)});
                return 1;
            } else if (n_bytes_read == d.input_blocksize) d.w_full += 1 else d.w_partial += 1;
            continue;
        }
        if (d.translation_needed) {
            for (d.ibuf[0..n_bytes_read]) |*b| b.* = d.trans[b.*];
        }
        var bufstart: []u8 = d.ibuf[0..n_bytes_read];
        if (d.conv & C_SWAB != 0) bufstart = swabBuffer(d.ibuf, &n_bytes_read, &saved_byte);
        if (d.conv & C_BLOCK != 0) {
            try copyWithBlock(d, bufstart);
        } else if (d.conv & C_UNBLOCK != 0) {
            try copyWithUnblock(d, bufstart);
        } else try copySimple(d, bufstart);
    }
    if (saved_byte >= 0) {
        const sc: [1]u8 = .{@intCast(saved_byte)};
        if (d.conv & C_BLOCK != 0) {
            try copyWithBlock(d, &sc);
        } else if (d.conv & C_UNBLOCK != 0) {
            try copyWithUnblock(d, &sc);
        } else try outputChar(d, sc[0]);
    }
    if (d.conv & C_BLOCK != 0 and d.col > 0) {
        var i = d.col;
        while (i < d.conversion_blocksize) : (i += 1) try outputChar(d, d.space_char);
    }
    if (d.col != 0 and d.conv & C_UNBLOCK != 0) try outputChar(d, d.newline_char);
    if (d.oc != 0) {
        const nw = iwrite(d, d.obuf[0..d.oc]);
        d.w_bytes += @intCast(nw);
        if (nw != 0) d.w_partial += 1;
        if (nw != d.oc) {
            diagnose(d, d.last_errno, "error writing {f}", .{quote.quoteA(out_name)});
            return 1;
        }
    }
    if (d.final_op_was_seek) {
        if (sys.fstatFd(d.out_fd, &e)) |st| {
            if (st.isReg()) {
                if (sys.seekFd(d.out_fd, 0, 1, &e)) |off| {
                    if (off >= 0 and @as(i64, @intCast(st.size)) < off) {
                        if (truncateSignalled(d, @intCast(off))) |te| {
                            diagnose(d, te, "failed to truncate to {d} bytes in output file {f}", .{ off, quote.quoteA(out_name) });
                            return 1;
                        }
                    }
                }
            }
        } else {
            diagnose(d, e, "cannot fstat {f}", .{quote.quoteA(out_name)});
            return 1;
        }
    }
    return exit_status;
}


/// Run the copy described by `d`; returns the exit status.
pub fn run(d: *Job) u8 {
    if (d.in_fd == sys.invalid_handle) d.in_fd = std.Io.File.stdin().handle;
    if (d.out_fd == sys.invalid_handle) d.out_fd = std.Io.File.stdout().handle;
    applyTranslations(d);
    d.start_ns = nowNs(d); // for statistics asked for while a file is opening
    var e: E = .SUCCESS;
    if (d.input_file) |inf| {
        const fd = openSignalled(d, inf, sys.O.RDONLY | d.iflags, &e) orelse {
            warn(d, "failed to open {f}: {s}", .{ quote.quoteA(inf), sys.errnoText(e) });
            return 1;
        };
        d.in_fd = fd;
    } else setFdFlags(d, d.in_fd, d.iflags, "standard input") catch return 1;
    if (sys.seekFd(d.in_fd, 0, 1, &e)) |off| {
        d.input_seekable = true;
        d.input_offset = off;
    }

    var exit_status: u8 = 0;
    if (d.output_file) |outf| {
        var opts: u32 = d.oflags;
        if (d.conv & C_NOCREAT == 0) opts |= sys.O.CREAT;
        if (d.conv & C_EXCL != 0) opts |= sys.O.EXCL;
        if (!(d.seek_records != 0 or d.conv & C_NOTRUNC != 0)) opts |= sys.O.TRUNC;
        // The length to truncate to, if that is going to happen (GNU checks
        // that it exists before it touches the output).
        var size: i64 = 0;
        if (d.seek_records != 0 and d.conv & C_NOTRUNC == 0) {
            size = byteOffset(d.seek_records, d.output_blocksize, d.seek_bytes) orelse {
                warn(d, "offset too large: cannot truncate to a length of seek={d} ({d}-byte) blocks", .{ d.seek_records, d.output_blocksize });
                return 1;
            };
        }
        var fd: ?sys.Handle = null;
        if (d.seek_records != 0) fd = openSignalled(d, outf, sys.O.RDWR | opts, &e);
        if (fd == null) fd = openSignalled(d, outf, sys.O.WRONLY | opts, &e);
        const ofd = fd orelse {
            warn(d, "failed to open {f}: {s}", .{ quote.quoteA(outf), sys.errnoText(e) });
            return 1;
        };
        d.out_fd = ofd;
        if (d.seek_records != 0 and d.conv & C_NOTRUNC == 0) {
            if (truncateSignalled(d, @intCast(size))) |te| {
                var se: E = .SUCCESS;
                if (sys.fstatFd(d.out_fd, &se)) |st| {
                    if (st.isReg() or st.isDir()) {
                        diagnose(d, te, "failed to truncate to {d} bytes in output file {f}", .{ size, quote.quoteA(outf) });
                        exit_status = 1;
                    }
                } else {
                    diagnose(d, se, "cannot fstat {f}", .{quote.quoteA(outf)});
                    exit_status = 1;
                }
            }
        }
    } else setFdFlags(d, d.out_fd, d.oflags, "standard output") catch return 1;

    d.start_ns = nowNs(d);
    exit_status = ddCopy(d) catch return 1;
    const sync_status = synchronizeOutput(d);
    if (sync_status != 0) exit_status = sync_status;
    if (closeSignalled(d.in_fd)) |ce| {
        diagnose(d, ce, "closing input file {f}", .{quote.quoteA(d.input_file orelse "standard input")});
        return 1;
    }
    if (closeSignalled(d.out_fd)) |ce| {
        diagnose(d, ce, "closing output file {f}", .{quote.quoteA(d.output_file orelse "standard output")});
        return 1;
    }
    printStats(d);
    return exit_status;
}
