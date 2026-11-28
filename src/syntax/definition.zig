// SPDX-License-Identifier: GPL-2.0-or-later
//! Sublime `.sublime-syntax` grammar model and loader.
//!
//! A Registry owns every loaded Syntax. All definition data (strings, rules,
//! contexts) lives in the registry's arena and is freed together; compiled
//! regexes use the registry's general allocator and are freed by deinit.
//!
//! Supported: variables, contexts, match / include rules, push / set / pop,
//! anonymous contexts, captures, scope / meta_scope / meta_content_scope,
//! meta_include_prototype, the `prototype` context, cross-syntax references
//! (`scope:source.x`, `Packages/X/X.sublime-syntax`, optional `#context`).
//!
//! Not supported (a warning is recorded and the construct is skipped, so a
//! grammar still loads and highlights approximately): `extends`,
//! `with_prototype`, `embed`/`escape`, `branch`/`fail`, `clear_scopes`,
//! `meta_prepend`/`meta_append`, `hidden`, `version` semantics.

const std = @import("std");
const regex = @import("regex");
const yaml = @import("yaml");

pub const ScopeId = u32;

pub const ContextRef = struct {
    /// Context name, "scope:..." or "Packages/...sublime-syntax[#name]" text,
    /// or empty when `anon` is set.
    name: []const u8 = "",
    anon: ?*Context = null,
};

pub const Capture = struct { index: u32, scopes: []const ScopeId };

pub const Action = union(enum) {
    none,
    push: []const ContextRef,
    set: []const ContextRef,
    /// Number of contexts to pop.
    pop: u32,
};

/// Lazily compiled regex plus the per-rule search cache the engine keeps.
pub const Runtime = struct {
    state: enum { uncompiled, ready, failed } = .uncompiled,
    re: regex.Regex = undefined,
    searcher: regex.Searcher = undefined,
    /// Rules containing \G depend on the search start, so they are not cached.
    cacheable: bool = true,
    // Search cache, valid only for `cache_line`.
    cache_line: u64 = 0,
    cache_found: bool = false,
    cache_regs: []usize = &.{},
};

pub const MatchRule = struct {
    syntax: *Syntax,
    /// Pattern with {{variables}} not yet expanded.
    pattern: []const u8,
    scope: []const ScopeId,
    captures: []const Capture,
    action: Action,
    rt: Runtime = .{},
};

pub const Include = ContextRef;

pub const Rule = union(enum) {
    match: *MatchRule,
    include: Include,
};

pub const Context = struct {
    name: []const u8,
    syntax: *Syntax,
    meta_scope: []const ScopeId = &.{},
    meta_content_scope: []const ScopeId = &.{},
    meta_include_prototype: bool = true,
    rules: []const Rule = &.{},
    /// Engine cache: prototype + includes flattened to match rules.
    flat: ?[]const *MatchRule = null,
    flattening: bool = false,
};

pub const Syntax = struct {
    name: []const u8,
    file_name: []const u8,
    scope_name: []const u8,
    /// Scopes applied to every token.
    scope: []const ScopeId,
    extensions: []const []const u8,
    first_line_match: []const u8,
    variables: std.StringHashMapUnmanaged([]const u8) = .empty,
    contexts: std.StringHashMapUnmanaged(*Context) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,
};

pub const LoadError = error{ OutOfMemory, InvalidSyntax } || yaml.ParseError;

/// A YAML alias is a reference, so a small grammar can nest a context inside
/// itself, or stand for far more rules than its text holds. These bound what
/// one grammar may unfold to: how deep anonymous contexts nest, and how many
/// rules, captures and context references are read.
const max_context_depth = 32;
const max_grammar_items = 100_000;
/// What one pattern may grow to as its variables are replaced.
const max_pattern_len = 1 << 20;
const max_variable_uses = 100_000;

/// The text of a scalar (following an alias), or null for a collection.
fn str(v: yaml.Value) ?[]const u8 {
    return switch (v.deref()) {
        .scalar => |s| s.text,
        else => null,
    };
}

pub const Registry = struct {
    gpa: std.mem.Allocator,
    arena_state: std.heap.ArenaAllocator,
    scope_ids: std.StringHashMapUnmanaged(ScopeId) = .empty,
    scope_names: std.ArrayList([]const u8) = .empty,
    syntaxes: std.ArrayList(*Syntax) = .empty,
    /// Every MatchRule, so deinit can free compiled regexes.
    rules: std.ArrayList(*MatchRule) = .empty,
    diag: yaml.Diagnostic = .{},
    /// Why the last load failed.
    last_error: []const u8 = "",
    /// What is left of `max_grammar_items` for the grammar being loaded.
    items_left: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa, .arena_state = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(r: *Registry) void {
        for (r.rules.items) |rule| {
            if (rule.rt.state == .ready) {
                rule.rt.searcher.deinit();
                rule.rt.re.deinit(r.gpa);
            }
            if (rule.rt.cache_regs.len != 0) r.gpa.free(rule.rt.cache_regs);
        }
        r.rules.deinit(r.gpa);
        r.scope_ids.deinit(r.gpa);
        r.scope_names.deinit(r.gpa);
        r.syntaxes.deinit(r.gpa);
        r.arena_state.deinit();
    }

    fn arena(r: *Registry) std.mem.Allocator {
        return r.arena_state.allocator();
    }

    pub fn scopeName(r: *const Registry, id: ScopeId) []const u8 {
        return r.scope_names.items[id];
    }

    pub fn intern(r: *Registry, name: []const u8) !ScopeId {
        if (r.scope_ids.get(name)) |id| return id;
        const owned = try r.arena().dupe(u8, name);
        const id: ScopeId = @intCast(r.scope_names.items.len);
        try r.scope_names.append(r.gpa, owned);
        try r.scope_ids.put(r.gpa, owned, id);
        return id;
    }

    fn scopes(r: *Registry, text: []const u8) ![]const ScopeId {
        var out: std.ArrayList(ScopeId) = .empty;
        var it = std.mem.tokenizeAny(u8, text, " \t");
        while (it.next()) |tok| try out.append(r.arena(), try r.intern(tok));
        return out.items;
    }

    // ---- lookup --------------------------------------------------------

    pub fn byScope(r: *const Registry, scope_name: []const u8) ?*Syntax {
        for (r.syntaxes.items) |s| if (std.mem.eql(u8, s.scope_name, scope_name)) return s;
        return null;
    }

    pub fn byName(r: *const Registry, name: []const u8) ?*Syntax {
        for (r.syntaxes.items) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
        return null;
    }

    pub fn byExtension(r: *const Registry, ext: []const u8) ?*Syntax {
        for (r.syntaxes.items) |s| for (s.extensions) |e| if (std.mem.eql(u8, e, ext)) return s;
        return null;
    }

    /// Pick a grammar for a file: first by file name / extension, then by the
    /// grammars' `first_line_match` against `first_line`.
    pub fn detect(r: *Registry, path: []const u8, first_line: []const u8) ?*Syntax {
        const base = std.Io.Dir.path.basename(path);
        if (base.len > 0 and !std.mem.eql(u8, base, "-")) {
            for (r.syntaxes.items) |s| for (s.extensions) |ext| {
                if (std.mem.eql(u8, base, ext)) return s;
                if (base.len > ext.len + 1 and std.mem.endsWith(u8, base, ext) and
                    base[base.len - ext.len - 1] == '.') return s;
            };
        }
        if (first_line.len == 0) return null;
        for (r.syntaxes.items) |s| {
            if (s.first_line_match.len == 0) continue;
            var re = regex.Regex.compile(r.gpa, s.first_line_match, .{ .dialect = .oniguruma }, null) catch continue;
            defer re.deinit(r.gpa);
            var se = searcherOf(re, r.gpa) catch continue;
            defer se.deinit();
            const m = se.find(first_line, 0) catch continue;
            if (m != null) return s;
        }
        return null;
    }

    fn byFile(r: *const Registry, path: []const u8) ?*Syntax {
        const base = std.Io.Dir.path.basename(path);
        for (r.syntaxes.items) |s| if (std.mem.eql(u8, std.Io.Dir.path.basename(s.file_name), base)) return s;
        return null;
    }

    /// Resolve a reference made from a rule or context of `from`.
    pub fn resolve(r: *Registry, ref: ContextRef, from: *Syntax) ?*Context {
        if (ref.anon) |a| return a;
        var name = ref.name;
        var syn = from;
        var ctx_name: []const u8 = name;
        if (std.mem.startsWith(u8, name, "scope:")) {
            const rest = name["scope:".len..];
            const hash = std.mem.indexOfScalar(u8, rest, '#');
            const scope_part = if (hash) |h| rest[0..h] else rest;
            syn = r.byScope(scope_part) orelse return null;
            ctx_name = if (hash) |h| rest[h + 1 ..] else "main";
        } else if (std.mem.indexOf(u8, name, ".sublime-syntax") != null or std.mem.startsWith(u8, name, "Packages/")) {
            const hash = std.mem.indexOfScalar(u8, name, '#');
            const file = if (hash) |h| name[0..h] else name;
            syn = r.byFile(file) orelse return null;
            ctx_name = if (hash) |h| name[h + 1 ..] else "main";
        }
        name = ctx_name;
        return syn.contexts.get(name);
    }

    // ---- loading -------------------------------------------------------

    /// Parse a grammar from text. `file_name` is used for Packages/ references
    /// and diagnostics. The returned Syntax is owned by the registry.
    pub fn load(r: *Registry, text: []const u8, file_name: []const u8) LoadError!*Syntax {
        const a = r.arena();
        var diag: yaml.Diagnostic = .{};
        // The document copies what it keeps, so the caller may free `text`
        // after load returns. It is never deinited: its arena lives in the
        // registry's, because names and patterns point into it.
        const doc = yaml.Document.parse(a, text, .{}, &diag) catch |e| {
            r.diag = diag;
            r.last_error = diag.message;
            return e;
        };
        if (doc.root != .map) return r.bad("grammar is not a mapping");
        const top = doc.root.map;
        r.items_left = max_grammar_items;

        const syn = try a.create(Syntax);
        const scope_name = top.getString("scope") orelse "";
        syn.* = .{
            .name = if (top.get("name")) |n| str(n) orelse "" else try a.dupe(u8, std.Io.Dir.path.stem(file_name)),
            .file_name = try a.dupe(u8, file_name),
            .scope_name = scope_name,
            .scope = try r.scopes(scope_name),
            .extensions = &.{},
            .first_line_match = top.getString("first_line_match") orelse "",
        };

        if (top.get("extends") != null) try r.warn(syn, "extends is not supported; inherited rules are missing");
        if (top.getSeq("file_extensions")) |fe| {
            var exts: std.ArrayList([]const u8) = .empty;
            for (fe.items.items) |e| if (str(e)) |s| try exts.append(a, s);
            syn.extensions = exts.items;
        }
        if (top.getMap("variables")) |vars| for (vars.keys(), vars.entries.values()) |k, e| {
            const name = str(k) orelse continue;
            if (str(e.value)) |s| try syn.variables.put(a, name, s);
        };

        const ctxs = top.get("contexts") orelse return r.bad("grammar has no contexts");
        if (ctxs != .map) return r.bad("contexts is not a mapping");
        // Create all named contexts first so rules can refer to any of them.
        for (ctxs.map.keys()) |k| {
            const name = str(k) orelse return r.bad("context name is not a string");
            const c = try a.create(Context);
            c.* = .{ .name = name, .syntax = syn };
            try syn.contexts.put(a, name, c);
        }
        for (ctxs.map.keys(), ctxs.map.entries.values()) |k, e| {
            try r.fillContext(syn, syn.contexts.get(str(k).?).?, e.value, 0);
        }
        if (syn.contexts.get("main") == null) return r.bad("grammar has no main context");

        try r.syntaxes.append(r.gpa, syn);
        return syn;
    }

    fn bad(r: *Registry, msg: []const u8) LoadError {
        r.last_error = msg;
        return error.InvalidSyntax;
    }

    pub fn warn(r: *Registry, syn: *Syntax, msg: []const u8) !void {
        for (syn.warnings.items) |w| if (std.mem.eql(u8, w, msg)) return;
        try syn.warnings.append(r.arena(), msg);
    }

    /// Count `n` items against the grammar's allowance.
    fn spend(r: *Registry, n: usize) LoadError!void {
        if (n > r.items_left) return r.bad("grammar expands to too many items");
        r.items_left -= n;
    }

    /// A context's value is a list of rules and meta_* settings. `depth`
    /// counts the anonymous contexts around this one.
    fn fillContext(r: *Registry, syn: *Syntax, ctx: *Context, v: yaml.Value, depth: u32) LoadError!void {
        const a = r.arena();
        const list = v.deref();
        if (list != .seq) return r.bad("context is not a list");
        var rules: std.ArrayList(Rule) = .empty;
        for (list.seq.items.items) |entry| {
            try r.spend(1);
            const node = entry.deref();
            if (node != .map) return r.bad("context entry is not a mapping");
            const item = node.map;
            if (item.get("meta_scope")) |s| {
                ctx.meta_scope = try r.scopes(str(s) orelse "");
            } else if (item.get("meta_content_scope")) |s| {
                ctx.meta_content_scope = try r.scopes(str(s) orelse "");
            } else if (item.get("meta_include_prototype")) |s| {
                ctx.meta_include_prototype = !std.mem.eql(u8, str(s) orelse "true", "false");
            } else if (item.get("clear_scopes") != null) {
                try r.warn(syn, "clear_scopes is not supported");
            } else if (item.get("meta_prepend") != null or item.get("meta_append") != null) {
                try r.warn(syn, "meta_prepend/meta_append are not supported");
            } else if (item.get("include")) |inc| {
                try rules.append(a, .{ .include = .{ .name = str(inc) orelse "" } });
            } else if (item.get("match")) |m| {
                if (try r.matchRule(syn, item, str(m) orelse "", depth)) |rule| try rules.append(a, .{ .match = rule });
            } else try r.warn(syn, "unknown context entry skipped");
        }
        ctx.rules = rules.items;
    }

    fn matchRule(r: *Registry, syn: *Syntax, item: *const yaml.Map, pattern: []const u8, depth: u32) LoadError!?*MatchRule {
        const a = r.arena();
        for ([_][]const u8{ "embed", "escape", "branch_point", "fail", "with_prototype" }) |k| {
            if (item.get(k) != null) {
                try r.warn(syn, try std.fmt.allocPrint(a, "'{s}' is not supported; rule skipped", .{k}));
                return null;
            }
        }
        var caps: std.ArrayList(Capture) = .empty;
        if (item.getMap("captures")) |c| for (c.keys(), c.entries.values()) |k, e| {
            try r.spend(1);
            const idx = std.fmt.parseInt(u32, str(k) orelse continue, 10) catch continue;
            try caps.append(a, .{ .index = idx, .scopes = try r.scopes(str(e.value) orelse "") });
        };

        var action: Action = .none;
        if (item.get("push")) |p| {
            action = .{ .push = try r.contextRefs(syn, p, depth) };
        } else if (item.get("set")) |p| {
            action = .{ .set = try r.contextRefs(syn, p, depth) };
        } else if (item.get("pop")) |p| {
            const s = str(p) orelse "true";
            action = .{ .pop = if (std.mem.eql(u8, s, "true")) 1 else std.fmt.parseInt(u32, s, 10) catch 1 };
        }

        const rule = try a.create(MatchRule);
        rule.* = .{
            .syntax = syn,
            .pattern = pattern,
            .scope = try r.scopes(item.getString("scope") orelse ""),
            .captures = caps.items,
            .action = action,
        };
        try r.rules.append(r.gpa, rule);
        return rule;
    }

    /// A push/set target: a name, a list of names, or an anonymous context
    /// (a list of rules). A list whose first entry is a mapping is anonymous.
    fn contextRefs(r: *Registry, syn: *Syntax, v: yaml.Value, depth: u32) LoadError![]const ContextRef {
        const a = r.arena();
        switch (v.deref()) {
            .alias => unreachable,
            .scalar => |s| {
                try r.spend(1);
                const out = try a.alloc(ContextRef, 1);
                out[0] = .{ .name = s.text };
                return out;
            },
            .seq => |q| {
                const items = q.items.items;
                try r.spend(items.len);
                var anonymous = false;
                for (items) |it| if (it.deref() == .map) {
                    anonymous = true;
                };
                if (anonymous) {
                    if (depth >= max_context_depth) return r.bad("contexts are nested too deeply");
                    const c = try a.create(Context);
                    c.* = .{ .name = "<anonymous>", .syntax = syn };
                    try r.fillContext(syn, c, v, depth + 1);
                    const out = try a.alloc(ContextRef, 1);
                    out[0] = .{ .anon = c };
                    return out;
                }
                var out: std.ArrayList(ContextRef) = .empty;
                for (items) |it| try out.append(a, .{ .name = str(it) orelse "" });
                return out.items;
            },
            .map => return r.bad("push/set target is a mapping"),
        }
    }

    /// Expand {{variables}} in `pattern` using `syn`'s variables (recursively).
    /// `uses` counts the variables replaced: variables made of each other
    /// grow exponentially, so both it and the result are bounded.
    pub fn expand(r: *Registry, syn: *Syntax, pattern: []const u8, out: *std.ArrayList(u8), uses: *u32, depth: u32) error{ OutOfMemory, TooLong }!void {
        var i: usize = 0;
        while (i < pattern.len) {
            if (out.items.len > max_pattern_len) return error.TooLong;
            if (pattern[i] == '\\' and i + 1 < pattern.len) {
                try out.appendSlice(r.gpa, pattern[i .. i + 2]);
                i += 2;
                continue;
            }
            if (std.mem.startsWith(u8, pattern[i..], "{{")) {
                if (std.mem.indexOfPos(u8, pattern, i + 2, "}}")) |end| {
                    const name = pattern[i + 2 .. end];
                    const ok = name.len > 0 and for (name) |c| {
                        if (!(std.ascii.isAlphanumeric(c) or c == '_')) break false;
                    } else true;
                    if (ok and depth < 16) {
                        if (syn.variables.get(name)) |val| {
                            uses.* += 1;
                            if (uses.* > max_variable_uses) return error.TooLong;
                            try r.expand(syn, val, out, uses, depth + 1);
                            i = end + 2;
                            continue;
                        }
                    }
                }
            }
            try out.append(r.gpa, pattern[i]);
            i += 1;
        }
    }

    /// Compile `rule` on first use. Returns false when the pattern is invalid
    /// or unsupported (a warning is recorded and the rule never matches).
    pub fn ensureCompiled(r: *Registry, rule: *MatchRule) !bool {
        switch (rule.rt.state) {
            .ready => return true,
            .failed => return false,
            .uncompiled => {},
        }
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(r.gpa);
        var uses: u32 = 0;
        r.expand(rule.syntax, rule.pattern, &text, &uses, 0) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TooLong => {
                rule.rt.state = .failed;
                const msg = try std.fmt.allocPrint(r.arena(), "pattern /{s}/ rejected: its variables expand too far", .{rule.pattern});
                try r.warn(rule.syntax, msg);
                return false;
            },
        };

        var d: regex.Diagnostic = .{};
        var re = regex.Regex.compile(r.gpa, text.items, .{ .dialect = .oniguruma }, &d) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                rule.rt.state = .failed;
                const msg = try std.fmt.allocPrint(r.arena(), "pattern /{s}/ rejected: {s} (at {d})", .{ rule.pattern, d.message, d.pos });
                try r.warn(rule.syntax, msg);
                return false;
            },
        };
        errdefer re.deinit(r.gpa);
        var s = try searcherOf(re, r.gpa);
        errdefer s.deinit();
        const regs = try r.gpa.alloc(usize, 2 * (re.groupCount() + 1));
        rule.rt = .{
            .state = .ready,
            .re = re,
            .searcher = s,
            .cacheable = std.mem.indexOf(u8, text.items, "\\G") == null,
            .cache_regs = regs,
        };
        return true;
    }
};

/// regex-zig 0.3.0's `searcher` can report `error.GaveUp` (DFA cache exhausted);
/// creating one failing means no working memory, i.e. out of memory.
fn searcherOf(re: anytype, gpa: std.mem.Allocator) error{OutOfMemory}!@import("regex").Searcher {
    return re.searcher(gpa) catch error.OutOfMemory;
}

test "aliases are followed" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    const syn = try r.load(
        \\name: &n Aliased
        \\scope: source.aliased
        \\contexts:
        \\  main: &rules
        \\    - match: a
        \\      push: &inner
        \\        - match: b
        \\          pop: true
        \\    - match: c
        \\      push: *inner
        \\  other: *rules
    , "A.sublime-syntax");
    try std.testing.expectEqualStrings("Aliased", syn.name);
    try std.testing.expectEqual(2, syn.contexts.get("other").?.rules.len);
}

test "a context that contains itself is refused" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    try std.testing.expectError(error.InvalidSyntax, r.load(
        \\contexts:
        \\  main:
        \\    - match: a
        \\      push: &loop
        \\        - match: b
        \\          push: *loop
    , "L.sublime-syntax"));
    try std.testing.expectEqualStrings("contexts are nested too deeply", r.last_error);
}

test "aliases that unfold to too much are refused" {
    var r = Registry.init(std.testing.allocator);
    defer r.deinit();
    // Each level uses the one below twice: 2^24 rules from 24 short lines.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "contexts:\n  c0: &c0\n    - match: a\n");
    for (1..24) |i| try text.print(std.testing.allocator, "  c{d}: &c{d}\n    - {{match: a, push: *c{d}}}\n    - {{match: b, push: *c{d}}}\n", .{ i, i, i - 1, i - 1 });
    try text.appendSlice(std.testing.allocator, "  main: *c23\n");
    try std.testing.expectError(error.InvalidSyntax, r.load(text.items, "B.sublime-syntax"));
    try std.testing.expectEqualStrings("grammar expands to too many items", r.last_error);
}
