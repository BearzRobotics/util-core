// SPDX-License-Identifier: GPL-2.0-or-later
//! test library: evaluate a conditional expression (also used for `[`).
//! References: GNU coreutils manual "test invocation" (9.7); POSIX.1-2024
//! test (the 0 to 4 argument rules). Expressions longer than four arguments
//! use the GNU recursive-descent grammar (-o, -a, !, parentheses).
//!
//! Files are examined with stat(2)/lstat(2) through sys.fileStat; -r -w -x use
//! access(). Extension over POSIX (also in GNU): -a/-o, -N, -O, -G, -k, -h/-L,
//! ==, <, >, -nt, -ot, -ef and integers of any size.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// Evaluating the arguments of `[` (the closing "]" already removed).
    /// Only changes one diagnostic, as in GNU.
    bracket: bool = false,
};

/// A syntax error in the expression; evaluation stops (GNU exit status 2).
pub const Event = union(enum) {
    extra_argument: []const u8,
    missing_argument_after: []const u8,
    binary_operator_expected: []const u8,
    unary_operator_expected: []const u8,
    invalid_integer: []const u8,
    /// A ")" was needed; `found` is what stood there (null: end of input).
    close_paren_expected: ?[]const u8,
};
pub const Observer = common.Observer(Event);

pub const Error = error{Syntax};

/// Evaluate `args` as a test expression: true or false, or `error.Syntax`
/// after reporting the problem through `observer`. No arguments is false.
pub fn evaluate(env: Env, args: []const []const u8, options: Options, observer: Observer) Error!bool {
    var p: Parser = .{ .io = env.io, .observer = observer, .args = args, .bracket = options.bracket };
    return p.evaluate();
}

const Parser = struct {
    io: Io,
    observer: Observer,
    args: []const []const u8,
    pos: usize = 0,
    bracket: bool = false,

    fn fail(p: *Parser, ev: Event) Error {
        p.observer.emit(ev);
        return error.Syntax;
    }

    /// Evaluate all arguments the way GNU's main() does: the POSIX rules for
    /// up to four arguments, the full grammar above that.
    fn evaluate(p: *Parser) Error!bool {
        const n = p.args.len;
        if (n == 0) return false;
        const v = if (n > 4) try p.expr() else try p.posix(n);
        if (p.pos < n) return p.fail(.{ .extra_argument = p.args[p.pos] });
        return v;
    }

    fn at(p: *const Parser, i: usize) []const u8 {
        return p.args[i];
    }

    fn beyond(p: *Parser) Error {
        return p.fail(.{ .missing_argument_after = p.args[p.args.len - 1] });
    }

    /// GNU posixtest(nargs): `nargs` arguments starting at `pos`.
    fn posix(p: *Parser, nargs: usize) Error!bool {
        return switch (nargs) {
            1 => blk: {
                const v = p.at(p.pos).len > 0;
                p.pos += 1;
                break :blk v;
            },
            2 => p.two(),
            3 => p.three(),
            4 => p.four(),
            else => if (nargs > 4) p.expr() else false,
        };
    }

    // ------------------------------------------------ POSIX 2..4 arguments

    fn two(p: *Parser) Error!bool {
        const a0 = p.at(p.pos);
        if (std.mem.eql(u8, a0, "!")) {
            p.pos += 1;
            const v = p.at(p.pos).len > 0;
            p.pos += 1;
            return !v;
        }
        if (a0.len == 2 and a0[0] == '-') {
            const v = try p.unaryAt(a0, p.at(p.pos + 1));
            p.pos += 2;
            return v;
        }
        return p.beyond();
    }

    fn three(p: *Parser) Error!bool {
        const a0 = p.at(p.pos);
        const a1 = p.at(p.pos + 1);
        const a2 = p.at(p.pos + 2);
        if (isBinary(a1)) {
            const v = try p.binary(a0, a1, a2);
            p.pos += 3;
            return v;
        }
        if (std.mem.eql(u8, a0, "!")) {
            p.pos += 1;
            return !(try p.two());
        }
        if (std.mem.eql(u8, a0, "(") and std.mem.eql(u8, a2, ")")) {
            p.pos += 1;
            const v = a1.len > 0;
            p.pos += 2;
            return v;
        }
        if (std.mem.eql(u8, a1, "-a") or std.mem.eql(u8, a1, "-o")) return p.expr();
        return p.fail(.{ .binary_operator_expected = a1 });
    }

    fn four(p: *Parser) Error!bool {
        const a0 = p.at(p.pos);
        if (std.mem.eql(u8, a0, "!")) {
            p.pos += 1;
            return !(try p.three());
        }
        if (std.mem.eql(u8, a0, "(") and std.mem.eql(u8, p.at(p.pos + 3), ")")) {
            p.pos += 1;
            const v = try p.two();
            p.pos += 1;
            return v;
        }
        return p.expr();
    }

    // -------------------------------------------------- general grammar

    fn expr(p: *Parser) Error!bool {
        var v = try p.andExpr();
        while (p.pos < p.args.len and std.mem.eql(u8, p.at(p.pos), "-o")) {
            p.pos += 1;
            if (p.pos >= p.args.len) return p.beyond();
            const r = try p.andExpr();
            v = v or r;
        }
        return v;
    }

    fn andExpr(p: *Parser) Error!bool {
        var v = try p.term();
        while (p.pos < p.args.len and std.mem.eql(u8, p.at(p.pos), "-a")) {
            p.pos += 1;
            if (p.pos >= p.args.len) return p.beyond();
            const r = try p.term();
            v = v and r;
        }
        return v;
    }

    fn term(p: *Parser) Error!bool {
        var negated = false;
        while (p.pos < p.args.len and std.mem.eql(u8, p.at(p.pos), "!")) {
            p.pos += 1;
            if (p.pos >= p.args.len) return p.beyond();
            negated = !negated;
        }
        if (p.pos >= p.args.len) return p.beyond();
        const a = p.at(p.pos);
        var value: bool = undefined;
        if (std.mem.eql(u8, a, "(")) {
            p.pos += 1;
            if (p.pos >= p.args.len) return p.beyond();
            // The group is judged by the POSIX rules when it has at most four arguments.
            var nargs: usize = 1;
            while (p.pos + nargs < p.args.len and !std.mem.eql(u8, p.at(p.pos + nargs), ")")) : (nargs += 1) {
                if (nargs == 4) {
                    nargs = p.args.len - p.pos;
                    break;
                }
            }
            value = try p.posix(nargs);
            if (p.pos >= p.args.len) {
                // GNU's bracket form still sees the closing "]" here.
                return p.fail(.{ .close_paren_expected = if (p.bracket) "]" else null });
            }
            if (!std.mem.eql(u8, p.at(p.pos), ")")) {
                return p.fail(.{ .close_paren_expected = p.at(p.pos) });
            }
            p.pos += 1;
        } else if (p.args.len - p.pos >= 3 and isBinary(p.at(p.pos + 1))) {
            value = try p.binary(a, p.at(p.pos + 1), p.at(p.pos + 2));
            p.pos += 3;
        } else if (a.len == 2 and a[0] == '-') {
            if (p.pos + 1 >= p.args.len) {
                return p.beyond(); // a switch needs an operand
            } else {
                value = try p.unaryAt(a, p.at(p.pos + 1));
                p.pos += 2;
            }
        } else {
            value = a.len > 0;
            p.pos += 1;
        }
        return negated != value;
    }

    /// Unary operator `op` (a two-character switch) applied to `arg`.
    fn unaryAt(p: *Parser, op: []const u8, arg: []const u8) Error!bool {
        if (!isUnary(op)) return p.fail(.{ .unary_operator_expected = op });
        return p.unary(op, arg);
    }

    // ----------------------------------------------------------- operators

    fn isUnary(s: []const u8) bool {
        if (s.len != 2 or s[0] != '-') return false;
        return std.mem.indexOfScalar(u8, "bcdefghkLNOGnprsStuwxzg", s[1]) != null;
    }

    fn isBinary(s: []const u8) bool {
        const ops = [_][]const u8{ "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot", "-ef" };
        for (ops) |o| if (std.mem.eql(u8, s, o)) return true;
        return false;
    }

    fn unary(p: *Parser, op: []const u8, arg: []const u8) Error!bool {
        const c = op[1];
        switch (c) {
            'z' => return arg.len == 0,
            'n' => return arg.len > 0,
            't' => {
                const fd = parseInt(arg) orelse return p.fail(.{ .invalid_integer = arg });
                if (fd.big or fd.value < 0 or fd.value > std.math.maxInt(i32)) return false;
                const f: Io.File = .{ .handle = @intCast(fd.value), .flags = .{ .nonblocking = false } };
                return f.isTty(p.io) catch false;
            },
            'r', 'w', 'x' => {
                Io.Dir.cwd().access(p.io, arg, .{ .read = c == 'r', .write = c == 'w', .execute = c == 'x' }) catch return false;
                return true;
            },
            else => {},
        }
        var e: std.os.linux.E = undefined;
        const follow = c != 'h' and c != 'L';
        const st = sys.fileStat(arg, follow, &e) orelse return false;
        const t = st.mode & 0o170000;
        return switch (c) {
            'a', 'e' => true,
            'b' => t == 0o060000,
            'c' => t == 0o020000,
            'd' => t == 0o040000,
            'f' => t == 0o100000,
            'h', 'L' => t == 0o120000,
            'p' => t == 0o010000,
            'S' => t == 0o140000,
            's' => st.size > 0,
            'g' => st.mode & 0o2000 != 0,
            'u' => st.mode & 0o4000 != 0,
            'k' => st.mode & 0o1000 != 0,
            'O' => st.uid == sys.identity().euid,
            'G' => st.gid == sys.identity().egid,
            'N' => st.mtime_s > st.atime_s or (st.mtime_s == st.atime_s and st.mtime_ns > st.atime_ns),
            else => false,
        };
    }

    fn binary(p: *Parser, l: []const u8, op: []const u8, r: []const u8) Error!bool {
        if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, l, r);
        if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, l, r);
        if (std.mem.eql(u8, op, "<")) return std.mem.order(u8, l, r) == .lt;
        if (std.mem.eql(u8, op, ">")) return std.mem.order(u8, l, r) == .gt;
        if (op[1] == 'n' and op[2] == 't' or op[1] == 'o' and op[2] == 't' or op[1] == 'e' and op[2] == 'f') {
            var e: std.os.linux.E = undefined;
            const a = sys.fileStat(l, true, &e);
            const b = sys.fileStat(r, true, &e);
            if (op[1] == 'e') {
                return a != null and b != null and a.?.ino == b.?.ino and a.?.dev_major == b.?.dev_major and a.?.dev_minor == b.?.dev_minor;
            }
            // -nt: newer, or the left exists and the right does not; -ot the mirror.
            const newer = op[1] == 'n';
            if (a == null and b == null) return false;
            if (a == null) return !newer;
            if (b == null) return newer;
            const c = cmpTime(a.?, b.?);
            return if (newer) c > 0 else c < 0;
        }
        // Integer comparisons: arbitrary size.
        const x = parseInt(l) orelse return p.fail(.{ .invalid_integer = l });
        const y = parseInt(r) orelse return p.fail(.{ .invalid_integer = r });
        const c = cmpInt(x, y);
        return switch (op[2]) {
            'q' => c == 0,
            'e' => c != 0 and false or (op[1] == 'n' and c != 0) or (op[1] == 'l' and c <= 0) or (op[1] == 'g' and c >= 0),
            't' => (op[1] == 'l' and c < 0) or (op[1] == 'g' and c > 0),
            else => false,
        };
    }
};

fn cmpTime(a: sys.FileStat, b: sys.FileStat) i32 {
    if (a.mtime_s != b.mtime_s) return if (a.mtime_s > b.mtime_s) 1 else -1;
    if (a.mtime_ns != b.mtime_ns) return if (a.mtime_ns > b.mtime_ns) 1 else -1;
    return 0;
}

const Int = struct { neg: bool, digits: []const u8, value: i128 = 0, big: bool = false };

/// Decimal integer with optional blanks and sign, any length. Null if invalid.
fn parseInt(text: []const u8) ?Int {
    var s = std.mem.trim(u8, text, " \t\n\r\x0b\x0c");
    var neg = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    while (s.len > 1 and s[0] == '0') s = s[1..];
    if (std.mem.eql(u8, s, "0")) neg = false;
    var r: Int = .{ .neg = neg, .digits = s };
    if (s.len <= 36) {
        const v = std.fmt.parseInt(i128, s, 10) catch 0;
        r.value = if (neg) -v else v;
    } else r.big = true;
    return r;
}

fn cmpInt(a: Int, b: Int) i32 {
    if (a.neg != b.neg) return if (a.neg) -1 else 1;
    var c: i32 = 0;
    if (a.digits.len != b.digits.len) {
        c = if (a.digits.len < b.digits.len) -1 else 1;
    } else c = switch (std.mem.order(u8, a.digits, b.digits)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    return if (a.neg) -c else c;
}
