// SPDX-License-Identifier: GPL-2.0-or-later
//! od: thin wrapper over `util_core.od` (decision 0004). Parses arguments
//! (including the traditional OFFSET operands and -t type strings) the way GNU
//! od does and words the diagnostics; the formatting is in src/lib/od.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const od = @import("../lib/od.zig");
const Io = std.Io;

const help_text = @embedFile("../help/od.txt");

const Fmt = od.Fmt;

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

    var inputs: std.ArrayList(od.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    for (files.items) |name| {
        const in: od.Input = if (std.mem.eql(u8, name, "-"))
            .{ .name = name, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = name, .source = .{ .path = name } };
        inputs.append(ctx.gpa, in) catch return 1;
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: od.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = od.run(env, .{
        .formats = fmts.items,
        .radix = radix,
        .skip = skip,
        .limit = limit,
        .verbose = verbose,
        .width = width_opt,
        .strings = strings,
        .big_endian = big_endian,
        .label = if (have_label) label else null,
    }, inputs.items, &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
        error.OutOfMemory => {
            cli.warn(ctx, "memory exhausted", .{});
            return 1;
        },
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: od.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .open_failed, .read_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .invalid_width => |e| cli.warn(ctx.*, "warning: invalid width {d}; using {d} instead", .{ e.width, e.using }),
        .skip_past_end => cli.warn(ctx.*, "cannot skip past end of combined input", .{}),
    }
}

fn parseBytesM(modern: *bool, text: []const u8) ?u64 {
    modern.* = true;
    return parseBytes(text, true);
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
