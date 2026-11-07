//! getopt_long-compatible option parsing with glibc's diagnostics.
//!
//! Behaviour follows glibc getopt_long as the GNU tools use it: option
//! arguments may be permuted with operands (unless the spec starts with '+' or
//! POSIXLY_CORRECT is set), `--` ends options, bundled short options
//! (`-abc`, `-ofile`), long options with unique-prefix abbreviation and
//! `--opt=value` / `--opt value`. `--help` and `--version` are always present
//! and reported as `help_id` / `version_id`.

const std = @import("std");
const cli = @import("cli.zig");

pub const help_id: u32 = 1000;
pub const version_id: u32 = 1001;
/// Reported for each non-option argument when the spec starts with '-'
/// (getopt's RETURN_IN_ORDER mode); `Opt.arg` holds the argument.
pub const operand_id: u32 = 1002;

pub const Arg = enum { none, required, optional };

pub const Long = struct {
    name: []const u8,
    arg: Arg = .none,
    /// Value reported for this option; use the short option's character when
    /// the long option is an alias of a short one.
    id: u32,
};

pub const Opt = struct {
    id: u32,
    arg: ?[]const u8 = null,
    /// True when the option was written in its long form (`--name`).
    is_long: bool = false,
};

pub const Item = union(enum) {
    opt: Opt,
    /// No more options; operands are in `Parser.operands`.
    done,
    /// A diagnostic was printed; the caller exits with its usage status.
    bad,
};

pub const Parser = struct {
    ctx: cli.Context,
    /// Short option string as for getopt: "ab:c::"; a leading '+' stops
    /// option processing at the first operand.
    short: []const u8,
    longs: []const Long,
    index: usize = 0,
    /// Offset inside a bundle of short options (0 = not inside one).
    sub: usize = 0,
    stop_at_operand: bool,
    in_order: bool = false,
    ended: bool = false,
    operands: std.ArrayList([]const u8) = .empty,

    pub fn init(ctx: cli.Context, short: []const u8, longs: []const Long) Parser {
        var stop = cli.getenv(ctx, "POSIXLY_CORRECT") != null;
        var spec = short;
        var order = false;
        if (spec.len > 0 and spec[0] == '+') {
            stop = true;
            spec = spec[1..];
        } else if (spec.len > 0 and spec[0] == '-') {
            order = true;
            spec = spec[1..];
        }
        return .{ .ctx = ctx, .short = spec, .longs = longs, .stop_at_operand = stop, .in_order = order };
    }

    pub fn deinit(p: *Parser) void {
        p.operands.deinit(p.ctx.gpa);
    }

    fn pushOperand(p: *Parser, s: []const u8) void {
        p.operands.append(p.ctx.gpa, s) catch {};
    }

    fn shortKind(p: *const Parser, c: u8) ?Arg {
        if (c == ':') return null;
        const i = std.mem.indexOfScalar(u8, p.short, c) orelse return null;
        if (i + 1 < p.short.len and p.short[i + 1] == ':') {
            return if (i + 2 < p.short.len and p.short[i + 2] == ':') .optional else .required;
        }
        return .none;
    }

    /// The next option, or `.done` once only operands remain.
    pub fn next(p: *Parser) Item {
        const args = p.ctx.args;
        while (true) {
            if (p.sub == 0) {
                if (p.index >= args.len) return .done;
                const a: []const u8 = args[p.index];
                if (p.ended or a.len < 2 or a[0] != '-') {
                    if (p.in_order) {
                        p.index += 1;
                        return .{ .opt = .{ .id = operand_id, .arg = a } };
                    }
                    if (p.stop_at_operand and !p.ended) {
                        p.ended = true;
                        continue;
                    }
                    p.pushOperand(a);
                    p.index += 1;
                    continue;
                }
                if (std.mem.eql(u8, a, "--")) {
                    p.ended = true;
                    p.index += 1;
                    continue;
                }
                if (a[1] == '-') return p.long(a);
                p.sub = 1;
            }
            const a: []const u8 = args[p.index];
            const c = a[p.sub];
            p.sub += 1;
            const at_end = p.sub >= a.len;
            const kind = p.shortKind(c) orelse {
                cli.invalidShort(p.ctx, c);
                return .bad;
            };
            var value: ?[]const u8 = null;
            switch (kind) {
                .none => {},
                .optional => if (!at_end) {
                    value = a[p.sub..];
                    p.sub = a.len;
                },
                .required => {
                    if (!at_end) {
                        value = a[p.sub..];
                    } else if (p.index + 1 < args.len) {
                        p.index += 1;
                        value = args[p.index];
                    } else {
                        cli.warn(p.ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ c, p.ctx.name });
                        p.index += 1;
                        p.sub = 0;
                        return .bad;
                    }
                    p.sub = a.len;
                },
            }
            if (p.sub >= a.len) {
                p.sub = 0;
                p.index += 1;
            }
            return .{ .opt = .{ .id = c, .arg = value } };
        }
    }

    fn long(p: *Parser, a: []const u8) Item {
        const args = p.ctx.args;
        p.index += 1;
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const name = a[2 .. eq orelse a.len];
        var found: ?Long = null;
        var ambiguous = false;
        const builtin = [_]Long{
            .{ .name = "help", .id = help_id },
            .{ .name = "version", .id = version_id },
        };
        var exact = false;
        for ([_][]const Long{ p.longs, &builtin }) |table| {
            for (table) |l| {
                if (std.mem.eql(u8, l.name, name)) {
                    found = l;
                    exact = true;
                    break;
                }
                if (name.len > 0 and std.mem.startsWith(u8, l.name, name)) {
                    if (found) |f| {
                        if (f.id != l.id or f.arg != l.arg) ambiguous = true;
                    } else found = l;
                }
            }
            if (exact) break;
        }
        if (!exact and ambiguous) {
            var buf: [512]u8 = undefined;
            var n: usize = 0;
            for ([_][]const Long{ p.longs, &builtin }) |table| for (table) |l| {
                if (std.mem.startsWith(u8, l.name, name)) {
                    const piece = std.fmt.bufPrint(buf[n..], " '--{s}'", .{l.name}) catch break;
                    n += piece.len;
                }
            };
            cli.warn(p.ctx, "option '{s}' is ambiguous; possibilities:{s}\nTry '{s} --help' for more information.", .{ a, buf[0..n], p.ctx.name });
            return .bad;
        }
        const l = found orelse {
            cli.warn(p.ctx, "unrecognized option '{s}'\nTry '{s} --help' for more information.", .{ a, p.ctx.name });
            return .bad;
        };
        var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
        switch (l.arg) {
            .none => if (value != null) {
                cli.warn(p.ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ l.name, p.ctx.name });
                return .bad;
            },
            .required => if (value == null) {
                if (p.index < args.len) {
                    value = args[p.index];
                    p.index += 1;
                } else {
                    cli.warn(p.ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ l.name, p.ctx.name });
                    return .bad;
                }
            },
            .optional => {},
        }
        return .{ .opt = .{ .id = l.id, .arg = value, .is_long = true } };
    }
};

/// "Try 'x --help'" missing-operand style usage diagnostic helper.
pub fn usageError(ctx: cli.Context, comptime fmt: []const u8, args: anytype) void {
    cli.warn(ctx, fmt ++ "\nTry '{s} --help' for more information.", args ++ .{ctx.name});
}

test "bundled shorts, long abbreviations and permutation" {
    const t = std.testing;
    const argv = [_][:0]const u8{ "a", "-xvf", "file", "--verb", "b", "--", "-c" };
    const ctx: cli.Context = .{ .name = "t", .args = &argv, .io = undefined, .gpa = t.allocator };
    var p = Parser.init(ctx, "xvf:", &.{.{ .name = "verbose", .id = 'v' }});
    defer p.deinit();
    try t.expectEqual(@as(u32, 'x'), p.next().opt.id);
    try t.expectEqual(@as(u32, 'v'), p.next().opt.id);
    const f = p.next().opt;
    try t.expectEqual(@as(u32, 'f'), f.id);
    try t.expectEqualStrings("file", f.arg.?);
    try t.expectEqual(@as(u32, 'v'), p.next().opt.id);
    try t.expect(p.next() == .done);
    try t.expectEqual(@as(usize, 3), p.operands.items.len);
    try t.expectEqualStrings("-c", p.operands.items[2]);
}
