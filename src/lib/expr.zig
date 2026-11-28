// SPDX-License-Identifier: GPL-2.0-or-later
//! expr library: evaluate a GNU expr expression given as separate tokens.
//! Reference: GNU coreutils manual "expr invocation" (9.7); POSIX.1-2024 expr.
//!
//! Integers have arbitrary size (std.math.big). The `:` operator takes a
//! POSIX basic regular expression anchored at the start (src/posixre.zig).
//! GNU 9.7 reports a division by zero with status 2 here (the caller maps
//! every failure of this library to its own exit status).

const std = @import("std");
const numparse = @import("../numparse.zig");
const Io = std.Io;
const common = @import("common.zig");
const posixre = @import("../posixre.zig");
const big = std.math.big.int;

pub const Env = common.Env;

/// Why an expression could not be evaluated. All of these end the evaluation.
pub const Event = union(enum) {
    /// Syntax errors; the payload is the quoted-token text GNU shows.
    missing_argument_after: []const u8,
    expecting_close_after: []const u8,
    expecting_close_instead: []const u8,
    unexpected_argument: []const u8,
    /// A ")" where an operand belongs.
    unexpected_close,
    /// Other errors.
    non_integer_argument,
    division_by_zero,
    /// The regular-expression compile diagnostic (e.g. "Unmatched ( or \\(").
    regex_error: []const u8,
    regex_too_big,

    pub fn isSyntax(e: Event) bool {
        return switch (e) {
            .missing_argument_after, .expecting_close_after, .expecting_close_instead, .unexpected_argument, .unexpected_close => true,
            else => false,
        };
    }
};
pub const Observer = common.Observer(Event);

/// `Syntax`: a syntax error was reported; `Fatal`: any other error (reported,
/// except for allocation failure, which is silent).
pub const Error = error{ Syntax, Fatal };

/// The value of an expression. Owns its memory.
pub const Value = struct {
    arena: std.heap.ArenaAllocator,
    text: []const u8,

    pub fn deinit(v: *Value) void {
        v.arena.deinit();
    }

    /// expr's exit status 1 case: the empty string, or an integer zero.
    pub fn isNull(v: Value) bool {
        return isNullText(v.text);
    }
};

/// Evaluate `tokens` (one expression, already without any leading `--`).
pub fn eval(env: Env, tokens: []const []const u8, observer: Observer) Error!Value {
    var p: Parser = .{ .observer = observer, .toks = tokens, .arena = std.heap.ArenaAllocator.init(env.gpa) };
    errdefer p.arena.deinit();
    const v = try p.orExpr();
    if (p.pos < tokens.len) {
        observer.emit(.{ .unexpected_argument = tokens[p.pos] });
        return error.Syntax;
    }
    return .{ .arena = p.arena, .text = v };
}

pub const RunError = Error || error{WriteFailed};

/// Evaluate `tokens` and write the value and a newline to `w`. Returns true
/// when the value is null or zero (GNU exit status 1).
pub fn run(env: Env, tokens: []const []const u8, w: *Io.Writer, observer: Observer) RunError!bool {
    var v = try eval(env, tokens, observer);
    defer v.deinit();
    w.writeAll(v.text) catch return error.WriteFailed;
    w.writeByte('\n') catch return error.WriteFailed;
    w.flush() catch return error.WriteFailed;
    return v.isNull();
}

const Parser = struct {
    observer: Observer,
    toks: []const []const u8,
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

    fn syntax(p: *Parser, ev: Event) Error {
        p.observer.emit(ev);
        return error.Syntax;
    }

    fn fatal(p: *Parser, ev: Event) Error {
        p.observer.emit(ev);
        return error.Fatal;
    }

    fn missingAfter(p: *Parser) Error {
        return p.syntax(.{ .missing_argument_after = p.toks[p.toks.len - 1] });
    }

    fn orExpr(p: *Parser) Error![]const u8 {
        var v = try p.andExpr();
        while (p.peek()) |t| {
            if (!std.mem.eql(u8, t, "|")) break;
            p.pos += 1;
            if (p.pos >= p.toks.len) return p.missingAfter();
            const live = isNullText(v);
            if (!live) p.skip += 1;
            const r = p.andExpr() catch |e| {
                if (!live) p.skip -= 1;
                return e;
            };
            if (!live) p.skip -= 1;
            if (live) v = if (isNullText(r)) "0" else r;
        }
        return v;
    }

    fn andExpr(p: *Parser) Error![]const u8 {
        var v = try p.cmpExpr();
        while (p.peek()) |t| {
            if (!std.mem.eql(u8, t, "&")) break;
            p.pos += 1;
            if (p.pos >= p.toks.len) return p.missingAfter();
            const live = !isNullText(v);
            if (!live) p.skip += 1;
            const r = p.cmpExpr() catch |e| {
                if (!live) p.skip -= 1;
                return e;
            };
            if (!live) p.skip -= 1;
            if (!live or isNullText(r)) v = "0";
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
        if (std.mem.eql(u8, t, ")")) return p.syntax(.unexpected_close);
        p.pos += 1;
        if (std.mem.eql(u8, t, "(")) {
            if (p.pos >= p.toks.len) return p.missingAfter();
            const v = try p.orExpr();
            const close = p.peek() orelse return p.syntax(.{ .expecting_close_after = p.toks[p.toks.len - 1] });
            if (!std.mem.eql(u8, close, ")")) return p.syntax(.{ .expecting_close_instead = close });
            p.pos += 1;
            return v;
        }
        if (std.mem.eql(u8, t, "+")) {
            const q = p.peek() orelse return p.missingAfter();
            p.pos += 1;
            return q;
        }
        if (std.mem.eql(u8, t, "length")) {
            const s = try p.primary();
            return std.fmt.allocPrint(p.alloc(), "{d}", .{s.len}) catch return error.Fatal;
        }
        if (std.mem.eql(u8, t, "match")) {
            const s = try p.primary();
            const r = try p.primary();
            return p.regexMatch(s, r);
        }
        if (std.mem.eql(u8, t, "index")) {
            const s = try p.primary();
            const chars = try p.primary();
            for (s, 0..) |c, i| if (std.mem.indexOfScalar(u8, chars, c) != null) return std.fmt.allocPrint(p.alloc(), "{d}", .{i + 1}) catch return error.Fatal;
            return "0";
        }
        if (std.mem.eql(u8, t, "substr")) {
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
        if (!isInt(v)) return p.fatal(.non_integer_argument);
        return numparse.parseInt(i128, v, 10) catch if (v[0] == '-') std.math.minInt(i128) else std.math.maxInt(i128);
    }

    fn arith(p: *Parser, op: u8, a: []const u8, b: []const u8) Error![]const u8 {
        if (p.skip > 0) return "0";
        if (!isInt(a) or !isInt(b)) return p.fatal(.non_integer_argument);
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
                if (y.eqlZero()) return p.fatal(.division_by_zero);
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
        var c = posixre.compileFull(gpa, pattern, false, false, true, .{ .dot_newline = true, .stacked_ok = true }) catch |e| switch (e) {
            error.BadPattern => return p.fatal(.{ .regex_error = posixre.diagnose(pattern) }),
            else => return error.Fatal,
        };
        var searcher = posixre.Finder.init(gpa, &c) catch return error.Fatal;
        defer searcher.deinit();
        const m = (searcher.find(subject, 0) catch return p.fatal(.regex_too_big)) orelse {
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

fn isNullText(v: []const u8) bool {
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
