// SPDX-License-Identifier: GPL-2.0-or-later
//! Tab stop lists for expand and unexpand.
//! References: GNU coreutils manual "expand invocation" / "unexpand
//! invocation" (9.7); POSIX.1-2024 expand and unexpand (-t tablist).
//!
//! A tablist is numbers separated by commas or blanks. One number N means
//! stops every N columns. Several numbers are explicit stops (strictly
//! ascending). GNU extensions: the last number may be prefixed with `/`
//! ("then every N columns") or `+` ("then every N columns after the last
//! stop"). Columns are numbered from 0.

const std = @import("std");

pub const Extend = enum { none, multiple, offset };

pub const Stops = struct {
    /// Explicit stops, ascending. Empty with `every` set means a plain step.
    list: []const usize = &.{},
    /// Step after the explicit stops (or the only rule when `list` is empty).
    every: usize = 8,
    extend: Extend = .multiple,

    /// The first stop strictly after `col`, or null when `col` is beyond the
    /// last stop and the list does not repeat.
    pub fn next(s: Stops, col: usize) ?usize {
        if (s.list.len == 0) return col + s.every - col % s.every;
        for (s.list) |t| if (t > col) return t;
        if (s.every == 0) return null;
        return switch (s.extend) {
            .none => null,
            .multiple => col + s.every - col % s.every,
            .offset => blk: {
                const last = s.list[s.list.len - 1];
                break :blk last + ((col - last) / s.every + 1) * s.every;
            },
        };
    }
};

pub const ParseError = union(enum) {
    zero,
    not_ascending,
    invalid_chars: []const u8,
    slash_not_last,
    plus_not_last,
    slash_not_at_start: []const u8,
    plus_not_at_start: []const u8,
    too_large: []const u8,
    oom,
};

/// Parse `text`. The list is allocated from `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, err: *ParseError) ?Stops {
    var list: std.ArrayList(usize) = .empty;
    var extend: Extend = .none;
    var extend_size: usize = 0;
    var i: usize = 0;
    var seen_extend = false;
    while (i < text.len) {
        const c = text[i];
        if (c == ',' or c == ' ' or c == '\t') {
            i += 1;
            continue;
        }
        var spec: u8 = 0;
        const start = i;
        if (c == '/' or c == '+') {
            spec = c;
            i += 1;
        }
        const num_start = i;
        var v: usize = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            v = std.math.mul(usize, v, 10) catch {
                err.* = .{ .too_large = text[start..] };
                return null;
            };
            v = std.math.add(usize, v, text[i] - '0') catch {
                err.* = .{ .too_large = text[start..] };
                return null;
            };
        }
        if (i < text.len and text[i] != ',' and text[i] != ' ' and text[i] != '\t') {
            if (text[i] == '/' or text[i] == '+') {
                err.* = if (text[i] == '/') .{ .slash_not_at_start = text[i..] } else .{ .plus_not_at_start = text[i..] };
            } else err.* = .{ .invalid_chars = text[i..] };
            return null;
        }
        if (spec != 0) {
            if (seen_extend) {
                err.* = if (spec == '/') .slash_not_last else .plus_not_last;
                return null;
            }
            seen_extend = true;
            extend = if (spec == '/') .multiple else .offset;
            extend_size = if (i == num_start) 0 else v;
            // The specifier must belong to the last number.
            var j = i;
            while (j < text.len) : (j += 1) if (text[j] != ',' and text[j] != ' ' and text[j] != '\t') {
                err.* = if (spec == '/') .slash_not_last else .plus_not_last;
                return null;
            };
            if (i == num_start) continue; // "/" alone
            if (v == 0 and spec != '+') continue; // size 0: no extension
            continue;
        }
        if (v == 0) {
            err.* = .zero;
            return null;
        }
        if (list.items.len > 0 and v <= list.items[list.items.len - 1]) {
            err.* = .not_ascending;
            return null;
        }
        list.append(arena, v) catch {
            err.* = .oom;
            return null;
        };
    }
    if (list.items.len == 0 and !seen_extend) return .{}; // empty list: default stops
    if (list.items.len == 1 and !seen_extend) return .{ .every = list.items[0], .extend = .multiple };
    if (list.items.len == 0) return .{ .every = if (extend_size == 0) 8 else extend_size, .extend = .multiple };
    // GNU: a specifier with size 0 steps by the last explicit stop.
    if (seen_extend and extend_size == 0) extend_size = list.items[list.items.len - 1];
    return .{ .list = list.items, .every = extend_size, .extend = if (seen_extend) extend else .none };
}

test "next" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 8), (Stops{}).next(0));
    try t.expectEqual(@as(?usize, 16), (Stops{}).next(8));
    try t.expectEqual(@as(?usize, 12), (Stops{ .every = 4 }).next(9));
    const l = [_]usize{ 2, 4 };
    try t.expectEqual(@as(?usize, 2), (Stops{ .list = &l, .every = 0, .extend = .none }).next(0));
    try t.expectEqual(@as(?usize, null), (Stops{ .list = &l, .every = 0, .extend = .none }).next(4));
    try t.expectEqual(@as(?usize, 8), (Stops{ .list = &l, .every = 4, .extend = .multiple }).next(4) orelse 0);
    try t.expectEqual(@as(?usize, 5), (Stops{ .list = &[_]usize{1}, .every = 4, .extend = .offset }).next(1));
}

test "parse" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var err: ParseError = .zero;
    try t.expectEqual(@as(usize, 4), parse(arena, "4", &err).?.every);
    try t.expectEqual(@as(usize, 2), parse(arena, "2,4", &err).?.list.len);
    try t.expect(parse(arena, "0", &err) == null);
    try t.expect(err == .zero);
    try t.expect(parse(arena, "4,2", &err) == null);
    try t.expect(err == .not_ascending);
    try t.expect(parse(arena, "4,4", &err) == null);
    try t.expect(parse(arena, "x", &err) == null);
    try t.expect(err == .invalid_chars);
    try t.expectEqual(Extend.multiple, parse(arena, "2,/4", &err).?.extend);
    try t.expectEqual(Extend.offset, parse(arena, "1,+8", &err).?.extend);
}
