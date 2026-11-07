//! expr — evaluate expressions.
//! Reference: GNU coreutils manual "expr invocation" (9.7); POSIX.1-2024 expr.
//!
//! Integers have arbitrary size (std.math.big). The `:` operator takes a
//! POSIX basic regular expression anchored at the start (src/posixre.zig).
//! Exit status: 0 result is neither null nor 0, 1 null or 0, 2 syntax error,
//! 3 other errors (GNU 9.7 reports a division by zero with status 2 here).

const std = @import("std");
const cli = @import("../cli.zig");
const posixre = @import("../posixre.zig");
const big = std.math.big.int;

const Error = error{ Syntax, Fatal };

const Parser = struct {
    ctx: cli.Context,
    toks: []const [:0]const u8,
    pos: usize = 0,
    /// Nonzero while parsing an operand that short-circuiting means is never
    /// evaluated (GNU: no errors, no results; `0 & 1 / 0` is 0).
    skip: u32 = 0,
    arena: std.heap.ArenaAllocator,

    fn alloc(p: *Parser) std.mem.Allocator {
        return p.arena.allocator();
    }

    fn peek(p: *const Parser) ?[]const u8 {
        return if (p.pos < p.toks.len) p.toks[p.pos] else null;
    }

    fn syntax(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        cli.warn(p.ctx, "syntax error: " ++ fmt, args);
        return error.Syntax;
    }

    fn fatal(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        cli.warn(p.ctx, fmt, args);
        return error.Fatal;
    }

    fn missingAfter(p: *Parser) Error {
        return p.syntax("missing argument after {f}", .{cli.quoteC(p.toks[p.toks.len - 1])});
    }

    fn orExpr(p: *Parser) Error![]const u8 {
        var v = try p.andExpr();
        while (p.peek()) |t| {
            if (!std.mem.eql(u8, t, "|")) break;
            p.pos += 1;
            if (p.pos >= p.toks.len) return p.missingAfter();
            const live = isNull(v);
            if (!live) p.skip += 1;
            const r = p.andExpr() catch |e| {
                if (!live) p.skip -= 1;
                return e;
            };
            if (!live) p.skip -= 1;
            if (live) v = if (isNull(r)) "0" else r;
        }
        return v;
    }

    fn andExpr(p: *Parser) Error![]const u8 {
        var v = try p.cmpExpr();
        while (p.peek()) |t| {
            if (!std.mem.eql(u8, t, "&")) break;
            p.pos += 1;
            if (p.pos >= p.toks.len) return p.missingAfter();
            const live = !isNull(v);
            if (!live) p.skip += 1;
            const r = p.cmpExpr() catch |e| {
                if (!live) p.skip -= 1;
                return e;
            };
            if (!live) p.skip -= 1;
            if (!live or isNull(r)) v = "0";
        }
        return v;
    }

    fn cmpExpr(p: *Parser) Error![]const u8 {
        var v = try p.addExpr();
        while (p.peek()) |t| {
            const ops = [_][]const u8{ "=", "==", "!=", "<", "<=", ">", ">=" };
            var found: ?usize = null;
            for (ops, 0..) |o, i| if (std.mem.eql(u8, t, o)) {
                found = i;
                break;
            };
            const op = found orelse break;
            p.pos += 1;
            if (p.pos >= p.toks.len) return p.missingAfter();
            const r = try p.addExpr();
            const c: i32 = blk: {
                if (isInt(v) and isInt(r)) break :blk cmpInts(v, r);
                break :blk switch (std.mem.order(u8, v, r)) {
                    .lt => -1,
                    .eq => 0,
                    .gt => 1,
                };
            };
            const truth = switch (op) {
                0, 1 => c == 0,
                2 => c != 0,
                3 => c < 0,
                4 => c <= 0,
                5 => c > 0,
                else => c >= 0,
            };
            v = if (truth) "1" else "0";
        }
        return v;
    }

    fn addExpr(p: *Parser) Error![]const u8 {
        var v = try p.mulExpr();
        while (p.peek()) |t| {
            const plus = std.mem.eql(u8, t, "+");
            if (!plus and !std.mem.eql(u8, t, "-")) break;
            p.pos += 1;
            if (p.pos >= p.toks.len) return p.missingAfter();
            const r = try p.mulExpr();
            v = try p.arith(if (plus) '+' else '-', v, r);
        }
        return v;
    }

    fn mulExpr(p: *Parser) Error![]const u8 {
        var v = try p.matchExpr();
        while (p.peek()) |t| {
            const op: u8 = if (std.mem.eql(u8, t, "*")) '*' else if (std.mem.eql(u8, t, "/")) '/' else if (std.mem.eql(u8, t, "%")) '%' else break;
            p.pos += 1;
            if (p.pos >= p.toks.len) return p.missingAfter();
            const r = try p.matchExpr();
            v = try p.arith(op, v, r);
        }
        return v;
    }

    fn matchExpr(p: *Parser) Error![]const u8 {
        var v = try p.primary();
        while (p.peek()) |t| {
            if (!std.mem.eql(u8, t, ":")) break;
            p.pos += 1;
            if (p.pos >= p.toks.len) return p.missingAfter();
            const r = try p.primary();
            v = try p.regexMatch(v, r);
        }
        return v;
    }

    fn primary(p: *Parser) Error![]const u8 {
        const t = p.peek() orelse return p.missingAfter();
        p.pos += 1;
        if (std.mem.eql(u8, t, "(")) {
            if (p.pos >= p.toks.len) return p.missingAfter();
            const v = try p.orExpr();
            const close = p.peek() orelse return p.syntax("expecting {f} after {f}", .{ cli.quoteC(")"), cli.quoteC(p.toks[p.toks.len - 1]) });
            if (!std.mem.eql(u8, close, ")")) return p.syntax("expecting {f} instead of {f}", .{ cli.quoteC(")"), cli.quoteC(close) });
            p.pos += 1;
            return v;
        }
        if (std.mem.eql(u8, t, "+")) {
            const q = p.peek() orelse return p.missingAfter();
            p.pos += 1;
            return q;
        }
        if (std.mem.eql(u8, t, "length") and p.pos < p.toks.len) {
            const s = try p.primary();
            return std.fmt.allocPrint(p.alloc(), "{d}", .{s.len}) catch return error.Fatal;
        }
        if (std.mem.eql(u8, t, "match") and p.pos + 1 < p.toks.len + 0) {
            const s = try p.primary();
            const r = try p.primary();
            return p.regexMatch(s, r);
        }
        if (std.mem.eql(u8, t, "index") and p.pos < p.toks.len) {
            const s = try p.primary();
            const chars = try p.primary();
            for (s, 0..) |c, i| if (std.mem.indexOfScalar(u8, chars, c) != null) return std.fmt.allocPrint(p.alloc(), "{d}", .{i + 1}) catch return error.Fatal;
            return "0";
        }
        if (std.mem.eql(u8, t, "substr") and p.pos < p.toks.len) {
            const s = try p.primary();
            const pos_v = try p.primary();
            const len_v = try p.primary();
            // GNU: a non-integer POS or LENGTH gives the null string.
            if (p.skip > 0 or !isInt(pos_v) or !isInt(len_v)) return "";
            const pos = try p.intOf(pos_v);
            const len = try p.intOf(len_v);
            return substr(p.alloc(), s, pos, len) catch return error.Fatal;
        }
        return t;
    }

    fn intOf(p: *Parser, v: []const u8) Error!i128 {
        if (!isInt(v)) return p.fatal("non-integer argument", .{});
        return std.fmt.parseInt(i128, v, 10) catch if (v[0] == '-') std.math.minInt(i128) else std.math.maxInt(i128);
    }

    fn arith(p: *Parser, op: u8, a: []const u8, b: []const u8) Error![]const u8 {
        if (p.skip > 0) return "0";
        if (!isInt(a) or !isInt(b)) return p.fatal("non-integer argument", .{});
        const gpa = p.alloc();
        var x = big.Managed.init(gpa) catch return error.Fatal;
        var y = big.Managed.init(gpa) catch return error.Fatal;
        x.setString(10, a) catch return error.Fatal;
        y.setString(10, b) catch return error.Fatal;
        var r = big.Managed.init(gpa) catch return error.Fatal;
        switch (op) {
            '+' => r.add(&x, &y) catch return error.Fatal,
            '-' => r.sub(&x, &y) catch return error.Fatal,
            '*' => r.mul(&x, &y) catch return error.Fatal,
            else => {
                if (y.eqlZero()) return p.fatal("division by zero", .{});
                var q = big.Managed.init(gpa) catch return error.Fatal;
                var m = big.Managed.init(gpa) catch return error.Fatal;
                // Truncated division, as C: the remainder has the sign of x.
                big.Managed.divTrunc(&q, &m, &x, &y) catch return error.Fatal;
                r = if (op == '/') q else m;
            },
        }
        return r.toString(gpa, 10, .lower) catch error.Fatal;
    }

    fn regexMatch(p: *Parser, subject: []const u8, pattern: []const u8) Error![]const u8 {
        if (p.skip > 0) return "0";
        const gpa = p.alloc();
        var c = posixre.compileMode(gpa, pattern, false, false, true) catch |e| switch (e) {
            error.BadPattern => return p.fatal("{s}", .{posixre.diagnose(pattern)}),
            else => return error.Fatal,
        };
        var searcher = c.re.searcher(gpa) catch return error.Fatal;
        defer searcher.deinit();
        const m = (searcher.find(subject, 0) catch return p.fatal("Regular expression too big", .{})) orelse {
            return if (c.groups > 0) "" else "0";
        };
        if (c.groups > 0) {
            const g = m.group(1) orelse return "";
            return subject[g[0]..g[1]];
        }
        return std.fmt.allocPrint(gpa, "{d}", .{m.end() - m.start()}) catch error.Fatal;
    }
};

fn substr(gpa: std.mem.Allocator, s: []const u8, pos: i128, len: i128) ![]const u8 {
    if (pos <= 0 or len <= 0 or pos > s.len) return "";
    const start: usize = @intCast(pos - 1);
    const n: usize = @intCast(@min(len, @as(i128, @intCast(s.len - start))));
    return gpa.dupe(u8, s[start .. start + n]);
}

fn isInt(v: []const u8) bool {
    if (v.len == 0) return false;
    var i: usize = 0;
    if (v[0] == '-') i = 1;
    if (i >= v.len) return false;
    for (v[i..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isNull(v: []const u8) bool {
    if (v.len == 0) return true;
    if (!isInt(v)) return false;
    for (v) |c| if (c != '-' and c != '0') return false;
    return true;
}

fn cmpInts(a: []const u8, b: []const u8) i32 {
    const na = a[0] == '-';
    const nb = b[0] == '-';
    const da = std.mem.trimStart(u8, if (na) a[1..] else a, "0");
    const db = std.mem.trimStart(u8, if (nb) b[1..] else b, "0");
    const za = da.len == 0;
    const zb = db.len == 0;
    const sa: i32 = if (za) 0 else if (na) -1 else 1;
    const sb: i32 = if (zb) 0 else if (nb) -1 else 1;
    if (sa != sb) return if (sa < sb) -1 else 1;
    if (sa == 0) return 0;
    var c: i32 = if (da.len != db.len) (if (da.len < db.len) -1 else 1) else switch (std.mem.order(u8, da, db)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    if (sa < 0) c = -c;
    return c;
}

pub fn main(ctx: cli.Context) u8 {
    var args: []const [:0]const u8 = ctx.args;
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return help(ctx);
    if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) return if (cli.printVersion(ctx)) 0 else 1;
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args = args[1..];
    if (args.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 2;
    }
    var p: Parser = .{ .ctx = ctx, .toks = args, .arena = std.heap.ArenaAllocator.init(ctx.gpa) };
    defer p.arena.deinit();
    const v = p.orExpr() catch |e| return if (e == error.Syntax) 2 else 2;
    if (p.pos < args.len) {
        cli.warn(ctx, "syntax error: unexpected argument {f}", .{cli.quoteC(args[p.pos])});
        return 2;
    }
    var buf: [128]u8 = undefined;
    _ = &buf;
    const out = std.fmt.allocPrint(ctx.gpa, "{s}\n", .{v}) catch return 3;
    defer ctx.gpa.free(out);
    if (!cli.writeStdout(ctx.io, out)) return 3;
    return if (isNull(v)) 1 else 0;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: expr EXPRESSION\n  or:  expr OPTION\n\n      --help        display this help and exit\n      --version     output version information and exit\n\nPrint the value of EXPRESSION to standard output.  A blank line below\nseparates increasing precedence groups.  EXPRESSION may be:\n\n  ARG1 | ARG2       ARG1 if it is neither null nor 0, otherwise ARG2\n\n  ARG1 & ARG2       ARG1 if neither argument is null or 0, otherwise 0\n\n  ARG1 < ARG2       ARG1 is less than ARG2\n  ARG1 <= ARG2      ARG1 is less than or equal to ARG2\n  ARG1 = ARG2       ARG1 is equal to ARG2\n  ARG1 != ARG2      ARG1 is unequal to ARG2\n  ARG1 >= ARG2      ARG1 is greater than or equal to ARG2\n  ARG1 > ARG2       ARG1 is greater than ARG2\n\n  ARG1 + ARG2       arithmetic sum of ARG1 and ARG2\n  ARG1 - ARG2       arithmetic difference of ARG1 and ARG2\n\n  ARG1 * ARG2       arithmetic product of ARG1 and ARG2\n  ARG1 / ARG2       arithmetic quotient of ARG1 divided by ARG2\n  ARG1 % ARG2       arithmetic remainder of ARG1 divided by ARG2\n\n  STRING : REGEXP   anchored pattern match of REGEXP in STRING\n\n  match STRING REGEXP        same as STRING : REGEXP\n  substr STRING POS LENGTH   substring of STRING, POS counted from 1\n  index STRING CHARS         index in STRING where any CHARS is found, or 0\n  length STRING              length of STRING\n  + TOKEN                    interpret TOKEN as a string, even if it is a\n                               keyword like 'match' or an operator like '/'\n\n  ( EXPRESSION )             value of EXPRESSION\n")) 0 else 1;
}
