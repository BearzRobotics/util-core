// SPDX-License-Identifier: GPL-2.0-or-later
//! dd: thin wrapper over `util_core.dd` (decision 0004). Parses the operands
//! the way GNU dd does (including the diagnostics for bad operands) and
//! routes the library's diagnostics and statistics to standard error; the
//! copy is in src/lib/dd.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const human = @import("../human.zig");
const dd = @import("../lib/dd.zig");
const Io = std.Io;

const help_text = @embedFile("../help/dd.txt");

fn operandMatches(str: []const u8, pattern: []const u8, delim: u8) bool {
    if (!std.mem.startsWith(u8, str, pattern)) return false;
    return str.len == pattern.len or str[pattern.len] == delim;
}

fn usageFail(ctx: cli.Context) noreturn {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    std.process.exit(1);
}

fn parseSymbols(ctx: cli.Context, str_in: []const u8, table: []const dd.Sym, exclusive: bool, msg: []const u8) u32 {
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
            const q = @import("../quotearg.zig").quoteAlloc(ctx.gpa, piece, .locale, null) catch "";
            cli.warn(ctx, "{s}: {s}", .{ msg, q });
            usageFail(ctx);
        }
        if (exclusive) value = found.? else value |= found.?;
        if (comma == null) break;
        str = str[comma.? + 1 ..];
    }
    return value;
}

const IntErr = enum { ok, invalid, overflow };

/// dd.c parse_integer (suffixes bcEGkKMPQRTwYZ0, "B" after a suffix, "x").
fn parseInteger(ctx: cli.Context, str: []const u8, err: *IntErr) i64 {
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
        const o = parseInteger(ctx, str[end + 1 ..], &e2);
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
            cli.warn(ctx, "warning: {f} is a zero multiplier; use {f} if that is intended", .{ cli.quoteC("0x"), cli.quoteC("00x") });
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

fn scanArgs(ctx: cli.Context, d: *dd.Job, args: []const []const u8) void {
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
            d.conv |= parseSymbols(ctx, val, &dd.conversions, false, "invalid conversion");
        } else if (operandMatches(name, "iflag", '=')) {
            d.iflags |= parseSymbols(ctx, val, &dd.flag_syms, false, "invalid input flag");
        } else if (operandMatches(name, "oflag", '=')) {
            d.oflags |= parseSymbols(ctx, val, &dd.flag_syms, false, "invalid output flag");
        } else if (operandMatches(name, "status", '=')) {
            d.status = parseSymbols(ctx, val, &dd.status_syms, true, "invalid status level");
        } else {
            var invalid: IntErr = .ok;
            const n = parseInteger(ctx, val, &invalid);
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
    } else d.conv |= dd.C_TWOBUFS;
    if (d.input_blocksize == 0) d.input_blocksize = 512;
    if (d.output_blocksize == 0) d.output_blocksize = 512;
    if (d.conversion_blocksize == 0) d.conv &= ~(dd.C_BLOCK | dd.C_UNBLOCK);
    if (d.iflags & (dd.O_DSYNC | dd.O_SYNC) != 0) d.iflags |= dd.O_RSYNC;
    if (d.oflags & dd.O_FULLBLOCK != 0) {
        cli.warn(ctx, "invalid output flag: {f}", .{cli.quoteC("fullblock")});
        usageFail(ctx);
    }
    if (skip_b) d.iflags |= dd.O_SKIP_BYTES;
    if (d.iflags & dd.O_SKIP_BYTES != 0 and skip != 0) {
        d.skip_records = @divTrunc(skip, @as(i64, @intCast(d.input_blocksize)));
        d.skip_bytes = @rem(skip, @as(i64, @intCast(d.input_blocksize)));
    } else if (skip != 0) d.skip_records = skip;
    if (count_b) d.iflags |= dd.O_COUNT_BYTES;
    if (d.iflags & dd.O_COUNT_BYTES != 0 and count != std.math.maxInt(i64)) {
        d.max_records = @divTrunc(count, @as(i64, @intCast(d.input_blocksize)));
        d.max_bytes = @intCast(@rem(count, @as(i64, @intCast(d.input_blocksize))));
    } else if (count != std.math.maxInt(i64)) d.max_records = count;
    if (seek_b) d.oflags |= dd.O_SEEK_BYTES;
    if (d.oflags & dd.O_SEEK_BYTES != 0 and seek != 0) {
        d.seek_records = @divTrunc(seek, @as(i64, @intCast(d.output_blocksize)));
        d.seek_bytes = @rem(seek, @as(i64, @intCast(d.output_blocksize)));
    } else if (seek != 0) d.seek_records = seek;
    d.warn_partial_read = d.conv & dd.C_TWOBUFS == 0 and d.iflags & dd.O_FULLBLOCK == 0 and
        (d.skip_records != 0 or (d.max_records > 0 and d.max_records < std.math.maxInt(i64)) or ((d.iflags | d.oflags) & dd.O_DIRECT) != 0);
    d.fullblock = d.iflags & dd.O_FULLBLOCK != 0;
    d.iflags &= ~dd.O_FULLBLOCK;
    if (multipleBits(d.conv & (dd.C_ASCII | dd.C_EBCDIC | dd.C_IBM))) fatal(ctx, "cannot combine any two of {ascii,ebcdic,ibm}");
    if (multipleBits(d.conv & (dd.C_BLOCK | dd.C_UNBLOCK))) fatal(ctx, "cannot combine block and unblock");
    if (multipleBits(d.conv & (dd.C_LCASE | dd.C_UCASE))) fatal(ctx, "cannot combine lcase and ucase");
    if (multipleBits(d.conv & (dd.C_EXCL | dd.C_NOCREAT))) fatal(ctx, "cannot combine excl and nocreat");
    if (multipleBits(d.iflags & (dd.O_DIRECT | dd.O_NOCACHE)) or multipleBits(d.oflags & (dd.O_DIRECT | dd.O_NOCACHE))) fatal(ctx, "cannot combine direct and nocache");
    d.iflags &= ~dd.O_NOCACHE;
    d.oflags &= ~dd.O_NOCACHE;
}

fn fatal(ctx: cli.Context, msg: []const u8) noreturn {
    cli.warn(ctx, "{s}", .{msg});
    std.process.exit(1);
}

pub fn main(ctx: cli.Context) u8 {
    var d = dd.Job.init(.{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ }, .{ .context = @constCast(&ctx), .func = report });

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
    scanArgs(ctx, &d, list.items);
    dd.catchSignals(cli.getenv(ctx, "POSIXLY_CORRECT") != null);

    return dd.run(&d);
}

fn report(context: ?*anyopaque, ev: dd.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .diag => |t| cli.warn(ctx.*, "{s}", .{t}),
        .raw => |t| Io.File.stderr().writeStreamingAll(ctx.io, t) catch {},
    }
}
