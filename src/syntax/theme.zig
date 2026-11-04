//! Maps Sublime scope names to terminal colors (SGR sequences).
//!
//! The default theme uses only the 16 standard ANSI colors so it follows the
//! user's terminal palette. A scope is colored by the longest rule prefix that
//! matches it at a '.' boundary; among the scopes of a token the innermost one
//! that has a color wins. Results are memoised per scope id.

const std = @import("std");
const def = @import("definition.zig");

pub const Rule = struct { prefix: []const u8, sgr: []const u8 };

/// Order does not matter; the longest matching prefix wins.
pub const default_rules = [_]Rule{
    .{ .prefix = "comment", .sgr = "\x1b[90m" },
    .{ .prefix = "string", .sgr = "\x1b[32m" },
    .{ .prefix = "constant", .sgr = "\x1b[33m" },
    .{ .prefix = "constant.character.escape", .sgr = "\x1b[36m" },
    .{ .prefix = "constant.language", .sgr = "\x1b[35m" },
    .{ .prefix = "keyword", .sgr = "\x1b[35m" },
    .{ .prefix = "keyword.operator", .sgr = "\x1b[31m" },
    .{ .prefix = "storage", .sgr = "\x1b[35m" },
    .{ .prefix = "entity.name.function", .sgr = "\x1b[34m" },
    .{ .prefix = "entity.name", .sgr = "\x1b[36m" },
    .{ .prefix = "entity.other.inherited-class", .sgr = "\x1b[36m" },
    .{ .prefix = "support.function", .sgr = "\x1b[34m" },
    .{ .prefix = "support", .sgr = "\x1b[36m" },
    .{ .prefix = "variable.parameter", .sgr = "\x1b[33m" },
    .{ .prefix = "variable.language", .sgr = "\x1b[35m" },
    .{ .prefix = "meta.annotation", .sgr = "\x1b[33m" },
    .{ .prefix = "invalid", .sgr = "\x1b[41;97m" },
    // Punctuation inside a string or comment inherits the outer color: an
    // explicit empty rule stops a broader match from applying.
    .{ .prefix = "punctuation", .sgr = "" },
};

const not_computed: u16 = 0xffff;
const no_color: u16 = 0xfffe;

pub const Theme = struct {
    rules: []const Rule = &default_rules,
    memo: std.ArrayList(u16) = .empty,

    pub fn deinit(t: *Theme, gpa: std.mem.Allocator) void {
        t.memo.deinit(gpa);
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
            const sgr = t.rules[m].sgr;
            // An empty rule means "keep looking outward".
            if (sgr.len == 0) continue;
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
