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
    var cutter: Cutter = .{
        .options = &options,
        .ranges = ranges.items,
        .between = if (odelim_given) odelim else null,
        .odelim = odelim,
        .out = &out,
    };
    defer cutter.held.deinit(env.gpa);
    var buf: [65536]u8 = undefined;
    for (inputs) |in| {
        const name = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            observer.emit(.{ .name = name, .err = e });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        cutter.startLine();
        while (true) {
            const n = common.readChunk(env.io, opened.file, &buf) catch |e| {
                out.flush();
                observer.emit(.{ .name = name, .err = e });
                result.failed = true;
                break;
            };
            if (n == 0) break;
            try cutter.feed(env.gpa, buf[0..n]);
            if (out.failed) break;
        }
        cutter.endInput();
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

/// Cuts lines as their pieces arrive, so that a line of any length takes no
/// memory. The one thing held is a first field that may or may not be printed,
/// until the line shows whether it has a delimiter (as in GNU).
const Cutter = struct {
    options: *const Options,
    ranges: []const Range,
    /// Bytes mode: what goes between separate ranges.
    between: ?[]const u8,
    /// Fields mode: what goes between printed fields.
    odelim: []const u8,
    out: *stickyout.Out,

    /// The current line has had some bytes.
    started: bool = false,
    /// Bytes mode: bytes of the line seen so far.
    pos: usize = 0,
    /// The first range that may still select something in this line.
    ri: usize = 0,
    printed_any: bool = false,
    /// Fields mode: the number of the current field.
    field: usize = 1,
    held: std.ArrayList(u8) = .empty,

    fn startLine(c: *Cutter) void {
        c.started = false;
        c.pos = 0;
        c.ri = 0;
        c.printed_any = false;
        c.field = 1;
        c.held.clearRetainingCapacity();
    }

    fn feed(c: *Cutter, gpa: std.mem.Allocator, chunk: []const u8) error{OutOfMemory}!void {
        var rest = chunk;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, c.options.line_delimiter);
            const piece = rest[0 .. nl orelse rest.len];
            c.started = true;
            if (c.options.mode == .bytes) c.bytes(piece) else try c.fields(gpa, piece);
            if (nl == null) return;
            c.endLine();
            if (c.out.failed) return;
            rest = rest[piece.len + 1 ..];
        }
    }

    /// An input that does not end with the line delimiter still has a last line.
    fn endInput(c: *Cutter) void {
        if (c.started) c.endLine();
    }

    fn endLine(c: *Cutter) void {
        defer c.startLine();
        if (c.options.mode == .fields and c.field == 1) {
            // No delimiter in the line: all of it is printed, or none.
            if (c.options.only_delimited) return;
            c.out.write(c.held.items);
        }
        c.out.writeByte(c.options.line_delimiter);
    }

    fn bytes(c: *Cutter, piece: []const u8) void {
        const first = c.pos + 1;
        const last = c.pos + piece.len;
        c.pos = last;
        while (c.ri < c.ranges.len and c.ranges[c.ri].lo <= last) {
            const r = c.ranges[c.ri];
            const lo = @max(r.lo, first);
            const hi = @min(r.hi, last);
            if (lo == r.lo and c.printed_any) if (c.between) |b| c.out.write(b);
            if (hi >= lo) {
                c.out.write(piece[lo - first .. hi - first + 1]);
                c.printed_any = true;
            }
            if (r.hi > last) break;
            c.ri += 1;
        }
    }

    fn selected(c: *Cutter) bool {
        while (c.ri < c.ranges.len and c.ranges[c.ri].hi < c.field) c.ri += 1;
        return c.ri < c.ranges.len and c.ranges[c.ri].lo <= c.field;
    }

    fn fields(c: *Cutter, gpa: std.mem.Allocator, piece: []const u8) error{OutOfMemory}!void {
        var rest = piece;
        while (true) {
            const end = std.mem.indexOfScalar(u8, rest, c.options.delimiter);
            const part = rest[0 .. end orelse rest.len];
            if (c.field == 1) {
                // Printed whatever follows, when it is selected and
                // undelimited lines are not suppressed.
                if (c.selected() and !c.options.only_delimited) c.out.write(part) else try c.held.appendSlice(gpa, part);
            } else if (c.selected()) c.out.write(part);
            if (end == null) return;
            if (c.field == 1) {
                if (c.selected()) {
                    c.out.write(c.held.items); // empty unless it had to wait
                    c.printed_any = true;
                }
                c.held.clearRetainingCapacity();
            }
            c.field += 1;
            if (c.selected()) {
                if (c.printed_any) c.out.write(c.odelim);
                c.printed_any = true;
            }
            rest = rest[part.len + 1 ..];
        }
    }
};

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
