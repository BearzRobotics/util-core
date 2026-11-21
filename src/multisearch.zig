// SPDX-License-Identifier: GPL-2.0-or-later
//! Multi-literal search: an Aho-Corasick automaton compiled to a dense DFA
//! over byte classes. Bytes that occur in no literal share one class, so the
//! table has (states x classes) entries rather than (states x 256); entries
//! are pre-multiplied state offsets and the accepting states are numbered
//! first, so the hot loop is one table load and one compare per byte and
//! only stops at a hit or when it returns to the start state (where, if the
//! literals start with few distinct bytes, a vector scan skips ahead).
//!
//! With `fold`, ASCII letters match in either case (literals are lower-cased
//! on construction; both cases of a letter share a class).

const std = @import("std");
const Allocator = std.mem.Allocator;

const V = @Vector(32, u8);
const none: u32 = std.math.maxInt(u32);

pub const Mode = enum { any, word, line };

pub const Ac = struct {
    gpa: Allocator,
    cls: [256]u8,
    nc: u32,
    /// `table[s + class]` is the (pre-multiplied) next state of state offset `s`.
    table: []u32,
    /// Offset of the start state; accepting states have smaller offsets.
    root: u32,
    /// Per state index: length of the literal that ends exactly here (0 = none).
    own: []u32,
    /// Per state index: nearest proper suffix state that ends a literal.
    dlink: []u32,
    /// Distinct first bytes of the literals (both cases with `fold`); the
    /// vector skip is used when there are at most `first.len` of them.
    first: [6]u8 = undefined,
    nfirst: u8 = 0,
    /// Distinct first-two-byte pairs of the literals (when every literal has
    /// two bytes and there are at most `pairs.len`): candidate starts are
    /// found with a vector scan on both bytes. `pair_or` lets a folded
    /// letter match in either case (0x20, else 0); `pair_eq` is the target.
    pair_eq: [12][2]u8 = undefined,
    pair_or: [12][2]u8 = undefined,
    npairs: u8 = 0,

    pub fn deinit(a: *Ac) void {
        a.gpa.free(a.table);
        a.gpa.free(a.own);
        a.gpa.free(a.dlink);
    }

    /// Build the automaton for `pats` (none empty). Null when the table
    /// would exceed `max_bytes` or memory is short.
    pub fn build(gpa: Allocator, pats: []const []const u8, fold: bool, max_bytes: usize) ?Ac {
        return buildInner(gpa, pats, fold, max_bytes) catch null;
    }

    fn buildInner(gpa: Allocator, pats: []const []const u8, fold: bool, max_bytes: usize) !?Ac {
        var a: Ac = undefined;
        a.gpa = gpa;
        a.cls = @splat(0);
        var used: [256]bool = @splat(false);
        var total: usize = 1;
        for (pats) |p| {
            if (p.len == 0) return null;
            total += p.len;
            for (p) |c| used[if (fold) std.ascii.toLower(c) else c] = true;
        }
        var nc: u32 = 1;
        for (0..256) |b| if (used[b]) {
            a.cls[b] = @intCast(nc);
            nc += 1;
        };
        if (fold) for ('A'..'Z' + 1) |u| {
            a.cls[u] = a.cls[std.ascii.toLower(@intCast(u))];
        };
        if (nc > 255) return null;
        a.nc = nc;
        if (total > std.math.maxInt(u32) / nc / 4) return null;
        if (total * nc * 4 > max_bytes) return null;

        // trie; state 0 is the root, `none` marks a missing edge
        const go = try gpa.alloc(u32, total * nc);
        defer gpa.free(go);
        @memset(go, none);
        const own0 = try gpa.alloc(u32, total);
        defer gpa.free(own0);
        @memset(own0, 0);
        var n: u32 = 1;
        for (pats) |p| {
            var s: u32 = 0;
            for (p) |c| {
                const k = a.cls[c];
                const e = &go[s * nc + k];
                if (e.* == none) {
                    e.* = n;
                    n += 1;
                }
                s = e.*;
            }
            own0[s] = @intCast(p.len);
        }
        // breadth-first: failure links, dictionary links, complete the goto
        const fail = try gpa.alloc(u32, n);
        defer gpa.free(fail);
        const dl0 = try gpa.alloc(u32, n);
        defer gpa.free(dl0);
        const queue = try gpa.alloc(u32, n);
        defer gpa.free(queue);
        var qh: usize = 0;
        var qt: usize = 0;
        fail[0] = 0;
        dl0[0] = none;
        for (0..nc) |k| {
            const e = &go[k];
            if (e.* == none) {
                e.* = 0;
            } else {
                fail[e.*] = 0;
                dl0[e.*] = none;
                queue[qt] = e.*;
                qt += 1;
            }
        }
        while (qh < qt) {
            const s = queue[qh];
            qh += 1;
            const f = fail[s];
            // `own0[f]`/`dl0[f]` are final: f is shallower than s
            for (0..nc) |k| {
                const e = &go[s * nc + k];
                if (e.* == none) {
                    e.* = go[f * nc + k];
                } else {
                    const t = e.*;
                    const ft = go[f * nc + k];
                    fail[t] = ft;
                    dl0[t] = if (own0[ft] != 0) ft else dl0[ft];
                    queue[qt] = t;
                    qt += 1;
                }
            }
        }
        // number accepting states first
        const map = try gpa.alloc(u32, n);
        defer gpa.free(map);
        var nacc: u32 = 0;
        for (0..n) |s| if (own0[s] != 0 or dl0[s] != none) {
            nacc += 1;
        };
        var ai: u32 = 0;
        var ri: u32 = nacc;
        for (0..n) |s| {
            if (own0[s] != 0 or dl0[s] != none) {
                map[s] = ai;
                ai += 1;
            } else {
                map[s] = ri;
                ri += 1;
            }
        }
        // the root is not accepting (no empty literal), so it is the first
        // non-accepting state
        std.debug.assert(map[0] == nacc);
        a.root = nacc * nc;
        a.table = try gpa.alloc(u32, n * nc);
        errdefer gpa.free(a.table);
        a.own = try gpa.alloc(u32, n);
        errdefer gpa.free(a.own);
        a.dlink = try gpa.alloc(u32, n);
        errdefer gpa.free(a.dlink);
        for (0..n) |s| {
            const ns = map[s];
            a.own[ns] = own0[s];
            a.dlink[ns] = if (dl0[s] == none) none else map[dl0[s]];
            for (0..nc) |k| a.table[ns * nc + k] = map[go[s * nc + k]] * nc;
        }
        // first bytes
        var nf: usize = 0;
        var too_many = false;
        for (pats) |p| {
            const c0 = if (fold) std.ascii.toLower(p[0]) else p[0];
            var cand: [2]u8 = .{ c0, c0 };
            var nn: usize = 1;
            if (fold and std.ascii.isAlphabetic(c0)) {
                cand[1] = std.ascii.toUpper(c0);
                nn = 2;
            }
            for (cand[0..nn]) |c| {
                if (std.mem.indexOfScalar(u8, a.first[0..nf], c) != null) continue;
                if (nf == a.first.len) {
                    too_many = true;
                    break;
                }
                a.first[nf] = c;
                nf += 1;
            }
            if (too_many) break;
        }
        a.nfirst = if (too_many) 0 else @intCast(nf);
        // first pairs
        a.npairs = 0;
        var np: usize = 0;
        var pair_ok = true;
        outer: for (pats) |p| {
            if (p.len < 2) {
                pair_ok = false;
                break;
            }
            var eq: [2]u8 = undefined;
            var orv: [2]u8 = undefined;
            for (0..2) |k| {
                const c = if (fold) std.ascii.toLower(p[k]) else p[k];
                eq[k] = c;
                orv[k] = if (fold and std.ascii.isAlphabetic(c)) 0x20 else 0;
            }
            for (0..np) |q| if (std.mem.eql(u8, &a.pair_eq[q], &eq)) continue :outer;
            if (np == a.pair_eq.len) {
                pair_ok = false;
                break;
            }
            a.pair_eq[np] = eq;
            a.pair_or[np] = orv;
            np += 1;
        }
        if (pair_ok) a.npairs = @intCast(np);
        return a;
    }

    /// Index of the first byte at or after `i` that starts some literal.
    inline fn skipToFirst(a: *const Ac, hay: []const u8, from: usize) usize {
        var i = from;
        const nf = a.nfirst;
        var vs: [6]V = undefined;
        for (0..nf) |k| vs[k] = @splat(a.first[k]);
        while (i + 32 <= hay.len) : (i += 32) {
            const v: V = hay[i..][0..32].*;
            var m: @Vector(32, bool) = v == vs[0];
            for (1..nf) |k| m = @select(bool, m, m, v == vs[k]);
            const mask: u32 = @bitCast(m);
            if (mask != 0) return i + @ctz(mask);
        }
        while (i < hay.len) : (i += 1) {
            if (std.mem.indexOfScalar(u8, a.first[0..nf], hay[i]) != null) return i;
        }
        return hay.len;
    }

    /// Index of the next position at or after `from` whose two bytes are a
    /// literal's first pair, or `hay.len`.
    fn skipToPair(a: *const Ac, hay: []const u8, from: usize) usize {
        const np = a.npairs;
        var e0: [12]V = undefined;
        var o0: [12]V = undefined;
        var e1: [12]V = undefined;
        var o1: [12]V = undefined;
        for (0..np) |k| {
            e0[k] = @splat(a.pair_eq[k][0]);
            o0[k] = @splat(a.pair_or[k][0]);
            e1[k] = @splat(a.pair_eq[k][1]);
            o1[k] = @splat(a.pair_or[k][1]);
        }
        var i = from;
        while (i + 33 <= hay.len) : (i += 32) {
            const v0: V = hay[i..][0..32].*;
            const v1: V = hay[i + 1 ..][0..32].*;
            var m: @Vector(32, bool) = (v0 | o0[0]) == e0[0];
            m = m & ((v1 | o1[0]) == e1[0]);
            for (1..np) |k| {
                const mk = ((v0 | o0[k]) == e0[k]) & ((v1 | o1[k]) == e1[k]);
                m = @select(bool, m, m, mk);
            }
            const mask: u32 = @bitCast(m);
            if (mask != 0) return i + @ctz(mask);
        }
        while (i + 1 < hay.len) : (i += 1) {
            for (0..np) |k| {
                if ((hay[i] | a.pair_or[k][0]) == a.pair_eq[k][0] and (hay[i + 1] | a.pair_or[k][1]) == a.pair_eq[k][1]) return i;
            }
        }
        return hay.len;
    }

    /// End (exclusive) of the earliest-ending occurrence of any literal
    /// that starts at or after `from`, or null.
    pub fn firstEnd(a: *const Ac, hay: []const u8, from: usize) ?usize {
        const t = a.table.ptr;
        const cls = &a.cls;
        const root = a.root;
        var s: u32 = root;
        var i = from;
        const n = hay.len;
        while (i < n) {
            if (a.npairs > 0) {
                i = a.skipToPair(hay, i);
                if (i + 1 >= n) return null;
            } else if (a.nfirst > 0) {
                i = a.skipToFirst(hay, i);
                if (i >= n) return null;
            }
            // run until a hit or the start state
            while (i < n) {
                s = t[s + cls[hay[i]]];
                i += 1;
                if (s <= root) break;
            }
            if (s < root) return i;
        }
        return null;
    }

    /// Does `line` hold an occurrence of a literal that satisfies `mode`
    /// (`word`: the bytes around it are not word bytes; `line`: it is the
    /// whole line)? Null when a neighbouring byte is non-ASCII and `utf8`,
    /// where the caller must decide with a real regex.
    pub fn check(a: *const Ac, line: []const u8, mode: Mode, utf8: bool) ?bool {
        const t = a.table.ptr;
        const cls = &a.cls;
        const root = a.root;
        const nc = a.nc;
        var s: u32 = root;
        var i: usize = 0;
        while (i < line.len) {
            s = t[s + cls[line[i]]];
            i += 1;
            if (s >= root) continue;
            var st = s / nc;
            while (st != none) : (st = a.dlink[st]) {
                const len = a.own[st];
                if (len == 0) continue;
                const start = i - len;
                switch (mode) {
                    .any => return true,
                    .line => if (start == 0 and i == line.len) return true,
                    .word => {
                        const before: ?u8 = if (start > 0) line[start - 1] else null;
                        const after: ?u8 = if (i < line.len) line[i] else null;
                        if (utf8 and ((before orelse 0) >= 0x80 or (after orelse 0) >= 0x80)) return null;
                        if (!(before != null and isWord(before.?)) and !(after != null and isWord(after.?))) return true;
                    },
                }
            }
        }
        return false;
    }
};

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn naiveFirstEnd(hay: []const u8, from: usize, pats: []const []const u8, fold: bool) ?usize {
    var e = from;
    while (e <= hay.len) : (e += 1) {
        for (pats) |p| {
            if (p.len > e - from) continue;
            const w = hay[e - p.len .. e];
            const same = if (fold) std.ascii.eqlIgnoreCase(w, p) else std.mem.eql(u8, w, p);
            if (same) return e;
        }
    }
    return null;
}

test "Ac agrees with a naive search" {
    var prng = std.Random.DefaultPrng.init(99);
    const rnd = prng.random();
    const alpha = "abAB c\n\xc3";
    var hay: [300]u8 = undefined;
    for (0..3000) |_| {
        var store: [12][4]u8 = undefined;
        var pats: [12][]const u8 = undefined;
        const np = 1 + rnd.uintLessThan(usize, if (rnd.boolean()) @as(usize, 3) else 12);
        for (0..np) |k| {
            const l = (if (rnd.boolean()) @as(usize, 1) else 2) + rnd.uintLessThan(usize, 3);
            for (store[k][0..l]) |*b| b.* = alpha[rnd.uintLessThan(usize, alpha.len)];
            pats[k] = store[k][0..l];
        }
        const fold = rnd.boolean();
        var a = Ac.build(std.testing.allocator, pats[0..np], fold, 1 << 20).?;
        defer a.deinit();
        const len = rnd.uintLessThan(usize, hay.len);
        for (hay[0..len]) |*b| b.* = alpha[rnd.uintLessThan(usize, alpha.len)];
        const from = if (len == 0) 0 else rnd.uintLessThan(usize, len + 1);
        // pats are stored as given; fold compares case-insensitively
        try std.testing.expectEqual(naiveFirstEnd(hay[0..len], from, pats[0..np], fold), a.firstEnd(hay[0..len], from));
        try std.testing.expectEqual(naiveFirstEnd(hay[0..len], 0, pats[0..np], fold) != null, a.check(hay[0..len], .any, false).?);
        // whole line and word checks against definitions
        var want_line = false;
        for (pats[0..np]) |p| {
            const same = if (fold) std.ascii.eqlIgnoreCase(hay[0..len], p) else std.mem.eql(u8, hay[0..len], p);
            if (same) want_line = true;
        }
        try std.testing.expectEqual(want_line, a.check(hay[0..len], .line, false).?);
        var want_word = false;
        for (pats[0..np]) |p| {
            var st: usize = 0;
            while (st + p.len <= len) : (st += 1) {
                const w = hay[st .. st + p.len];
                const same = if (fold) std.ascii.eqlIgnoreCase(w, p) else std.mem.eql(u8, w, p);
                if (!same) continue;
                const bw = st > 0 and isWord(hay[st - 1]);
                const aw = st + p.len < len and isWord(hay[st + p.len]);
                if (!bw and !aw) want_word = true;
            }
        }
        try std.testing.expectEqual(want_word, a.check(hay[0..len], .word, false).?);
    }
}

test "Ac skip path and refusal" {
    const pats = [_][]const u8{ "two", "the", "Thx" };
    var a = Ac.build(std.testing.allocator, &pats, true, 1 << 20).?;
    defer a.deinit();
    try std.testing.expect(a.nfirst > 0);
    try std.testing.expectEqual(@as(?usize, 51), a.firstEnd("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx tHe", 0));
    try std.testing.expectEqual(@as(?usize, null), a.firstEnd("qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq t", 0));
    try std.testing.expectEqual(@as(?bool, null), a.check("\xc3\xa9the", .word, true));
    try std.testing.expectEqual(@as(?bool, true), a.check("a the.", .word, true));
    try std.testing.expect(Ac.build(std.testing.allocator, &pats, true, 16) == null);
    try std.testing.expect(Ac.build(std.testing.allocator, &[_][]const u8{""}, false, 1 << 20) == null);
}
