// SPDX-License-Identifier: GPL-2.0-or-later
//! Maps Sublime scope names to terminal colors (SGR sequences).
//!
//! A theme is a list of rules. A scope is colored by the longest rule prefix
//! that matches it at a '.' boundary; among the scopes of a token the
//! innermost one that has a color wins. A rule can name a palette color (0..15,
//! which follows the user's terminal palette) or an RGB color, which is
//! written as 24-bit, 256-color or 16-color escapes according to what the
//! terminal supports. Results are memoised per scope id.
//!
//! The built-in themes are `ansi` (16 palette colors, the safe default),
//! `night`, `ember` (dark) and `day`, `paper` (light). Users add their own
//! with `parse` (a small text format, see docs/compatibility/cat.md).

const std = @import("std");
const def = @import("definition.zig");

pub const Depth = enum { ansi16, ansi256, truecolor };

pub const Color = union(enum) {
    default,
    /// 0..7 normal, 8..15 bright: the terminal's own palette.
    palette: u8,
    rgb: [3]u8,
};

pub const Rule = struct {
    prefix: []const u8,
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    /// No color of its own: look at the next scope outward (punctuation in a
    /// string takes the string's color).
    inherit: bool = false,
};

fn pal(prefix: []const u8, n: u8) Rule {
    return .{ .prefix = prefix, .fg = .{ .palette = n } };
}

fn hex(v: u24) Color {
    return .{ .rgb = .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) } };
}

/// Order does not matter; the longest matching prefix wins (a later rule of
/// the same length wins over an earlier one).
pub const default_rules = [_]Rule{
    pal("comment", 8),
    pal("string", 2),
    pal("constant", 3),
    pal("constant.character.escape", 6),
    pal("constant.language", 5),
    pal("keyword", 5),
    pal("keyword.operator", 1),
    pal("storage", 5),
    pal("entity.name.function", 4),
    pal("entity.name", 6),
    pal("entity.other.inherited-class", 6),
    pal("support.function", 4),
    pal("support", 6),
    pal("variable.parameter", 3),
    pal("variable.language", 5),
    pal("meta.annotation", 3),
    pal("meta.preprocessor", 5),
    .{ .prefix = "invalid", .fg = .{ .palette = 15 }, .bg = .{ .palette = 1 } },
    .{ .prefix = "punctuation", .inherit = true },
};

const Palette = struct {
    comment: u24,
    string: u24,
    number: u24,
    escape: u24,
    language: u24,
    keyword: u24,
    operator: u24,
    function: u24,
    type: u24,
    support: u24,
    param: u24,
    annotation: u24,
    preproc: u24,
    invalid_fg: u24,
    invalid_bg: u24,
};

fn fromPalette(comptime p: Palette) [19]Rule {
    return .{
        .{ .prefix = "comment", .fg = hex(p.comment), .italic = true },
        .{ .prefix = "string", .fg = hex(p.string) },
        .{ .prefix = "constant", .fg = hex(p.number) },
        .{ .prefix = "constant.character.escape", .fg = hex(p.escape) },
        .{ .prefix = "constant.language", .fg = hex(p.language) },
        .{ .prefix = "keyword", .fg = hex(p.keyword) },
        .{ .prefix = "keyword.operator", .fg = hex(p.operator) },
        .{ .prefix = "storage", .fg = hex(p.keyword) },
        .{ .prefix = "entity.name.function", .fg = hex(p.function) },
        .{ .prefix = "entity.name", .fg = hex(p.type) },
        .{ .prefix = "entity.other.inherited-class", .fg = hex(p.type) },
        .{ .prefix = "support.function", .fg = hex(p.function) },
        .{ .prefix = "support", .fg = hex(p.support) },
        .{ .prefix = "variable.parameter", .fg = hex(p.param) },
        .{ .prefix = "variable.language", .fg = hex(p.language) },
        .{ .prefix = "meta.annotation", .fg = hex(p.annotation) },
        .{ .prefix = "meta.preprocessor", .fg = hex(p.preproc) },
        .{ .prefix = "invalid", .fg = hex(p.invalid_fg), .bg = hex(p.invalid_bg) },
        .{ .prefix = "punctuation", .inherit = true },
    };
}

const night_rules = fromPalette(.{
    .comment = 0x6c7a8c, .string = 0x9ece6a, .number = 0xff9e64, .escape = 0x7dcfff,
    .language = 0xbb9af7, .keyword = 0xf7768e, .operator = 0x89ddff, .function = 0x7aa2f7,
    .type = 0xe0af68, .support = 0x2ac3de, .param = 0xffc777, .annotation = 0xe0af68,
    .preproc = 0xbb9af7, .invalid_fg = 0xffffff, .invalid_bg = 0xc53b53,
});

const ember_rules = fromPalette(.{
    .comment = 0x8a7f72, .string = 0xb8c47a, .number = 0xe8a15c, .escape = 0x7fc4b8,
    .language = 0xd68fb0, .keyword = 0xe46a5a, .operator = 0xd9a86c, .function = 0xe6c15a,
    .type = 0x8fb4d9, .support = 0x7fc4b8, .param = 0xe8a15c, .annotation = 0xd9a86c,
    .preproc = 0xd68fb0, .invalid_fg = 0xffffff, .invalid_bg = 0xb23a2e,
});

const day_rules = fromPalette(.{
    .comment = 0x7a8394, .string = 0x2e7d32, .number = 0xb85c00, .escape = 0x00838f,
    .language = 0x7b3fb0, .keyword = 0xc2185b, .operator = 0x00796b, .function = 0x1a5fb4,
    .type = 0x9a6700, .support = 0x00697a, .param = 0x8a4b00, .annotation = 0x9a6700,
    .preproc = 0x7b3fb0, .invalid_fg = 0xffffff, .invalid_bg = 0xc62828,
});

const paper_rules = fromPalette(.{
    .comment = 0x8c8577, .string = 0x5b7a1e, .number = 0xa8531a, .escape = 0x2a7f78,
    .language = 0x8a3f6b, .keyword = 0xa3321f, .operator = 0x7a6420, .function = 0x1f5f8b,
    .type = 0x7a5c14, .support = 0x2a7f78, .param = 0xa8531a, .annotation = 0x7a5c14,
    .preproc = 0x8a3f6b, .invalid_fg = 0xffffff, .invalid_bg = 0xa3321f,
});

pub const Builtin = struct {
    name: []const u8,
    rules: []const Rule,
    /// For choosing a theme by the terminal background.
    light: bool,
};

pub const builtin_themes = [_]Builtin{
    .{ .name = "ansi", .rules = &default_rules, .light = false },
    .{ .name = "night", .rules = &night_rules, .light = false },
    .{ .name = "ember", .rules = &ember_rules, .light = false },
    .{ .name = "day", .rules = &day_rules, .light = true },
    .{ .name = "paper", .rules = &paper_rules, .light = true },
};

pub fn findBuiltin(name: []const u8) ?*const Builtin {
    for (&builtin_themes) |*t| if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
    return null;
}

/// Parse a theme file. One rule per line: `scope = color [bold] [italic]
/// [underline] [on color]`, where a color is `#rrggbb`, a palette number
/// 0..15, or `inherit`. `extends = NAME` (a built-in theme) starts from that
/// theme; `#` starts a comment line. Returns null on a malformed line.
fn parseInner(gpa: std.mem.Allocator, text: []const u8) error{ OutOfMemory, Malformed }![]Rule {
    var rules: std.ArrayList(Rule) = .empty;
    errdefer {
        freeRules(gpa, rules.items);
        rules.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Malformed;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return error.Malformed;
        if (std.mem.eql(u8, key, "extends")) {
            const base = findBuiltin(value) orelse return error.Malformed;
            for (base.rules) |r| try rules.append(gpa, .{
                .prefix = try gpa.dupe(u8, r.prefix),
                .fg = r.fg,
                .bg = r.bg,
                .bold = r.bold,
                .italic = r.italic,
                .underline = r.underline,
                .inherit = r.inherit,
            });
            continue;
        }
        var rule: Rule = .{ .prefix = try gpa.dupe(u8, key) };
        errdefer gpa.free(rule.prefix);
        var words = std.mem.tokenizeAny(u8, value, " \t");
        var on_bg = false;
        var seen_fg = false;
        while (words.next()) |w| {
            if (std.mem.eql(u8, w, "bold")) {
                rule.bold = true;
            } else if (std.mem.eql(u8, w, "italic")) {
                rule.italic = true;
            } else if (std.mem.eql(u8, w, "underline")) {
                rule.underline = true;
            } else if (std.mem.eql(u8, w, "on")) {
                on_bg = true;
            } else if (std.mem.eql(u8, w, "inherit")) {
                rule.inherit = true;
            } else {
                const c = parseColor(w) orelse return error.Malformed;
                if (on_bg) rule.bg = c else rule.fg = c;
                seen_fg = seen_fg or !on_bg;
            }
        }
        try rules.append(gpa, rule);
    }
    return try rules.toOwnedSlice(gpa);
}

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !?[]Rule {
    return parseInner(gpa, text) catch |e| switch (e) {
        error.Malformed => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn parseColor(w: []const u8) ?Color {
    if (w.len == 7 and w[0] == '#') {
        const v = std.fmt.parseInt(u24, w[1..], 16) catch return null;
        return hex(v);
    }
    const n = std.fmt.parseInt(u8, w, 10) catch return null;
    return if (n < 16) .{ .palette = n } else null;
}

pub fn freeRules(gpa: std.mem.Allocator, rules: []const Rule) void {
    for (rules) |r| gpa.free(r.prefix);
}

fn cube(c: u8) u8 {
    if (c < 48) return 0;
    if (c < 115) return 1;
    return @intCast((@as(u16, c) - 35) / 40);
}

fn gray256(r: u8, g: u8, b: u8) ?u8 {
    const avg = (@as(u16, r) + g + b) / 3;
    if (@max(r, @max(g, b)) - @min(r, @min(g, b)) > 10) return null;
    if (avg < 8) return 16;
    if (avg > 248) return 231;
    return @intCast(232 + (avg - 8) / 10);
}

fn to256(c: [3]u8) u8 {
    if (gray256(c[0], c[1], c[2])) |g| return g;
    return 16 + 36 * cube(c[0]) + 6 * cube(c[1]) + cube(c[2]);
}

/// Nearest of the 16 palette colors.
fn to16(c: [3]u8) u8 {
    const bright = @as(u16, c[0]) + c[1] + c[2] > 3 * 170;
    const r: u8 = if (c[0] > 127) 1 else 0;
    const g: u8 = if (c[1] > 127) 1 else 0;
    const b: u8 = if (c[2] > 127) 1 else 0;
    var n: u8 = r | (g << 1) | (b << 2);
    if (n == 0 and @as(u16, c[0]) + c[1] + c[2] > 3 * 90) return 8;
    if (bright and n != 0) n += 8;
    return n;
}

fn appendColor(w: *std.Io.Writer, c: Color, depth: Depth, fg: bool) !void {
    switch (c) {
        .default => {},
        .palette => |n| {
            const base: u8 = if (fg) 30 else 40;
            if (n < 8) try w.print("{d}", .{base + n}) else try w.print("{d}", .{base + 60 + n - 8});
        },
        .rgb => |v| switch (depth) {
            .truecolor => try w.print("{d};2;{d};{d};{d}", .{ if (fg) @as(u8, 38) else 48, v[0], v[1], v[2] }),
            .ansi256 => try w.print("{d};5;{d}", .{ if (fg) @as(u8, 38) else 48, to256(v) }),
            .ansi16 => try appendColor(w, .{ .palette = to16(v) }, depth, fg),
        },
    }
}

/// The escape sequence for a rule at a color depth (null: no attributes).
pub fn renderSgr(r: Rule, depth: Depth, buf: []u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("\x1b[") catch return null;
    var first = true;
    const flags = [_]struct { on: bool, code: []const u8 }{
        .{ .on = r.bold, .code = "1" },
        .{ .on = r.italic, .code = "3" },
        .{ .on = r.underline, .code = "4" },
    };
    for (flags) |f| if (f.on) {
        if (!first) w.writeByte(';') catch return null;
        w.writeAll(f.code) catch return null;
        first = false;
    };
    inline for (.{ .{ r.fg, true }, .{ r.bg, false } }) |cb| {
        if (cb[0] != .default) {
            if (!first) w.writeByte(';') catch return null;
            appendColor(&w, cb[0], depth, cb[1]) catch return null;
            first = false;
        }
    }
    if (first) return null;
    w.writeByte('m') catch return null;
    return w.buffered();
}

/// Entries of the memo that are no rule's index; a theme file holds far fewer
/// rules than these.
const not_computed: u32 = 0xffff_ffff;
const no_color: u32 = 0xffff_fffe;

const Rendered = struct { buf: [64]u8 = undefined, len: u8 = 0, done: bool = false };

pub const Theme = struct {
    rules: []const Rule = &default_rules,
    depth: Depth = .ansi16,
    /// `rules` came from `parse` and are freed with the theme.
    owned: bool = false,
    memo: std.ArrayList(u32) = .empty,
    rendered: std.ArrayList(Rendered) = .empty,

    pub fn deinit(t: *Theme, gpa: std.mem.Allocator) void {
        t.memo.deinit(gpa);
        t.rendered.deinit(gpa);
        if (t.owned) {
            freeRules(gpa, t.rules);
            gpa.free(t.rules);
            t.owned = false;
        }
    }

    /// Switch to another rule set (drops what was computed).
    pub fn use(t: *Theme, gpa: std.mem.Allocator, rules: []const Rule, owned: bool, depth: Depth) void {
        if (t.owned) {
            freeRules(gpa, t.rules);
            gpa.free(t.rules);
        }
        t.rules = rules;
        t.owned = owned;
        t.depth = depth;
        t.memo.clearRetainingCapacity();
        t.rendered.clearRetainingCapacity();
    }

    /// Index of the best rule for `name`, or null.
    fn lookup(t: *const Theme, name: []const u8) ?usize {
        var best: ?usize = null;
        var best_len: usize = 0;
        for (t.rules, 0..) |r, i| {
            if (r.prefix.len < best_len) continue;
            const hit = std.mem.eql(u8, name, r.prefix) or
                (name.len > r.prefix.len and std.mem.startsWith(u8, name, r.prefix) and name[r.prefix.len] == '.');
            if (hit and r.prefix.len >= best_len) {
                best = i;
                best_len = r.prefix.len;
            }
        }
        return best;
    }

    fn sgrOf(t: *Theme, gpa: std.mem.Allocator, idx: usize) !?[]const u8 {
        while (t.rendered.items.len < t.rules.len) try t.rendered.append(gpa, .{});
        const slot = &t.rendered.items[idx];
        if (!slot.done) {
            slot.done = true;
            const r = t.rules[idx];
            if (r.inherit) {
                slot.len = 0;
            } else if (renderSgr(r, t.depth, &slot.buf)) |text| slot.len = @intCast(text.len);
        }
        return if (slot.len == 0) null else slot.buf[0..slot.len];
    }

    /// SGR sequence for a token with these scopes (outermost first), or null
    /// for the terminal's default color.
    pub fn colorFor(t: *Theme, gpa: std.mem.Allocator, reg: *const def.Registry, scopes: []const def.ScopeId) !?[]const u8 {
        var k = scopes.len;
        while (k > 0) {
            k -= 1;
            const id = scopes[k];
            while (t.memo.items.len <= id) try t.memo.append(gpa, not_computed);
            if (t.memo.items[id] == not_computed) {
                t.memo.items[id] = if (t.lookup(reg.scopeName(id))) |i| @intCast(i) else no_color;
            }
            const m = t.memo.items[id];
            if (m == no_color) continue;
            // An inherit rule (or one with no attributes) means "keep looking outward".
            const sgr = (try t.sgrOf(gpa, m)) orelse continue;
            return sgr;
        }
        return null;
    }
};

test "longest prefix wins, boundary respected, innermost scope wins" {
    const gpa = std.testing.allocator;
    var reg = def.Registry.init(gpa);
    defer reg.deinit();
    var t: Theme = .{};
    defer t.deinit(gpa);

    const comment = try reg.intern("comment.line.rust");
    const string = try reg.intern("string.quoted.double");
    const esc = try reg.intern("constant.character.escape.rust");
    const num = try reg.intern("constant.numeric.hex");
    const punct = try reg.intern("punctuation.definition.string.begin");
    const commentary = try reg.intern("commentary.foo"); // not "comment" + '.'
    const meta = try reg.intern("meta.block");

    try std.testing.expectEqualStrings("\x1b[90m", (try t.colorFor(gpa, &reg, &.{comment})).?);
    try std.testing.expectEqualStrings("\x1b[36m", (try t.colorFor(gpa, &reg, &.{ string, esc })).?);
    try std.testing.expectEqualStrings("\x1b[33m", (try t.colorFor(gpa, &reg, &.{num})).?);
    // Punctuation inside a string takes the string color.
    try std.testing.expectEqualStrings("\x1b[32m", (try t.colorFor(gpa, &reg, &.{ string, punct })).?);
    try std.testing.expect((try t.colorFor(gpa, &reg, &.{commentary})) == null);
    try std.testing.expect((try t.colorFor(gpa, &reg, &.{meta})) == null);
    try std.testing.expect((try t.colorFor(gpa, &reg, &.{})) == null);
}

test "rgb is reduced to the terminal's depth" {
    var buf: [64]u8 = undefined;
    const r: Rule = .{ .prefix = "x", .fg = hex(0xff9e64), .italic = true };
    try std.testing.expectEqualStrings("\x1b[3;38;2;255;158;100m", renderSgr(r, .truecolor, &buf).?);
    try std.testing.expectEqualStrings("\x1b[3;38;5;215m", renderSgr(r, .ansi256, &buf).?);
    try std.testing.expect(renderSgr(r, .ansi16, &buf).?.len > 0);
    try std.testing.expectEqualStrings("\x1b[90m", renderSgr(pal("c", 8), .truecolor, &buf).?);
    try std.testing.expectEqualStrings("\x1b[97;41m", renderSgr(default_rules[17], .ansi16, &buf).?);
}

test "theme files" {
    const gpa = std.testing.allocator;
    const rules = (try parse(gpa,
        \\# mine
        \\extends = ansi
        \\comment = #112233 italic
        \\string = 4 bold on 0
    )).?;
    var t: Theme = .{};
    t.use(gpa, rules, true, .truecolor);
    defer t.deinit(gpa);
    var reg = def.Registry.init(gpa);
    defer reg.deinit();
    const c = try reg.intern("comment.line");
    const s = try reg.intern("string.quoted");
    try std.testing.expectEqualStrings("\x1b[3;38;2;17;34;51m", (try t.colorFor(gpa, &reg, &.{c})).?);
    try std.testing.expectEqualStrings("\x1b[1;34;40m", (try t.colorFor(gpa, &reg, &.{s})).?);
    try std.testing.expect((try parse(gpa, "no equals here")) == null);
    try std.testing.expect((try parse(gpa, "comment = zzz")) == null);
}
