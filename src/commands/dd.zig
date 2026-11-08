//! dd — convert and copy a file.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "dd invocation"
//! (9.7), POSIX.1-2024 dd, and GNU coreutils 9.6 src/dd.c (operand parsing,
//! the copy loop, conversions and statistics were studied there and
//! rewritten). Not implemented: SIGUSR1 statistics, O_DIRECT alignment, page
//! cache hints (`nocache`), `status=progress` refresh timing beyond one line
//! per second, and the `iflag`/`oflag` effects on standard streams.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const human = @import("../human.zig");
const fmt_float = @import("../fmt_float.zig");
const Io = std.Io;
const E = std.os.linux.E;

const help_text = @embedFile("../help/dd.txt");

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

const C_ASCII: u32 = 1 << 0;
const C_EBCDIC: u32 = 1 << 1;
const C_IBM: u32 = 1 << 2;
const C_BLOCK: u32 = 1 << 3;
const C_UNBLOCK: u32 = 1 << 4;
const C_LCASE: u32 = 1 << 5;
const C_UCASE: u32 = 1 << 6;
const C_SWAB: u32 = 1 << 7;
const C_SYNC: u32 = 1 << 8;
const C_NOERROR: u32 = 1 << 9;
const C_NOTRUNC: u32 = 1 << 10;
const C_FDATASYNC: u32 = 1 << 11;
const C_FSYNC: u32 = 1 << 12;
const C_EXCL: u32 = 1 << 13;
const C_NOCREAT: u32 = 1 << 14;
const C_SPARSE: u32 = 1 << 15;
const C_TWOBUFS: u32 = 1 << 16;

const Sym = struct { name: []const u8, value: u32 };

const conversions = [_]Sym{
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

// O_* values (Linux x86-64) plus private bits for the dd-only flags.
const O_APPEND: u32 = 0o2000;
const O_DIRECT: u32 = 0o40000;
const O_DIRECTORY: u32 = 0o200000;
const O_DSYNC: u32 = 0o10000;
const O_NOATIME: u32 = 0o1000000;
const O_NOCTTY: u32 = 0o400;
const O_NOFOLLOW: u32 = 0o400000;
const O_NONBLOCK: u32 = 0o4000;
const O_SYNC: u32 = 0o4010000;
const O_RSYNC: u32 = 0o4010000;
const O_FULLBLOCK: u32 = 1 << 28;
const O_NOCACHE: u32 = 1 << 29;
const O_COUNT_BYTES: u32 = 1 << 30;
const O_SKIP_BYTES: u32 = 1 << 31;
const O_SEEK_BYTES: u32 = 1 << 27;

const flag_syms = [_]Sym{
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

const STATUS_DEFAULT = 0;
const STATUS_NONE = 1;
const STATUS_NOXFER = 2;
const STATUS_PROGRESS = 3;
const status_syms = [_]Sym{
    .{ .name = "none", .value = STATUS_NONE },
    .{ .name = "noxfer", .value = STATUS_NOXFER },
    .{ .name = "progress", .value = STATUS_PROGRESS },
};

const human_opts: u32 = human.autoscale | human.round_to_nearest | human.space_before_unit | human.si | human.b_suffix;

const D = struct {
    ctx: cli.Context,
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
};

fn nowNs(d: *D) i96 {
    return Io.Timestamp.now(d.ctx.io, .awake).toNanoseconds();
}

fn operandMatches(str: []const u8, pattern: []const u8, delim: u8) bool {
    if (!std.mem.startsWith(u8, str, pattern)) return false;
    return str.len == pattern.len or str[pattern.len] == delim;
}

fn usageFail(ctx: cli.Context) noreturn {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    std.process.exit(1);
}

fn parseSymbols(d: *D, str_in: []const u8, table: []const Sym, exclusive: bool, msg: []const u8) u32 {
    var value: u32 = 0;
    var str = str_in;
    while (true) {
        const comma = std.mem.indexOfScalar(u8, str, ',');
        const piece = if (comma) |c| str[0..c] else str;
        var found: ?u32 = null;
        for (table) |e| {
            if (std.mem.eql(u8, piece, e.name)) {
                found = e.value;
                break;
            }
        }
        if (found == null) {
            const q = @import("../quotearg.zig").quoteAlloc(d.ctx.gpa, piece, .locale, null) catch "";
            cli.warn(d.ctx, "{s}: {s}", .{ msg, q });
            usageFail(d.ctx);
        }
        if (exclusive) value = found.? else value |= found.?;
        if (comma == null) break;
        str = str[comma.? + 1 ..];
    }
    return value;
}

const IntErr = enum { ok, invalid, overflow };

/// dd.c parse_integer (suffixes bcEGkKMPQRTwYZ0, "B" after a suffix, "x").
fn parseInteger(d: *D, str: []const u8, err: *IntErr) i64 {
    err.* = .ok;
    const r = human.strtoumaxBase(str, "bcEGkKMPQRTwYZ0", true);
    var e = r.err;
    var n = r.value;
    var end = r.end;
    if (e == .invalid_suffix_char or e == .invalid_suffix_char_with_overflow) {
        if (end < str.len and str[end] == 'B' and end > 0 and str[end - 1] != 'B') {
            end += 1;
            if (end == str.len) e = if (e == .invalid_suffix_char_with_overflow) .overflow else .ok;
        }
    }
    if ((e == .invalid_suffix_char or e == .invalid_suffix_char_with_overflow) and end < str.len and str[end] == 'x') {
        var e2: IntErr = .ok;
        const o = parseInteger(d, str[end + 1 ..], &e2);
        if (e2 != .ok) {
            err.* = e2;
            return 0;
        }
        const prod = @mulWithOverflow(@as(i64, @intCast(@min(n, std.math.maxInt(i64)))), o);
        if (prod[1] != 0 or (prod[0] != 0 and e == .invalid_suffix_char_with_overflow)) {
            err.* = .overflow;
            return std.math.maxInt(i64);
        }
        if (prod[0] == 0 and std.mem.startsWith(u8, str, "0x")) {
            cli.warn(d.ctx, "warning: {f} is a zero multiplier; use {f} if that is intended", .{ cli.quoteC("0x"), cli.quoteC("00x") });
        }
        return prod[0];
    }
    switch (e) {
        .ok => {},
        .overflow => {
            err.* = .overflow;
            return std.math.maxInt(i64);
        },
        else => {
            err.* = .invalid;
            return 0;
        },
    }
    if (n > std.math.maxInt(i64)) {
        err.* = .overflow;
        n = std.math.maxInt(i64);
    }
    return @intCast(n);
}

fn multipleBits(v: u32) bool {
    return v & (v -% 1) != 0;
}

fn scanArgs(d: *D, args: []const []const u8) void {
    const ctx = d.ctx;
    var blocksize: usize = 0;
    var count: i64 = std.math.maxInt(i64);
    var skip: i64 = 0;
    var seek: i64 = 0;
    var count_b = false;
    var skip_b = false;
    var seek_b = false;
    for (args) |name| {
        const eq = std.mem.indexOfScalar(u8, name, '=');
        if (eq == null) {
            cli.warn(ctx, "unrecognized operand {f}", .{cli.quoteA(name)});
            usageFail(ctx);
        }
        const val = name[eq.? + 1 ..];
        if (operandMatches(name, "if", '=')) {
            d.input_file = val;
        } else if (operandMatches(name, "of", '=')) {
            d.output_file = val;
        } else if (operandMatches(name, "conv", '=')) {
            d.conv |= parseSymbols(d, val, &conversions, false, "invalid conversion");
        } else if (operandMatches(name, "iflag", '=')) {
            d.iflags |= parseSymbols(d, val, &flag_syms, false, "invalid input flag");
        } else if (operandMatches(name, "oflag", '=')) {
            d.oflags |= parseSymbols(d, val, &flag_syms, false, "invalid output flag");
        } else if (operandMatches(name, "status", '=')) {
            d.status = parseSymbols(d, val, &status_syms, true, "invalid status level");
        } else {
            var invalid: IntErr = .ok;
            const n = parseInteger(d, val, &invalid);
            const has_b = std.mem.indexOfScalar(u8, val, 'B') != null;
            var n_min: i64 = 0;
            var n_max: i64 = std.math.maxInt(i64);
            var target: ?*usize = null;
            const max_blocksize: i64 = std.math.maxInt(i64) - 2;
            if (operandMatches(name, "ibs", '=')) {
                n_min = 1;
                n_max = max_blocksize;
                target = &d.input_blocksize;
            } else if (operandMatches(name, "obs", '=')) {
                n_min = 1;
                n_max = max_blocksize;
                target = &d.output_blocksize;
            } else if (operandMatches(name, "bs", '=')) {
                n_min = 1;
                n_max = max_blocksize;
                target = &blocksize;
            } else if (operandMatches(name, "cbs", '=')) {
                n_min = 1;
                n_max = std.math.maxInt(i64);
                target = &d.conversion_blocksize;
            } else if (operandMatches(name, "skip", '=') or operandMatches(name, "iseek", '=')) {
                skip = n;
                skip_b = has_b;
            } else if (operandMatches(name[@intFromBool(name.len > 0 and name[0] == 'o')..], "seek", '=')) {
                seek = n;
                seek_b = has_b;
            } else if (operandMatches(name, "count", '=')) {
                count = n;
                count_b = has_b;
            } else {
                cli.warn(ctx, "unrecognized operand {f}", .{cli.quoteA(name)});
                usageFail(ctx);
            }
            if (invalid == .ok) {
                if (n < n_min) invalid = .invalid else if (n > n_max) invalid = .overflow;
            }
            if (invalid != .ok) {
                if (invalid == .overflow) {
                    cli.warn(ctx, "invalid number: {f}: Value too large for defined data type", .{cli.quoteA(val)});
                } else cli.warn(ctx, "invalid number: {f}", .{cli.quoteA(val)});
                std.process.exit(1);
            }
            if (target) |t| t.* = @intCast(n);
        }
    }
    if (blocksize != 0) {
        d.input_blocksize = blocksize;
        d.output_blocksize = blocksize;
    } else d.conv |= C_TWOBUFS;
    if (d.input_blocksize == 0) d.input_blocksize = 512;
    if (d.output_blocksize == 0) d.output_blocksize = 512;
    if (d.conversion_blocksize == 0) d.conv &= ~(C_BLOCK | C_UNBLOCK);
    if (d.iflags & (O_DSYNC | O_SYNC) != 0) d.iflags |= O_RSYNC;
    if (d.oflags & O_FULLBLOCK != 0) {
        cli.warn(ctx, "invalid output flag: {f}", .{cli.quoteC("fullblock")});
        usageFail(ctx);
    }
    if (skip_b) d.iflags |= O_SKIP_BYTES;
    if (d.iflags & O_SKIP_BYTES != 0 and skip != 0) {
        d.skip_records = @divTrunc(skip, @as(i64, @intCast(d.input_blocksize)));
        d.skip_bytes = @rem(skip, @as(i64, @intCast(d.input_blocksize)));
    } else if (skip != 0) d.skip_records = skip;
    if (count_b) d.iflags |= O_COUNT_BYTES;
    if (d.iflags & O_COUNT_BYTES != 0 and count != std.math.maxInt(i64)) {
        d.max_records = @divTrunc(count, @as(i64, @intCast(d.input_blocksize)));
        d.max_bytes = @intCast(@rem(count, @as(i64, @intCast(d.input_blocksize))));
    } else if (count != std.math.maxInt(i64)) d.max_records = count;
    if (seek_b) d.oflags |= O_SEEK_BYTES;
    if (d.oflags & O_SEEK_BYTES != 0 and seek != 0) {
        d.seek_records = @divTrunc(seek, @as(i64, @intCast(d.output_blocksize)));
        d.seek_bytes = @rem(seek, @as(i64, @intCast(d.output_blocksize)));
    } else if (seek != 0) d.seek_records = seek;
    d.warn_partial_read = d.conv & C_TWOBUFS == 0 and d.iflags & O_FULLBLOCK == 0 and
        (d.skip_records != 0 or (d.max_records > 0 and d.max_records < std.math.maxInt(i64)) or ((d.iflags | d.oflags) & O_DIRECT) != 0);
    d.fullblock = d.iflags & O_FULLBLOCK != 0;
    d.iflags &= ~O_FULLBLOCK;
    if (multipleBits(d.conv & (C_ASCII | C_EBCDIC | C_IBM))) fatal(ctx, "cannot combine any two of {ascii,ebcdic,ibm}");
    if (multipleBits(d.conv & (C_BLOCK | C_UNBLOCK))) fatal(ctx, "cannot combine block and unblock");
    if (multipleBits(d.conv & (C_LCASE | C_UCASE))) fatal(ctx, "cannot combine lcase and ucase");
    if (multipleBits(d.conv & (C_EXCL | C_NOCREAT))) fatal(ctx, "cannot combine excl and nocreat");
    if (multipleBits(d.iflags & (O_DIRECT | O_NOCACHE)) or multipleBits(d.oflags & (O_DIRECT | O_NOCACHE))) fatal(ctx, "cannot combine direct and nocache");
    d.iflags &= ~O_NOCACHE;
    d.oflags &= ~O_NOCACHE;
}

fn fatal(ctx: cli.Context, msg: []const u8) noreturn {
    cli.warn(ctx, "{s}", .{msg});
    std.process.exit(1);
}

fn translateCharset(d: *D, table: *const [256]u8) void {
    for (0..256) |i| d.trans[i] = table[d.trans[i]];
    d.translation_needed = true;
}

fn applyTranslations(d: *D) void {
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

fn printXferStats(d: *D, progress: bool) void {
    const ctx = d.ctx;
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
    var dbuf: [64]u8 = undefined;
    var dstr: []const u8 = undefined;
    if (progress) {
        dstr = std.fmt.bufPrint(&dbuf, "{d:.0} s", .{delta_s}) catch "";
    } else {
        var fb: [128]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fb);
        const g = fmt_float.formatAlloc(fba.allocator(), .{ .conv = 'g' }, delta_s) catch "0";
        dstr = std.fmt.bufPrint(&dbuf, "{s} s", .{g}) catch "";
    }
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
    Io.File.stderr().writeStreamingAll(ctx.io, line.items) catch {};
}

fn printStats(d: *D) void {
    if (d.status == STATUS_NONE) return;
    const ctx = d.ctx;
    if (d.progress_len > 0) {
        Io.File.stderr().writeStreamingAll(ctx.io, "\n") catch {};
        d.progress_len = 0;
    }
    var buf: [256]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d}+{d} records in\n{d}+{d} records out\n", .{ d.r_full, d.r_partial, d.w_full, d.w_partial }) catch "";
    Io.File.stderr().writeStreamingAll(ctx.io, t) catch {};
    if (d.r_truncate != 0) {
        const t2 = std.fmt.bufPrint(&buf, "{d} truncated record{s}\n", .{ d.r_truncate, if (d.r_truncate == 1) "" else "s" }) catch "";
        Io.File.stderr().writeStreamingAll(ctx.io, t2) catch {};
    }
    if (d.status == STATUS_NOXFER) return;
    printXferStats(d, false);
}

fn diagnose(d: *D, e: E, comptime fmt: []const u8, args: anytype) void {
    cli.warn(d.ctx, fmt ++ ": {s}", args ++ .{sys.errnoText(e)});
}

// ------------------------------------------------------------------ I/O

fn iread(d: *D, buf: []u8, e: *E) ?usize {
    const n = sys.readFd(0, buf, e) orelse return null;
    if (n > 0 and d.warn_partial_read) {
        if (d.prev_nread > 0 and @as(usize, @intCast(d.prev_nread)) < buf.len) {
            if (d.status != STATUS_NONE) {
                cli.warn(d.ctx, "warning: partial read ({d} byte{s}); suggest iflag=fullblock", .{ d.prev_nread, if (d.prev_nread == 1) "" else "s" });
            }
            d.warn_partial_read = false;
        }
    }
    d.prev_nread = @intCast(n);
    return n;
}

fn ireadFull(d: *D, buf: []u8, e: *E) ?usize {
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

fn iwrite(d: *D, buf: []const u8) usize {
    var total: usize = 0;
    // A partial final block cannot be written with O_DIRECT: drop the flag (as GNU does).
    if (d.oflags & O_DIRECT != 0 and buf.len > 0 and buf.len < d.output_blocksize) {
        const old = std.os.linux.fcntl(1, std.os.linux.F.GETFL, 0);
        if (std.os.linux.errno(old) == .SUCCESS) _ = std.os.linux.fcntl(1, std.os.linux.F.SETFL, old & ~@as(usize, O_DIRECT));
        d.oflags &= ~@as(@TypeOf(d.oflags), O_DIRECT);
    }
    while (total < buf.len) {
        d.final_op_was_seek = false;
        var nwritten: usize = 0;
        if (d.conv & C_SPARSE != 0 and isNul(buf)) {
            var se: E = .SUCCESS;
            if (sys.seekFd(1, @intCast(buf.len), 1, &se) == null) {
                d.conv &= ~C_SPARSE;
            } else {
                d.final_op_was_seek = true;
                nwritten = buf.len;
            }
        }
        if (nwritten == 0) {
            const rc = std.os.linux.write(1, buf.ptr + total, buf.len - total);
            const e = std.os.linux.errno(rc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) {
                last_errno = e;
                break;
            }
            if (rc == 0) {
                last_errno = .NOSPC;
                break;
            }
            nwritten = rc;
        }
        total += nwritten;
    }
    return total;
}

var last_errno: E = .SUCCESS;

fn quit(d: *D, code: u8) noreturn {
    finishUp(d);
    std.process.exit(code);
}

fn finishUp(d: *D) void {
    _ = synchronizeOutput(d);
    _ = sys.closeFd(0);
    _ = sys.closeFd(1);
    printStats(d);
}

fn synchronizeOutput(d: *D) u8 {
    var status: u8 = 0;
    const mask = d.conv;
    d.conv &= ~(C_FDATASYNC | C_FSYNC);
    var need_fsync = mask & C_FSYNC != 0;
    if (mask & C_FDATASYNC != 0) {
        if (sys.syncFile(1, .data)) |e| {
            if (e != .NOSYS and e != .INVAL) {
                diagnose(d, e, "fdatasync failed for {f}", .{cli.quoteA(d.output_file orelse "standard output")});
                status = 1;
            }
            need_fsync = true;
        }
    }
    if (need_fsync) {
        if (sys.syncFile(1, .file)) |e| {
            diagnose(d, e, "fsync failed for {f}", .{cli.quoteA(d.output_file orelse "standard output")});
            return 1;
        }
    }
    return status;
}

fn writeOutput(d: *D) void {
    const n = iwrite(d, d.obuf[0..d.output_blocksize]);
    d.w_bytes += @intCast(n);
    if (n != d.output_blocksize) {
        diagnose(d, last_errno, "writing to {f}", .{cli.quoteA(d.output_file orelse "standard output")});
        if (n != 0) d.w_partial += 1;
        quit(d, 1);
    } else d.w_full += 1;
    d.oc = 0;
}

fn outputChar(d: *D, c: u8) void {
    d.obuf[d.oc] = c;
    d.oc += 1;
    if (d.oc >= d.output_blocksize) writeOutput(d);
}

fn copySimple(d: *D, buf: []const u8) void {
    var start: usize = 0;
    var nread = buf.len;
    while (true) {
        const nfree = @min(nread, d.output_blocksize - d.oc);
        @memcpy(d.obuf[d.oc..][0..nfree], buf[start..][0..nfree]);
        nread -= nfree;
        start += nfree;
        d.oc += nfree;
        if (d.oc >= d.output_blocksize) writeOutput(d);
        if (nread == 0) break;
    }
}

fn copyWithBlock(d: *D, buf: []const u8) void {
    for (buf) |ch| {
        if (ch == d.newline_char) {
            if (d.col < d.conversion_blocksize) {
                var j = d.col;
                while (j < d.conversion_blocksize) : (j += 1) outputChar(d, d.space_char);
            }
            d.col = 0;
        } else {
            if (d.col == d.conversion_blocksize) {
                d.r_truncate += 1;
            } else if (d.col < d.conversion_blocksize) outputChar(d, ch);
            d.col += 1;
        }
    }
}

fn copyWithUnblock(d: *D, buf: []const u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const ch = buf[i];
        const was = d.col;
        d.col += 1;
        if (was >= d.conversion_blocksize) {
            // End of a record: emit a newline and look at this byte again.
            d.col = 0;
            d.pending_spaces = 0;
            outputChar(d, d.newline_char);
            continue;
        } else if (ch == d.space_char) {
            d.pending_spaces += 1;
        } else {
            while (d.pending_spaces > 0) {
                outputChar(d, d.space_char);
                d.pending_spaces -= 1;
            }
            outputChar(d, ch);
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

fn skipInput(d: *D, records_in: i64, bytes: *i64) i64 {
    // Try lseek first.
    var records = records_in;
    var e: E = .SUCCESS;
    const offset = records * @as(i64, @intCast(d.input_blocksize)) + bytes.*;
    if (sys.seekFd(0, offset, 1, &e) != null) {
        if (sys.fstatFd(0, &e)) |st| {
            if (st.isReg() and st.size > 0 and d.input_offset >= 0 and @as(i64, @intCast(st.size)) - d.input_offset < offset) {
                records = @divTrunc(offset - @as(i64, @intCast(st.size)), @as(i64, @intCast(d.input_blocksize)));
                d.input_offset = @intCast(st.size);
            } else {
                records = 0;
                d.input_offset += offset;
            }
        }
        return records;
    }
    // Read and discard.
    var remaining = records;
    while (remaining > 0 or bytes.* > 0) {
        const want = if (remaining > 0) d.input_blocksize else @as(usize, @intCast(bytes.*));
        const n = (if (d.fullblock) ireadFull(d, d.ibuf[0..want], &e) else iread(d, d.ibuf[0..want], &e)) orelse {
            if (d.conv & C_NOERROR == 0 or d.status != STATUS_NONE) diagnose(d, e, "error reading {f}", .{cli.quoteA(d.input_file orelse "standard input")});
            if (d.conv & C_NOERROR != 0) {
                printStats(d);
                continue;
            }
            quit(d, 1);
        };
        if (n == 0) break;
        if (remaining > 0) {
            if (n == d.input_blocksize) remaining -= 1;
        } else bytes.* -= @intCast(n);
        d.input_offset += @intCast(n);
        if (remaining == 0 and bytes.* == 0) break;
    }
    return remaining;
}

fn setFdFlags(d: *D, fd: i32, add: u32, name: []const u8) void {
    const flags = add & ~(O_NOCTTY | O_NOFOLLOW);
    if (flags == 0) return;
    const old = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
    if (std.os.linux.errno(old) != .SUCCESS) {
        diagnose(d, std.os.linux.errno(old), "setting flags for {f}", .{cli.quoteA(name)});
        std.process.exit(1);
    }
    var new: usize = old | flags;
    if (new != old) {
        if (new & O_DIRECTORY != 0) {
            var fe: E = .SUCCESS;
            const st = sys.fstatFd(fd, &fe);
            if (st == null) {
                diagnose(d, fe, "setting flags for {f}", .{cli.quoteA(name)});
                std.process.exit(1);
            } else if (!st.?.isDir()) {
                diagnose(d, .NOTDIR, "setting flags for {f}", .{cli.quoteA(name)});
                std.process.exit(1);
            }
            new &= ~@as(usize, O_DIRECTORY);
        }
        const rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, new);
        if (std.os.linux.errno(rc) != .SUCCESS) {
            diagnose(d, std.os.linux.errno(rc), "setting flags for {f}", .{cli.quoteA(name)});
            std.process.exit(1);
        }
    }
}

fn memExhausted(d: *D, which: []const u8, size: usize) noreturn {
    var hb: [human.longest]u8 = undefined;
    const h = human.readable(size, &hb, human_opts | human.base_1024, 1, 1);
    cli.warn(d.ctx, "memory exhausted by {s} buffer of size {d} bytes ({s})", .{ which, size, h });
    std.process.exit(1);
}

fn ddCopy(d: *D) u8 {
    var exit_status: u8 = 0;
    var e: E = .SUCCESS;
    const in_name = d.input_file orelse "standard input";
    const out_name = d.output_file orelse "standard output";

    // Buffers.
    const extra: usize = @intFromBool(d.conv & C_SWAB != 0);
    d.ibuf = d.ctx.gpa.alloc(u8, d.input_blocksize + extra) catch {
        memExhausted(d, "input", d.input_blocksize);
        std.process.exit(1);
    };
    if (d.conv & C_TWOBUFS != 0) {
        d.obuf = d.ctx.gpa.alloc(u8, d.output_blocksize) catch {
            memExhausted(d, "output", d.output_blocksize);
            std.process.exit(1);
        };
        d.separate_obuf = true;
    } else d.obuf = d.ibuf;
    defer {
        d.ctx.gpa.free(d.ibuf);
        if (d.separate_obuf) d.ctx.gpa.free(d.obuf);
    }

    if (d.skip_records != 0 or d.skip_bytes != 0) {
        const us_bytes = d.skip_records * @as(i64, @intCast(d.input_blocksize)) + d.skip_bytes;
        const off0 = d.input_offset;
        var sb = d.skip_bytes;
        const us_blocks = skipInput(d, d.skip_records, &sb);
        if ((us_blocks != 0 or (d.input_offset >= 0 and us_bytes != d.input_offset - off0)) and d.status != STATUS_NONE) {
            cli.warn(d.ctx, "{f}: cannot skip to specified offset", .{cli.quote(in_name)});
        }
    }
    if (d.seek_records != 0 or d.seek_bytes != 0) {
        const off = d.seek_records * @as(i64, @intCast(d.output_blocksize)) + d.seek_bytes;
        var se: E = .SUCCESS;
        if (sys.seekFd(1, off, 1, &se) == null) {
            // Not seekable: write zeros instead.
            const zeros = d.ctx.gpa.alloc(u8, d.output_blocksize) catch return 1;
            defer d.ctx.gpa.free(zeros);
            @memset(zeros, 0);
            var remaining = off;
            while (remaining > 0) {
                const n: usize = @intCast(@min(remaining, @as(i64, @intCast(zeros.len))));
                if (sys.writeAllFd(1, zeros[0..n])) |we| {
                    diagnose(d, we, "writing to {f}", .{cli.quoteA(out_name)});
                    quit(d, 1);
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
                d.input_offset += @intCast(n);
            } else break;
            nread = n;
        } else {
            if (d.conv & C_NOERROR == 0 or d.status != STATUS_NONE) diagnose(d, e, "error reading {f}", .{cli.quoteA(in_name)});
            if (d.conv & C_NOERROR != 0) {
                printStats(d);
                const bad = d.input_blocksize - partread;
                var se: E = .SUCCESS;
                if (sys.seekFd(0, @intCast(bad), 1, &se) == null) {
                    diagnose(d, se, "{f}: cannot seek", .{cli.quote(in_name)});
                    exit_status = 1;
                }
                d.input_offset += @intCast(bad);
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
                diagnose(d, last_errno, "error writing {f}", .{cli.quoteA(out_name)});
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
            copyWithBlock(d, bufstart);
        } else if (d.conv & C_UNBLOCK != 0) {
            copyWithUnblock(d, bufstart);
        } else copySimple(d, bufstart);
    }
    if (saved_byte >= 0) {
        const sc: [1]u8 = .{@intCast(saved_byte)};
        if (d.conv & C_BLOCK != 0) {
            copyWithBlock(d, &sc);
        } else if (d.conv & C_UNBLOCK != 0) {
            copyWithUnblock(d, &sc);
        } else outputChar(d, sc[0]);
    }
    if (d.conv & C_BLOCK != 0 and d.col > 0) {
        var i = d.col;
        while (i < d.conversion_blocksize) : (i += 1) outputChar(d, d.space_char);
    }
    if (d.col != 0 and d.conv & C_UNBLOCK != 0) outputChar(d, d.newline_char);
    if (d.oc != 0) {
        const nw = iwrite(d, d.obuf[0..d.oc]);
        d.w_bytes += @intCast(nw);
        if (nw != 0) d.w_partial += 1;
        if (nw != d.oc) {
            diagnose(d, last_errno, "error writing {f}", .{cli.quoteA(out_name)});
            return 1;
        }
    }
    if (d.final_op_was_seek) {
        if (sys.fstatFd(1, &e)) |st| {
            if (st.isReg()) {
                if (sys.seekFd(1, 0, 1, &e)) |off| {
                    if (off >= 0 and @as(i64, @intCast(st.size)) < off) {
                        if (sys.ftruncateFd(1, @intCast(off))) |te| {
                            diagnose(d, te, "failed to truncate to {d} bytes in output file {f}", .{ off, cli.quoteA(out_name) });
                            return 1;
                        }
                    }
                }
            }
        } else {
            diagnose(d, e, "cannot fstat {f}", .{cli.quoteA(out_name)});
            return 1;
        }
    }
    return exit_status;
}

pub fn main(ctx: cli.Context) u8 {
    var d: D = .{ .ctx = ctx };
    for (0..256) |i| d.trans[i] = @intCast(i);

    // Only --help and --version are options (getopt with a leading "+").
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(ctx.gpa);
    {
        var p = getopt.Parser.init(ctx, "+", &.{});
        defer p.deinit();
        while (true) switch (p.next()) {
            .done => break,
            .bad => return 1,
            .opt => |o| switch (o.id) {
                getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
                getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
                else => {},
            },
        };
        for (p.operands.items) |o| list.append(ctx.gpa, o) catch {};
    }
    scanArgs(&d, list.items);
    applyTranslations(&d);

    var e: E = .SUCCESS;
    if (d.input_file) |inf| {
        const fd = sys.openFd(inf, sys.O.RDONLY | d.iflags, 0, &e) orelse {
            cli.warn(ctx, "failed to open {f}: {s}", .{ cli.quoteA(inf), sys.errnoText(e) });
            return 1;
        };
        if (fd != 0) {
            _ = sys.dup2(fd, 0);
            _ = sys.closeFd(fd);
        }
    } else setFdFlags(&d, 0, d.iflags, "standard input");
    if (sys.seekFd(0, 0, 1, &e)) |off| {
        d.input_seekable = true;
        d.input_offset = off;
    }

    var exit_status: u8 = 0;
    if (d.output_file) |outf| {
        var opts: u32 = d.oflags;
        if (d.conv & C_NOCREAT == 0) opts |= sys.O.CREAT;
        if (d.conv & C_EXCL != 0) opts |= sys.O.EXCL;
        if (!(d.seek_records != 0 or d.conv & C_NOTRUNC != 0)) opts |= sys.O.TRUNC;
        const size: i64 = d.seek_records * @as(i64, @intCast(d.output_blocksize)) + d.seek_bytes;
        var fd: ?i32 = null;
        if (d.seek_records != 0) fd = sys.openFd(outf, sys.O.RDWR | opts, 0o666, &e);
        if (fd == null) fd = sys.openFd(outf, sys.O.WRONLY | opts, 0o666, &e);
        const ofd = fd orelse {
            cli.warn(ctx, "failed to open {f}: {s}", .{ cli.quoteA(outf), sys.errnoText(e) });
            return 1;
        };
        if (ofd != 1) {
            _ = sys.dup2(ofd, 1);
            _ = sys.closeFd(ofd);
        }
        if (d.seek_records != 0 and d.conv & C_NOTRUNC == 0) {
            if (sys.ftruncateFd(1, @intCast(size))) |te| {
                var se: E = .SUCCESS;
                if (sys.fstatFd(1, &se)) |st| {
                    if (st.isReg() or st.isDir()) {
                        diagnose(&d, te, "failed to truncate to {d} bytes in output file {f}", .{ size, cli.quoteA(outf) });
                        exit_status = 1;
                    }
                } else {
                    diagnose(&d, se, "cannot fstat {f}", .{cli.quoteA(outf)});
                    exit_status = 1;
                }
            }
        }
    } else setFdFlags(&d, 1, d.oflags, "standard output");

    d.start_ns = nowNs(&d);
    exit_status = ddCopy(&d);
    const sync_status = synchronizeOutput(&d);
    if (sync_status != 0) exit_status = sync_status;
    if (sys.closeFd(0)) |ce| {
        diagnose(&d, ce, "closing input file {f}", .{cli.quoteA(d.input_file orelse "standard input")});
        return 1;
    }
    if (sys.closeFd(1)) |ce| {
        diagnose(&d, ce, "closing output file {f}", .{cli.quoteA(d.output_file orelse "standard output")});
        return 1;
    }
    printStats(&d);
    return exit_status;
}
