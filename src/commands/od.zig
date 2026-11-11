// SPDX-License-Identifier: GPL-2.0-or-later
//! od — dump files in octal and other formats.
//! Reference: GNU coreutils manual "od invocation" (9.7); POSIX.1-2024 od
//! (-A -b -c -d -j -N -o -s -t -v -x and the offset operand).
//!
//! Input is cut into blocks of `bytes_per_block` bytes. Every -t format prints
//! one line per block; the columns of all formats are aligned to the widest
//! one (each field is left-padded by (line width - own width) / fields), a
//! repeated full block becomes `*`, and a short final block is zero-padded
//! for display.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const fmt_float = @import("../fmt_float.zig");
const Io = std.Io;

const help_text = @embedFile("../help/od.txt");

const Kind = enum { a, c, d, u, o, x, f };

const Fmt = struct {
    kind: Kind,
    size: u8, // bytes per element
    /// f only: 'B' bfloat16, 'H' half, or 0.
    half: u8 = 0,
    z: bool = false,
    width: usize = 0, // natural field width
    pad: usize = 0, // extra left padding per field (alignment)
};

const a_names = [_][]const u8{
    "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel", "bs", "ht", "nl", "vt", "ff", "cr", "so", "si",
    "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb", "can", "em", "sub", "esc", "fs", "gs", "rs", "us",
    "sp",
};

fn fieldWidth(f: Fmt) usize {
    return switch (f.kind) {
        .a, .c => 3,
        .x => 2 * @as(usize, f.size),
        .o => (8 * @as(usize, f.size) + 2) / 3,
        .u => switch (f.size) {
            1 => 3,
            2 => 5,
            4 => 10,
            else => 20,
        },
        .d => switch (f.size) {
            1 => 4,
            2 => 6,
            4 => 11,
            else => 20,
        },
        .f => switch (f.size) {
            2 => 15,
            4 => 15,
            8 => 24,
            else => 29,
        },
    };
}

/// BYTES arguments: decimal, 0x hex or 0-prefixed octal, with b/KB/K/MB/M...
fn parseBytes(text: []const u8, allow_suffix: bool) ?u64 {
    if (text.len == 0) return null;
    var i: usize = 0;
    var base: u8 = 10;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        base = 16;
        i = 2;
    } else if (text[0] == '0' and text.len > 1 and std.ascii.isDigit(text[1])) {
        base = 8;
        i = 1;
    }
    var j = i;
    while (j < text.len and std.fmt.charToDigit(text[j], base) catch null != null) j += 1;
    if (j == i and base == 10) return null;
    const v = std.fmt.parseInt(u64, text[i..j], base) catch if (j == i) @as(u64, 0) else return null;
    const suffix = text[j..];
    if (suffix.len == 0) return v;
    if (!allow_suffix) return null;
    const mult: u64 = if (std.mem.eql(u8, suffix, "b")) 512 else blk: {
        const letters = "KMGTPEZY";
        const idx = std.mem.indexOfScalar(u8, letters, suffix[0]) orelse return null;
        var decimal = false;
        if (suffix.len == 2 and suffix[1] == 'B') decimal = true else if (suffix.len != 1) return null;
        var m: u64 = 1;
        for (0..idx + 1) |_| m *|= if (decimal) 1000 else 1024;
        break :blk m;
    };
    return v *| mult;
}

pub fn main(ctx: cli.Context) u8 {
    var radix: u8 = 'o';
    var fmts: std.ArrayList(Fmt) = .empty;
    defer fmts.deinit(ctx.gpa);
    var skip: u64 = 0;
    var limit: ?u64 = null;
    var verbose = false;
    var width_opt: ?u64 = null;
    var strings: ?u64 = null;
    var big_endian = false;
    var traditional = false;
    var modern = false; // -A -j -N -S -t -v -w disable the old OFFSET operand

    var p = getopt.Parser.init(ctx, "A:abcdfij:lN:osS:t:vw::x", &.{
        .{ .name = "address-radix", .arg = .required, .id = 'A' },
        .{ .name = "skip-bytes", .arg = .required, .id = 'j' },
        .{ .name = "read-bytes", .arg = .required, .id = 'N' },
        .{ .name = "format", .arg = .required, .id = 't' },
        .{ .name = "output-duplicates", .id = 'v' },
        .{ .name = "width", .arg = .optional, .id = 'w' },
        .{ .name = "strings", .arg = .optional, .id = 1200 },
        .{ .name = "endian", .arg = .required, .id = 1201 },
        .{ .name = "traditional", .id = 1202 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'A' => {
                modern = true;
                const a = o.arg.?;
                if (a.len == 0 or std.mem.indexOfScalar(u8, "doxn", a[0]) == null) {
                    cli.warn(ctx, "invalid output address radix {f}; it must be one character from [doxn]", .{cli.quoteC(a)});
                    return 1;
                }
                radix = a[0];
            },
            'j' => skip = parseBytesM(&modern, o.arg.?) orelse {
                cli.warn(ctx, "invalid -j argument {f}", .{cli.quoteC(o.arg.?)});
                return 1;
            },
            1299 => skip = parseBytes(o.arg.?, true) orelse {
                cli.warn(ctx, "invalid -j argument {f}", .{cli.quoteC(o.arg.?)});
                return 1;
            },
            'N' => limit = parseBytesM(&modern, o.arg.?) orelse {
                cli.warn(ctx, "invalid -N argument {f}", .{cli.quoteC(o.arg.?)});
                return 1;
            },
            1298 => limit = parseBytes(o.arg.?, true) orelse {
                cli.warn(ctx, "invalid -N argument {f}", .{cli.quoteC(o.arg.?)});
                return 1;
            },
            'S', 1200 => {
                modern = true;
                if (o.arg) |a| {
                    strings = parseBytes(a, true) orelse {
                        cli.warn(ctx, "invalid -S argument {f}", .{cli.quoteC(a)});
                        return 1;
                    };
                } else strings = 3;
            },
            'w' => {
                modern = true;
                if (o.arg) |a| {
                    width_opt = parseBytes(a, false) orelse {
                        cli.warn(ctx, "invalid -w argument {f}", .{cli.quoteC(a)});
                        return 1;
                    };
                    if (width_opt.? == 0) {
                        cli.warn(ctx, "invalid -w argument {f}", .{cli.quoteC(a)});
                        return 1;
                    }
                } else width_opt = 32;
            },
            'v' => {
                verbose = true;
                modern = true;
            },
            't' => {
                modern = true;
                if (!parseType(ctx, o.arg.?, &fmts)) return 1;
            },
            'a' => fmts.append(ctx.gpa, .{ .kind = .a, .size = 1 }) catch return 1,
            'b' => fmts.append(ctx.gpa, .{ .kind = .o, .size = 1 }) catch return 1,
            'c' => fmts.append(ctx.gpa, .{ .kind = .c, .size = 1 }) catch return 1,
            'd' => fmts.append(ctx.gpa, .{ .kind = .u, .size = 2 }) catch return 1,
            'f' => fmts.append(ctx.gpa, .{ .kind = .f, .size = 4 }) catch return 1,
            'i' => fmts.append(ctx.gpa, .{ .kind = .d, .size = 4 }) catch return 1,
            'l' => fmts.append(ctx.gpa, .{ .kind = .d, .size = 8 }) catch return 1,
            'o' => fmts.append(ctx.gpa, .{ .kind = .o, .size = 2 }) catch return 1,
            's' => fmts.append(ctx.gpa, .{ .kind = .d, .size = 2 }) catch return 1,
            'x' => fmts.append(ctx.gpa, .{ .kind = .x, .size = 2 }) catch return 1,
            1201 => {
                const v = o.arg.?;
                if (std.mem.eql(u8, v, "big")) big_endian = true else if (std.mem.eql(u8, v, "little")) big_endian = false else {
                    cli.warn(ctx, "invalid argument {f} for '--endian'\nValid arguments are:\n  - 'little'\n  - 'big'\nTry '{s} --help' for more information.", .{ cli.quoteC(v), ctx.name });
                    return 1;
                }
            },
            1202 => traditional = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    for (p.operands.items) |f| files.append(ctx.gpa, f) catch return 1;

    // Old-style offset (and label) operands exist only with --traditional;
    // GNU 9.7 treats such operands as file names otherwise.
    var label: ?u64 = null;
    var have_label = false;
    if (traditional) {
        const n = files.items.len;
        if (n == 1 and oldOffset(files.items[0]) != null) {
            skip = oldOffset(files.items[0]).?;
            files.clearRetainingCapacity();
        } else if (n == 2 and oldOffset(files.items[1]) != null) {
            skip = oldOffset(files.items[1]).?;
            files.shrinkRetainingCapacity(1);
        } else if (n == 3 and oldOffset(files.items[1]) != null and oldOffset(files.items[2]) != null) {
            skip = oldOffset(files.items[1]).?;
            label = oldOffset(files.items[2]).?;
            have_label = true;
            files.shrinkRetainingCapacity(1);
        } else if (n > 1) {
            cli.warn(ctx, "extra operand {f}", .{cli.quoteC(files.items[1])});
            cli.warn(ctx, "compatibility mode supports at most one file\nTry '{s} --help' for more information.", .{ctx.name});
            return 1;
        }
    }
    if (!traditional and !modern) {
        // OFFSET operand of the second call format (only without the options
        // added after POSIX): last operand starts with '+', or is a digit
        // string when there are two operands.
        const n = files.items.len;
        if (n >= 1 and n <= 2) {
            const last = files.items[n - 1];
            if (last.len > 0 and (last[0] == '+' or (n == 2 and std.ascii.isDigit(last[0])))) {
                if (oldOffset(last)) |off| {
                    skip = off;
                    files.shrinkRetainingCapacity(n - 1);
                }
            }
        }
    }
    if (files.items.len == 0) files.append(ctx.gpa, "-") catch return 1;

    if (strings != null) {
        if (fmts.items.len > 0) {
            cli.warn(ctx, "no type may be specified when dumping strings", .{});
            return 1;
        }
    }
    if (fmts.items.len == 0) fmts.append(ctx.gpa, .{ .kind = .o, .size = 2 }) catch return 1;

    // Block size: lcm of element sizes; default 16 (or the lcm if larger).
    var lcm: usize = 1;
    for (fmts.items) |*f| {
        f.width = fieldWidth(f.*);
        lcm = lcmOf(lcm, f.size);
    }
    var bpb: usize = 16;
    if (lcm > 16) bpb = lcm;
    if (width_opt) |w| {
        if (w % lcm != 0 or w == 0 or w > 1 << 20) {
            cli.warn(ctx, "warning: invalid width {d}; using {d} instead", .{ w, lcm });
            bpb = lcm;
        } else bpb = @intCast(w);
    } else if (bpb % lcm != 0) bpb = lcm;

    // Column alignment across formats.
    var line_w: usize = 0;
    for (fmts.items) |f| line_w = @max(line_w, (f.width + 1) * (bpb / f.size));
    for (fmts.items) |*f| {
        const n = bpb / f.size;
        f.pad = (line_w - (f.width + 1) * n) / n;
    }

    var src = Source.init(ctx, files.items, limit);
    defer src.deinit();
    if (skip > 0 and !src.skipBytes(skip)) {
        if (!src.had_error) cli.warn(ctx, "cannot skip past end of combined input", .{});
        return 1;
    }

    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    if (strings) |min| {
        dumpStrings(&src, &out, min, radix, skip);
    } else {
        const buf = ctx.gpa.alloc(u8, bpb * 2) catch return 1;
        defer ctx.gpa.free(buf);
        const cur = buf[0..bpb];
        const prev = buf[bpb..];
        var have_prev = false;
        var star_printed = false;
        var addr: u64 = skip;
        var lab: u64 = label orelse 0;
        while (true) {
            const n = src.read(cur);
            if (n == 0) break;
            if (!verbose and n == bpb and have_prev and std.mem.eql(u8, cur, prev)) {
                if (!star_printed) {
                    out.write("*\n");
                    star_printed = true;
                }
            } else {
                star_printed = false;
                if (n < bpb) @memset(cur[n..], 0);
                printBlock(&out, fmts.items, cur, n, addr, radix, big_endian, line_w, if (have_label) lab else null);
                @memcpy(prev, cur);
                have_prev = n == bpb;
            }
            addr += n;
            lab += n;
            if (n < bpb) break;
        }
        if (radix != 'n' and (src.opened_any or !src.had_error)) {
            printAddr(&out, addr, radix);
            if (have_label) {
                out.write(" (");
                printAddr(&out, lab, radix);
                out.write(")");
            }
            out.writeByte('\n');
        }
    }
    out.flush();
    if (out.failed) return 1;
    if (src.had_error) status = 1;
    return status;
}

fn parseBytesM(modern: *bool, text: []const u8) ?u64 {
    modern.* = true;
    return parseBytes(text, true);
}

fn lcmOf(a: usize, b: usize) usize {
    return a / std.math.gcd(a, b) * b;
}

/// Traditional OFFSET: [+]octal-digits with an optional b/B (x512), or [+]0xHEX.
fn oldOffset(text: []const u8) ?u64 {
    var s = text;
    if (s.len > 0 and s[0] == '+') s = s[1..];
    if (s.len == 0) return null;
    if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        return std.fmt.parseInt(u64, s[2..], 16) catch null;
    }
    var mult: u64 = 1;
    if (s[s.len - 1] == 'b' or s[s.len - 1] == 'B') {
        mult = if (s[s.len - 1] == 'b') 512 else 1024;
        s = s[0 .. s.len - 1];
    }
    if (s.len == 0) return null;
    const v = std.fmt.parseInt(u64, s, 8) catch return null;
    return v *| mult;
}

fn parseType(ctx: cli.Context, text: []const u8, fmts: *std.ArrayList(Fmt)) bool {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        i += 1;
        var f: Fmt = undefined;
        switch (c) {
            'a' => f = .{ .kind = .a, .size = 1 },
            'c' => f = .{ .kind = .c, .size = 1 },
            'd', 'o', 'u', 'x' => {
                var size: usize = 4; // default int
                if (i < text.len and std.ascii.isDigit(text[i])) {
                    var j = i;
                    var v: usize = 0;
                    while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) v = v * 10 + (text[j] - '0');
                    size = v;
                    i = j;
                } else if (i < text.len and std.mem.indexOfScalar(u8, "CSIL", text[i]) != null) {
                    size = switch (text[i]) {
                        'C' => 1,
                        'S' => 2,
                        'I' => 4,
                        else => 8,
                    };
                    i += 1;
                } else size = 4;
                if (size != 1 and size != 2 and size != 4 and size != 8) {
                    cli.warn(ctx, "invalid type string {f};\nthis system doesn't provide a {d}-byte integral type", .{ cli.quoteC(text), size });
                    return false;
                }
                f = .{ .kind = switch (c) {
                    'd' => .d,
                    'o' => .o,
                    'u' => .u,
                    else => .x,
                }, .size = @intCast(size) };
            },
            'f' => {
                var size: usize = 8; // double by default
                var half: u8 = 0;
                if (i < text.len and std.ascii.isDigit(text[i])) {
                    var j = i;
                    var v: usize = 0;
                    while (j < text.len and std.ascii.isDigit(text[j])) : (j += 1) v = v * 10 + (text[j] - '0');
                    size = v;
                    i = j;
                } else if (i < text.len and std.mem.indexOfScalar(u8, "BHFDL", text[i]) != null) {
                    switch (text[i]) {
                        'B' => {
                            size = 2;
                            half = 'B';
                        },
                        'H' => {
                            size = 2;
                            half = 'H';
                        },
                        'F' => size = 4,
                        'D' => size = 8,
                        else => size = 16,
                    }
                    i += 1;
                }
                if (size != 2 and size != 4 and size != 8 and size != 16) {
                    cli.warn(ctx, "invalid type string {f};\nthis system doesn't provide a {d}-byte floating point type", .{ cli.quoteC(text), size });
                    return false;
                }
                if (size == 2 and half == 0) half = 'H';
                f = .{ .kind = .f, .size = @intCast(size), .half = half };
            },
            else => {
                cli.warn(ctx, "invalid character '{c}' in type string {f}", .{ c, cli.quoteC(text) });
                return false;
            },
        }
        if (i < text.len and text[i] == 'z') {
            f.z = true;
            i += 1;
        }
        fmts.append(ctx.gpa, f) catch return false;
    }
    return true;
}

// ----------------------------------------------------------------- input

const Source = struct {
    ctx: cli.Context,
    files: []const []const u8,
    next_file: usize = 0,
    cur: ?Io.File = null,
    left: ?u64,
    had_error: bool = false,
    opened_any: bool = false,
    /// Kind of the most recently opened input (a character device such as
    /// /dev/null can be 'skipped' arbitrarily far, like lseek does).
    last_char_dev: bool = false,
    buf: [65536]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,

    fn init(ctx: cli.Context, files: []const []const u8, limit: ?u64) Source {
        return .{ .ctx = ctx, .files = files, .left = limit };
    }

    fn deinit(s: *Source) void {
        if (s.cur) |f| cli.closeInput(s.ctx.io, f);
    }

    /// Refill the internal buffer; false at the end of all input.
    fn fill(s: *Source) bool {
        while (true) {
            if (s.cur == null) {
                if (s.next_file >= s.files.len) return false;
                const name = s.files[s.next_file];
                s.next_file += 1;
                s.cur = cli.openInput(s.ctx.io, name) catch |e| {
                    s.had_error = true;
                    if (e == error.IsDir) s.opened_any = true; // GNU opens it and fails on read
                    cli.warn(s.ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
                    continue;
                };
                s.opened_any = true;
                if (s.cur.?.stat(s.ctx.io)) |st| {
                    s.last_char_dev = st.kind == .character_device;
                } else |_| {}
            }
            const n = cli.readChunk(s.ctx.io, s.cur.?, &s.buf) catch |e| {
                s.had_error = true;
                cli.warn(s.ctx, "{f}: {s}", .{ cli.quote(s.files[s.next_file - 1]), cli.errText(e) });
                cli.closeInput(s.ctx.io, s.cur.?);
                s.cur = null;
                continue;
            };
            if (n == 0) {
                cli.closeInput(s.ctx.io, s.cur.?);
                s.cur = null;
                continue;
            }
            s.pos = 0;
            s.len = n;
            return true;
        }
    }

    fn skipBytes(s: *Source, n: u64) bool {
        var left = n;
        while (left > 0) {
            if (s.pos == s.len and !s.fill()) return s.last_char_dev;
            const take: usize = @intCast(@min(left, s.len - s.pos));
            s.pos += take;
            left -= take;
        }
        return true;
    }

    /// Read up to out.len bytes, honouring -N.
    fn read(s: *Source, out: []u8) usize {
        var want = out.len;
        if (s.left) |l| want = @min(want, @as(usize, @intCast(@min(l, std.math.maxInt(usize)))));
        var got: usize = 0;
        while (got < want) {
            if (s.pos == s.len and !s.fill()) break;
            const take = @min(want - got, s.len - s.pos);
            @memcpy(out[got .. got + take], s.buf[s.pos .. s.pos + take]);
            s.pos += take;
            got += take;
        }
        if (s.left) |*l| l.* -= got;
        return got;
    }
};

// ---------------------------------------------------------------- output

fn printAddr(out: *cli.Out, addr: u64, radix: u8) void {
    switch (radix) {
        'o' => out.print("{o:0>7}", .{addr}),
        'd' => out.print("{d:0>7}", .{addr}),
        'x' => out.print("{x:0>6}", .{addr}),
        else => {},
    }
}

fn addrWidth(radix: u8) usize {
    return switch (radix) {
        'o', 'd' => 7,
        'x' => 6,
        else => 0,
    };
}

fn spaces(out: *cli.Out, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) out.writeByte(' ');
}

fn printBlock(out: *cli.Out, fmts: []const Fmt, block: []const u8, n_bytes: usize, addr: u64, radix: u8, big: bool, line_w: usize, label: ?u64) void {
    for (fmts, 0..) |f, fi| {
        if (fi == 0) {
            printAddr(out, addr, radix);
            if (label) |l| {
                out.write(" (");
                printAddr(out, l, radix);
                out.write(")");
            }
        } else {
            spaces(out, addrWidth(radix));
            if (label != null) spaces(out, 3 + addrWidth(radix));
        }
        const n_elems = (n_bytes + f.size - 1) / f.size;
        var i: usize = 0;
        while (i < n_elems) : (i += 1) {
            var tmp: [16]u8 = undefined;
            const e = block[i * f.size ..][0..f.size];
            @memcpy(tmp[0..f.size], e);
            if (big and f.size > 1) std.mem.reverse(u8, tmp[0..f.size]);
            out.writeByte(' ');
            spaces(out, f.pad);
            printElem(out, f, tmp[0..f.size]);
        }
        if (f.z) {
            // Pad the missing fields, then ">printable<".
            const missing = (block.len / f.size) - n_elems;
            spaces(out, missing * (1 + f.pad + f.width));
            // Alignment remainder lost to integer division in `pad`.
            const used = (block.len / f.size) * (1 + f.pad + f.width);
            spaces(out, line_w - used);
            out.write("  >");
            for (block[0..n_bytes]) |c| out.writeByte(if (c >= 0x20 and c < 0x7f) c else '.');
            out.writeByte('<');
        }
        out.writeByte('\n');
    }
}

fn printElem(out: *cli.Out, f: Fmt, e: []const u8) void {
    var buf: [64]u8 = undefined;
    switch (f.kind) {
        .a => {
            const c = e[0] & 0x7f;
            const s: []const u8 = if (c <= 32) a_names[c] else if (c == 127) "del" else @as(*const [1]u8, &e[0]);
            var one: [1]u8 = .{c};
            const shown = if (c > 32 and c < 127) one[0..] else s;
            printRight(out, shown, f.width);
        },
        .c => {
            const c = e[0];
            const s: []const u8 = switch (c) {
                0 => "\\0",
                7 => "\\a",
                8 => "\\b",
                9 => "\\t",
                10 => "\\n",
                11 => "\\v",
                12 => "\\f",
                13 => "\\r",
                else => if (c >= 0x20 and c < 0x7f) @as(*const [1]u8, &e[0]) else std.fmt.bufPrint(&buf, "{o:0>3}", .{c}) catch "?",
            };
            printRight(out, s, f.width);
        },
        .o, .x, .u, .d => {
            var v: u64 = 0;
            for (e, 0..) |b, k| v |= @as(u64, b) << @intCast(8 * k);
            const s: []const u8 = switch (f.kind) {
                .o => std.fmt.bufPrint(&buf, "{o:0>[1]}", .{ v, f.width }) catch "?",
                .x => std.fmt.bufPrint(&buf, "{x:0>[1]}", .{ v, f.width }) catch "?",
                .u => std.fmt.bufPrint(&buf, "{d}", .{v}) catch "?",
                else => blk: {
                    const bits: u7 = @intCast(8 * f.size);
                    const sv: i64 = if (bits == 64) @bitCast(v) else signExtend(v, bits);
                    break :blk std.fmt.bufPrint(&buf, "{d}", .{sv}) catch "?";
                },
            };
            printRight(out, s, f.width);
        },
        .f => {
            var tb: [64]u8 = undefined;
            const t: []const u8 = switch (f.size) {
                2 => blk: {
                    const bits = std.mem.readInt(u16, e[0..2], .little);
                    const v: f32 = if (f.half == 'B') @bitCast(@as(u32, bits) << 16) else @floatCast(@as(f16, @bitCast(bits)));
                    break :blk shortestG(f32, v, 6, &tb);
                },
                4 => shortestG(f32, @bitCast(std.mem.readInt(u32, e[0..4], .little)), 6, &tb),
                8 => shortestG(f64, @bitCast(std.mem.readInt(u64, e[0..8], .little)), 15, &tb),
                else => blk: {
                    const lo = std.mem.readInt(u64, e[0..8], .little);
                    const hi = std.mem.readInt(u16, e[8..10], .little);
                    const bits: u80 = (@as(u80, hi) << 64) | lo;
                    // x87 encodings with a clear integer bit (and a non-zero,
                    // non-max exponent) are "unnormals"; glibc prints them as nan.
                    const exp15 = hi & 0x7fff;
                    if (exp15 != 0 and exp15 != 0x7fff and (lo >> 63) == 0) break :blk if (hi & 0x8000 != 0) "-nan" else "nan";
                    if (exp15 == 0x7fff and (lo >> 63) == 0) break :blk if (hi & 0x8000 != 0) "-nan" else "nan";
                    if (exp15 == 0 and lo != 0) break :blk denormalG(lo, hi & 0x8000 != 0, &tb);
                    break :blk shortestG(f80, @bitCast(bits), 18, &tb);
                },
            };
            printRight(out, t, f.width);
        },
    }
}

/// C `%g` of the shortest decimal that reads back as `v` (GNU od prints
/// floating point values this way, with at most `prec` significant digits).
fn shortestG(comptime T: type, v: T, dig: usize, buf: *[64]u8) []const u8 {
    if (std.math.isNan(v)) return if (std.math.signbit(v)) "-nan" else "nan";
    if (std.math.isInf(v)) return if (v < 0) "-inf" else "inf";
    var raw: [64]u8 = undefined;
    const sci = std.fmt.bufPrint(&raw, "{e}", .{v}) catch return "?";
    var i: usize = 0;
    var neg = false;
    if (sci[0] == '-') {
        neg = true;
        i = 1;
    }
    const epos = std.mem.indexOfScalar(u8, sci, 'e') orelse return "?";
    var digits: [48]u8 = undefined;
    var nd: usize = 0;
    for (sci[i..epos]) |c| {
        if (c != '.') {
            digits[nd] = c;
            nd += 1;
        }
    }
    const exp = std.fmt.parseInt(i32, sci[epos + 1 ..], 10) catch return "?";
    var w: std.Io.Writer = .fixed(buf);
    if (neg) w.writeByte('-') catch {};
    if (nd == 1 and digits[0] == '0') {
        w.writeByte('0') catch {};
        return w.buffered();
    }
    // GNU tries precisions dig, dig+1, ... (from 1 for subnormals) until the
    // text reads back; %g then goes scientific when exp >= that precision.
    const sub = v != 0 and @abs(v) < std.math.floatMin(T);
    const prec: usize = if (sub) nd else @max(nd, dig);
    if (exp < -4 or exp >= @as(i32, @intCast(prec))) {
        w.writeByte(digits[0]) catch {};
        if (nd > 1) {
            w.writeByte('.') catch {};
            w.writeAll(digits[1..nd]) catch {};
        }
        w.print("e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) }) catch {};
    } else if (exp < 0) {
        w.writeAll("0.") catch {};
        var z: i32 = -exp - 1;
        while (z > 0) : (z -= 1) w.writeByte('0') catch {};
        w.writeAll(digits[0..nd]) catch {};
    } else {
        const int_digits: usize = @intCast(exp + 1);
        if (nd <= int_digits) {
            w.writeAll(digits[0..nd]) catch {};
            var z = int_digits - nd;
            while (z > 0) : (z -= 1) w.writeByte('0') catch {};
        } else {
            w.writeAll(digits[0..int_digits]) catch {};
            w.writeByte('.') catch {};
            w.writeAll(digits[int_digits..nd]) catch {};
        }
    }
    return w.buffered();
}

/// Shortest `%g` text (precision 1..21) that reads back as the x87 denormal
/// with mantissa `m` (value m * 2^-16445). std.fmt mis-scales these, so the
/// round trip is checked exactly with big integers: a decimal D*10^q
/// represents the value when |D*10^q - m*2^-16445| <= 2^-16446.
fn denormalG(m: u64, neg: bool, buf: *[64]u8) []const u8 {
    const gpa = std.heap.page_allocator;
    const value: f80 = @bitCast((@as(u80, @intFromBool(neg)) << 79) | m);
    var p: usize = 1;
    while (p <= 21) : (p += 1) {
        const e_txt = fmt_float.formatAllocLong(gpa, .{ .conv = 'e', .precision = p - 1 }, value) catch return "?";
        defer gpa.free(e_txt);
        // e_txt: [-]d[.ddd]e-XXXX
        var i: usize = 0;
        if (e_txt[0] == '-') i = 1;
        const epos = std.mem.indexOfScalar(u8, e_txt, 'e') orelse return "?";
        var digits: [32]u8 = undefined;
        var nd: usize = 0;
        for (e_txt[i..epos]) |c| if (c != '.') {
            digits[nd] = c;
            nd += 1;
        };
        const x = std.fmt.parseInt(i32, e_txt[epos + 1 ..], 10) catch return "?";
        const q: i32 = x - @as(i32, @intCast(nd)) + 1; // value ~ D * 10^q, q negative here
        if (q >= 0) continue;
        const k: usize = @intCast(-q);
        var d_big = std.math.big.int.Managed.init(gpa) catch return "?";
        defer d_big.deinit();
        d_big.setString(10, digits[0..nd]) catch return "?";
        d_big.shiftLeft(&d_big, 16446) catch return "?"; // D * 2^16446
        var ten = std.math.big.int.Managed.initSet(gpa, 10) catch return "?";
        defer ten.deinit();
        var pw = std.math.big.int.Managed.init(gpa) catch return "?";
        defer pw.deinit();
        pw.pow(&ten, @intCast(k)) catch return "?"; // 10^k
        var m2 = std.math.big.int.Managed.initSet(gpa, m) catch return "?";
        defer m2.deinit();
        m2.shiftLeft(&m2, 1) catch return "?"; // 2m
        m2.mul(&m2, &pw) catch return "?"; // 2m * 10^k
        var diff = std.math.big.int.Managed.init(gpa) catch return "?";
        defer diff.deinit();
        diff.sub(&d_big, &m2) catch return "?";
        diff.abs();
        if (diff.order(pw) != .gt) {
            const g = fmt_float.formatAllocLong(gpa, .{ .conv = 'g', .precision = p }, value) catch return "?";
            defer gpa.free(g);
            const n = @min(g.len, buf.len);
            @memcpy(buf[0..n], g[0..n]);
            return buf[0..n];
        }
    }
    return "?";
}

fn signExtend(v: u64, bits: u7) i64 {
    const shift: u6 = @intCast(64 - @as(u7, bits));
    return @as(i64, @bitCast(v << shift)) >> shift;
}

fn printRight(out: *cli.Out, s: []const u8, width: usize) void {
    if (s.len < width) spaces(out, width - s.len);
    out.write(s);
}

fn dumpStrings(src: *Source, out: *cli.Out, min: u64, radix: u8, start: u64) void {
    var addr: u64 = start;
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(src.ctx.gpa);
    var str_start: u64 = addr;
    var one: [1]u8 = undefined;
    while (true) {
        if (src.read(&one) == 0) break;
        const c = one[0];
        if (c == 0) {
            if (cur.items.len >= min) {
                if (radix != 'n') {
                    printAddr(out, str_start, radix);
                    out.writeByte(' ');
                }
                out.write(cur.items);
                out.writeByte('\n');
            }
            cur.clearRetainingCapacity();
        } else if (c >= 0x20 and c < 0x7f) {
            if (cur.items.len == 0) str_start = addr;
            cur.append(src.ctx.gpa, c) catch return;
        } else cur.clearRetainingCapacity();
        addr += 1;
    }
}
