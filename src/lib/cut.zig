// SPDX-License-Identifier: GPL-2.0-or-later
//! cut library (decision 0004): select bytes, characters or fields from each
//! line. References: GNU coreutils manual "cut invocation" (9.7); POSIX.1-2024.
//!
//! Characters are bytes (C locale): the multibyte behaviour of UTF-8 locales
//! is not implemented. GNU extensions implemented: complement,
//! output delimiter, NUL-terminated lines.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const lines = @import("../lines.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

/// 1-based, inclusive; `hi == max_pos` means "to the end of the line".
pub const Range = struct { lo: usize, hi: usize };
pub const max_pos = std.math.maxInt(usize);

pub const Mode = enum { bytes, fields };

pub const Options = struct {
    mode: Mode = .fields,
    /// Sorted, merged ranges, as returned by `parseList`.
    ranges: []const Range = &.{},
    complement: bool = false,
    /// Input field delimiter (fields mode).
    delimiter: u8 = '\t',
    only_delimited: bool = false,
    /// Output delimiter; null: the input delimiter (fields) or none (bytes).
    /// An empty string is a single NUL byte, as in GNU.
    output_delimiter: ?[]const u8 = null,
    line_delimiter: u8 = '\n',
};

/// A problem with one input; the run continues with the next one.
pub const Event = struct {
    name: []const u8,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

/// Why a position list was rejected.
pub const ListProblem = union(enum) {
    /// `-` alone.
    no_endpoint,
    /// A position 0 or an empty element.
    zero_position,
    /// Not a number; the offending text.
    bad_value: []const u8,
    decreasing,
};

pub const ListError = error{ InvalidList, OutOfMemory };

/// Parse `1,3-5,-2,4-` (commas or blanks as separators) into sorted, merged
/// ranges owned by the caller. On `InvalidList`, `problem` says why.
pub fn parseList(gpa: std.mem.Allocator, text: []const u8, problem: *ListProblem) ListError![]Range {
    var list: std.ArrayList(Range) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitAny(u8, text, ", \t");
    while (it.next()) |tok| {
        // GNU reports an empty element like position 0.
        if (tok.len == 0) {
            problem.* = .zero_position;
            return error.InvalidList;
        }
        var lo: usize = 1;
        var hi: usize = max_pos;
        if (tok[0] == '-') {
            if (tok.len == 1) {
                problem.* = .no_endpoint;
                return error.InvalidList;
            }
            hi = parseNum(tok[1..]) orelse {
                problem.* = .{ .bad_value = tok[1..] };
                return error.InvalidList;
            };
            if (hi == 0) {
                problem.* = .decreasing;
                return error.InvalidList;
            }
        } else if (std.mem.indexOfScalar(u8, tok, '-')) |d| {
            lo = parseNum(tok[0..d]) orelse {
                problem.* = .{ .bad_value = tok[0..d] };
                return error.InvalidList;
            };
            if (lo == 0) {
                problem.* = .zero_position;
                return error.InvalidList;
            }
            if (d + 1 < tok.len) {
                hi = parseNum(tok[d + 1 ..]) orelse {
                    problem.* = .{ .bad_value = tok[d + 1 ..] };
                    return error.InvalidList;
                };
                if (hi < lo) {
                    problem.* = .decreasing;
                    return error.InvalidList;
                }
            }
        } else {
            lo = parseNum(tok) orelse {
                problem.* = .{ .bad_value = tok };
                return error.InvalidList;
            };
            if (lo == 0) {
                problem.* = .zero_position;
                return error.InvalidList;
            }
            hi = lo;
        }
        try list.append(gpa, .{ .lo = lo, .hi = hi });
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
    return list.toOwnedSlice(gpa);
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

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(env.gpa);
    try ranges.appendSlice(env.gpa, options.ranges);
    if (options.complement) try invert(env.gpa, &ranges);

    const field_delim = options.delimiter;
    const odelim: []const u8 = if (options.output_delimiter) |o| (if (o.len == 0) "\x00" else o) else &[_]u8{field_delim};
    const odelim_given = options.output_delimiter != null;

    var out = stickyout.Out.init(writer);
    var result: Result = .{};
    for (inputs) |in| {
        const name = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            observer.emit(.{ .name = name, .err = e });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        var reader = lines.LineReader.init(env.gpa, env.io, opened.file, options.line_delimiter);
        defer reader.deinit();
        while (reader.next() catch |e| {
            out.flush();
            observer.emit(.{ .name = name, .err = e });
            result.failed = true;
            break;
        }) |line| {
            if (options.mode == .bytes) {
                cutBytes(&out, line.text, ranges.items, if (odelim_given) odelim else null);
            } else if (!cutFields(&out, line.text, ranges.items, field_delim, odelim, options.only_delimited)) continue;
            out.writeByte(options.line_delimiter);
            if (out.failed) break;
        }
        if (out.failed) break;
    }
    try out.finish();
    return result;
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
fn cutBytes(out: *stickyout.Out, line: []const u8, ranges: []const Range, between: ?[]const u8) void {
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
fn cutFields(out: *stickyout.Out, line: []const u8, ranges: []const Range, delim: u8, odelim: []const u8, only_delimited: bool) bool {
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

test "invert complements merged ranges" {
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

test "parseList sorts and merges" {
    const t = std.testing;
    var problem: ListProblem = undefined;
    const r = try parseList(t.allocator, "5-7,1,2-3,6-", &problem);
    defer t.allocator.free(r);
    try t.expectEqual(@as(usize, 3), r.len);
    try t.expectEqual(@as(usize, 1), r[0].hi);
    try t.expectEqual(@as(usize, 2), r[1].lo);
    try t.expectEqual(@as(usize, 5), r[2].lo);
    try t.expectEqual(max_pos, r[2].hi);
    try t.expectError(error.InvalidList, parseList(t.allocator, "3-1", &problem));
    try t.expect(problem == .decreasing);
}
