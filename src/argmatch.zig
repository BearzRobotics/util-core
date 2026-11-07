//! Port of gnulib argmatch: match an option argument against a table of
//! names (exact match, else unique prefix) and the standard diagnostics.

const std = @import("std");
const cli = @import("cli.zig");
const quotearg = @import("quotearg.zig");

pub const Entry = struct { name: []const u8, value: u32 };

pub const Result = union(enum) { ok: u32, invalid, ambiguous };

pub fn match(arg: []const u8, table: []const Entry) Result {
    var found: ?usize = null;
    var ambiguous = false;
    for (table, 0..) |e, i| {
        if (std.mem.startsWith(u8, e.name, arg)) {
            if (e.name.len == arg.len) return .{ .ok = e.value };
            if (found == null) {
                found = i;
            } else if (table[found.?].value != e.value) ambiguous = true;
        }
    }
    if (ambiguous) return .ambiguous;
    if (found) |f| return .{ .ok = table[f].value };
    return .invalid;
}

/// Print "invalid/ambiguous argument ... for 'CONTEXT'" plus the valid list
/// and the usage hint, as XARGMATCH does. The caller exits with status 1.
pub fn die(ctx: cli.Context, arg: []const u8, context: []const u8, table: []const Entry, r: Result) void {
    const q = quotearg.quoteAlloc(ctx.gpa, arg, .locale, null) catch return;
    defer ctx.gpa.free(q);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    const w = struct {
        fn p(b: *std.ArrayList(u8), g: std.mem.Allocator, comptime f: []const u8, a: anytype) void {
            const s = std.fmt.allocPrint(g, f, a) catch return;
            defer g.free(s);
            b.appendSlice(g, s) catch {};
        }
    }.p;
    w(&buf, ctx.gpa, "{s} argument {s} for {f}\nValid arguments are:", .{ if (r == .ambiguous) "ambiguous" else "invalid", q, cli.quoteC(context) });
    for (table, 0..) |e, i| {
        if (i == 0 or table[i - 1].value != e.value) {
            w(&buf, ctx.gpa, "\n  - {f}", .{cli.quoteC(e.name)});
        } else w(&buf, ctx.gpa, ", {f}", .{cli.quoteC(e.name)});
    }
    w(&buf, ctx.gpa, "\nTry '{s} --help' for more information.", .{ctx.name});
    cli.warn(ctx, "{s}", .{buf.items});
}
