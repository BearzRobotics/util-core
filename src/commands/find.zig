//! find — walk directory trees and evaluate an expression. Reference: GNU
//! findutils 4.10 (parser.c, pred.c, tree.c, find.c). Traversal order is the
//! order of readdir, like fts without a comparison function.

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const posixre = @import("../posixre.zig");
const regex = @import("regex");
const fnmatch = @import("../fnmatch.zig");
const strftime = @import("../strftime.zig");
const tzmod = @import("../tz.zig");
const userdb = @import("../userdb.zig");
const datetime = @import("../datetime.zig");
const quotearg = @import("../quotearg.zig");
const modemod = @import("../mode.zig");
const LX = std.os.linux;
const Io = std.Io;

const help_text = @embedFile("../help/find.txt");

const Cmp = enum { eq, gt, lt };

const Kind = enum {
    // operators
    and_, or_, comma, not_,
    // tests
    name, iname, path, ipath, lname, ilname, regex_, type_, xtype, size, perm, user, group, uid, gid,
    nouser, nogroup, newer, atime, ctime, mtime, amin, cmin, mmin, used, empty, links, inum, samefile,
    fstype, readable, writable, executable, true_, false_,
    // actions
    print, print0, printf, fprint, fprint0, fprintf, ls, fls, exec, delete, prune, quit,
};

const TimeSel = enum { a, b, c, m, t };

const Node = struct {
    kind: Kind,
    a: ?*Node = null,
    b: ?*Node = null,
    str: []const u8 = "",
    num: i64 = 0,
    cmp: Cmp = .eq,
    re: ?*regex.Regex = null,
    types: u64 = 0, // bit set of type letters
    // perm
    perm_kind: u8 = 0, // 0 exact, '-' all, '/' any
    perm_bits: u32 = 0,
    // size
    size_unit: u8 = 'b',
    // newerXY
    x: TimeSel = .m,
    y: TimeSel = .m,
    ref_sec: i64 = 0,
    ref_nsec: i64 = 0,
    ref_dev: u64 = 0,
    ref_ino: u64 = 0,
    // exec
    argv: []const []const u8 = &.{},
    plus: bool = false,
    dir: bool = false,
    prompt: bool = false,
    batch: std.ArrayList([]const u8) = .empty,
    batch_dirs: std.ArrayList([]const u8) = .empty,
    batch_len: usize = 0,
    // output files
    out: ?*OutFile = null,
    fmt_parts: []const FmtPart = &.{},
};

const FmtPart = struct {
    lit: []const u8 = "",
    dir: u8 = 0, // conversion character, 0 = literal only
    flags: []const u8 = "",
    width: ?usize = null,
    prec: ?usize = null,
    tchar: u8 = 0, // for %A %C %T
    stop: bool = false, // \c
};

const OutFile = struct {
    path: []const u8,
    fd: i32,
    buf: std.ArrayList(u8) = .empty,
};

const Follow = enum { physical, command_line, logical };

const State = struct {
    ctx: cli.Context,
    gpa: std.mem.Allocator,
    follow: Follow = .physical,
    maxdepth: i64 = -1,
    mindepth: i64 = 0,
    depth_first: bool = false,
    xdev: bool = false,
    daystart: bool = false,
    warn: bool = true,
    ignore_race: bool = false,
    regextype: u8 = 'e', // e default emacs, d findutils-default, e emacs, b/r/m basic, x/g/a/p extended
    root: *Node = undefined,
    has_action: bool = false,
    saw_prune: bool = false,
    saw_delete: bool = false,
    explicit_depth: bool = false,
    exit_status: u8 = 0,
    quit: bool = false,
    start_sec: i64 = 0,
    start_nsec: u32 = 0,
    day_start: i64 = 0,
    zone: tzmod.Zone = undefined,
    zone_loaded: bool = false,
    db: userdb.Db = undefined,
    db_loaded: bool = false,
    out: std.ArrayList(u8) = .empty,
    outs: std.ArrayList(*OutFile) = .empty,
    execs: std.ArrayList(*Node) = .empty,
    utf8: bool = false,
    // current file
    cur_path: []const u8 = "",
    cur_name_off: usize = 0,
    cur_depth: i64 = 0,
    cur_st: ?sys.FileStat = null,
    cur_lst: ?sys.FileStat = null,
    cur_dtype: u8 = 0, // type letter from readdir, 0 unknown
    cur_loaded: bool = false,
    cur_failed: bool = false,
    cur_cmdline: bool = false,
    cur_root: []const u8 = "",
    cur_dev: u64 = 0,
    cur_dir_path: []const u8 = "",
    prune_flag: bool = false,
    mounts: ?[]MountEnt = null,
    stdin_used: bool = false,
};

const MountEnt = struct { dev: u64, fstype: []const u8 };

fn oom(ctx: cli.Context) noreturn {
    cli.warn(ctx, "memory exhausted", .{});
    std.process.exit(1);
}

// ------------------------------------------------------------- messages

fn quoteInner(st: *State, text: []const u8) []const u8 {
    const raw = std.fmt.allocPrint(st.gpa, "{f}", .{cli.quoteC(text)}) catch oom(st.ctx);
    if (st.utf8 and raw.len >= 2) {
        const out = std.fmt.allocPrint(st.gpa, "\u{2018}{s}\u{2019}", .{raw[1 .. raw.len - 1]}) catch oom(st.ctx);
        return out;
    }
    return raw;
}

fn fail(st: *State, comptime fmt: []const u8, args: anytype) noreturn {
    flushOut(st);
    cli.warn(st.ctx, fmt, args);
    std.process.exit(1);
}

fn warnMsg(st: *State, comptime fmt: []const u8, args: anytype) void {
    if (!st.warn) return;
    cli.warn(st.ctx, "warning: " ++ fmt, args);
}

fn flushOut(st: *State) void {
    if (st.out.items.len > 0) {
        _ = sys.writeAllFd(1, st.out.items);
        st.out.clearRetainingCapacity();
    }
}

fn emit(st: *State, bytes: []const u8) void {
    st.out.appendSlice(st.gpa, bytes) catch oom(st.ctx);
    if (st.out.items.len > 65536) flushOut(st);
}

// -------------------------------------------------------------- parsing

const Parser = struct {
    st: *State,
    args: []const []const u8,
    i: usize = 0,
    last_pred: []const u8 = "",
    seen_test: bool = false,
    seen_expr: bool = false,
    at_start: bool = true,
    no_starts: bool = false,

    fn more(p: *Parser) bool {
        return p.i < p.args.len;
    }

    fn peek(p: *Parser) []const u8 {
        return p.args[p.i];
    }

    fn mk(p: *Parser, kind: Kind) *Node {
        const n = p.st.gpa.create(Node) catch oom(p.st.ctx);
        n.* = .{ .kind = kind };
        return n;
    }

    fn needArg(p: *Parser, name: []const u8) []const u8 {
        if (p.i >= p.args.len) fail(p.st, "missing argument to `{s}'", .{name});
        const a = p.args[p.i];
        p.i += 1;
        return a;
    }

    fn isBinOp(a: []const u8) bool {
        return std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-and") or std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-or") or std.mem.eql(u8, a, ",");
    }

    /// An operand must follow the operator `op`.
    fn expectOperand(p: *Parser, op: []const u8) void {
        if (!p.more()) fail(p.st, "expected an expression after '{s}'", .{op});
        const t = p.peek();
        if (std.mem.eql(u8, t, ")")) fail(p.st, "expected an expression between '{s}' and ')'", .{op});
        if (isBinOp(t)) fail(p.st, "invalid expression; you have used a binary operator '{s}' with nothing before it.", .{t});
    }

    // expression := or ( ',' or )*
    fn parseComma(p: *Parser) *Node {
        var left = p.parseOr();
        while (p.more() and std.mem.eql(u8, p.peek(), ",")) {
            p.i += 1;
            p.expectOperand(",");
            const right = p.parseOr();
            const n = p.mk(.comma);
            n.a = left;
            n.b = right;
            left = n;
        }
        return left;
    }

    fn parseOr(p: *Parser) *Node {
        var left = p.parseAnd();
        while (p.more() and (std.mem.eql(u8, p.peek(), "-o") or std.mem.eql(u8, p.peek(), "-or"))) {
            const opname = p.peek();
            p.i += 1;
            p.expectOperand(opname);
            const right = p.parseAnd();
            const n = p.mk(.or_);
            n.a = left;
            n.b = right;
            left = n;
        }
        return left;
    }

    fn parseAnd(p: *Parser) *Node {
        var left = p.parseUnary();
        while (p.more()) {
            const a = p.peek();
            if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-or") or std.mem.eql(u8, a, ",") or std.mem.eql(u8, a, ")")) break;
            if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-and")) {
                p.i += 1;
                p.expectOperand(a);
            }
            const right = p.parseUnary();
            const n = p.mk(.and_);
            n.a = left;
            n.b = right;
            left = n;
        }
        return left;
    }

    fn parseUnary(p: *Parser) *Node {
        if (!p.more()) fail(p.st, "invalid expression", .{});
        const a = p.peek();
        p.at_start = false;
        if (std.mem.eql(u8, a, "!") or std.mem.eql(u8, a, "-not")) {
            p.i += 1;
            p.expectOperand(a);
            const inner = p.parseUnary();
            const n = p.mk(.not_);
            n.a = inner;
            return n;
        }
        return p.parsePrimary();
    }

    fn parsePrimary(p: *Parser) *Node {
        const st = p.st;
        const a = p.peek();
        if (std.mem.eql(u8, a, "(")) {
            p.i += 1;
            if (!p.more()) fail(st, "invalid expression; expected to find a ')' but didn't see one. Perhaps you need an extra predicate after '('", .{});
            if (std.mem.eql(u8, p.peek(), ")")) fail(st, "invalid expression; empty parentheses are not allowed.", .{});
            const inner = p.parseComma();
            if (!p.more() or !std.mem.eql(u8, p.peek(), ")")) fail(st, "invalid expression; I was expecting to find a ')' somewhere but did not see one.", .{});
            p.i += 1;
            return inner;
        }
        if (std.mem.eql(u8, a, ")")) fail(st, "you have too many ')'", .{});
        if (isBinOp(a)) fail(st, "invalid expression; you have used a binary operator '{s}' with nothing before it.", .{a});
        if (a.len == 0 or a[0] != '-') {
            // an operand that is not a predicate
            cli.warn(st.ctx, "paths must precede expression: `{s}'", .{a});
            if (p.no_starts and p.last_pred.len > 0) cli.warn(st.ctx, "possible unquoted pattern after predicate `{s}'?", .{p.last_pred});
            flushOut(st);
            std.process.exit(1);
        }
        p.i += 1;
        return p.predicate(a);
    }

    fn numArg(p: *Parser, name: []const u8, comptime bad_fmt: []const u8) i64 {
        const a = p.needArg(name);
        return std.fmt.parseInt(i64, a, 10) catch fail(p.st, bad_fmt, .{ a });
    }

    fn cmpNum(p: *Parser, name: []const u8, text: []const u8, node: *Node) void {
        var s = text;
        node.cmp = .eq;
        if (s.len > 0 and s[0] == '+') {
            node.cmp = .gt;
            s = s[1..];
        } else if (s.len > 0 and s[0] == '-') {
            node.cmp = .lt;
            s = s[1..];
        }
        node.num = std.fmt.parseInt(i64, s, 10) catch fail(p.st, "invalid argument `{s}' to `{s}'", .{ text, name });
        if (s.len == 0 or !std.ascii.isDigit(s[0])) fail(p.st, "invalid argument `{s}' to `{s}'", .{ text, name });
    }

    fn setTest(p: *Parser, name: []const u8) void {
        p.seen_test = true;
        p.last_pred = name;
    }

    fn globOpt(p: *Parser, name: []const u8) void {
        const st = p.st;
        _ = name;
        _ = st;
    }

    fn predicate(p: *Parser, a: []const u8) *Node {
        const st = p.st;
        const eq = std.mem.eql;
        // options without effect on evaluation return -true
        if (eq(u8, a, "-depth") or eq(u8, a, "-d")) {
            p.globOpt(a);
            st.depth_first = true;
            st.explicit_depth = true;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-mount") or eq(u8, a, "-xdev")) {
            p.globOpt(a);
            st.xdev = true;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-noleaf")) {
            p.globOpt(a);
            return p.mk(.true_);
        }
        if (eq(u8, a, "-ignore_readdir_race")) {
            st.ignore_race = true;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-noignore_readdir_race")) {
            st.ignore_race = false;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-follow")) {
            st.follow = .logical;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-daystart")) {
            st.daystart = true;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-warn")) {
            st.warn = true;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-nowarn")) {
            st.warn = false;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-maxdepth") or eq(u8, a, "-mindepth")) {
            p.globOpt(a);
            const v = p.needArg(a);
            const n = std.fmt.parseInt(i64, v, 10) catch -1;
            if (n < 0 or v.len == 0 or !std.ascii.isDigit(v[0])) fail(st, "Expected a positive decimal integer argument to {s}, but got {s}", .{ a, quoteInner(st, v) });
            if (eq(u8, a, "-maxdepth")) st.maxdepth = n else st.mindepth = n;
            return p.mk(.true_);
        }
        if (eq(u8, a, "-regextype")) {
            const v = p.needArg(a);
            if (eq(u8, v, "posix-basic") or eq(u8, v, "ed") or eq(u8, v, "sed")) {
                st.regextype = 'b';
            } else if (eq(u8, v, "grep")) {
                st.regextype = 'r';
            } else if (eq(u8, v, "posix-minimal-basic")) {
                st.regextype = 'm';
            } else if (eq(u8, v, "posix-extended")) {
                st.regextype = 'x';
            } else if (eq(u8, v, "posix-egrep") or eq(u8, v, "egrep")) {
                st.regextype = 'g';
            } else if (eq(u8, v, "awk")) {
                st.regextype = 'a';
            } else if (eq(u8, v, "gnu-awk")) {
                st.regextype = 'p';
            } else if (eq(u8, v, "posix-awk")) {
                st.regextype = 'x';
            } else if (eq(u8, v, "emacs")) {
                st.regextype = 'e';
            } else if (eq(u8, v, "findutils-default")) {
                st.regextype = 'd';
            } else fail(st, "Unknown regular expression type {s}; valid types are 'findutils-default', 'ed', 'emacs', 'gnu-awk', 'grep', 'posix-awk', 'awk', 'posix-basic', 'posix-egrep', 'egrep', 'posix-extended', 'posix-minimal-basic', 'sed'.", .{quoteInner(st, v)});
            return p.mk(.true_);
        }
        if (eq(u8, a, "-files0-from")) {
            _ = p.needArg(a);
            fail(st, "-files0-from is not supported here", .{});
        }
        if (eq(u8, a, "-true")) {
            p.setTest(a);
            return p.mk(.true_);
        }
        if (eq(u8, a, "-false")) {
            p.setTest(a);
            return p.mk(.false_);
        }
        if (eq(u8, a, "-name") or eq(u8, a, "-iname") or eq(u8, a, "-path") or eq(u8, a, "-wholename") or eq(u8, a, "-ipath") or eq(u8, a, "-iwholename") or eq(u8, a, "-lname") or eq(u8, a, "-ilname")) {
            const pat = p.needArg(a);
            p.setTest(a);
            const kind: Kind = if (eq(u8, a, "-name")) .name else if (eq(u8, a, "-iname")) .iname else if (eq(u8, a, "-path") or eq(u8, a, "-wholename")) .path else if (eq(u8, a, "-ipath") or eq(u8, a, "-iwholename")) .ipath else if (eq(u8, a, "-lname")) .lname else .ilname;
            const n = p.mk(kind);
            n.str = pat;
            return n;
        }
        if (eq(u8, a, "-regex") or eq(u8, a, "-iregex")) {
            const pat = p.needArg(a);
            p.setTest(a);
            const n = p.mk(.regex_);
            n.str = pat;
            n.re = p.compileRegex(pat, eq(u8, a, "-iregex"));
            return n;
        }
        if (eq(u8, a, "-type") or eq(u8, a, "-xtype")) {
            const v = p.needArg(a);
            p.setTest(a);
            const n = p.mk(if (eq(u8, a, "-type")) .type_ else .xtype);
            var expect_letter = true;
            if (v.len == 0) fail(st, "Arguments to {s} should contain at least one letter", .{a});
            for (v) |ch| {
                if (ch == ',') {
                    if (expect_letter) fail(st, "Unknown argument to {s}: ,", .{a});
                    expect_letter = true;
                    continue;
                }
                if (!expect_letter) fail(st, "Must separate multiple arguments to {s} using: ','", .{a});
                if (ch == 'D') fail(st, "{s} D is not supported because Solaris doors are not supported on the platform find was compiled on.", .{a});
                if (std.mem.indexOfScalar(u8, "bcdpfls", ch) == null) fail(st, "Unknown argument to {s}: {c}", .{ a, ch });
                n.types |= @as(u64, 1) << @intCast(ch - 'A');
                expect_letter = false;
            }
            if (expect_letter) fail(st, "Last file type in list argument to {s} is missing, i.e., list is ending on: ','", .{a});
            return n;
        }
        if (eq(u8, a, "-size")) {
            const v = p.needArg(a);
            p.setTest(a);
            if (v.len == 0) fail(st, "invalid null argument to -size", .{});
            const n = p.mk(.size);
            var s = v;
            if (s.len > 0 and s[0] == '+') {
                n.cmp = .gt;
                s = s[1..];
            } else if (s.len > 0 and s[0] == '-') {
                n.cmp = .lt;
                s = s[1..];
            }
            var end: usize = 0;
            while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
            if (end == 0) {
                if (s.len == 0) fail(st, "invalid -size type `{c}'", .{v[0]});
                if (std.mem.indexOfScalar(u8, "bcwkMG", s[0]) != null) fail(st, "Invalid argument `{s}' to -size", .{v});
                fail(st, "invalid -size type `{c}'", .{s[0]});
            }
            n.num = std.fmt.parseInt(i64, s[0..end], 10) catch fail(st, "invalid argument `{s}' to `-size'", .{v});
            if (end == s.len) {
                n.size_unit = 'b';
            } else if (end + 1 == s.len and std.mem.indexOfScalar(u8, "bcwkMG", s[end]) != null) {
                n.size_unit = s[end];
            } else if (end + 1 == s.len) {
                fail(st, "invalid -size type `{c}'", .{s[end]});
            } else fail(st, "Invalid argument `{s}' to -size", .{v});
            return n;
        }
        if (eq(u8, a, "-perm")) {
            const v = p.needArg(a);
            p.setTest(a);
            const n = p.mk(.perm);
            var s = v;
            if (s.len > 0 and (s[0] == '-' or s[0] == '/')) {
                n.perm_kind = s[0];
                s = s[1..];
            }
            if (s.len > 0 and s[0] == '+' and false) {}
            const parsed: ?u32 = blk: {
                if (s.len > 0 and std.ascii.isDigit(s[0])) {
                    const o = std.fmt.parseInt(u32, s, 8) catch break :blk null;
                    if (o > 0o7777) break :blk null;
                    break :blk o;
                }
                if (s.len == 0) break :blk null;
                const m = modemod.apply(s, 0, true, 0) orelse break :blk null;
                break :blk m;
            };
            n.perm_bits = parsed orelse fail(st, "invalid mode {s}", .{quoteInner(st, v)});
            if (n.perm_kind == '/' and n.perm_bits == 0) {
                cli.warn(st.ctx, "warning: you have specified a mode pattern {s} (which is equivalent to /000). The meaning of -perm /000 has now been changed to be consistent with -perm -000; that is, while it used to match no files, it now matches all files.", .{v});
            }
            return n;
        }
        if (eq(u8, a, "-user") or eq(u8, a, "-group")) {
            const v = p.needArg(a);
            p.setTest(a);
            const n = p.mk(if (eq(u8, a, "-user")) .user else .group);
            loadDb(st);
            const is_user = n.kind == .user;
            if (is_user) {
                if (st.db.userByName(v)) |u| {
                    n.num = u.uid;
                    return n;
                }
            } else if (st.db.groupByName(v)) |g| {
                n.num = g.gid;
                return n;
            }
            if (v.len > 0 and (std.ascii.isDigit(v[0]) or (v[0] == '+' and v.len > 1 and std.ascii.isDigit(v[1])))) {
                n.num = std.fmt.parseInt(i64, v, 10) catch fail(st, "invalid {s} name or {s} argument to {s}: {s}", .{ if (is_user) "user" else "group", if (is_user) "UID" else "GID", a, quoteInner(st, v) });
                return n;
            }
            fail(st, "invalid {s} name or {s} argument to {s}: {s}", .{ if (is_user) "user" else "group", if (is_user) "UID" else "GID", a, quoteInner(st, v) });
        }
        if (eq(u8, a, "-uid") or eq(u8, a, "-gid") or eq(u8, a, "-inum") or eq(u8, a, "-links")) {
            const v = p.needArg(a);
            p.setTest(a);
            const kind: Kind = if (eq(u8, a, "-uid")) .uid else if (eq(u8, a, "-gid")) .gid else if (eq(u8, a, "-inum")) .inum else .links;
            const n = p.mk(kind);
            var s = v;
            if (s.len > 0 and s[0] == '+') {
                n.cmp = .gt;
                s = s[1..];
            } else if (s.len > 0 and s[0] == '-') {
                n.cmp = .lt;
                s = s[1..];
            }
            if (s.len == 0 or !std.ascii.isDigit(s[0])) {
                fail(st, "non-numeric argument to {s}: {s}", .{ a, quoteInner(st, v) });
            }
            for (s) |ch| {
                if (!std.ascii.isDigit(ch)) fail(st, "non-numeric argument to {s}: {s}", .{ a, quoteInner(st, v) });
            }
            n.num = std.fmt.parseInt(i64, s, 10) catch fail(st, "invalid argument `{s}' to `{s}'", .{ v, a });
            return n;
        }
        if (eq(u8, a, "-amin") or eq(u8, a, "-cmin") or eq(u8, a, "-mmin") or eq(u8, a, "-atime") or eq(u8, a, "-ctime") or eq(u8, a, "-mtime") or eq(u8, a, "-used")) {
            const v = p.needArg(a);
            p.setTest(a);
            const kind: Kind = if (eq(u8, a, "-amin")) .amin else if (eq(u8, a, "-cmin")) .cmin else if (eq(u8, a, "-mmin")) .mmin else if (eq(u8, a, "-atime")) .atime else if (eq(u8, a, "-ctime")) .ctime else if (eq(u8, a, "-mtime")) .mtime else .used;
            const n = p.mk(kind);
            if (kind == .used and (v.len == 0 or !(std.ascii.isDigit(v[0]) or ((v[0] == '+' or v[0] == '-') and v.len > 1 and std.ascii.isDigit(v[1]))))) fail(st, "Invalid argument {s} to -used", .{v});
            p.cmpNum(a, v, n);
            return n;
        }
        if (eq(u8, a, "-newer") or eq(u8, a, "-anewer") or eq(u8, a, "-cnewer") or (a.len == 8 and std.mem.startsWith(u8, a, "-newer"))) {
            const v = p.needArg(a);
            p.setTest(a);
            const n = p.mk(.newer);
            if (eq(u8, a, "-newer")) {
                n.x = .m;
                n.y = .m;
            } else if (eq(u8, a, "-anewer")) {
                n.x = .a;
                n.y = .m;
            } else if (eq(u8, a, "-cnewer")) {
                n.x = .c;
                n.y = .m;
            } else {
                n.x = selOf(a[6]) orelse fail(st, "invalid predicate `{s}'", .{a});
                if (n.x == .t) fail(st, "invalid predicate `{s}'", .{a});
                n.y = selOf(a[7]) orelse fail(st, "invalid predicate `{s}'", .{a});
                if (n.x == .b or n.y == .b) {
                    cli.warn(st.ctx, "This system does not provide a way to find the birth time of a file.", .{});
                    fail(st, "invalid predicate `{s}'", .{a});
                }
            }
            if (n.y == .t) {
                const now = datetime.Timespec{ .sec = st.start_sec, .nsec = st.start_nsec };
                ensureZone(st);
                const ts = datetime.parse(st.gpa, st.ctx.io, v, now, &st.zone) orelse fail(st, "I cannot figure out how to interpret {s} as a date or time", .{quoteInner(st, v)});
                n.ref_sec = ts.sec;
                n.ref_nsec = ts.nsec;
            } else {
                var err: LX.E = .SUCCESS;
                const rs = sys.fileStat(v, st.follow == .logical, &err) orelse fail(st, "{s}: {s}", .{ quoteInner(st, v), sys.errnoText(err) });
                const t = timeOf(rs, n.y);
                n.ref_sec = t[0];
                n.ref_nsec = t[1];
            }
            return n;
        }
        if (eq(u8, a, "-context")) {
            _ = p.needArg(a);
            fail(st, "invalid predicate -context: SELinux is not enabled.", .{});
        }
        if (eq(u8, a, "-samefile")) {
            const v = p.needArg(a);
            p.setTest(a);
            const n = p.mk(.samefile);
            var err: LX.E = .SUCCESS;
            const rs = sys.fileStat(v, st.follow == .logical, &err) orelse fail(st, "{s}: {s}", .{ quoteInner(st, v), sys.errnoText(err) });
            n.ref_dev = devKey(rs);
            n.ref_ino = rs.ino;
            return n;
        }
        if (eq(u8, a, "-fstype")) {
            const v = p.needArg(a);
            p.setTest(a);
            const n = p.mk(.fstype);
            n.str = v;
            return n;
        }
        if (eq(u8, a, "-empty")) {
            p.setTest(a);
            return p.mk(.empty);
        }
        if (eq(u8, a, "-nouser")) {
            p.setTest(a);
            return p.mk(.nouser);
        }
        if (eq(u8, a, "-nogroup")) {
            p.setTest(a);
            return p.mk(.nogroup);
        }
        if (eq(u8, a, "-readable")) {
            p.setTest(a);
            return p.mk(.readable);
        }
        if (eq(u8, a, "-writable")) {
            p.setTest(a);
            return p.mk(.writable);
        }
        if (eq(u8, a, "-executable")) {
            p.setTest(a);
            return p.mk(.executable);
        }
        // actions
        if (eq(u8, a, "-print")) {
            st.has_action = true;
            return p.mk(.print);
        }
        if (eq(u8, a, "-print0")) {
            st.has_action = true;
            return p.mk(.print0);
        }
        if (eq(u8, a, "-ls")) {
            st.has_action = true;
            return p.mk(.ls);
        }
        if (eq(u8, a, "-prune")) {
            st.saw_prune = true;
            return p.mk(.prune);
        }
        if (eq(u8, a, "-quit")) {
            return p.mk(.quit);
        }
        if (eq(u8, a, "-delete")) {
            st.saw_delete = true;
            st.has_action = true;
            st.depth_first = true;
            return p.mk(.delete);
        }
        if (eq(u8, a, "-printf")) {
            const f = p.needArg(a);
            st.has_action = true;
            const n = p.mk(.printf);
            n.fmt_parts = p.parseFormat(f);
            return n;
        }
        if (eq(u8, a, "-fprint") or eq(u8, a, "-fprint0") or eq(u8, a, "-fls")) {
            const f = p.needArg(a);
            st.has_action = true;
            const n = p.mk(if (eq(u8, a, "-fprint")) .fprint else if (eq(u8, a, "-fprint0")) .fprint0 else .fls);
            n.out = p.openOut(f);
            return n;
        }
        if (eq(u8, a, "-fprintf")) {
            const f = p.needArg(a);
            if (p.i >= p.args.len) fail(st, "invalid argument `{s}' to `-fprintf'", .{f});
            const fmt = p.needArg(a);
            st.has_action = true;
            const n = p.mk(.fprintf);
            n.out = p.openOut(f);
            n.fmt_parts = p.parseFormat(fmt);
            return n;
        }
        if (eq(u8, a, "-exec") or eq(u8, a, "-execdir") or eq(u8, a, "-ok") or eq(u8, a, "-okdir")) {
            const n = p.mk(.exec);
            n.dir = eq(u8, a, "-execdir") or eq(u8, a, "-okdir");
            n.prompt = eq(u8, a, "-ok") or eq(u8, a, "-okdir");
            st.has_action = true;
            var argv: std.ArrayList([]const u8) = .empty;
            var terminated = false;
            while (p.more()) {
                const x = p.args[p.i];
                p.i += 1;
                if (eq(u8, x, ";")) {
                    terminated = true;
                    break;
                }
                if (eq(u8, x, "+") and argv.items.len > 0 and eq(u8, argv.items[argv.items.len - 1], "{}") and !n.prompt) {
                    n.plus = true;
                    terminated = true;
                    break;
                }
                if (eq(u8, x, "+") and argv.items.len > 0 and !n.prompt and std.mem.indexOf(u8, argv.items[argv.items.len - 1], "{}") != null) {
                    fail(st, "In '{s} ... {{}} +' the '{{}}' must appear by itself, but you specified '{s}'", .{ a, argv.items[argv.items.len - 1] });
                }
                argv.append(st.gpa, x) catch oom(st.ctx);
            }
            if (!terminated) fail(st, "missing argument to `{s}'", .{a});
            if (argv.items.len == 0) fail(st, "invalid argument `;' to `{s}'", .{a});
            if (n.plus) {
                var cnt: usize = 0;
                for (argv.items) |x| {
                    if (std.mem.indexOf(u8, x, "{}") != null) cnt += 1;
                }
                if (cnt > 1) fail(st, "Only one instance of {{}} is supported with -exec ... +", .{});
            }
            n.argv = argv.items;
            if (n.plus) st.execs.append(st.gpa, n) catch oom(st.ctx);
            return n;
        }
        fail(st, "unknown predicate `{s}'", .{a});
    }

    fn openOut(p: *Parser, name: []const u8) *OutFile {
        const st = p.st;
        for (st.outs.items) |o| {
            if (std.mem.eql(u8, o.path, name)) return o;
        }
        const o = st.gpa.create(OutFile) catch oom(st.ctx);
        o.* = .{ .path = name, .fd = -1 };
        if (std.mem.eql(u8, name, "/dev/stdout")) {
            o.fd = 1;
        } else if (std.mem.eql(u8, name, "/dev/stderr")) {
            o.fd = 2;
        } else {
            var err: LX.E = .SUCCESS;
            o.fd = sys.openFd(name, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, 0o666, &err) orelse fail(st, "{s}: {s}", .{ quoteInner(st, name), sys.errnoText(err) });
        }
        st.outs.append(st.gpa, o) catch oom(st.ctx);
        return o;
    }

    fn compileRegex(p: *Parser, pat: []const u8, icase: bool) *regex.Regex {
        const st = p.st;
        var conv: []const u8 = pat;
        var ere = false;
        var lenient = false;
        switch (st.regextype) {
            'b' => ere = false,
            'r' => {
                ere = false;
                lenient = true;
            },
            'm' => {
                ere = false;
                lenient = true;
                conv = minimalBasic(st, pat);
            },
            'x' => ere = true,
            'g' => {
                ere = true;
                lenient = true;
            },
            'a', 'p' => {
                ere = true;
                conv = awkEre(st, pat, st.regextype == 'a');
            },
            else => {
                conv = emacsToEre(st, pat, st.regextype == 'e');
                ere = true;
            },
        }
        const body = posixre.translateOpts(st.gpa, conv, ere, .{ .icase = icase, .lenient_brace = lenient }) catch fail(st, "failed to compile regular expression '{s}': {s}", .{ pat, posixre.diagnoseMode(conv, ere) });
        const src = std.fmt.allocPrint(st.gpa, "(?s)\\A(?:{s})\\z", .{body}) catch oom(st.ctx);
        const re = st.gpa.create(regex.Regex) catch oom(st.ctx);
        re.* = regex.Regex.compile(st.gpa, src, .{ .dialect = .perl, .ignore_case = icase, .limits = posixre.big_limits }, null) catch fail(st, "failed to compile regular expression '{s}': {s}", .{ pat, posixre.diagnoseMode(conv, ere) });
        return re;
    }

    fn parseFormat(p: *Parser, f: []const u8) []const FmtPart {
        const st = p.st;
        var parts: std.ArrayList(FmtPart) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < f.len) {
            const c = f[i];
            if (c == '\\') {
                i += 1;
                if (i >= f.len) {
                    warnMsg(st, "escape `\\' followed by nothing at all", .{});
                    lit.append(st.gpa, '\\') catch oom(st.ctx);
                    break;
                }
                const e = f[i];
                i += 1;
                switch (e) {
                    'a' => lit.append(st.gpa, 7) catch oom(st.ctx),
                    'b' => lit.append(st.gpa, 8) catch oom(st.ctx),
                    'f' => lit.append(st.gpa, 12) catch oom(st.ctx),
                    'n' => lit.append(st.gpa, '\n') catch oom(st.ctx),
                    'r' => lit.append(st.gpa, '\r') catch oom(st.ctx),
                    't' => lit.append(st.gpa, '\t') catch oom(st.ctx),
                    'v' => lit.append(st.gpa, 11) catch oom(st.ctx),
                    '\\' => lit.append(st.gpa, '\\') catch oom(st.ctx),
                    'c' => {
                        parts.append(st.gpa, .{ .lit = lit.toOwnedSlice(st.gpa) catch oom(st.ctx), .stop = true }) catch oom(st.ctx);
                        return parts.items;
                    },
                    '0'...'7' => {
                        var v: u32 = e - '0';
                        var k: usize = 1;
                        while (k < 3 and i < f.len and f[i] >= '0' and f[i] <= '7') : (k += 1) {
                            v = v * 8 + (f[i] - '0');
                            i += 1;
                        }
                        lit.append(st.gpa, @truncate(v)) catch oom(st.ctx);
                    },
                    else => {
                        warnMsg(st, "unrecognized escape `\\{c}'", .{e});
                        lit.append(st.gpa, '\\') catch oom(st.ctx);
                        lit.append(st.gpa, e) catch oom(st.ctx);
                    },
                }
                continue;
            }
            if (c != '%') {
                lit.append(st.gpa, c) catch oom(st.ctx);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= f.len) fail(st, "error: % at end of format string", .{});
            if (f[i] == '%') {
                lit.append(st.gpa, '%') catch oom(st.ctx);
                i += 1;
                continue;
            }
            const fstart = i;
            while (i < f.len and std.mem.indexOfScalar(u8, "-+ #0", f[i]) != null) i += 1;
            const flags = f[fstart..i];
            var width: ?usize = null;
            var w0 = i;
            while (i < f.len and std.ascii.isDigit(f[i])) i += 1;
            if (i > w0) width = std.fmt.parseInt(usize, f[w0..i], 10) catch 0;
            var prec: ?usize = null;
            if (i < f.len and f[i] == '.') {
                i += 1;
                w0 = i;
                while (i < f.len and std.ascii.isDigit(f[i])) i += 1;
                prec = if (i > w0) (std.fmt.parseInt(usize, f[w0..i], 10) catch 0) else 0;
            }
            if (i >= f.len) fail(st, "error: % at end of format string", .{});
            const d = f[i];
            i += 1;
            var tchar: u8 = 0;
            if (d == 'A' or d == 'C' or d == 'T') {
                if (i >= f.len) fail(st, "error: % at end of format string", .{});
                tchar = f[i];
                i += 1;
            }
            const known = "abcdDfFgGhHiklmMnpPsStuUyYZ";
            if (d == '%') {
                // "%5%" prints "%5": the conversion character itself is dropped
                lit.append(st.gpa, '%') catch oom(st.ctx);
                lit.appendSlice(st.gpa, f[fstart .. i - 1]) catch oom(st.ctx);
                continue;
            }
            if (d != 'A' and d != 'C' and d != 'T' and std.mem.indexOfScalar(u8, known, d) == null) {
                warnMsg(st, "unrecognized format directive `%{c}'", .{d});
                lit.append(st.gpa, '%') catch oom(st.ctx);
                lit.appendSlice(st.gpa, f[fstart..i]) catch oom(st.ctx);
                continue;
            }
            parts.append(st.gpa, .{ .lit = lit.toOwnedSlice(st.gpa) catch oom(st.ctx), .dir = d, .flags = flags, .width = width, .prec = prec, .tchar = tchar }) catch oom(st.ctx);
        }
        if (lit.items.len > 0) parts.append(st.gpa, .{ .lit = lit.toOwnedSlice(st.gpa) catch oom(st.ctx) }) catch oom(st.ctx);
        return parts.items;
    }
};

fn isCloseOrEnd(a: []const u8) bool {
    return std.mem.eql(u8, a, ")") or std.mem.eql(u8, a, ",") or std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-or");
}

fn selOf(c: u8) ?TimeSel {
    return switch (c) {
        'a' => .a,
        'B' => .b,
        'c' => .c,
        'm' => .m,
        't' => .t,
        else => null,
    };
}

fn timeOf(s: sys.FileStat, sel: TimeSel) [2]i64 {
    return switch (sel) {
        .a => .{ s.atime_s, s.atime_ns },
        .b => if (s.has_btime) .{ s.btime_s, s.btime_ns } else .{ 0, 0 },
        .c => .{ s.ctime_s, s.ctime_ns },
        else => .{ s.mtime_s, s.mtime_ns },
    };
}

fn devKey(s: sys.FileStat) u64 {
    return (@as(u64, s.dev_major) << 32) | s.dev_minor;
}

fn loadDb(st: *State) void {
    if (!st.db_loaded) {
        st.db = userdb.Db.load(st.gpa, st.ctx.io);
        st.db_loaded = true;
    }
}

fn ensureZone(st: *State) void {
    if (!st.zone_loaded) {
        st.zone = tzmod.load(st.gpa, st.ctx.io, cli.getenv(st.ctx, "TZ"));
        st.zone_loaded = true;
    }
}

/// Emacs regex syntax to POSIX ERE: groups, alternation and intervals are
/// backslashed in Emacs and plain in ERE; the postfix operators agree. In the
/// Emacs syntax proper `.` does not match a newline and bracket expressions
/// have no character classes.
fn emacsToEre(st: *State, pat: []const u8, strict_emacs: bool) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var at_start = true;
    while (i < pat.len) {
        const c = pat[i];
        if (c == '[') {
            // collect the set up to the first ']' (no [:class:] support)
            i += 1;
            var neg = false;
            if (i < pat.len and pat[i] == '^') {
                neg = true;
                i += 1;
            }
            var members: std.ArrayList(u8) = .empty;
            var has_close = false;
            var has_open = false;
            if (i < pat.len and pat[i] == ']') {
                has_close = true;
                i += 1;
            }
            while (i < pat.len and pat[i] != ']') : (i += 1) {
                if (pat[i] == '[') has_open = true else members.append(st.gpa, pat[i]) catch oom(st.ctx);
            }
            const closed = i < pat.len;
            if (closed) i += 1;
            out.append(st.gpa, '[') catch oom(st.ctx);
            if (neg) out.append(st.gpa, '^') catch oom(st.ctx);
            if (has_close) out.append(st.gpa, ']') catch oom(st.ctx);
            out.appendSlice(st.gpa, members.items) catch oom(st.ctx);
            if (has_open) out.append(st.gpa, '[') catch oom(st.ctx);
            if (closed) out.append(st.gpa, ']') catch oom(st.ctx);
            at_start = false;
            continue;
        }
        if (c == '\\' and i + 1 < pat.len) {
            const n = pat[i + 1];
            i += 2;
            switch (n) {
                '(' => {
                    out.append(st.gpa, '(') catch oom(st.ctx);
                    at_start = true;
                    continue;
                },
                '|' => {
                    out.append(st.gpa, '|') catch oom(st.ctx);
                    at_start = true;
                    continue;
                },
                ')' => out.append(st.gpa, n) catch oom(st.ctx),
                '{', '}' => {
                    out.append(st.gpa, '\\') catch oom(st.ctx);
                    out.append(st.gpa, n) catch oom(st.ctx);
                },
                else => {
                    out.append(st.gpa, '\\') catch oom(st.ctx);
                    out.append(st.gpa, n) catch oom(st.ctx);
                },
            }
            at_start = false;
            continue;
        }
        switch (c) {
            '.' => {
                if (strict_emacs) out.appendSlice(st.gpa, "[^\n]") catch oom(st.ctx) else out.append(st.gpa, '.') catch oom(st.ctx);
                at_start = false;
            },
            '*', '+', '?' => {
                if (at_start) out.append(st.gpa, '\\') catch oom(st.ctx);
                out.append(st.gpa, c) catch oom(st.ctx);
            },
            '(', ')', '|', '{', '}' => {
                out.append(st.gpa, '\\') catch oom(st.ctx);
                out.append(st.gpa, c) catch oom(st.ctx);
                at_start = false;
            },
            '^' => {
                out.append(st.gpa, c) catch oom(st.ctx);
            },
            else => {
                out.append(st.gpa, c) catch oom(st.ctx);
                at_start = false;
            },
        }
        i += 1;
    }
    return out.items;
}

/// GNU awk syntax: ERE in which a leading repetition operator is literal and
/// (for plain `awk`) intervals are not available.
fn awkEre(st: *State, pat: []const u8, no_intervals: bool) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at_start = true;
    var in_br = false;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        const c = pat[i];
        if (in_br) {
            out.append(st.gpa, c) catch oom(st.ctx);
            if (c == ']') in_br = false;
            continue;
        }
        if (c == '\\' and i + 1 < pat.len) {
            out.append(st.gpa, c) catch oom(st.ctx);
            i += 1;
            out.append(st.gpa, pat[i]) catch oom(st.ctx);
            at_start = false;
            continue;
        }
        switch (c) {
            '[' => {
                in_br = true;
                out.append(st.gpa, c) catch oom(st.ctx);
                if (i + 1 < pat.len and pat[i + 1] == '^') {
                    i += 1;
                    out.append(st.gpa, '^') catch oom(st.ctx);
                }
                if (i + 1 < pat.len and pat[i + 1] == ']') {
                    i += 1;
                    out.append(st.gpa, ']') catch oom(st.ctx);
                }
                at_start = false;
            },
            '*', '+', '?' => {
                if (at_start) out.append(st.gpa, '\\') catch oom(st.ctx);
                out.append(st.gpa, c) catch oom(st.ctx);
            },
            '{', '}' => {
                if (no_intervals or at_start) out.append(st.gpa, '\\') catch oom(st.ctx);
                out.append(st.gpa, c) catch oom(st.ctx);
                at_start = false;
            },
            '(', '|' => {
                out.append(st.gpa, c) catch oom(st.ctx);
                at_start = true;
            },
            '^' => out.append(st.gpa, c) catch oom(st.ctx),
            else => {
                out.append(st.gpa, c) catch oom(st.ctx);
                at_start = false;
            },
        }
    }
    return out.items;
}

/// POSIX minimal basic syntax: the GNU extensions \| \+ \? are ordinary.
fn minimalBasic(st: *State, pat: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pat.len) {
        if (pat[i] == '\\' and i + 1 < pat.len) {
            const n = pat[i + 1];
            i += 2;
            if (n == '|' or n == '+' or n == '?') {
                out.append(st.gpa, n) catch oom(st.ctx);
            } else {
                out.append(st.gpa, '\\') catch oom(st.ctx);
                out.append(st.gpa, n) catch oom(st.ctx);
            }
            continue;
        }
        out.append(st.gpa, pat[i]) catch oom(st.ctx);
        i += 1;
    }
    return out.items;
}

// ------------------------------------------------------------ evaluation

/// Stat the current entry on first use (like GNU's deferred stat); a failure is
/// reported once and makes the test fail.
fn loadStat(st: *State) bool {
    if (st.cur_loaded) return !st.cur_failed;
    st.cur_loaded = true;
    var err: LX.E = .SUCCESS;
    var lst: ?sys.FileStat = null;
    var stt: ?sys.FileStat = null;
    if (!statEntry(st, st.cur_path, st.cur_cmdline, &lst, &stt, &err)) {
        st.cur_failed = true;
        if (!(st.ignore_race and err == .NOENT)) {
            flushOut(st);
            cli.warn(st.ctx, "{s}: {s}", .{ quoteInner(st, st.cur_path), sys.errnoText(err) });
            st.exit_status = 1;
        }
        return false;
    }
    st.cur_lst = lst;
    st.cur_st = stt;
    return true;
}

fn getSt(st: *State) ?sys.FileStat {
    if (!loadStat(st)) return null;
    return st.cur_st;
}

fn getLst(st: *State) ?sys.FileStat {
    if (!loadStat(st)) return null;
    return st.cur_lst;
}

fn typeBit(mode: u32) u64 {
    const ch: u8 = switch (mode & 0o170000) {
        0o100000 => 'f',
        0o040000 => 'd',
        0o120000 => 'l',
        0o060000 => 'b',
        0o020000 => 'c',
        0o010000 => 'p',
        0o140000 => 's',
        else => 'D',
    };
    return @as(u64, 1) << @intCast(ch - 'A');
}

fn cmpI(cmp: Cmp, a: i64, b: i64) bool {
    return switch (cmp) {
        .eq => a == b,
        .gt => a > b,
        .lt => a < b,
    };
}

fn lower(st: *State, s: []const u8) []u8 {
    const out = st.gpa.alloc(u8, s.len) catch oom(st.ctx);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn basename(st: *State) []const u8 {
    return st.cur_path[st.cur_name_off..];
}

fn originTime(st: *State) i64 {
    return if (st.daystart) st.day_start else st.start_sec;
}

fn testTime(st: *State, n: *Node, s: sys.FileStat) bool {
    const t = switch (n.kind) {
        .atime, .amin => s.atime_s,
        .ctime, .cmin => s.ctime_s,
        else => s.mtime_s,
    };
    const tn: u32 = switch (n.kind) {
        .atime, .amin => s.atime_ns,
        .ctime, .cmin => s.ctime_ns,
        else => s.mtime_ns,
    };
    const on: u32 = if (st.daystart) 0 else st.start_nsec;
    var delta = originTime(st) - t;
    if (on < tn) delta -= 1;
    const unit: i64 = switch (n.kind) {
        .amin, .cmin, .mmin => 60,
        else => 86400,
    };
    // GNU rounds toward minus infinity for negative deltas as well
    if (unit == 60) {
        // minutes round up: a file 30 seconds old is "1" minute old
        const age_ns: i128 = @as(i128, delta) * 1_000_000_000 + (if (on < tn) @as(i128, on) + 1_000_000_000 - tn else @as(i128, on) - tn);
        _ = age_ns;
        var secs = originTime(st) - t;
        const frac: i64 = @as(i64, on) - @as(i64, tn);
        var total_ns: i128 = @as(i128, secs) * 1_000_000_000 + frac;
        _ = &secs;
        const nn: i128 = n.num;
        const min_ns: i128 = 60 * 1_000_000_000;
        return switch (n.cmp) {
            .gt => total_ns > nn * min_ns,
            .lt => total_ns < nn * min_ns,
            .eq => blk: {
                total_ns = total_ns;
                break :blk total_ns > (nn - 1) * min_ns and total_ns <= nn * min_ns;
            },
        };
    }
    const v = @divFloor(delta, unit);
    return cmpI(n.cmp, v, n.num);
}

fn fsTypeOf(st: *State, dev: u64) []const u8 {
    if (st.mounts == null) {
        var list: std.ArrayList(MountEnt) = .empty;
        var err: LX.E = .SUCCESS;
        if (sys.openFd("/proc/self/mountinfo", sys.O.RDONLY, 0, &err)) |fd| {
            var data: std.ArrayList(u8) = .empty;
            var buf: [8192]u8 = undefined;
            while (true) {
                const k = sys.readFd(fd, &buf, &err) orelse break;
                if (k == 0) break;
                data.appendSlice(st.gpa, buf[0..k]) catch oom(st.ctx);
            }
            _ = sys.closeFd(fd);
            var lines = std.mem.splitScalar(u8, data.items, '\n');
            while (lines.next()) |ln| {
                var f = std.mem.tokenizeScalar(u8, ln, ' ');
                _ = f.next();
                _ = f.next();
                const mm = f.next() orelse continue;
                var seen_dash = false;
                var typ: []const u8 = "";
                while (f.next()) |tok| {
                    if (seen_dash) {
                        typ = tok;
                        break;
                    }
                    if (std.mem.eql(u8, tok, "-")) seen_dash = true;
                }
                const colon = std.mem.indexOfScalar(u8, mm, ':') orelse continue;
                const maj = std.fmt.parseInt(u32, mm[0..colon], 10) catch continue;
                const min = std.fmt.parseInt(u32, mm[colon + 1 ..], 10) catch continue;
                list.append(st.gpa, .{ .dev = (@as(u64, maj) << 32) | min, .fstype = st.gpa.dupe(u8, typ) catch oom(st.ctx) }) catch oom(st.ctx);
            }
        }
        st.mounts = list.items;
    }
    for (st.mounts.?) |m| {
        if (m.dev == dev) return m.fstype;
    }
    return "unknown";
}

fn evalNode(st: *State, n: *Node) bool {
    if (st.quit) return false;
    switch (n.kind) {
        .and_ => return evalNode(st, n.a.?) and evalNode(st, n.b.?),
        .or_ => return evalNode(st, n.a.?) or evalNode(st, n.b.?),
        .comma => {
            _ = evalNode(st, n.a.?);
            return evalNode(st, n.b.?);
        },
        .not_ => return !evalNode(st, n.a.?),
        .true_ => return true,
        .false_ => return false,
        .name, .iname => {
            const base = basename(st);
            // for a start point the whole argument without trailing slashes counts
            var b = base;
            if (st.cur_depth == 0) {
                var p = st.cur_path;
                while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
                b = if (std.mem.lastIndexOfScalar(u8, p, '/')) |k| (if (p.len == 1) p else p[k + 1 ..]) else p;
            }
            if (n.kind == .iname) {
                return fnmatch.match(n.str, b, .{ .casefold = true });
            }
            return fnmatch.match(n.str, b, .{});
        },
        .path => return fnmatch.match(n.str, st.cur_path, .{}),
        .ipath => return fnmatch.match(n.str, st.cur_path, .{ .casefold = true }),
        .lname, .ilname => {
            const s = getLst(st) orelse return false;
            if (!s.isLink()) return false;
            var buf: [4096]u8 = undefined;
            var err: LX.E = .SUCCESS;
            const k = sys.readlinkPath(st.cur_path, &buf, &err) orelse return false;
            if (n.kind == .ilname) return fnmatch.match(n.str, buf[0..k], .{ .casefold = true });
            return fnmatch.match(n.str, buf[0..k], .{});
        },
        .regex_ => {
            var sr = n.re.?.searcher(st.gpa) catch oom(st.ctx);
            defer sr.deinit();
            return ((sr.find(st.cur_path, 0) catch null) != null);
        },
        .type_ => {
            if (st.cur_dtype != 0 and !(st.follow == .logical and st.cur_dtype == 'l') and !(st.follow == .command_line and st.cur_cmdline)) {
                return n.types & (@as(u64, 1) << @intCast(st.cur_dtype - 'A')) != 0;
            }
            const s = getSt(st) orelse return false;
            return n.types & typeBit(s.mode) != 0;
        },
        .xtype => {
            // the type seen with the opposite symlink treatment
            const s0 = getLst(st) orelse return false;
            if (st.follow == .logical) {
                return n.types & typeBit(s0.mode) != 0;
            }
            if (!s0.isLink()) return n.types & typeBit(s0.mode) != 0;
            var err: LX.E = .SUCCESS;
            const s = sys.fileStat(st.cur_path, true, &err) orelse {
                // dangling link
                return n.types & (@as(u64, 1) << ('l' - 'A')) != 0;
            };
            return n.types & typeBit(s.mode) != 0;
        },
        .size => {
            const s = getSt(st) orelse return false;
            const unit: u64 = switch (n.size_unit) {
                'b' => 512,
                'c' => 1,
                'w' => 2,
                'k' => 1024,
                'M' => 1 << 20,
                'G' => 1 << 30,
                'T' => @as(u64, 1) << 40,
                else => @as(u64, 1) << 50,
            };
            const v: u64 = (s.size + unit - 1) / unit;
            return cmpI(n.cmp, @intCast(@min(v, std.math.maxInt(i64))), n.num);
        },
        .perm => {
            const s = getSt(st) orelse return false;
            const bits: u32 = s.mode & 0o7777;
            return switch (n.perm_kind) {
                '-' => bits & n.perm_bits == n.perm_bits,
                '/' => n.perm_bits == 0 or bits & n.perm_bits != 0,
                else => bits == n.perm_bits,
            };
        },
        .user => return (getSt(st) orelse return false).uid == n.num,
        .group => return (getSt(st) orelse return false).gid == n.num,
        .uid => return cmpI(n.cmp, (getSt(st) orelse return false).uid, n.num),
        .gid => return cmpI(n.cmp, (getSt(st) orelse return false).gid, n.num),
        .inum => return cmpI(n.cmp, @intCast((getSt(st) orelse return false).ino), n.num),
        .links => return cmpI(n.cmp, (getSt(st) orelse return false).nlink, n.num),
        .nouser => {
            loadDb(st);
            return st.db.userByUid((getSt(st) orelse return false).uid) == null;
        },
        .nogroup => {
            loadDb(st);
            return st.db.groupByGid((getSt(st) orelse return false).gid) == null;
        },
        .atime, .ctime, .mtime, .amin, .cmin, .mmin => return testTime(st, n, getSt(st) orelse return false),
        .used => {
            const s = getSt(st) orelse return false;
            const delta: i128 = (@as(i128, s.atime_s) - s.ctime_s) * 1_000_000_000 + (@as(i128, s.atime_ns) - s.ctime_ns);
            if (delta < 0) return false;
            const day: i128 = 86400 * 1_000_000_000;
            const nn: i128 = n.num;
            return switch (n.cmp) {
                .gt => delta > nn * day,
                .lt => delta < nn * day,
                .eq => delta > 0 and delta > (nn - 1) * day and delta <= nn * day,
            };
        },
        .newer => {
            const s = getSt(st) orelse return false;
            const t = timeOf(s, n.x);
            if (t[0] != n.ref_sec) return t[0] > n.ref_sec;
            return t[1] > n.ref_nsec;
        },
        .samefile => {
            const s = getSt(st) orelse return false;
            return s.ino == n.ref_ino and devKey(s) == n.ref_dev;
        },
        .fstype => {
            const s = getSt(st) orelse return false;
            return std.mem.eql(u8, fsTypeOf(st, devKey(s)), n.str);
        },
        .empty => {
            const s = getSt(st) orelse return false;
            if (s.isReg()) return s.size == 0;
            if (s.isDir()) return dirIsEmpty(st, st.cur_path);
            return false;
        },
        .readable => return sys.accessPath(st.cur_path, 4) == null,
        .writable => return sys.accessPath(st.cur_path, 2) == null,
        .executable => return sys.accessPath(st.cur_path, 1) == null,
        .print => {
            emit(st, st.cur_path);
            emit(st, "\n");
            return true;
        },
        .print0 => {
            emit(st, st.cur_path);
            emit(st, "\x00");
            return true;
        },
        .ls => {
            printLs(st, null);
            return true;
        },
        .fls => {
            printLs(st, n.out);
            return true;
        },
        .fprint => {
            outWrite(st, n.out.?, st.cur_path);
            outWrite(st, n.out.?, "\n");
            return true;
        },
        .fprint0 => {
            outWrite(st, n.out.?, st.cur_path);
            outWrite(st, n.out.?, "\x00");
            return true;
        },
        .printf => {
            printFormat(st, n.fmt_parts, null);
            return true;
        },
        .fprintf => {
            printFormat(st, n.fmt_parts, n.out);
            return true;
        },
        .prune => {
            if (!st.depth_first) st.prune_flag = true;
            return true;
        },
        .quit => {
            st.quit = true;
            return true;
        },
        .delete => return doDelete(st),
        .exec => return doExec(st, n),
    }
}

fn dirIsEmpty(st: *State, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(st.ctx.io, path, .{ .iterate = true }) catch |e| {
        const emap: LX.E = switch (e) {
            error.AccessDenied => .ACCES,
            error.FileNotFound => .NOENT,
            error.NotDir => .NOTDIR,
            else => .IO,
        };
        flushOut(st);
        cli.warn(st.ctx, "{s}: {s}", .{ quoteInner(st, path), sys.errnoText(emap) });
        st.exit_status = 1;
        return false;
    };
    defer d.close(st.ctx.io);
    var it = d.iterate();
    const first = it.next(st.ctx.io) catch return false;
    return first == null;
}

fn outWrite(st: *State, o: *OutFile, bytes: []const u8) void {
    if (o.fd == 1) {
        emit(st, bytes);
        return;
    }
    o.buf.appendSlice(st.gpa, bytes) catch oom(st.ctx);
    if (o.buf.items.len > 65536 or o.fd == 2) flushFile(o);
}

fn flushFile(o: *OutFile) void {
    if (o.buf.items.len > 0) {
        _ = sys.writeAllFd(o.fd, o.buf.items);
        o.buf.clearRetainingCapacity();
    }
}

fn doDelete(st: *State) bool {
    const s = getLst(st) orelse return false;
    // never delete the "." start point name
    if (st.cur_depth == 0 and std.mem.eql(u8, st.cur_path, ".")) return true;
    const is_dir = s.isDir();
    if (sys.unlinkPath(st.cur_path, is_dir)) |e| {
        flushOut(st);
        cli.warn(st.ctx, "cannot delete {s}: {s}", .{ quoteInner(st, st.cur_path), sys.errnoText(e) });
        st.exit_status = 1;
        return false;
    }
    return true;
}

// ----------------------------------------------------------------- exec

fn replaceBraces(st: *State, arg: []const u8, repl: []const u8) []const u8 {
    if (std.mem.indexOf(u8, arg, "{}") == null) return arg;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < arg.len) {
        if (i + 1 < arg.len and arg[i] == '{' and arg[i + 1] == '}') {
            out.appendSlice(st.gpa, repl) catch oom(st.ctx);
            i += 2;
        } else {
            out.append(st.gpa, arg[i]) catch oom(st.ctx);
            i += 1;
        }
    }
    return out.items;
}

fn runCommand(st: *State, argv: []const []const u8, cwd: ?[]const u8) bool {
    flushOut(st);
    for (st.outs.items) |o| flushFile(o);
    const cwd_opt: std.process.Child.Cwd = if (cwd) |c| .{ .path = c } else .inherit;
    var child = std.process.spawn(st.ctx.io, .{ .argv = argv, .cwd = cwd_opt, .stdin = .inherit }) catch |e| {
        const text: []const u8 = switch (e) {
            error.FileNotFound => "No such file or directory",
            error.AccessDenied, error.PermissionDenied => "Permission denied",
            error.InvalidExe => "Exec format error",
            else => @errorName(e),
        };
        cli.warn(st.ctx, "{s}: {s}", .{ quoteInner(st, argv[0]), text });
        return false;
    };
    _ = &child;
    const pid: i32 = @intCast(child.id.?);
    switch (sys.waitPid(pid, true)) {
        .exited => |c| return c == 0,
        else => return false,
    }
}

fn stripSlashes(p: []const u8) []const u8 {
    var t = p;
    while (t.len > 1 and t[t.len - 1] == '/') t = t[0 .. t.len - 1];
    return t;
}

/// %f for any path: the last component, plus a slash if the path ends with
/// one (as GNU find prints for start points such as "a/").
fn baseOf(p: []const u8) []const u8 {
    const t = stripSlashes(p);
    if (std.mem.eql(u8, t, "/")) return "/";
    const comp = if (std.mem.lastIndexOfScalar(u8, t, '/')) |k| t[k + 1 ..] else t;
    if (t.len < p.len) return p[p.len - (p.len - t.len) - comp.len .. p.len - (p.len - t.len) + 1];
    return comp;
}

/// %h for any path, with find's treatment of trailing slashes.
fn dirnameOf(p: []const u8) []const u8 {
    const t = stripSlashes(p);
    if (std.mem.eql(u8, t, "/")) return if (p.len > 1) p[0 .. p.len - 1] else "";
    if (std.mem.lastIndexOfScalar(u8, t, '/')) |k| return if (k == 0) "/" else t[0..k];
    if (t.len < p.len) {
        if (std.mem.eql(u8, t, "..")) return ".";
        return p[0 .. p.len - 1];
    }
    return ".";
}

fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |k| {
        if (k == 0) return "/";
        return path[0..k];
    }
    return ".";
}

fn doExec(st: *State, n: *Node) bool {
    const name_for_dir = blk: {
        if (!n.dir) break :blk st.cur_path;
        const base = basename(st);
        if (st.cur_depth == 0) {
            break :blk std.fmt.allocPrint(st.gpa, "./{s}", .{baseOf(st.cur_path)}) catch oom(st.ctx);
        }
        break :blk std.fmt.allocPrint(st.gpa, "./{s}", .{base}) catch oom(st.ctx);
    };
    const cwd: ?[]const u8 = if (n.dir) (if (st.cur_depth == 0) blk: {
        const d = dirOf(blk2: {
            var p = st.cur_path;
            while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
            break :blk2 p;
        });
        break :blk d;
    } else st.cur_dir_path) else null;
    if (n.plus) {
        n.batch.append(st.gpa, name_for_dir) catch oom(st.ctx);
        if (n.dir) n.batch_dirs.append(st.gpa, cwd orelse ".") catch oom(st.ctx);
        n.batch_len += name_for_dir.len + 1;
        if (n.batch_len > 100000) flushBatch(st, n);
        return true;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    for (n.argv) |a| argv.append(st.gpa, replaceBraces(st, a, name_for_dir)) catch oom(st.ctx);
    if (n.prompt) {
        flushOut(st);
        var pr: std.ArrayList(u8) = .empty;
        pr.append(st.gpa, '<') catch oom(st.ctx);
        for (argv.items[0..1]) |a| {
            pr.append(st.gpa, ' ') catch oom(st.ctx);
            pr.appendSlice(st.gpa, a) catch oom(st.ctx);
        }
        pr.appendSlice(st.gpa, " ... ") catch oom(st.ctx);
        pr.appendSlice(st.gpa, st.cur_path) catch oom(st.ctx);
        pr.appendSlice(st.gpa, " > ? ") catch oom(st.ctx);
        _ = sys.writeAllFd(2, pr.items);
        // read one line from stdin
        var line: [256]u8 = undefined;
        var k: usize = 0;
        var err: LX.E = .SUCCESS;
        while (k < line.len) {
            var b: [1]u8 = undefined;
            const got = sys.readFd(0, &b, &err) orelse break;
            if (got == 0) break;
            if (b[0] == '\n') break;
            line[k] = b[0];
            k += 1;
        }
        if (k == 0 or (line[0] != 'y' and line[0] != 'Y')) return false;
    }
    return runCommand(st, argv.items, cwd);
}

fn flushBatch(st: *State, n: *Node) void {
    if (n.batch.items.len == 0) return;
    var argv: std.ArrayList([]const u8) = .empty;
    for (n.argv[0 .. n.argv.len - 1]) |a| argv.append(st.gpa, a) catch oom(st.ctx);
    if (n.dir) {
        // run once per directory group
        var i: usize = 0;
        while (i < n.batch.items.len) {
            const d = n.batch_dirs.items[i];
            var j = i;
            argv.shrinkRetainingCapacity(n.argv.len - 1);
            while (j < n.batch.items.len and std.mem.eql(u8, n.batch_dirs.items[j], d)) : (j += 1) {
                argv.append(st.gpa, n.batch.items[j]) catch oom(st.ctx);
            }
            if (!runCommand(st, argv.items, d)) st.exit_status = 1;
            i = j;
        }
    } else {
        for (n.batch.items) |f| argv.append(st.gpa, f) catch oom(st.ctx);
        if (!runCommand(st, argv.items, null)) st.exit_status = 1;
    }
    n.batch.clearRetainingCapacity();
    n.batch_dirs.clearRetainingCapacity();
    n.batch_len = 0;
}

// --------------------------------------------------------------- printing

fn modeStr(mode: u32, buf: *[10]u8) void {
    buf[0] = switch (mode & 0o170000) {
        0o100000 => '-',
        0o040000 => 'd',
        0o060000 => 'b',
        0o020000 => 'c',
        0o120000 => 'l',
        0o010000 => 'p',
        0o140000 => 's',
        else => '?',
    };
    buf[1] = if (mode & 0o400 != 0) 'r' else '-';
    buf[2] = if (mode & 0o200 != 0) 'w' else '-';
    buf[3] = if (mode & 0o4000 != 0) (if (mode & 0o100 != 0) @as(u8, 's') else 'S') else if (mode & 0o100 != 0) 'x' else '-';
    buf[4] = if (mode & 0o040 != 0) 'r' else '-';
    buf[5] = if (mode & 0o020 != 0) 'w' else '-';
    buf[6] = if (mode & 0o2000 != 0) (if (mode & 0o010 != 0) @as(u8, 's') else 'S') else if (mode & 0o010 != 0) 'x' else '-';
    buf[7] = if (mode & 0o004 != 0) 'r' else '-';
    buf[8] = if (mode & 0o002 != 0) 'w' else '-';
    buf[9] = if (mode & 0o1000 != 0) (if (mode & 0o001 != 0) @as(u8, 't') else 'T') else if (mode & 0o001 != 0) 'x' else '-';
}

fn userName(st: *State, uid: u32) []const u8 {
    loadDb(st);
    if (st.db.userByUid(uid)) |u| return u.name;
    return std.fmt.allocPrint(st.gpa, "{d}", .{uid}) catch oom(st.ctx);
}

fn groupName(st: *State, gid: u32) []const u8 {
    loadDb(st);
    if (st.db.groupByGid(gid)) |g| return g.name;
    return std.fmt.allocPrint(st.gpa, "{d}", .{gid}) catch oom(st.ctx);
}

fn printLs(st: *State, o: ?*OutFile) void {
    var space_set: quotearg.ExtraSet = .{};
    space_set.add(' ');
    const s = getSt(st) orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(st.gpa);
    var ms: [10]u8 = undefined;
    modeStr(s.mode, &ms);
    const user = userName(st, s.uid);
    const group = groupName(st, s.gid);
    ensureZone(st);
    const tm = tzmod.localtime(&st.zone, s.mtime_s);
    const six_months: i64 = 183 * 86400 / 1; // GNU: 6 months
    const recent = st.start_sec - s.mtime_s < six_months and s.mtime_s - st.start_sec < 3600;
    var tbuf: std.ArrayList(u8) = .empty;
    defer tbuf.deinit(st.gpa);
    strftime.format(&tbuf, st.gpa, if (recent) "%b %e %H:%M" else "%b %e  %Y", &tm, s.mtime_s, 0) catch oom(st.ctx);
    out.print(st.gpa, "{d: >9} {d: >6} {s} {d: >3} {s: <8} {s: <8} ", .{ s.ino, (s.blocks + 1) / 2, ms[0..], s.nlink, user, group }) catch oom(st.ctx);
    const kind = s.mode & 0o170000;
    if (kind == 0o020000 or kind == 0o060000) {
        out.print(st.gpa, "{d: >3}, {d: >3} ", .{ s.rdev_major, s.rdev_minor }) catch oom(st.ctx);
    } else out.print(st.gpa, "{d: >8} ", .{s.size}) catch oom(st.ctx);
    out.appendSlice(st.gpa, tbuf.items) catch oom(st.ctx);
    out.append(st.gpa, ' ') catch oom(st.ctx);
    quotearg.quote(&out, st.gpa, st.cur_path, .escape, &space_set) catch oom(st.ctx);
    if (s.isLink()) {
        var buf: [4096]u8 = undefined;
        var err: LX.E = .SUCCESS;
        if (sys.readlinkPath(st.cur_path, &buf, &err)) |k| {
            out.appendSlice(st.gpa, " -> ") catch oom(st.ctx);
            quotearg.quote(&out, st.gpa, buf[0..k], .escape, &space_set) catch oom(st.ctx);
        }
    }
    out.append(st.gpa, '\n') catch oom(st.ctx);
    if (o) |f| outWrite(st, f, out.items) else emit(st, out.items);
}

fn padTo(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8, width: ?usize, left: bool, zero: bool) !void {
    const w = width orelse 0;
    if (text.len >= w) return out.appendSlice(gpa, text);
    const pad = w - text.len;
    if (left) {
        try out.appendSlice(gpa, text);
        try out.appendNTimes(gpa, ' ', pad);
    } else if (zero) {
        // keep a sign in front of the zeros
        var t = text;
        if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
            try out.append(gpa, t[0]);
            t = t[1..];
        }
        try out.appendNTimes(gpa, '0', pad);
        try out.appendSlice(gpa, t);
    } else {
        try out.appendNTimes(gpa, ' ', pad);
        try out.appendSlice(gpa, text);
    }
}

fn fmtTime(st: *State, out: *std.ArrayList(u8), tchar: u8, sec: i64, nsec: i64) void {
    ensureZone(st);
    const tm = tzmod.localtime(&st.zone, sec);
    switch (tchar) {
        '@' => out.print(st.gpa, "{d}.{d:0>10}", .{ sec, @as(u64, @intCast(nsec)) * 10 }) catch oom(st.ctx),
        '+' => {
            strftime.format(out, st.gpa, "%Y-%m-%d+%H:%M:%S", &tm, sec, @intCast(nsec)) catch oom(st.ctx);
            out.print(st.gpa, ".{d:0>10}", .{@as(u64, @intCast(nsec)) * 10}) catch oom(st.ctx);
            // %Z-less like GNU: "+%T" style has no zone
        },
        else => {
            const f = [_]u8{ '%', tchar };
            if (tchar != 1 and std.mem.indexOfScalar(u8, "aAbBcCdDeFgGhHIjklmMnprRsStTuUVwWxXyYzZEO", tchar) == null) {
                out.appendSlice(st.gpa, &f) catch oom(st.ctx);
            } else if (tchar == 'S') {
                strftime.format(out, st.gpa, "%S", &tm, sec, @intCast(nsec)) catch oom(st.ctx);
                out.print(st.gpa, ".{d:0>10}", .{@as(u64, @intCast(nsec)) * 10}) catch oom(st.ctx);
            } else if (tchar == 'T' or tchar == 'X') {
                strftime.format(out, st.gpa, "%H:%M:%S", &tm, sec, @intCast(nsec)) catch oom(st.ctx);
                out.print(st.gpa, ".{d:0>10}", .{@as(u64, @intCast(nsec)) * 10}) catch oom(st.ctx);
            } else if (tchar == 1) {
                // like ctime with fractional seconds
                strftime.format(out, st.gpa, "%a %b %e %H:%M:%S", &tm, sec, @intCast(nsec)) catch oom(st.ctx);
                out.print(st.gpa, ".{d:0>10}", .{@as(u64, @intCast(nsec)) * 10}) catch oom(st.ctx);
                strftime.format(out, st.gpa, " %Y", &tm, sec, @intCast(nsec)) catch oom(st.ctx);
            } else strftime.format(out, st.gpa, &f, &tm, sec, @intCast(nsec)) catch oom(st.ctx);
        },
    }
}

/// printf("%g"): six significant digits, trailing zeros removed.
fn fmtG(st: *State, out: *std.ArrayList(u8), v: f64) void {
    if (v == 0) {
        out.append(st.gpa, '0') catch oom(st.ctx);
        return;
    }
    const mag: i32 = @intFromFloat(@floor(std.math.log10(@abs(v))));
    var decimals: i32 = 5 - mag;
    if (decimals < 0) decimals = 0;
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, @as(usize, @intCast(decimals)) }) catch return;
    var end = txt.len;
    if (std.mem.indexOfScalar(u8, txt, '.') != null) {
        while (end > 0 and txt[end - 1] == '0') end -= 1;
        if (end > 0 and txt[end - 1] == '.') end -= 1;
    }
    out.appendSlice(st.gpa, txt[0..end]) catch oom(st.ctx);
}

fn printFormat(st: *State, parts: []const FmtPart, o: ?*OutFile) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(st.gpa);
    const s = getSt(st);
    for (parts) |pt| {
        out.appendSlice(st.gpa, pt.lit) catch oom(st.ctx);
        if (pt.stop) break;
        if (pt.dir == 0) continue;
        const left = std.mem.indexOfScalar(u8, pt.flags, '-') != null;
        const zero = std.mem.indexOfScalar(u8, pt.flags, '0') != null;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(st.gpa);
        var is_num = false;
        switch (pt.dir) {
            'p' => tmp.appendSlice(st.gpa, st.cur_path) catch oom(st.ctx),
            'f' => tmp.appendSlice(st.gpa, baseOf(st.cur_path)) catch oom(st.ctx),
            'h' => tmp.appendSlice(st.gpa, dirnameOf(st.cur_path)) catch oom(st.ctx),
            'H' => tmp.appendSlice(st.gpa, st.cur_root) catch oom(st.ctx),
            'P' => {
                if (st.cur_path.len > st.cur_root.len) {
                    var r = st.cur_path[st.cur_root.len..];
                    if (r.len > 0 and r[0] == '/') r = r[1..];
                    tmp.appendSlice(st.gpa, r) catch oom(st.ctx);
                }
            },
            'd' => {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{st.cur_depth}) catch oom(st.ctx);
            },
            'y', 'Y' => {
                if (s) |sv| {
                    var c: u8 = switch (sv.mode & 0o170000) {
                        0o100000 => 'f',
                        0o040000 => 'd',
                        0o120000 => 'l',
                        0o060000 => 'b',
                        0o020000 => 'c',
                        0o010000 => 'p',
                        0o140000 => 's',
                        else => 'U',
                    };
                    if (pt.dir == 'Y' and sv.isLink()) {
                        var err: LX.E = .SUCCESS;
                        if (sys.fileStat(st.cur_path, true, &err)) |t| {
                            c = switch (t.mode & 0o170000) {
                                0o100000 => 'f',
                                0o040000 => 'd',
                                0o060000 => 'b',
                                0o020000 => 'c',
                                0o010000 => 'p',
                                0o140000 => 's',
                                else => 'U',
                            };
                        } else c = if (err == .LOOP) 'L' else if (err == .NOENT) 'N' else '?';
                    }
                    tmp.append(st.gpa, c) catch oom(st.ctx);
                }
            },
            'l' => {
                if (s) |sv| if (sv.isLink()) {
                    var buf: [4096]u8 = undefined;
                    var err: LX.E = .SUCCESS;
                    if (sys.readlinkPath(st.cur_path, &buf, &err)) |k| tmp.appendSlice(st.gpa, buf[0..k]) catch oom(st.ctx);
                };
            },
            's' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.size}) catch oom(st.ctx);
            },
            'S' => if (s) |sv| {
                is_num = true;
                if (sv.size == 0) {
                    tmp.appendSlice(st.gpa, "1") catch oom(st.ctx);
                } else {
                    const ratio: f64 = @as(f64, @floatFromInt(sv.blocks)) * 512.0 / @as(f64, @floatFromInt(sv.size));
                    fmtG(st, &tmp, ratio);
                }
            },
            'b' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.blocks}) catch oom(st.ctx);
            },
            'k' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{(sv.blocks + 1) / 2}) catch oom(st.ctx);
            },
            'n' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.nlink}) catch oom(st.ctx);
            },
            'i' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.ino}) catch oom(st.ctx);
            },
            'D' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{(@as(u64, sv.dev_major) << 8) | sv.dev_minor}) catch oom(st.ctx);
            },
            'm' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{o}", .{sv.mode & 0o7777}) catch oom(st.ctx);
            },
            'M' => if (s) |sv| {
                var ms: [10]u8 = undefined;
                modeStr(sv.mode, &ms);
                tmp.appendSlice(st.gpa, &ms) catch oom(st.ctx);
            },
            'u' => if (s) |sv| tmp.appendSlice(st.gpa, userName(st, sv.uid)) catch oom(st.ctx),
            'g' => if (s) |sv| tmp.appendSlice(st.gpa, groupName(st, sv.gid)) catch oom(st.ctx),
            'U' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.uid}) catch oom(st.ctx);
            },
            'G' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.gid}) catch oom(st.ctx);
            },
            'F' => if (s) |sv| tmp.appendSlice(st.gpa, fsTypeOf(st, devKey(sv))) catch oom(st.ctx),
            'Z' => {
                flushOut(st);
                cli.warn(st.ctx, "getfilecon failed: {s}: No data available", .{quoteInner(st, st.cur_path)});
                st.exit_status = 1;
            },
            'a' => if (s) |sv| fmtTime(st, &tmp, 1, sv.atime_s, sv.atime_ns),
            'c' => if (s) |sv| fmtTime(st, &tmp, 1, sv.ctime_s, sv.ctime_ns),
            't' => if (s) |sv| fmtTime(st, &tmp, 1, sv.mtime_s, sv.mtime_ns),
            'A' => if (s) |sv| fmtTime(st, &tmp, pt.tchar, sv.atime_s, sv.atime_ns),
            'C' => if (s) |sv| fmtTime(st, &tmp, pt.tchar, sv.ctime_s, sv.ctime_ns),
            'T' => if (s) |sv| fmtTime(st, &tmp, pt.tchar, sv.mtime_s, sv.mtime_ns),
            else => {},
        }
        var text: []const u8 = tmp.items;
        if (pt.dir != 'd' and pt.dir != 'm') {
            if (pt.prec) |pr| if (text.len > pr) {
                text = text[0..pr];
            };
        }
        if (pt.dir == 'm' and std.mem.indexOfScalar(u8, pt.flags, '#') != null) {
            const t2 = std.fmt.allocPrint(st.gpa, "0{s}", .{text}) catch oom(st.ctx);
            text = t2;
        }
        padTo(&out, st.gpa, text, pt.width, left, zero and (pt.dir == 'd' or pt.dir == 'm')) catch oom(st.ctx);
    }
    if (o) |f| outWrite(st, f, out.items) else emit(st, out.items);
}

// -------------------------------------------------------------- traversal

const Ancestor = struct { dev: u64, ino: u64, path: []const u8 };

fn statEntry(st: *State, path: []const u8, cmdline: bool, lst: *?sys.FileStat, stt: *?sys.FileStat, err: *LX.E) bool {
    var e: LX.E = .SUCCESS;
    lst.* = sys.fileStat(path, false, &e);
    if (lst.* == null) {
        err.* = e;
        return false;
    }
    const follow = st.follow == .logical or (st.follow == .command_line and cmdline);
    if (follow and lst.*.?.isLink()) {
        stt.* = sys.fileStat(path, true, &e);
        if (stt.* == null) stt.* = lst.*;
    } else stt.* = lst.*;
    return true;
}

const Cur = struct {
    path: []const u8,
    name_off: usize,
    depth: i64,
    st: ?sys.FileStat,
    lst: ?sys.FileStat,
    dtype: u8,
    loaded: bool,
    failed: bool,
    cmdline: bool,
    dir: []const u8,
};

fn saveCur(st: *State) Cur {
    return .{ .path = st.cur_path, .name_off = st.cur_name_off, .depth = st.cur_depth, .st = st.cur_st, .lst = st.cur_lst, .dtype = st.cur_dtype, .loaded = st.cur_loaded, .failed = st.cur_failed, .cmdline = st.cur_cmdline, .dir = st.cur_dir_path };
}

fn restoreCur(st: *State, c: Cur) void {
    st.cur_path = c.path;
    st.cur_name_off = c.name_off;
    st.cur_depth = c.depth;
    st.cur_st = c.st;
    st.cur_lst = c.lst;
    st.cur_dtype = c.dtype;
    st.cur_loaded = c.loaded;
    st.cur_failed = c.failed;
    st.cur_cmdline = c.cmdline;
    st.cur_dir_path = c.dir;
}

fn dtypeOf(kind: Io.File.Kind) u8 {
    return switch (kind) {
        .directory => 'd',
        .file => 'f',
        .sym_link => 'l',
        .block_device => 'b',
        .character_device => 'c',
        .named_pipe => 'p',
        .unix_domain_socket => 's',
        else => 0,
    };
}

fn visit(st: *State, path: []const u8, name_off: usize, depth: i64, cmdline: bool, ancestors: *std.ArrayList(Ancestor), root_dev: u64, parent_dir: []const u8, dtype: u8) void {
    if (st.quit) return;
    st.cur_path = path;
    st.cur_name_off = name_off;
    st.cur_depth = depth;
    st.cur_dtype = dtype;
    st.cur_cmdline = cmdline;
    st.cur_dir_path = parent_dir;
    st.cur_loaded = false;
    st.cur_failed = false;
    st.cur_st = null;
    st.cur_lst = null;
    const logical = st.follow == .logical;
    const eager = cmdline or dtype == 0 or (logical and (dtype == 'l' or dtype == 'd')) or (st.xdev and dtype == 'd');
    if (eager) {
        if (!loadStat(st)) return;
    }
    const is_dir: bool = if (st.cur_loaded) st.cur_st.?.isDir() else dtype == 'd';
    var dev: u64 = 0;
    var ino: u64 = 0;
    if (st.cur_loaded and st.cur_st != null) {
        dev = devKey(st.cur_st.?);
        ino = st.cur_st.?.ino;
    }
    // directory loop detection (only symbolic links can make loops)
    if (is_dir and logical) {
        for (ancestors.items) |a| {
            if (a.ino == ino and a.dev == dev) {
                flushOut(st);
                cli.warn(st.ctx, "File system loop detected; {s} is part of the same file system loop as {s}.", .{ quoteInner(st, path), quoteInner(st, a.path) });
                st.exit_status = 1;
                return;
            }
        }
    }

    var descend = is_dir and (st.maxdepth < 0 or depth < st.maxdepth);
    if (st.xdev and is_dir and depth > 0 and dev != root_dev) descend = false;

    const eval_here = depth >= st.mindepth;
    st.prune_flag = false;
    const snap = saveCur(st);
    if (!st.depth_first and eval_here) {
        _ = evalNode(st, st.root);
        if (st.quit) return;
        if (st.prune_flag) descend = false;
    }
    if (descend) {
        ancestors.append(st.gpa, .{ .dev = dev, .ino = ino, .path = path }) catch oom(st.ctx);
        walkDir(st, path, depth, ancestors, root_dev);
        _ = ancestors.pop();
        if (st.quit) return;
        restoreCur(st, snap);
    }
    if (st.depth_first and eval_here) {
        _ = evalNode(st, st.root);
    }
}

fn walkDir(st: *State, path: []const u8, depth: i64, ancestors: *std.ArrayList(Ancestor), root_dev: u64) void {
    var d = Io.Dir.cwd().openDir(st.ctx.io, path, .{ .iterate = true }) catch |e| {
        const emap: LX.E = switch (e) {
            error.AccessDenied => .ACCES,
            error.FileNotFound => .NOENT,
            error.NotDir => .NOTDIR,
            error.SymLinkLoop => .LOOP,
            else => .IO,
        };
        flushOut(st);
        cli.warn(st.ctx, "{s}: {s}", .{ quoteInner(st, path), sys.errnoText(emap) });
        st.exit_status = 1;
        return;
    };
    var names: std.ArrayList([]u8) = .empty;
    var kinds: std.ArrayList(u8) = .empty;
    defer {
        for (names.items) |nm| st.gpa.free(nm);
        names.deinit(st.gpa);
        kinds.deinit(st.gpa);
    }
    var it = d.iterate();
    while (it.next(st.ctx.io) catch null) |entry| {
        names.append(st.gpa, st.gpa.dupe(u8, entry.name) catch oom(st.ctx)) catch oom(st.ctx);
        kinds.append(st.gpa, dtypeOf(entry.kind)) catch oom(st.ctx);
    }
    d.close(st.ctx.io);
    var base = path;
    if (base.len > 1 and base[base.len - 1] == '/') {
        // fts: the trailing slash of the parent is not doubled
        base = base[0 .. base.len - 1];
        if (base.len == 0) base = "/";
    }
    for (names.items, kinds.items) |nm, kd| {
        if (st.quit) return;
        const child = if (std.mem.eql(u8, base, "/"))
            std.fmt.allocPrint(st.gpa, "/{s}", .{nm}) catch oom(st.ctx)
        else
            std.fmt.allocPrint(st.gpa, "{s}/{s}", .{ base, nm }) catch oom(st.ctx);
        const off = child.len - nm.len;
        visit(st, child, off, depth + 1, false, ancestors, root_dev, path, kd);
    }
}

// -------------------------------------------------------------------- main

fn localeIsUtf8(ctx: cli.Context) bool {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |k| {
        const v = cli.getenv(ctx, k) orelse continue;
        if (v.len == 0) continue;
        return std.ascii.findIgnoreCase(v, "utf-8") != null or std.ascii.findIgnoreCase(v, "utf8") != null;
    }
    return false;
}

fn debugFlags(st: *State, list: []const u8) void {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |f| {
        const known = [_][]const u8{ "exec", "opt", "rates", "search", "stat", "time", "tree", "all" };
        var ok = false;
        for (known) |k| {
            if (std.mem.eql(u8, k, f)) ok = true;
        }
        if (!ok) cli.warn(st.ctx, "Ignoring unrecognised debug flag {s}", .{quoteInner(st, f)});
    }
}

fn looksLikeExpr(a: []const u8) bool {
    if (a.len == 0) return false;
    if (a[0] == '-' and a.len > 1) return true;
    return std.mem.eql(u8, a, "(") or std.mem.eql(u8, a, "!");
}

pub fn main(ctx: cli.Context) u8 {
    var st = State{ .ctx = ctx, .gpa = std.heap.smp_allocator };
    st.utf8 = localeIsUtf8(ctx);
    var args_list: std.ArrayList([]const u8) = .empty;
    for (ctx.args) |a| args_list.append(st.gpa, a) catch oom(ctx);
    const args = args_list.items;
    var i: usize = 0;
    // leading options
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-H")) {
            st.follow = .command_line;
        } else if (std.mem.eql(u8, a, "-L")) {
            st.follow = .logical;
        } else if (std.mem.eql(u8, a, "-P")) {
            st.follow = .physical;
        } else if (std.mem.eql(u8, a, "-D")) {
            i += 1;
            if (i >= args.len) {
                cli.warn(ctx, "Missing argument after the -D option.\nTry '{s} --help' for more information.", .{ctx.name});
                return 1;
            }
            if (std.mem.eql(u8, args[i], "help")) {
                const t =
                    \\Valid arguments for -D:
                    \\exec       Show diagnostic information relating to -exec, -execdir, -ok and -okdir
                    \\opt        Show diagnostic information relating to optimisation
                    \\rates      Indicate how often each predicate succeeded
                    \\search     Navigate the directory tree verbosely
                    \\stat       Trace calls to stat(2) and lstat(2)
                    \\time       Show diagnostic information relating to time-of-day and timestamp comparisons
                    \\tree       Display the expression tree
                    \\all        Set all of the debug flags (but help)
                    \\help       Explain the various -D options
                    \\
                ;
                return if (cli.writeStdout(ctx.io, t)) 0 else 1;
            }
            debugFlags(&st, args[i]);
        } else if (std.mem.startsWith(u8, a, "-D")) {
            debugFlags(&st, a[2..]);
        } else if (std.mem.startsWith(u8, a, "-O")) {
            const rest = a[2..];
            if (rest.len == 0) fail(&st, "The -O option must be immediately followed by a decimal integer", .{});
            if (!std.ascii.isDigit(rest[0])) fail(&st, "Please specify a decimal number immediately after -O", .{});
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else break;
        i += 1;
    }
    if (args.len >= 1) {
        if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-help")) {
            const text = std.mem.replaceOwned(u8, st.gpa, help_text, "@NAME@", ctx.name) catch return 1;
            return if (cli.writeStdout(ctx.io, text)) 0 else 1;
        }
        if (std.mem.eql(u8, args[0], "--version") or std.mem.eql(u8, args[0], "-version")) {
            const v =
                \\find (GNU findutils) 4.10.0
                \\Copyright (C) 2024 Free Software Foundation, Inc.
                \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
                \\This is free software: you are free to change and redistribute it.
                \\There is NO WARRANTY, to the extent permitted by law.
                \\
                \\Written by Eric B. Decker, James Youngman, and Kevin Dalley.
                \\Features enabled: D_TYPE O_NOFOLLOW(enabled) LEAF_OPTIMISATION FTS(FTS_CWDFD) CBO(level=1) 
                \\
            ;
            return if (cli.writeStdout(ctx.io, v)) 0 else 1;
        }
    }
    // start points
    var starts: std.ArrayList([]const u8) = .empty;
    while (i < args.len and !looksLikeExpr(args[i])) : (i += 1) {
        starts.append(st.gpa, args[i]) catch oom(ctx);
    }
    const now = Io.Timestamp.now(ctx.io, .real);
    st.start_sec = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    st.start_nsec = @intCast(@mod(now.nanoseconds, std.time.ns_per_s));

    var p = Parser{ .st = &st, .args = args, .i = i, .no_starts = starts.items.len == 0 };
    if (i >= args.len) {
        const t = p.mk(.print);
        st.root = t;
    } else {
        // daystart needs the zone
        const e = p.parseComma();
        if (p.i < args.len) {
            // leftover tokens: a stray ')' or an operand
            const a = args[p.i];
            if (std.mem.eql(u8, a, ")")) fail(&st, "you have too many ')'", .{});
            fail(&st, "invalid expression", .{});
        }
        if (st.has_action) {
            st.root = e;
        } else {
            const pr = p.mk(.print);
            const n = p.mk(.and_);
            n.a = e;
            n.b = pr;
            st.root = n;
        }
    }
    if (st.saw_delete and st.saw_prune and !st.explicit_depth) fail(&st, "The -delete action automatically turns on -depth, but -prune does nothing when -depth is in effect.  If you want to carry on anyway, just explicitly use the -depth option.", .{});
    if (st.daystart) {
        ensureZone(&st);
        const tm = tzmod.localtime(&st.zone, st.start_sec);
        st.day_start = tzmod.mktime(&st.zone, tm.year, @as(i64, tm.mon) - 1, @as(i64, tm.mday) + 1, 0, 0, 0);
    }
    if (starts.items.len == 0) starts.append(st.gpa, ".") catch oom(ctx);

    for (starts.items) |sp| {
        if (st.quit) break;
        var anc: std.ArrayList(Ancestor) = .empty;
        defer anc.deinit(st.gpa);
        st.cur_root = sp;
        var rdev: u64 = 0;
        {
            var err: LX.E = .SUCCESS;
            if (sys.fileStat(sp, false, &err)) |rs| rdev = devKey(rs);
        }
        // name offset: after the last slash that is not trailing
        var tl = sp.len;
        while (tl > 1 and sp[tl - 1] == '/') tl -= 1;
        const off = if (std.mem.lastIndexOfScalar(u8, sp[0..tl], '/')) |k| (if (tl == 1) 0 else k + 1) else 0;
        visit(&st, sp, off, 0, true, &anc, rdev, dirOf(sp), 0);
    }
    for (st.execs.items) |n| flushBatch(&st, n);
    flushOut(&st);
    for (st.outs.items) |o| flushFile(o);
    return st.exit_status;
}
