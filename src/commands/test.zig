// SPDX-License-Identifier: GPL-2.0-or-later
//! test — evaluate a conditional expression (also installed as `[`).
//! References: GNU coreutils manual "test invocation" (9.7); POSIX.1-2024
//! test (the 0 to 4 argument rules). Expressions longer than four arguments
//! use the GNU recursive-descent grammar (-o, -a, !, parentheses).
//!
//! Exit status: 0 true, 1 false, 2 for a syntax error. Files are examined
//! with stat(2)/lstat(2) through sys.fileStat; -r -w -x use access().

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

pub fn main(ctx: cli.Context) u8 {
    return run(ctx, false);
}

pub fn run(ctx: cli.Context, bracket: bool) u8 {
    var args: []const [:0]const u8 = ctx.args;
    if (bracket) {
        // "[ expr ]": the last argument must be "]". --help and --version
        // work only as the sole argument, without the closing bracket.
        if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return help(ctx);
        if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) return if (cli.printVersion(ctx)) 0 else 1;
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            cli.warn(ctx, "missing ']'", .{});
            return 2;
        }
        args = args[0 .. args.len - 1];
    }
    var p: Parser = .{ .ctx = ctx, .args = args, .bracket = bracket };
    const result = p.evaluate() catch return 2;
    return if (result) 0 else 1;
}

const Parser = struct {
    ctx: cli.Context,
    args: []const [:0]const u8,
    pos: usize = 0,
    bracket: bool = false,

    const Error = error{Syntax};

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        cli.warn(p.ctx, fmt, args);
        return error.Syntax;
    }

    /// Evaluate all arguments the way GNU's main() does: the POSIX rules for
    /// up to four arguments, the full grammar above that.
    fn evaluate(p: *Parser) Error!bool {
        const n = p.args.len;
        if (n == 0) return false;
        const v = if (n > 4) try p.expr() else try p.posix(n);
        if (p.pos < n) return p.fail("extra argument {f}", .{cli.quoteC(p.args[p.pos])});
        return v;
    }

    fn at(p: *const Parser, i: usize) []const u8 {
        return p.args[i];
    }

    fn beyond(p: *Parser) Error {
        return p.fail("missing argument after {f}", .{cli.quoteC(p.args[p.args.len - 1])});
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
        return p.fail("{f}: binary operator expected", .{cli.quoteC(a1)});
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
            if (p.bracket) return p.fail("{f} expected, found {f}", .{ cli.quoteC(")"), cli.quoteC("]") });
            return p.fail("{f} expected", .{cli.quoteC(")")});
        }
            if (!std.mem.eql(u8, p.at(p.pos), ")")) {
                return p.fail("{f} expected, found {f}", .{ cli.quoteC(")"), cli.quoteC(p.at(p.pos)) });
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
        if (!isUnary(op)) return p.fail("{f}: unary operator expected", .{cli.quoteC(op)});
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
                const fd = parseInt(arg) orelse return p.fail("invalid integer {f}", .{cli.quoteC(arg)});
                if (fd.big or fd.value < 0 or fd.value > std.math.maxInt(i32)) return false;
                const f: Io.File = .{ .handle = @intCast(fd.value), .flags = .{ .nonblocking = false } };
                return f.isTty(p.ctx.io) catch false;
            },
            'r', 'w', 'x' => {
                Io.Dir.cwd().access(p.ctx.io, arg, .{ .read = c == 'r', .write = c == 'w', .execute = c == 'x' }) catch return false;
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
        const x = parseInt(l) orelse return p.fail("invalid integer {f}", .{cli.quoteC(l)});
        const y = parseInt(r) orelse return p.fail("invalid integer {f}", .{cli.quoteC(r)});
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

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io,
        "Usage: test EXPRESSION\n" ++
        "  or:  test\n" ++
        "  or:  [ EXPRESSION ]\n" ++
        "  or:  [ ]\n" ++
        "  or:  [ OPTION\n" ++
        "Exit with the status determined by EXPRESSION.\n" ++
        "\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n" ++
        "\n" ++
        "An omitted EXPRESSION defaults to false.  Otherwise,\n" ++
        "EXPRESSION is true or false and sets exit status.  It is one of:\n" ++
        "\n" ++
        "  ( EXPRESSION )               EXPRESSION is true\n" ++
        "  ! EXPRESSION                 EXPRESSION is false\n" ++
        "  EXPRESSION1 -a EXPRESSION2   both EXPRESSION1 and EXPRESSION2 are true\n" ++
        "  EXPRESSION1 -o EXPRESSION2   either EXPRESSION1 or EXPRESSION2 is true\n" ++
        "\n" ++
        "  -n STRING            the length of STRING is nonzero\n" ++
        "  STRING               equivalent to -n STRING\n" ++
        "  -z STRING            the length of STRING is zero\n" ++
        "  STRING1 = STRING2    the strings are equal\n" ++
        "  STRING1 != STRING2   the strings are not equal\n" ++
        "  STRING1 > STRING2    STRING1 is greater than STRING2 in the current locale\n" ++
        "  STRING1 < STRING2    STRING1 is less than STRING2 in the current locale\n" ++
        "\n" ++
        "  INTEGER1 -eq INTEGER2   INTEGER1 is equal to INTEGER2\n" ++
        "  INTEGER1 -ge INTEGER2   INTEGER1 is greater than or equal to INTEGER2\n" ++
        "  INTEGER1 -gt INTEGER2   INTEGER1 is greater than INTEGER2\n" ++
        "  INTEGER1 -le INTEGER2   INTEGER1 is less than or equal to INTEGER2\n" ++
        "  INTEGER1 -lt INTEGER2   INTEGER1 is less than INTEGER2\n" ++
        "  INTEGER1 -ne INTEGER2   INTEGER1 is not equal to INTEGER2\n" ++
        "\n" ++
        "  FILE1 -ef FILE2   FILE1 and FILE2 have the same device and inode numbers\n" ++
        "  FILE1 -nt FILE2   FILE1 is newer (modification date) than FILE2\n" ++
        "  FILE1 -ot FILE2   FILE1 is older than FILE2\n" ++
        "\n" ++
        "  -b FILE     FILE exists and is block special\n" ++
        "  -c FILE     FILE exists and is character special\n" ++
        "  -d FILE     FILE exists and is a directory\n" ++
        "  -e FILE     FILE exists\n" ++
        "  -f FILE     FILE exists and is a regular file\n" ++
        "  -g FILE     FILE exists and is set-group-ID\n" ++
        "  -G FILE     FILE exists and is owned by the effective group ID\n" ++
        "  -h FILE     FILE exists and is a symbolic link (same as -L)\n" ++
        "  -k FILE     FILE exists and has its sticky bit set\n" ++
        "  -L FILE     FILE exists and is a symbolic link (same as -h)\n" ++
        "  -N FILE     FILE exists and has been modified since it was last read\n" ++
        "  -O FILE     FILE exists and is owned by the effective user ID\n" ++
        "  -p FILE     FILE exists and is a named pipe\n" ++
        "  -r FILE     FILE exists and the user has read access\n" ++
        "  -s FILE     FILE exists and has a size greater than zero\n" ++
        "  -S FILE     FILE exists and is a socket\n" ++
        "  -t FD       file descriptor FD is opened on a terminal\n" ++
        "  -u FILE     FILE exists and its set-user-ID bit is set\n" ++
        "  -w FILE     FILE exists and the user has write access\n" ++
        "  -x FILE     FILE exists and the user has execute (or search) access\n" ++
        "\n" ++
        "Except for -h and -L, all FILE-related tests dereference symbolic links.\n" ++
        "Beware that parentheses need to be escaped (e.g., by backslashes) for shells.\n" ++
        "INTEGER may also be -l STRING, which evaluates to the length of STRING.\n" ++
        "\n" ++
        "Binary -a and -o are ambiguous.  Use 'test EXPR1 && test EXPR2'\n" ++
        "or 'test EXPR1 || test EXPR2' instead.\n" ++
        "\n" ++
        "'[' honors --help and --version, but 'test' treats them as STRINGs.\n" ++
        "\n" ++
        "Your shell may have its own version of test and/or [, which usually supersedes\n" ++
        "the version described here.  Please refer to your shell's documentation\n" ++
        "for details about the options it supports.\n" ++
        "\n" ++
        "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>\n" ++
        "Report any translation bugs to <https://translationproject.org/team/>\n" ++
        "Full documentation <https://www.gnu.org/software/coreutils/test>\n" ++
        "or available locally via: info '(coreutils) test invocation'\n")) 0 else 1;
}
