// SPDX-License-Identifier: GPL-2.0-or-later
//! cut — select bytes, characters or fields from each line.
//! References: GNU coreutils manual "cut invocation" (9.7); POSIX.1-2024 cut.
//!
//! Characters are bytes (C locale): -c is the same as -b and -n is accepted
//! and ignored, which matches GNU's behaviour in a single-byte locale; the
//! multibyte behaviour of UTF-8 locales is not implemented.
//! GNU extensions: --complement, --output-delimiter, -z, long options.

const std = @import("std");
const cli = @import("../cli.zig");
const lines = @import("../lines.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "bytes", "characters", "fields", "delimiter", "only-delimited", "output-delimiter", "complement", "zero-terminated", "help", "version" };

const Range = struct { lo: usize, hi: usize }; // 1-based, inclusive; hi == max means "to the end"
const max_pos = std.math.maxInt(usize);

const Mode = enum { none, bytes, fields };

pub fn main(ctx: cli.Context) u8 {
    var mode: Mode = .none;
    var list_text: ?[]const u8 = null;
    var delim: ?u8 = null;
    var only_delimited = false;
    var out_delim: ?[]const u8 = null;
    var complement = false;
    var line_delim: u8 = '\n';
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);

    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            switch (k) {
                0, 1, 2, 3, 5 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                            return 1;
                        }
                        val = args[i];
                    }
                    switch (k) {
                        0, 1 => if (!setList(ctx, &mode, &list_text, .bytes, val)) return 1,
                        2 => if (!setList(ctx, &mode, &list_text, .fields, val)) return 1,
                        3 => if (!setDelim(ctx, &delim, val)) return 1,
                        else => out_delim = val,
                    }
                },
                4 => only_delimited = true,
                6 => complement = true,
                7 => line_delim = 0,
                8 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'n' => {},
            's' => only_delimited = true,
            'z' => line_delim = 0,
            'b', 'c', 'f', 'd' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                const ok = switch (a[j]) {
                    'b', 'c' => setList(ctx, &mode, &list_text, .bytes, val),
                    'f' => setList(ctx, &mode, &list_text, .fields, val),
                    else => setDelim(ctx, &delim, val),
                };
                if (!ok) return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    if (mode == .none) {
        cli.warn(ctx, "you must specify a list of bytes, characters, or fields\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (mode == .bytes and delim != null) {
        cli.warn(ctx, "an input delimiter may be specified only when operating on fields\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (mode == .bytes and only_delimited) {
        cli.warn(ctx, "suppressing non-delimited lines makes sense\n\tonly when operating on fields\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var ranges = parseList(ctx, list_text.?, mode == .fields) orelse return 1;
    defer ranges.deinit(ctx.gpa);
    if (complement) invert(ctx.gpa, &ranges) catch return oom(ctx);

    const field_delim = delim orelse '\t';
    // GNU: an empty --output-delimiter is a single NUL byte.
    const odelim: []const u8 = if (out_delim) |o| (if (o.len == 0) "\x00" else o) else &[_]u8{field_delim};
    const odelim_given = out_delim != null;

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    for (inputs) |path| {
        const file = cli.openInput(ctx.io, path) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        var reader = lines.LineReader.init(ctx.gpa, ctx.io, file, line_delim);
        defer reader.deinit();
        while (reader.next() catch |e| {
            out.flush();
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            status = 1;
            break;
        }) |line| {
            if (mode == .bytes) {
                cutBytes(&out, line.text, ranges.items, if (odelim_given) odelim else null);
            } else if (!cutFields(&out, line.text, ranges.items, field_delim, odelim, only_delimited)) continue;
            out.writeByte(line_delim);
            if (out.failed) break;
        }
        if (out.failed) break;
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return status;
}

fn setList(ctx: cli.Context, mode: *Mode, text: *?[]const u8, want: Mode, val: []const u8) bool {
    if (mode.* != .none and mode.* != want) {
        cli.warn(ctx, "only one list may be specified\nTry '{s} --help' for more information.", .{ctx.name});
        return false;
    }
    mode.* = want;
    text.* = val;
    return true;
}

fn setDelim(ctx: cli.Context, delim: *?u8, val: []const u8) bool {
    if (val.len > 1) {
        cli.warn(ctx, "the delimiter must be a single character\nTry '{s} --help' for more information.", .{ctx.name});
        return false;
    }
    delim.* = if (val.len == 0) 0 else val[0];
    return true;
}

/// Parse `1,3-5,-2,4-` (commas or blanks as separators) into sorted,
/// merged ranges. Messages follow GNU cut.
fn parseList(ctx: cli.Context, text: []const u8, fields: bool) ?std.ArrayList(Range) {
    var list: std.ArrayList(Range) = .empty;
    var it = std.mem.splitAny(u8, text, ", \t");
    while (it.next()) |tok| {
        // GNU reports an empty element like position 0.
        if (tok.len == 0) return zeroPos(ctx, &list, fields);
        var lo: usize = 1;
        var hi: usize = max_pos;
        if (tok[0] == '-') {
            if (tok.len == 1) {
                cli.warn(ctx, "invalid range with no endpoint: -\nTry '{s} --help' for more information.", .{ctx.name});
                return fail(ctx, &list);
            }
            hi = parseNum(tok[1..]) orelse return badList(ctx, &list, tok[1..], fields);
            if (hi == 0) return decreasing(ctx, &list);
        } else if (std.mem.indexOfScalar(u8, tok, '-')) |d| {
            lo = parseNum(tok[0..d]) orelse return badList(ctx, &list, tok[0..d], fields);
            if (lo == 0) return zeroPos(ctx, &list, fields);
            if (d + 1 < tok.len) {
                hi = parseNum(tok[d + 1 ..]) orelse return badList(ctx, &list, tok[d + 1 ..], fields);
                if (hi < lo) return decreasing(ctx, &list);
            }
        } else {
            lo = parseNum(tok) orelse return badList(ctx, &list, tok, fields);
            if (lo == 0) return zeroPos(ctx, &list, fields);
            hi = lo;
        }
        list.append(ctx.gpa, .{ .lo = lo, .hi = hi }) catch return fail(ctx, &list);
    }
    // Sort by start and merge overlapping ranges.
    std.mem.sort(Range, list.items, {}, struct {
        fn lt(_: void, x: Range, y: Range) bool {
            return x.lo < y.lo;
        }
    }.lt);
    var w: usize = 0;
    for (list.items) |r| {
        if (w > 0 and r.lo <= list.items[w - 1].hi) {
            if (r.hi > list.items[w - 1].hi) list.items[w - 1].hi = r.hi;
        } else {
            list.items[w] = r;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
    return list;
}

fn fail(ctx: cli.Context, list: *std.ArrayList(Range)) ?std.ArrayList(Range) {
    list.deinit(ctx.gpa);
    return null;
}

fn zeroPos(ctx: cli.Context, list: *std.ArrayList(Range), fields: bool) ?std.ArrayList(Range) {
    cli.warn(ctx, "{s} are numbered from 1\nTry '{s} --help' for more information.", .{ if (fields) "fields" else "byte/character positions", ctx.name });
    return fail(ctx, list);
}

fn badList(ctx: cli.Context, list: *std.ArrayList(Range), tok: []const u8, fields: bool) ?std.ArrayList(Range) {
    if (fields) {
        cli.warn(ctx, "invalid field value '{s}'\nTry '{s} --help' for more information.", .{ tok, ctx.name });
    } else cli.warn(ctx, "invalid byte/character position '{s}'\nTry '{s} --help' for more information.", .{ tok, ctx.name });
    return fail(ctx, list);
}

fn decreasing(ctx: cli.Context, list: *std.ArrayList(Range)) ?std.ArrayList(Range) {
    cli.warn(ctx, "invalid decreasing range\nTry '{s} --help' for more information.", .{ctx.name});
    return fail(ctx, list);
}

/// Digits only; overflow saturates (GNU treats huge values as "to the end").
fn parseNum(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var v: usize = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v *| 10 +| (c - '0');
    }
    return v;
}

/// Replace `ranges` by the positions it does not cover.
fn invert(gpa: std.mem.Allocator, ranges: *std.ArrayList(Range)) !void {
    var out: std.ArrayList(Range) = .empty;
    errdefer out.deinit(gpa);
    var next: usize = 1;
    for (ranges.items) |r| {
        if (r.lo > next) try out.append(gpa, .{ .lo = next, .hi = r.lo - 1 });
        if (r.hi == max_pos) {
            next = max_pos;
            break;
        }
        next = r.hi + 1;
    }
    if (ranges.items.len == 0 or ranges.items[ranges.items.len - 1].hi != max_pos) try out.append(gpa, .{ .lo = next, .hi = max_pos });
    ranges.deinit(gpa);
    ranges.* = out;
}

/// Write the selected bytes of `line`; `between` goes between separate ranges.
fn cutBytes(out: *cli.Out, line: []const u8, ranges: []const Range, between: ?[]const u8) void {
    var printed_any = false;
    for (ranges) |r| {
        if (r.lo > line.len) break;
        const hi = @min(r.hi, line.len);
        if (printed_any) if (between) |b| out.write(b);
        out.write(line[r.lo - 1 .. hi]);
        printed_any = true;
    }
}

/// Write the selected fields. Returns false when the line is suppressed.
fn cutFields(out: *cli.Out, line: []const u8, ranges: []const Range, delim: u8, odelim: []const u8, only_delimited: bool) bool {
    if (std.mem.indexOfScalar(u8, line, delim) == null) {
        if (only_delimited) return false;
        out.write(line);
        return true;
    }
    var field: usize = 1;
    var start: usize = 0;
    var ri: usize = 0;
    var printed_any = false;
    while (true) {
        const end = std.mem.indexOfScalarPos(u8, line, start, delim) orelse line.len;
        while (ri < ranges.len and ranges[ri].hi < field) ri += 1;
        if (ri < ranges.len and ranges[ri].lo <= field) {
            if (printed_any) out.write(odelim);
            out.write(line[start..end]);
            printed_any = true;
        }
        if (end >= line.len) break;
        start = end + 1;
        field += 1;
        if (ri >= ranges.len) break;
    }
    return true;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: cut OPTION... [FILE]...\n" ++
        "Print selected parts of lines from each FILE to standard output.\n\n" ++
        "  -b, --bytes=LIST        select only these bytes\n" ++
        "  -c, --characters=LIST   select only these characters\n" ++
        "  -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter\n" ++
        "  -f, --fields=LIST       select only these fields; also print any line\n" ++
        "                            that contains no delimiter character, unless\n" ++
        "                            the -s option is specified\n" ++
        "  -n                      (ignored)\n" ++
        "      --complement        complement the set of selected bytes, characters\n" ++
        "                            or fields\n" ++
        "  -s, --only-delimited    do not print lines not containing delimiters\n" ++
        "      --output-delimiter=STRING  use STRING as the output delimiter\n" ++
        "                            the default is to use the input delimiter\n" ++
        "  -z, --zero-terminated   line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n\n" ++
        "Use one, and only one of -b, -c or -f.  Each LIST is made up of one\n" ++
        "range, or many ranges separated by commas.\n")) 0 else 1;
}

test "parseList-style merging via invert" {
    const t = std.testing;
    var r: std.ArrayList(Range) = .empty;
    defer r.deinit(t.allocator);
    try r.append(t.allocator, .{ .lo = 2, .hi = 3 });
    try r.append(t.allocator, .{ .lo = 6, .hi = max_pos });
    try invert(t.allocator, &r);
    try t.expectEqual(@as(usize, 2), r.items.len);
    try t.expectEqual(@as(usize, 1), r.items[0].lo);
    try t.expectEqual(@as(usize, 1), r.items[0].hi);
    try t.expectEqual(@as(usize, 4), r.items[1].lo);
    try t.expectEqual(@as(usize, 5), r.items[1].hi);
}
