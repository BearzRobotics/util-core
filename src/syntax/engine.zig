//! Line-at-a-time Sublime-syntax highlighter.
//!
//! Memory use does not depend on file size: the only state carried between
//! lines is the context stack (`State`). Feed lines including their trailing
//! '\n', as Sublime grammars expect.
//!
//! Matching: at each position every rule of the top context is searched; the
//! rule whose match starts earliest wins, the first listed rule on ties. A
//! rule's earliest match is cached for the rest of the line and reused while
//! it still starts at or after the current position.
//!
//! Scope assembly (documented behaviour, checked against Sublime's manual
//! only from memory — see docs/compatibility/sublime-syntax.md):
//!   text between matches   syntax scope + every stacked meta_scope and
//!                          meta_content_scope
//!   a pop / set match      as above but without the popped context's
//!                          meta_content_scope
//!   a push / set match     also gets the pushed contexts' meta_scope
//!   then the rule's `scope`, then capture scopes on their sub-ranges.
//! Contexts listed in push/set are pushed in order, so the last is on top.

const std = @import("std");
const def = @import("definition.zig");

const Registry = def.Registry;
const Context = def.Context;
const MatchRule = def.MatchRule;
const ScopeId = def.ScopeId;

const max_stack_depth = 256;
const max_zero_width_steps = 64;
const unset = std.math.maxInt(usize);

pub const State = struct {
    syntax: *def.Syntax,
    stack: std.ArrayList(*Context) = .empty,

    pub fn init(gpa: std.mem.Allocator, syntax: *def.Syntax) !State {
        var s: State = .{ .syntax = syntax };
        try s.stack.append(gpa, syntax.contexts.get("main").?);
        return s;
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.stack.deinit(gpa);
    }
};

pub const Highlighter = struct {
    reg: *Registry,
    line_id: u64 = 0,
    scopes: std.ArrayList(ScopeId) = .empty,
    points: std.ArrayList(usize) = .empty,
    seg: std.ArrayList(ScopeId) = .empty,

    pub fn init(reg: *Registry) Highlighter {
        return .{ .reg = reg };
    }

    pub fn deinit(h: *Highlighter) void {
        h.scopes.deinit(h.reg.gpa);
        h.points.deinit(h.reg.gpa);
        h.seg.deinit(h.reg.gpa);
    }

    /// Match rules of `ctx` in priority order: the syntax's prototype first
    /// (unless disabled), then the context's own rules with includes inlined.
    fn flatten(h: *Highlighter, ctx: *Context) ![]const *MatchRule {
        if (ctx.flat) |f| return f;
        if (ctx.flattening) return &.{};
        ctx.flattening = true;
        defer ctx.flattening = false;
        var list: std.ArrayList(*MatchRule) = .empty;
        if (ctx.meta_include_prototype and !std.mem.eql(u8, ctx.name, "prototype")) {
            if (ctx.syntax.contexts.get("prototype")) |p| try h.collect(&list, p, 0);
        }
        try h.collect(&list, ctx, 0);
        ctx.flat = list.items;
        return list.items;
    }

    fn collect(h: *Highlighter, list: *std.ArrayList(*MatchRule), ctx: *Context, depth: u32) !void {
        if (depth > 32) return;
        const a = h.reg.arena_state.allocator();
        for (ctx.rules) |rule| switch (rule) {
            .match => |m| try list.append(a, m),
            .include => |inc| {
                if (h.reg.resolve(inc, ctx.syntax)) |target| {
                    try h.collect(list, target, depth + 1);
                } else {
                    const msg = try std.fmt.allocPrint(a, "unresolved include '{s}' in context '{s}'", .{ inc.name, ctx.name });
                    try h.reg.warn(ctx.syntax, msg);
                }
            },
        };
    }

    fn pushScopes(h: *Highlighter, ids: []const ScopeId) !void {
        try h.scopes.appendSlice(h.reg.gpa, ids);
    }

    /// Fill h.scopes with the scopes of text inside the current stack.
    fn baseScopes(h: *Highlighter, st: *const State, drop_top_content: bool) !void {
        h.scopes.clearRetainingCapacity();
        try h.pushScopes(st.syntax.scope);
        for (st.stack.items, 0..) |c, i| {
            try h.pushScopes(c.meta_scope);
            if (!(drop_top_content and i + 1 == st.stack.items.len)) try h.pushScopes(c.meta_content_scope);
        }
    }

    /// Highlight one line (with its '\n'), reporting tokens to `sink`:
    /// `sink.token(start, end, scopes)` with scopes valid only during the call.
    pub fn highlightLine(h: *Highlighter, st: *State, line: []const u8, sink: anytype) !void {
        const gpa = h.reg.gpa;
        h.line_id += 1;
        var pos: usize = 0;
        var zero_steps: u32 = 0;

        while (pos < line.len) {
            const top = st.stack.items[st.stack.items.len - 1];
            const rules = try h.flatten(top);

            var best: ?*MatchRule = null;
            var best_start: usize = std.math.maxInt(usize);
            for (rules) |rule| {
                if (!try h.reg.ensureCompiled(rule)) continue;
                const rt = &rule.rt;
                const fresh = rt.cacheable and rt.cache_line == h.line_id and
                    (!rt.cache_found or rt.cache_regs[0] >= pos);
                if (!fresh) {
                    rt.cache_line = if (rt.cacheable) h.line_id else 0;
                    rt.cache_found = false;
                    if (rt.searcher.find(line, pos)) |maybe| {
                        if (maybe) |m| {
                            @memcpy(rt.cache_regs, m.regs);
                            rt.cache_found = true;
                        }
                    } else |err| switch (err) {
                        // A runaway pattern is treated as not matching here.
                        error.StepLimitExceeded, error.StackLimitExceeded => {},
                        error.OutOfMemory => return error.OutOfMemory,
                    }
                }
                if (rt.cache_found and rt.cache_regs[0] < best_start) {
                    best = rule;
                    best_start = rt.cache_regs[0];
                    if (best_start == pos) break; // cannot be beaten
                }
            }

            const rule = best orelse {
                try h.baseScopes(st, false);
                sink.token(pos, line.len, h.scopes.items);
                return;
            };

            if (best_start > pos) {
                try h.baseScopes(st, false);
                sink.token(pos, best_start, h.scopes.items);
            }

            const regs = rule.rt.cache_regs;
            const ms = regs[0];
            const me = regs[1];

            // Contexts to push, resolved before touching the stack.
            var targets: [16]*Context = undefined;
            var ntargets: usize = 0;
            var popping: u32 = 0;
            var replacing = false;
            switch (rule.action) {
                .none => {},
                .pop => |n| popping = n,
                .push, .set => |refs| {
                    replacing = rule.action == .set;
                    for (refs) |ref| {
                        const c = h.reg.resolve(ref, rule.syntax) orelse {
                            const a = h.reg.arena_state.allocator();
                            try h.reg.warn(rule.syntax, try std.fmt.allocPrint(a, "unresolved context '{s}'", .{ref.name}));
                            continue;
                        };
                        if (ntargets < targets.len) {
                            targets[ntargets] = c;
                            ntargets += 1;
                        }
                    }
                },
            }

            try h.baseScopes(st, popping > 0 or replacing);
            for (targets[0..ntargets]) |c| try h.pushScopes(c.meta_scope);
            try h.pushScopes(rule.scope);
            try h.emitMatch(rule, ms, me, sink);

            // Apply the stack change.
            const stack = &st.stack;
            const pops = if (replacing) 1 else popping;
            var k: u32 = 0;
            while (k < pops and stack.items.len > 1) : (k += 1) _ = stack.pop();
            if (replacing and stack.items.len == 1 and k == 0) _ = stack.pop();
            for (targets[0..ntargets]) |c| {
                if (stack.items.len >= max_stack_depth) break;
                try stack.append(gpa, c);
            }
            if (stack.items.len == 0) try stack.append(gpa, st.syntax.contexts.get("main").?);

            if (me == pos) {
                zero_steps += 1;
                if (zero_steps > max_zero_width_steps) {
                    // Break a grammar loop that never consumes input.
                    try h.baseScopes(st, false);
                    sink.token(pos, pos + 1, h.scopes.items);
                    pos += 1;
                    zero_steps = 0;
                }
            } else {
                zero_steps = 0;
                pos = me;
            }
        }
    }

    /// Emit [ms, me) with h.scopes plus any capture scopes on sub-ranges.
    fn emitMatch(h: *Highlighter, rule: *MatchRule, ms: usize, me: usize, sink: anytype) !void {
        const gpa = h.reg.gpa;
        const regs = rule.rt.cache_regs;
        if (me == ms) return;
        if (rule.captures.len == 0) {
            sink.token(ms, me, h.scopes.items);
            return;
        }
        h.points.clearRetainingCapacity();
        try h.points.append(gpa, ms);
        try h.points.append(gpa, me);
        for (rule.captures) |c| {
            if (2 * c.index + 1 >= regs.len) continue;
            const s = regs[2 * c.index];
            const e = regs[2 * c.index + 1];
            if (s == unset or e == unset or s >= e) continue;
            try h.points.append(gpa, std.math.clamp(s, ms, me));
            try h.points.append(gpa, std.math.clamp(e, ms, me));
        }
        std.mem.sort(usize, h.points.items, {}, std.sort.asc(usize));

        const base_len = h.scopes.items.len;
        var prev = h.points.items[0];
        for (h.points.items[1..]) |p| {
            if (p == prev) continue;
            h.scopes.shrinkRetainingCapacity(base_len);
            for (rule.captures) |c| {
                if (2 * c.index + 1 >= regs.len) continue;
                const s = regs[2 * c.index];
                const e = regs[2 * c.index + 1];
                if (s == unset or e == unset) continue;
                if (s <= prev and p <= e) try h.pushScopes(c.scopes);
            }
            sink.token(prev, p, h.scopes.items);
            prev = p;
        }
        h.scopes.shrinkRetainingCapacity(base_len);
    }
};

// ---- tests ---------------------------------------------------------------

const Collector = struct {
    reg: *Registry,
    out: *std.ArrayList(u8),
    line: []const u8 = "",
    gpa: std.mem.Allocator,

    pub fn token(c: *Collector, s: usize, e: usize, scopes: []const ScopeId) void {
        c.out.print(c.gpa, "[{s}|", .{c.line[s..e]}) catch return;
        for (scopes, 0..) |id, i| {
            if (i > 0) c.out.append(c.gpa, ' ') catch return;
            c.out.appendSlice(c.gpa, c.reg.scopeName(id)) catch return;
        }
        c.out.append(c.gpa, ']') catch return;
    }
};

const toy =
    \\%YAML 1.2
    \\---
    \\name: Toy
    \\scope: source.toy
    \\file_extensions: [toy]
    \\variables:
    \\  ident: '[a-z]+'
    \\contexts:
    \\  main:
    \\    - match: '\b(if|else)\b'
    \\      scope: keyword.control
    \\    - match: '"'
    \\      scope: punctuation.begin
    \\      push: string
    \\    - match: '({{ident}})(\()'
    \\      captures:
    \\        1: entity.function
    \\        2: punctuation.paren
    \\  string:
    \\    - meta_scope: string.quoted
    \\    - match: '\\.'
    \\      scope: constant.escape
    \\    - match: '"'
    \\      scope: punctuation.end
    \\      pop: true
;

fn run(reg: *Registry, st: *State, h: *Highlighter, line: []const u8, out: *std.ArrayList(u8)) !void {
    var c: Collector = .{ .reg = reg, .out = out, .line = line, .gpa = std.testing.allocator };
    try h.highlightLine(st, line, &c);
}

test "toy grammar: keywords, strings, captures, state across lines" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    const syn = try reg.load(toy, "Toy.sublime-syntax");
    var st = try State.init(gpa, syn);
    defer st.deinit(gpa);
    var h = Highlighter.init(&reg);
    defer h.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try run(&reg, &st, &h, "if foo(\n", &out);
    try std.testing.expectEqualStrings(
        "[if|source.toy keyword.control][ |source.toy]" ++
            "[foo|source.toy entity.function][(|source.toy punctuation.paren][\n|source.toy]",
        out.items,
    );

    out.clearRetainingCapacity();
    try run(&reg, &st, &h, "\"a\\nb\n", &out);
    try std.testing.expectEqualStrings(
        "[\"|source.toy string.quoted punctuation.begin][a|source.toy string.quoted]" ++
            "[\\n|source.toy string.quoted constant.escape][b\n|source.toy string.quoted]",
        out.items,
    );
    try std.testing.expectEqual(@as(usize, 2), st.stack.items.len); // still inside the string

    out.clearRetainingCapacity();
    try run(&reg, &st, &h, "x\" else\n", &out);
    try std.testing.expectEqualStrings(
        "[x|source.toy string.quoted][\"|source.toy string.quoted punctuation.end]" ++
            "[ |source.toy][else|source.toy keyword.control][\n|source.toy]",
        out.items,
    );
    try std.testing.expectEqual(@as(usize, 1), st.stack.items.len);
}

test "lookup by extension and scope" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    const syn = try reg.load(toy, "Toy.sublime-syntax");
    try std.testing.expect(reg.byExtension("toy") == syn);
    try std.testing.expect(reg.byScope("source.toy") == syn);
    try std.testing.expect(reg.byName("toy") == syn);
    try std.testing.expect(reg.byExtension("zz") == null);
}

test "zero-width push loop terminates" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    const syn = try reg.load(
        \\name: Loop
        \\scope: source.loop
        \\contexts:
        \\  main:
        \\    - match: '(?=.)'
        \\      push: main
    , "Loop.sublime-syntax");
    var st = try State.init(gpa, syn);
    defer st.deinit(gpa);
    var h = Highlighter.init(&reg);
    defer h.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try run(&reg, &st, &h, "abc\n", &out);
    try std.testing.expect(out.items.len > 0);
}

test "unsupported constructs are reported, not silent" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    const syn = try reg.load(
        \\name: W
        \\scope: source.w
        \\extends: Packages/X/X.sublime-syntax
        \\contexts:
        \\  main:
        \\    - match: 'a'
        \\      embed: scope:source.other
        \\    - match: '\p{L}+'
        \\      scope: word
    , "W.sublime-syntax");
    var st = try State.init(gpa, syn);
    defer st.deinit(gpa);
    var h = Highlighter.init(&reg);
    defer h.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try run(&reg, &st, &h, "ab\n", &out);
    try std.testing.expect(syn.warnings.items.len >= 3);
}

test "detect by extension, file name and first line" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    const toy_syn = try reg.load(toy, "Toy.sublime-syntax");
    const sh = try reg.load(
        \\name: Sh
        \\scope: source.sh
        \\file_extensions: [sh, Makefile]
        \\first_line_match: '^#!.*\bsh\b'
        \\contexts:
        \\  main: []
    , "Sh.sublime-syntax");
    try std.testing.expect(reg.detect("a/b/c.toy", "") == toy_syn);
    try std.testing.expect(reg.detect("Makefile", "") == sh);
    try std.testing.expect(reg.detect("x.TOY", "") == null);
    try std.testing.expect(reg.detect("noext", "#!/bin/sh\n") == sh);
    try std.testing.expect(reg.detect("-", "#!/usr/bin/env sh\n") == sh);
    try std.testing.expect(reg.detect("noext", "plain\n") == null);
}
