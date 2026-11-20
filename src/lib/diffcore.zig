// SPDX-License-Identifier: GPL-2.0-or-later
//! Comparison engine shared by diff, diff3 and sdiff (decision 0004): two
//! sequences of lines in, an edit script out.
//! References: Eugene W. Myers, "An O(ND) Difference Algorithm and Its
//! Variations" (1986); GNU diffutils 3.12 behaviour (observed, not copied):
//! lines that match nothing in the other file are discarded before the main
//! pass, the pass stops early on very large inputs ("too expensive"), and
//! runs of changes are slid to where they merge with their neighbours, so
//! that the script agrees with GNU diff's, not merely with a minimal one.
//!
//! Everything is bounded: the work is O((N+M)·D) with the usual cut-off, no
//! recursion is used and nothing reads process state, so arbitrary bytes are
//! safe input (decision 0007).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A text split into lines. `starts` has `count + 1` entries; line `i` is
/// `data[starts[i]..starts[i + 1]]` and includes its '\n' unless it is the
/// last line of a text that does not end in one.
pub const Lines = struct {
    data: []const u8,
    starts: []const usize,

    pub fn count(l: Lines) usize {
        return l.starts.len - 1;
    }

    /// Line `i` with its terminator, if it has one.
    pub fn raw(l: Lines, i: usize) []const u8 {
        return l.data[l.starts[i]..l.starts[i + 1]];
    }

    pub fn terminated(l: Lines, i: usize) bool {
        const r = l.raw(i);
        return r.len > 0 and r[r.len - 1] == '\n';
    }

    /// Line `i` without its terminator.
    pub fn body(l: Lines, i: usize) []const u8 {
        const r = l.raw(i);
        return if (r.len > 0 and r[r.len - 1] == '\n') r[0 .. r.len - 1] else r;
    }

    pub fn deinit(l: Lines, gpa: Allocator) void {
        gpa.free(l.starts);
    }
};

/// Split `data` at '\n'. The result borrows `data`.
pub fn splitLines(gpa: Allocator, data: []const u8) !Lines {
    var n: usize = 0;
    for (data) |c| {
        if (c == '\n') n += 1;
    }
    const last_partial = data.len > 0 and data[data.len - 1] != '\n';
    const total = n + @intFromBool(last_partial);
    const starts = try gpa.alloc(usize, total + 1);
    errdefer gpa.free(starts);
    var k: usize = 0;
    starts[0] = 0;
    for (data, 0..) |c, i| {
        if (c == '\n') {
            k += 1;
            starts[k] = i + 1;
        }
    }
    if (last_partial) starts[total] = data.len;
    return .{ .data = data, .starts = starts };
}

/// `--strip-trailing-cr`: remove a carriage return that precedes a newline.
/// Returns a new buffer owned by the caller.
pub fn stripCr(gpa: Allocator, data: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, data.len);
    var n: usize = 0;
    for (data, 0..) |c, i| {
        if (c == '\r' and i + 1 < data.len and data[i + 1] == '\n') continue;
        out[n] = c;
        n += 1;
    }
    return gpa.realloc(out, n) catch out[0..n];
}

/// How lines are compared.
pub const Flags = struct {
    /// -i
    ignore_case: bool = false,
    /// -E
    ignore_tab_expansion: bool = false,
    /// -Z
    ignore_trailing_space: bool = false,
    /// -b
    ignore_space_change: bool = false,
    /// -w
    ignore_all_space: bool = false,
    /// -d: look harder for a smaller script.
    minimal: bool = false,
    /// --speed-large-files
    speed_large_files: bool = false,
    /// --horizon-lines (at least the context size in the output styles).
    horizon_lines: usize = 0,

    fn anyIgnore(f: Flags) bool {
        return f.ignore_case or f.ignore_tab_expansion or f.ignore_trailing_space or f.ignore_space_change or f.ignore_all_space;
    }
};

/// A run of lines removed from the first sequence and/or added in the
/// second. All numbers are 0-based; `line0`/`line1` are the positions of the
/// first deleted/inserted line (or where it would be).
pub const Edit = struct {
    line0: usize,
    line1: usize,
    deleted: usize,
    inserted: usize,
};

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= 9 and c <= 13);
}

/// The comparison key of a line: two lines are equal under `flags` exactly
/// when their keys are equal bytes.
pub fn canonical(gpa: Allocator, out: *std.ArrayList(u8), l: Lines, i: usize, flags: Flags) ![]const u8 {
    if (!flags.anyIgnore()) return l.raw(i);
    out.clearRetainingCapacity();
    const bodyv = l.body(i);
    var col: usize = 0;
    if (flags.ignore_tab_expansion) {
        for (bodyv) |c| {
            if (c == '\t') {
                const n = 8 - col % 8;
                try out.appendNTimes(gpa, ' ', n);
                col += n;
            } else {
                try out.append(gpa, c);
                if (c == '\x08') {
                    if (col > 0) col -= 1;
                } else if (c == '\r') col = 0 else col += 1;
            }
        }
    } else try out.appendSlice(gpa, bodyv);
    if (flags.ignore_case) for (out.items) |*c| {
        c.* = std.ascii.toLower(c.*);
    };
    if (flags.ignore_all_space) {
        var w: usize = 0;
        for (out.items) |c| {
            if (!isSpace(c)) {
                out.items[w] = c;
                w += 1;
            }
        }
        out.shrinkRetainingCapacity(w);
    } else if (flags.ignore_space_change) {
        var w: usize = 0;
        var r: usize = 0;
        while (r < out.items.len) {
            if (isSpace(out.items[r])) {
                while (r < out.items.len and isSpace(out.items[r])) r += 1;
                if (r < out.items.len) {
                    out.items[w] = ' ';
                    w += 1;
                }
            } else {
                out.items[w] = out.items[r];
                w += 1;
                r += 1;
            }
        }
        out.shrinkRetainingCapacity(w);
    } else if (flags.ignore_trailing_space) {
        var n = out.items.len;
        while (n > 0 and isSpace(out.items[n - 1])) n -= 1;
        out.shrinkRetainingCapacity(n);
    } else if (l.terminated(i)) try out.append(gpa, '\n');
    return out.items;
}

/// Whether two lines are equal under `flags`.
pub fn linesEqual(gpa: Allocator, a: Lines, i: usize, b: Lines, j: usize, flags: Flags) !bool {
    var b0: std.ArrayList(u8) = .empty;
    defer b0.deinit(gpa);
    var b1: std.ArrayList(u8) = .empty;
    defer b1.deinit(gpa);
    return std.mem.eql(u8, try canonical(gpa, &b0, a, i, flags), try canonical(gpa, &b1, b, j, flags));
}

const SNAKE_LIMIT = 20;

const Part = struct { xmid: isize, ymid: isize, lo_minimal: bool, hi_minimal: bool };

const Ctx = struct {
    xv: []const u32,
    yv: []const u32,
    fd: []isize, // indexed d + foff
    bd: []isize,
    off: isize,
    heuristic: bool,
    too_expensive: isize,
    changed0: []u8, // flags per undiscarded index mapped through real0
    changed1: []u8,
    real0: []const usize,
    real1: []const usize,

    inline fn f(c: *Ctx, d: isize) *isize {
        return @ptrCast(c.fd.ptr + @as(usize, @bitCast(d + c.off)));
    }
    inline fn b(c: *Ctx, d: isize) *isize {
        return @ptrCast(c.bd.ptr + @as(usize, @bitCast(d + c.off)));
    }
    inline fn eq(c: *const Ctx, x: isize, y: isize) bool {
        return c.xv.ptr[@as(usize, @bitCast(x))] == c.yv.ptr[@as(usize, @bitCast(y))];
    }
};

fn diag(c: *Ctx, xoff: isize, xlim: isize, yoff: isize, ylim: isize, find_minimal: bool) Part {
    // The hot loop of the whole engine: every index is bounded by the
    // algorithm (diagonals within [dmin, dmax], x and y within the limits),
    // so the checks are switched off here and only here.
    @setRuntimeSafety(false);
    const dmin = xoff - ylim;
    const dmax = xlim - yoff;
    const fmid = xoff - yoff;
    const bmid = xlim - ylim;
    var fmin = fmid;
    var fmax = fmid;
    var bmin = bmid;
    var bmax = bmid;
    const odd = @mod(fmid - bmid, 2) != 0;
    var part: Part = undefined;

    c.f(fmid).* = xoff;
    c.b(bmid).* = xlim;

    var cost: isize = 1;
    while (true) : (cost += 1) {
        var big_snake = false;

        // Extend the top-down search by an edit step in each diagonal.
        if (fmin > dmin) {
            fmin -= 1;
            c.f(fmin - 1).* = -1;
        } else fmin += 1;
        if (fmax < dmax) {
            fmax += 1;
            c.f(fmax + 1).* = -1;
        } else fmax -= 1;
        var d = fmax;
        while (d >= fmin) : (d -= 2) {
            const tlo = c.f(d - 1).*;
            const thi = c.f(d + 1).*;
            const x0 = if (tlo < thi) thi else tlo + 1;
            var x = x0;
            var y = x0 - d;
            while (x < xlim and y < ylim and c.eq(x, y)) {
                x += 1;
                y += 1;
            }
            if (x - x0 > SNAKE_LIMIT) big_snake = true;
            c.f(d).* = x;
            if (odd and bmin <= d and d <= bmax and c.b(d).* <= x) {
                return .{ .xmid = x, .ymid = y, .lo_minimal = true, .hi_minimal = true };
            }
        }

        // Similarly extend the bottom-up search.
        if (bmin > dmin) {
            bmin -= 1;
            c.b(bmin - 1).* = std.math.maxInt(isize);
        } else bmin += 1;
        if (bmax < dmax) {
            bmax += 1;
            c.b(bmax + 1).* = std.math.maxInt(isize);
        } else bmax -= 1;
        d = bmax;
        while (d >= bmin) : (d -= 2) {
            const tlo = c.b(d - 1).*;
            const thi = c.b(d + 1).*;
            const x0 = if (tlo < thi) tlo else thi - 1;
            var x = x0;
            var y = x0 - d;
            while (xoff < x and yoff < y and c.eq(x - 1, y - 1)) {
                x -= 1;
                y -= 1;
            }
            if (x0 - x > SNAKE_LIMIT) big_snake = true;
            c.b(d).* = x;
            if (!odd and fmin <= d and d <= fmax and x <= c.f(d).*) {
                return .{ .xmid = x, .ymid = y, .lo_minimal = true, .hi_minimal = true };
            }
        }

        if (find_minimal) continue;

        if (200 < cost and big_snake and c.heuristic) {
            {
                var best: isize = 0;
                d = fmax;
                while (d >= fmin) : (d -= 2) {
                    const dd = d - fmid;
                    const x = c.f(d).*;
                    const y = x - d;
                    const v = (x - xoff) * 2 - dd;
                    if (v > 12 * (cost + (if (dd < 0) -dd else dd))) {
                        if (v > best and xoff + SNAKE_LIMIT <= x and x < xlim and yoff + SNAKE_LIMIT <= y and y < ylim) {
                            var k: isize = 1;
                            while (c.eq(x - k, y - k)) : (k += 1) {
                                if (k == SNAKE_LIMIT) {
                                    best = v;
                                    part.xmid = x;
                                    part.ymid = y;
                                    break;
                                }
                            }
                        }
                    }
                }
                if (best > 0) {
                    part.lo_minimal = true;
                    part.hi_minimal = false;
                    return part;
                }
            }
            {
                var best: isize = 0;
                d = bmax;
                while (d >= bmin) : (d -= 2) {
                    const dd = d - bmid;
                    const x = c.b(d).*;
                    const y = x - d;
                    const v = (xlim - x) * 2 + dd;
                    if (v > 12 * (cost + (if (dd < 0) -dd else dd))) {
                        if (v > best and xoff < x and x <= xlim - SNAKE_LIMIT and yoff < y and y <= ylim - SNAKE_LIMIT) {
                            var k: isize = 0;
                            while (c.eq(x + k, y + k)) : (k += 1) {
                                if (k == SNAKE_LIMIT - 1) {
                                    best = v;
                                    part.xmid = x;
                                    part.ymid = y;
                                    break;
                                }
                            }
                        }
                    }
                }
                if (best > 0) {
                    part.lo_minimal = false;
                    part.hi_minimal = true;
                    return part;
                }
            }
        }

        // Give up and report halfway between the best results so far.
        if (cost >= c.too_expensive) {
            var fxybest: isize = -1;
            var fxbest: isize = 0;
            d = fmax;
            while (d >= fmin) : (d -= 2) {
                var x = @min(c.f(d).*, xlim);
                var y = x - d;
                if (ylim < y) {
                    x = ylim + d;
                    y = ylim;
                }
                if (fxybest < x + y) {
                    fxybest = x + y;
                    fxbest = x;
                }
            }
            var bxybest: isize = std.math.maxInt(isize);
            var bxbest: isize = 0;
            d = bmax;
            while (d >= bmin) : (d -= 2) {
                var x = @max(xoff, c.b(d).*);
                var y = x - d;
                if (y < yoff) {
                    x = yoff + d;
                    y = yoff;
                }
                if (x + y < bxybest) {
                    bxybest = x + y;
                    bxbest = x;
                }
            }
            if ((xlim + ylim) - bxybest < fxybest - (xoff + yoff)) {
                return .{ .xmid = fxbest, .ymid = fxybest - fxbest, .lo_minimal = true, .hi_minimal = false };
            } else {
                return .{ .xmid = bxbest, .ymid = bxybest - bxbest, .lo_minimal = false, .hi_minimal = true };
            }
        }
    }
}

const Task = struct { xoff: isize, xlim: isize, yoff: isize, ylim: isize, minimal: bool };

fn compareseq(gpa: Allocator, c: *Ctx, n0: usize, n1: usize, minimal: bool) !void {
    var stack: std.ArrayList(Task) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .xoff = 0, .xlim = @intCast(n0), .yoff = 0, .ylim = @intCast(n1), .minimal = minimal });
    while (stack.pop()) |t| {
        var xoff = t.xoff;
        var xlim = t.xlim;
        var yoff = t.yoff;
        var ylim = t.ylim;
        while (xoff < xlim and yoff < ylim and c.eq(xoff, yoff)) {
            xoff += 1;
            yoff += 1;
        }
        while (xoff < xlim and yoff < ylim and c.eq(xlim - 1, ylim - 1)) {
            xlim -= 1;
            ylim -= 1;
        }
        if (xoff == xlim) {
            while (yoff < ylim) : (yoff += 1) c.changed1[c.real1[@intCast(yoff)]] = 1;
        } else if (yoff == ylim) {
            while (xoff < xlim) : (xoff += 1) c.changed0[c.real0[@intCast(xoff)]] = 1;
        } else {
            const part = diag(c, xoff, xlim, yoff, ylim, t.minimal);
            try stack.append(gpa, .{ .xoff = part.xmid, .xlim = xlim, .yoff = part.ymid, .ylim = ylim, .minimal = part.hi_minimal });
            try stack.append(gpa, .{ .xoff = xoff, .xlim = part.xmid, .yoff = yoff, .ylim = part.ymid, .minimal = part.lo_minimal });
        }
    }
}

/// Mark lines that should not take part in the main pass. `discards` is 1
/// for a line that matches nothing, 2 for a provisional discard.
fn discardConfusing(gpa: Allocator, equivs: []const u32, counts_other: []const u32, discards: []u8) void {
    _ = gpa;
    const end = equivs.len;
    var many: usize = 5;
    var tem: usize = end / 64;
    while (true) {
        tem >>= 2;
        if (tem == 0) break;
        many *= 2;
    }
    for (equivs, 0..) |e, i| {
        discards[i] = 0;
        if (e == 0) continue;
        const nmatch = counts_other[e];
        if (nmatch == 0) discards[i] = 1 else if (nmatch > many) discards[i] = 2;
    }

    var i: usize = 0;
    while (i < end) : (i += 1) {
        if (discards[i] == 2) {
            discards[i] = 0;
        } else if (discards[i] != 0) {
            var j: usize = i;
            var provisional: usize = 0;
            while (j < end) : (j += 1) {
                if (discards[j] == 0) break;
                if (discards[j] == 2) provisional += 1;
            }
            while (j > i and discards[j - 1] == 2) {
                j -= 1;
                discards[j] = 0;
                provisional -= 1;
            }
            const length = j - i;
            if (provisional * 4 > length) {
                while (j > i) {
                    j -= 1;
                    if (discards[j] == 2) discards[j] = 0;
                }
            } else {
                var minimum: usize = 1;
                var t: usize = length >> 2;
                while (true) {
                    t >>= 2;
                    if (t == 0) break;
                    minimum <<= 1;
                }
                minimum += 1;
                // Cancel any subrun of `minimum` or more provisionals.
                var consec: usize = 0;
                var jj: isize = 0;
                while (jj < @as(isize, @intCast(length))) : (jj += 1) {
                    const idx = i + @as(usize, @intCast(jj));
                    if (discards[idx] != 2) {
                        consec = 0;
                    } else {
                        consec += 1;
                        if (minimum == consec) {
                            jj -= @intCast(consec);
                        } else if (minimum < consec) discards[idx] = 0;
                    }
                }
                // From the beginning: cancel provisionals until 3
                // non-provisionals in a row or the first one 8 lines in.
                consec = 0;
                var j2: usize = 0;
                while (j2 < length) : (j2 += 1) {
                    if (j2 >= 8 and discards[i + j2] == 1) break;
                    if (discards[i + j2] == 2) {
                        consec = 0;
                        discards[i + j2] = 0;
                    } else if (discards[i + j2] == 0) consec = 0 else consec += 1;
                    if (consec == 3) break;
                }
                i += length - 1;
                consec = 0;
                j2 = 0;
                while (j2 < length) : (j2 += 1) {
                    if (j2 >= 8 and discards[i - j2] == 1) break;
                    if (discards[i - j2] == 2) {
                        consec = 0;
                        discards[i - j2] = 0;
                    } else if (discards[i - j2] == 0) consec = 0 else consec += 1;
                    if (consec == 3) break;
                }
            }
        }
    }
}

/// Slide each run of changes up or down where that does not change the
/// result, so runs merge with neighbours, as GNU diff does. `changed` and
/// `other` carry one extra element in front (index 0 is the sentinel).
fn shiftBoundaries(equivs: []const u32, changed_p: []u8, other_p: []u8) void {
    const i_end: isize = @intCast(equivs.len);
    // Arrays are accessed with an offset of one.
    const ch = struct {
        fn at(a: []u8, i: isize) *u8 {
            return &a[@intCast(i + 1)];
        }
    };
    var i: isize = 0;
    var j: isize = 0;
    while (true) {
        while (i < i_end and ch.at(changed_p, i).* == 0) {
            while (true) {
                const v = ch.at(other_p, j).*;
                j += 1;
                if (v == 0) break;
            }
            i += 1;
        }
        if (i == i_end) break;
        var start = i;
        i += 1;
        while (ch.at(changed_p, i).* != 0) i += 1;
        while (ch.at(other_p, j).* != 0) j += 1;

        var runlength: isize = undefined;
        var corresponding: isize = undefined;
        while (true) {
            runlength = i - start;
            while (start != 0 and equivs[@intCast(start - 1)] == equivs[@intCast(i - 1)]) {
                start -= 1;
                ch.at(changed_p, start).* = 1;
                i -= 1;
                ch.at(changed_p, i).* = 0;
                while (ch.at(changed_p, start - 1).* != 0) start -= 1;
                while (true) {
                    j -= 1;
                    if (ch.at(other_p, j).* == 0) break;
                }
            }
            corresponding = if (ch.at(other_p, j - 1).* != 0) i else i_end;
            while (i != i_end and equivs[@intCast(start)] == equivs[@intCast(i)]) {
                ch.at(changed_p, start).* = 0;
                start += 1;
                ch.at(changed_p, i).* = 1;
                i += 1;
                while (ch.at(changed_p, i).* != 0) i += 1;
                while (true) {
                    j += 1;
                    if (ch.at(other_p, j).* == 0) break;
                    corresponding = i;
                }
            }
            if (runlength == i - start) break;
        }
        while (corresponding < i) {
            start -= 1;
            ch.at(changed_p, start).* = 1;
            i -= 1;
            ch.at(changed_p, i).* = 0;
            while (true) {
                j -= 1;
                if (ch.at(other_p, j).* == 0) break;
            }
        }
    }
}

/// Compare `a` and `b` and return the edit script, in order of position.
/// `Edit` positions are line indexes into `a` and `b`. The caller frees the
/// slice.
pub fn compare(gpa: Allocator, a: Lines, b: Lines, flags: Flags) ![]Edit {
    const n0 = a.count();
    const n1 = b.count();

    // Identical beginning and end (compared as bytes, as GNU does), minus
    // `horizon_lines` lines that stay in the main pass.
    const minn = @min(n0, n1);
    var prefix_full: usize = 0;
    while (prefix_full < minn and std.mem.eql(u8, a.raw(prefix_full), b.raw(prefix_full))) prefix_full += 1;
    const prefix: usize = prefix_full -| flags.horizon_lines;
    var suffix_full: usize = 0;
    while (suffix_full < minn - prefix and std.mem.eql(u8, a.raw(n0 - 1 - suffix_full), b.raw(n1 - 1 - suffix_full))) suffix_full += 1;
    // A missing newline at the end of only one file makes the last lines
    // differ already as bytes, so no special case is needed here.
    const suffix: usize = suffix_full -| flags.horizon_lines;

    const m0 = n0 - prefix - suffix;
    const m1 = n1 - prefix - suffix;

    var edits: std.ArrayList(Edit) = .empty;
    errdefer edits.deinit(gpa);
    if (m0 == 0 and m1 == 0) return edits.toOwnedSlice(gpa);

    // Equivalence classes of the lines that remain.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var map = std.StringHashMap(u32).init(gpa);
    defer map.deinit();
    const eq0 = try gpa.alloc(u32, m0);
    defer gpa.free(eq0);
    const eq1 = try gpa.alloc(u32, m1);
    defer gpa.free(eq1);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var next_class: u32 = 1;
    const plain = !flags.anyIgnore();
    for ([_]struct { l: Lines, eq: []u32, base: usize }{ .{ .l = a, .eq = eq0, .base = prefix }, .{ .l = b, .eq = eq1, .base = prefix } }) |side| {
        for (side.eq, 0..) |*slot, k| {
            const key = try canonical(gpa, &scratch, side.l, side.base + k, flags);
            const gop = try map.getOrPut(key);
            if (!gop.found_existing) {
                if (!plain) gop.key_ptr.* = try arena.dupe(u8, key);
                gop.value_ptr.* = next_class;
                next_class += 1;
            }
            slot.* = gop.value_ptr.*;
        }
    }

    const counts = try gpa.alloc(u32, 2 * @as(usize, next_class));
    defer gpa.free(counts);
    @memset(counts, 0);
    const cnt0 = counts[0..next_class];
    const cnt1 = counts[next_class..];
    for (eq0) |e| cnt0[e] += 1;
    for (eq1) |e| cnt1[e] += 1;

    const flags_store = try gpa.alloc(u8, m0 + m1 + 4);
    defer gpa.free(flags_store);
    @memset(flags_store, 0);
    const changed0 = flags_store[0 .. m0 + 2]; // [0] and [m0+1] are sentinels
    const changed1 = flags_store[m0 + 2 ..];

    const disc0 = try gpa.alloc(u8, m0);
    defer gpa.free(disc0);
    const disc1 = try gpa.alloc(u8, m1);
    defer gpa.free(disc1);
    if (flags.minimal) {
        @memset(disc0, 0);
        @memset(disc1, 0);
    } else {
        discardConfusing(gpa, eq0, cnt1, disc0);
        discardConfusing(gpa, eq1, cnt0, disc1);
    }

    const undisc0 = try gpa.alloc(u32, m0);
    defer gpa.free(undisc0);
    const undisc1 = try gpa.alloc(u32, m1);
    defer gpa.free(undisc1);
    const real0 = try gpa.alloc(usize, m0);
    defer gpa.free(real0);
    const real1 = try gpa.alloc(usize, m1);
    defer gpa.free(real1);
    var k0: usize = 0;
    for (eq0, 0..) |e, i| {
        if (disc0[i] == 0) {
            undisc0[k0] = e;
            real0[k0] = i + 1; // +1: the flag arrays have a leading sentinel
            k0 += 1;
        } else changed0[i + 1] = 1;
    }
    var k1: usize = 0;
    for (eq1, 0..) |e, i| {
        if (disc1[i] == 0) {
            undisc1[k1] = e;
            real1[k1] = i + 1;
            k1 += 1;
        } else changed1[i + 1] = 1;
    }

    const diags = k0 + k1 + 3;
    const fd = try gpa.alloc(isize, diags * 2);
    defer gpa.free(fd);
    var too_expensive: isize = 1;
    var dd = diags;
    while (dd > 0) : (dd >>= 2) too_expensive <<= 1;
    too_expensive = @max(4096, too_expensive);
    var ctx: Ctx = .{
        .xv = undisc0[0..k0],
        .yv = undisc1[0..k1],
        .fd = fd[0..diags],
        .bd = fd[diags..],
        .off = @intCast(k1 + 1),
        .heuristic = flags.speed_large_files,
        .too_expensive = too_expensive,
        .changed0 = changed0,
        .changed1 = changed1,
        .real0 = real0[0..k0],
        .real1 = real1[0..k1],
    };
    try compareseq(gpa, &ctx, k0, k1, flags.minimal);

    shiftBoundaries(eq0, changed0, changed1);
    shiftBoundaries(eq1, changed1, changed0);

    // Build the script.
    var p0: usize = 0;
    var p1: usize = 0;
    while (p0 < m0 or p1 < m1) {
        const c0 = if (p0 < m0) changed0[p0 + 1] != 0 else false;
        const c1 = if (p1 < m1) changed1[p1 + 1] != 0 else false;
        if (c0 or c1) {
            const l0 = p0;
            const l1 = p1;
            while (p0 < m0 and changed0[p0 + 1] != 0) p0 += 1;
            while (p1 < m1 and changed1[p1 + 1] != 0) p1 += 1;
            try edits.append(gpa, .{ .line0 = l0 + prefix, .line1 = l1 + prefix, .deleted = p0 - l0, .inserted = p1 - l1 });
        }
        p0 += 1;
        p1 += 1;
    }
    return edits.toOwnedSlice(gpa);
}

test "compare finds simple edits" {
    const t = std.testing;
    const gpa = t.allocator;
    const a = try splitLines(gpa, "a\nb\nc\nd\n");
    defer a.deinit(gpa);
    const b = try splitLines(gpa, "a\nX\nc\nd\ne\n");
    defer b.deinit(gpa);
    const s = try compare(gpa, a, b, .{});
    defer gpa.free(s);
    try t.expectEqual(@as(usize, 2), s.len);
    try t.expectEqual(Edit{ .line0 = 1, .line1 = 1, .deleted = 1, .inserted = 1 }, s[0]);
    try t.expectEqual(Edit{ .line0 = 4, .line1 = 4, .deleted = 0, .inserted = 1 }, s[1]);
}

test "identical and empty inputs give an empty script" {
    const t = std.testing;
    const gpa = t.allocator;
    const a = try splitLines(gpa, "");
    defer a.deinit(gpa);
    const s = try compare(gpa, a, a, .{});
    defer gpa.free(s);
    try t.expectEqual(@as(usize, 0), s.len);
}

test "whitespace flags make lines equal" {
    const t = std.testing;
    const gpa = t.allocator;
    const a = try splitLines(gpa, "a  b\nx\n");
    defer a.deinit(gpa);
    const b = try splitLines(gpa, "a b\ny\n");
    defer b.deinit(gpa);
    const s = try compare(gpa, a, b, .{ .ignore_space_change = true });
    defer gpa.free(s);
    try t.expectEqual(@as(usize, 1), s.len);
    try t.expectEqual(@as(usize, 1), s[0].line0);
}
