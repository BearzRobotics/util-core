// SPDX-License-Identifier: GPL-2.0-or-later
//! find library: walk directory trees and evaluate an expression. Reference:
//! GNU findutils 4.10 (parser.c, pred.c, tree.c, find.c). Traversal order is
//! the order of readdir, like fts without a comparison function.
//!
//! Two stages, so that a library caller can use either:
//!
//!  * `compile` turns the expression tokens (what follows the start points on
//!    the command line: `-name`, `*.c`, `-o`, `-exec`, `rm`, `{}`, `;`, ...)
//!    into an `Expr`. A bad expression returns `error.Invalid` and fills a
//!    `Diagnostic` with GNU find's wording. Warnings (unknown escapes in a
//!    -printf format, ...) go to the Observer.
//!  * `Expr.run` walks start points, evaluates the expression on every entry
//!    and writes `-print`/`-printf`/`-ls`/`-json` output to a caller-supplied
//!    writer. `-exec`/`-ok`/`-delete` run through `Env.io`; `-ok` asks a
//!    caller-supplied `Confirm`.
//!
//! `walk` is the traversal alone: a callback is invoked for every entry (with
//! lazily loaded `stat` data) and may prune or stop the walk.
//!
//! Extensions (docs/compatibility/find.md): the `-json` action.

const std = @import("std");
const rx = @import("../regexutil.zig");
const Io = std.Io;
const LX = std.os.linux;
const common = @import("common.zig");
const fu = @import("fu_common.zig");
const sys = @import("../sys.zig");
const dirat = @import("../dirat.zig");
const programpath = @import("../programpath.zig");
const regex = @import("regex");
const fnmatch = @import("../fnmatch.zig");
const strftime = @import("../strftime.zig");
const tzmod = @import("../tz.zig");
const userdb = @import("../userdb.zig");
const fileinfo = @import("../fileinfo.zig");
const datetime = @import("../datetime.zig");
const quotearg = @import("../quotearg.zig");
const modemod = @import("../mode.zig");

pub const Env = common.Env;
pub const FileStat = sys.FileStat;
pub const RegexSyntax = fu.RegexSyntax;

/// What a problem during the walk is about. Texts are valid during the call.
pub const Event = union(enum) {
    /// A file or directory could not be examined (stat, open, readdir).
    path_error: struct { path: []const u8, text: []const u8 },
    /// A symbolic-link loop under -L.
    loop: struct { path: []const u8, ancestor: []const u8 },
    delete_failed: struct { path: []const u8, text: []const u8 },
    /// Writing the file of -fprint, -fprint0, -fprintf or -fls failed, so it
    /// is incomplete.
    output_failed: struct { path: []const u8, text: []const u8 },
    /// A -exec/-ok command could not be started.
    exec_failed: struct { program: []const u8, text: []const u8 },
    /// -printf %Z: this system has no security contexts.
    no_security_context: []const u8,
    /// A warning from `compile`, fully worded ("warning: ...") without the
    /// program prefix.
    warning: []const u8,
};
pub const Observer = common.Observer(Event);

/// The lines of a rejected expression, each printed as `find: <line>`.
pub const Diagnostic = struct {
    lines: []const []const u8 = &.{},

    pub fn deinit(d: *Diagnostic, gpa: std.mem.Allocator) void {
        for (d.lines) |l| gpa.free(l);
        gpa.free(d.lines);
        d.* = .{};
    }
};

/// Answers a -ok/-okdir question ("< cmd ... path > ? "). Without one the
/// answer is no.
pub const Confirm = struct {
    context: ?*anyopaque = null,
    func: *const fn (context: ?*anyopaque, prompt: []const u8) bool,
};

const Error = error{ OutOfMemory, Invalid };

/// The "quote" GNU find uses in its messages: single quotes with C escapes,
/// or curly quotes in a UTF-8 locale.
pub fn quoteMsg(gpa: std.mem.Allocator, text: []const u8, utf8: bool) std.mem.Allocator.Error![]const u8 {
    const raw = try std.fmt.allocPrint(gpa, "{f}", .{fu.quoteC(text)});
    if (utf8 and raw.len >= 2) {
        defer gpa.free(raw);
        return std.fmt.allocPrint(gpa, "\u{2018}{s}\u{2019}", .{raw[1 .. raw.len - 1]});
    }
    return raw;
}

fn quoteInner(st: *State, text: []const u8) Error![]const u8 {
    return quoteMsg(st.gpa, text, st.utf8);
}

/// Record a fatal parse problem and give back the error to return.
fn fail(st: *State, comptime fmt: []const u8, args: anytype) Error {
    st.diagLine(fmt, args) catch return error.OutOfMemory;
    return error.Invalid;
}

fn warnText(st: *State, comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    st.observer.emit(.{ .warning = msg });
}

fn warnMsg(st: *State, comptime fmt: []const u8, args: anytype) void {
    if (!st.warn) return;
    warnText(st, "warning: " ++ fmt, args);
}

fn warnAlways(st: *State, comptime fmt: []const u8, args: anytype) void {
    warnText(st, fmt, args);
}

fn flushOut(st: *State) void {
    if (st.out.items.len > 0) {
        if (st.writer) |w| {
            w.writeAll(st.out.items) catch {
                st.write_failed = true;
            };
        }
        st.out.clearRetainingCapacity();
    }
    if (st.writer) |w| w.flush() catch {
        st.write_failed = true;
    };
}

fn emit(st: *State, bytes: []const u8) void {
    st.out.appendSlice(st.gpa, bytes) catch st.nomem();
    if (st.out.items.len > 65536) flushOut(st);
}

/// Evaluate the expression (or call the visitor) for the current entry.
fn evalHere(st: *State) void {
    flushLeftBehind(st);
    if (st.visitor) |v| {
        var e: Entry = .{ .st = st };
        v.func(v.context, &e);
        return;
    }
    _ = evalNode(st, st.root);
}

const Cmp = enum { eq, gt, lt };

const Kind = enum {
    // operators
    and_, or_, comma, not_,
    // tests
    name, iname, path, ipath, lname, ilname, regex_, type_, xtype, size, perm, user, group, uid, gid,
    nouser, nogroup, newer, atime, ctime, mtime, amin, cmin, mmin, used, empty, links, inum, samefile,
    fstype, readable, writable, executable, true_, false_,
    // actions
    print, print0, printf, fprint, fprint0, fprintf, ls, fls, json, exec, delete, prune, quit,
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
    /// -execdir ... +: the directory the batched names are in, held open
    /// while the batch is not empty.
    batch_dir: ?ExecDir = null,
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
    fd: sys.Handle,
    /// Opened by the expression (closed with it); fds 1 and 2 are not.
    owned: bool = false,
    buf: std.ArrayList(u8) = .empty,
    /// Why some of the output is missing; reported at the end of the run.
    failure: ?[]const u8 = null,
};

pub const Follow = enum { physical, command_line, logical };

const State = struct {
    env: Env,
    /// The expression's arena: everything the parse and the walk allocate.
    gpa: std.mem.Allocator,
    observer: Observer,
    /// Standard output of the run (null outside `Expr.run`).
    writer: ?*Io.Writer = null,
    /// Where -fprint /dev/stderr goes.
    stderr: ?*Io.Writer = null,
    confirm: ?Confirm = null,
    visitor: ?Visitor = null,
    diag_lines: std.ArrayList([]const u8) = .empty,
    oom: bool = false,
    write_failed: bool = false,
    follow: Follow = .physical,
    maxdepth: i64 = -1,
    mindepth: i64 = 0,
    depth_first: bool = false,
    xdev: bool = false,
    daystart: bool = false,
    warn: bool = true,
    ignore_race: bool = false,
    regextype: fu.RegexSyntax = .emacs,
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
    /// Set when the expression has -execdir or -okdir.
    has_execdir: bool = false,
    /// The directory of the current start point, for -execdir on it.
    start_dir: ?ExecDir = null,
    /// Why `start_dir` is null.
    start_dir_errno: LX.E = .SUCCESS,
    /// The open directory the current file was found in; null for a start
    /// point.
    cur_parent: ?*dirat.Level = null,
    prune_flag: bool = false,
    mounts: ?fu.Mounts = null,
    stdin_used: bool = false,

    /// How system calls name the current file: its entry name in the open
    /// directory it was listed in (a start point is named by its path). The
    /// path in `cur_path` is for output and for the programs find runs.
    fn at(st: *const State) At {
        if (st.cur_parent) |p| return .{ .dir = p.fd, .name = st.cur_path[st.cur_name_off..] };
        return .{ .dir = sys.cwdFd(), .name = st.cur_path };
    }

    fn nomem(st: *State) void {
        st.oom = true;
    }

    /// Append one line of the parse diagnostic (printed as `find: <line>`).
    fn diagLine(st: *State, comptime fmt: []const u8, args: anytype) Error!void {
        const line = try std.fmt.allocPrint(st.gpa, fmt, args);
        try st.diag_lines.append(st.gpa, line);
    }
};


const At = struct { dir: sys.Handle, name: []const u8 };

/// A directory for -execdir to run a command in: the descriptor, which stays
/// right whatever happens to the path, and what it is.
const ExecDir = struct { fd: sys.Handle, dev: u64, ino: u64 };

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

    fn mk(p: *Parser, kind: Kind) Error!*Node {
        const n = p.st.gpa.create(Node) catch return error.OutOfMemory;
        n.* = .{ .kind = kind };
        return n;
    }

    fn needArg(p: *Parser, name: []const u8) Error![]const u8 {
        if (p.i >= p.args.len) return fail(p.st, "missing argument to `{s}'", .{name});
        const a = p.args[p.i];
        p.i += 1;
        return a;
    }

    fn isBinOp(a: []const u8) bool {
        return std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-and") or std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-or") or std.mem.eql(u8, a, ",");
    }

    /// An operand must follow the operator `op`.
    fn expectOperand(p: *Parser, op: []const u8) Error!void {
        if (!p.more()) return fail(p.st, "expected an expression after '{s}'", .{op});
        const t = p.peek();
        if (std.mem.eql(u8, t, ")")) return fail(p.st, "expected an expression between '{s}' and ')'", .{op});
        if (isBinOp(t)) return fail(p.st, "invalid expression; you have used a binary operator '{s}' with nothing before it.", .{t});
    }

    // expression := or ( ',' or )*
    fn parseComma(p: *Parser) Error!*Node {
        var left = try p.parseOr();
        while (p.more() and std.mem.eql(u8, p.peek(), ",")) {
            p.i += 1;
            try p.expectOperand(",");
            const right = try p.parseOr();
            const n = try p.mk(.comma);
            n.a = left;
            n.b = right;
            left = n;
        }
        return left;
    }

    fn parseOr(p: *Parser) Error!*Node {
        var left = try p.parseAnd();
        while (p.more() and (std.mem.eql(u8, p.peek(), "-o") or std.mem.eql(u8, p.peek(), "-or"))) {
            const opname = p.peek();
            p.i += 1;
            try p.expectOperand(opname);
            const right = try p.parseAnd();
            const n = try p.mk(.or_);
            n.a = left;
            n.b = right;
            left = n;
        }
        return left;
    }

    fn parseAnd(p: *Parser) Error!*Node {
        var left = try p.parseUnary();
        while (p.more()) {
            const a = p.peek();
            if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-or") or std.mem.eql(u8, a, ",") or std.mem.eql(u8, a, ")")) break;
            if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-and")) {
                p.i += 1;
                try p.expectOperand(a);
            }
            const right = try p.parseUnary();
            const n = try p.mk(.and_);
            n.a = left;
            n.b = right;
            left = n;
        }
        return left;
    }

    fn parseUnary(p: *Parser) Error!*Node {
        if (!p.more()) return fail(p.st, "invalid expression", .{});
        const a = p.peek();
        p.at_start = false;
        if (std.mem.eql(u8, a, "!") or std.mem.eql(u8, a, "-not")) {
            p.i += 1;
            try p.expectOperand(a);
            const inner = try p.parseUnary();
            const n = try p.mk(.not_);
            n.a = inner;
            return n;
        }
        return try p.parsePrimary();
    }

    fn parsePrimary(p: *Parser) Error!*Node {
        const st = p.st;
        const a = p.peek();
        if (std.mem.eql(u8, a, "(")) {
            p.i += 1;
            if (!p.more()) return fail(st, "invalid expression; expected to find a ')' but didn't see one. Perhaps you need an extra predicate after '('", .{});
            if (std.mem.eql(u8, p.peek(), ")")) return fail(st, "invalid expression; empty parentheses are not allowed.", .{});
            const inner = try p.parseComma();
            if (!p.more() or !std.mem.eql(u8, p.peek(), ")")) return fail(st, "invalid expression; I was expecting to find a ')' somewhere but did not see one.", .{});
            p.i += 1;
            return inner;
        }
        if (std.mem.eql(u8, a, ")")) return fail(st, "you have too many ')'", .{});
        if (isBinOp(a)) return fail(st, "invalid expression; you have used a binary operator '{s}' with nothing before it.", .{a});
        if (a.len == 0 or a[0] != '-') {
            // an operand that is not a predicate
            try st.diagLine("paths must precede expression: `{s}'", .{a});
            if (p.no_starts and p.last_pred.len > 0) try st.diagLine("possible unquoted pattern after predicate `{s}'?", .{p.last_pred});
            return error.Invalid;
        }
        p.i += 1;
        return try p.predicate(a);
    }

    fn numArg(p: *Parser, name: []const u8, comptime bad_fmt: []const u8) Error!i64 {
        const a = try p.needArg(name);
        return std.fmt.parseInt(i64, a, 10) catch return fail(p.st, bad_fmt, .{ a });
    }

    fn cmpNum(p: *Parser, name: []const u8, text: []const u8, node: *Node) Error!void {
        var s = text;
        node.cmp = .eq;
        if (s.len > 0 and s[0] == '+') {
            node.cmp = .gt;
            s = s[1..];
        } else if (s.len > 0 and s[0] == '-') {
            node.cmp = .lt;
            s = s[1..];
        }
        node.num = std.fmt.parseInt(i64, s, 10) catch return fail(p.st, "invalid argument `{s}' to `{s}'", .{ text, name });
        if (s.len == 0 or !std.ascii.isDigit(s[0])) return fail(p.st, "invalid argument `{s}' to `{s}'", .{ text, name });
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

    fn predicate(p: *Parser, a: []const u8) Error!*Node {
        const st = p.st;
        const eq = std.mem.eql;
        // options without effect on evaluation return -true
        if (eq(u8, a, "-depth") or eq(u8, a, "-d")) {
            p.globOpt(a);
            st.depth_first = true;
            st.explicit_depth = true;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-mount") or eq(u8, a, "-xdev")) {
            p.globOpt(a);
            st.xdev = true;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-noleaf")) {
            p.globOpt(a);
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-ignore_readdir_race")) {
            st.ignore_race = true;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-noignore_readdir_race")) {
            st.ignore_race = false;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-follow")) {
            st.follow = .logical;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-daystart")) {
            st.daystart = true;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-warn")) {
            st.warn = true;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-nowarn")) {
            st.warn = false;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-maxdepth") or eq(u8, a, "-mindepth")) {
            p.globOpt(a);
            const v = try p.needArg(a);
            const n = std.fmt.parseInt(i64, v, 10) catch -1;
            if (n < 0 or v.len == 0 or !std.ascii.isDigit(v[0])) return fail(st, "Expected a positive decimal integer argument to {s}, but got {s}", .{ a, try quoteInner(st, v) });
            if (eq(u8, a, "-maxdepth")) st.maxdepth = n else st.mindepth = n;
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-regextype")) {
            const v = try p.needArg(a);
            st.regextype = fu.RegexSyntax.parse(v) orelse return fail(st, "Unknown regular expression type {s}; valid types are 'findutils-default', 'ed', 'emacs', 'gnu-awk', 'grep', 'posix-awk', 'awk', 'posix-basic', 'posix-egrep', 'egrep', 'posix-extended', 'posix-minimal-basic', 'sed'.", .{try quoteInner(st, v)});
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-files0-from")) {
            _ = try p.needArg(a);
            return fail(st, "-files0-from is not supported here", .{});
        }
        if (eq(u8, a, "-true")) {
            p.setTest(a);
            return try p.mk(.true_);
        }
        if (eq(u8, a, "-false")) {
            p.setTest(a);
            return try p.mk(.false_);
        }
        if (eq(u8, a, "-name") or eq(u8, a, "-iname") or eq(u8, a, "-path") or eq(u8, a, "-wholename") or eq(u8, a, "-ipath") or eq(u8, a, "-iwholename") or eq(u8, a, "-lname") or eq(u8, a, "-ilname")) {
            const pat = try p.needArg(a);
            p.setTest(a);
            const kind: Kind = if (eq(u8, a, "-name")) .name else if (eq(u8, a, "-iname")) .iname else if (eq(u8, a, "-path") or eq(u8, a, "-wholename")) .path else if (eq(u8, a, "-ipath") or eq(u8, a, "-iwholename")) .ipath else if (eq(u8, a, "-lname")) .lname else .ilname;
            const n = try p.mk(kind);
            n.str = pat;
            return n;
        }
        if (eq(u8, a, "-regex") or eq(u8, a, "-iregex")) {
            const pat = try p.needArg(a);
            p.setTest(a);
            const n = try p.mk(.regex_);
            n.str = pat;
            n.re = try p.compileRegex(pat, eq(u8, a, "-iregex"));
            return n;
        }
        if (eq(u8, a, "-type") or eq(u8, a, "-xtype")) {
            const v = try p.needArg(a);
            p.setTest(a);
            const n = try p.mk(if (eq(u8, a, "-type")) .type_ else .xtype);
            var expect_letter = true;
            if (v.len == 0) return fail(st, "Arguments to {s} should contain at least one letter", .{a});
            for (v) |ch| {
                if (ch == ',') {
                    if (expect_letter) return fail(st, "Unknown argument to {s}: ,", .{a});
                    expect_letter = true;
                    continue;
                }
                if (!expect_letter) return fail(st, "Must separate multiple arguments to {s} using: ','", .{a});
                if (ch == 'D') return fail(st, "{s} D is not supported because Solaris doors are not supported on the platform find was compiled on.", .{a});
                if (std.mem.indexOfScalar(u8, "bcdpfls", ch) == null) return fail(st, "Unknown argument to {s}: {c}", .{ a, ch });
                n.types |= @as(u64, 1) << @intCast(ch - 'A');
                expect_letter = false;
            }
            if (expect_letter) return fail(st, "Last file type in list argument to {s} is missing, i.e., list is ending on: ','", .{a});
            return n;
        }
        if (eq(u8, a, "-size")) {
            const v = try p.needArg(a);
            p.setTest(a);
            if (v.len == 0) return fail(st, "invalid null argument to -size", .{});
            const n = try p.mk(.size);
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
                if (s.len == 0) return fail(st, "invalid -size type `{c}'", .{v[0]});
                if (std.mem.indexOfScalar(u8, "bcwkMG", s[0]) != null) return fail(st, "Invalid argument `{s}' to -size", .{v});
                return fail(st, "invalid -size type `{c}'", .{s[0]});
            }
            n.num = std.fmt.parseInt(i64, s[0..end], 10) catch return fail(st, "invalid argument `{s}' to `-size'", .{v});
            if (end == s.len) {
                n.size_unit = 'b';
            } else if (end + 1 == s.len and std.mem.indexOfScalar(u8, "bcwkMG", s[end]) != null) {
                n.size_unit = s[end];
            } else if (end + 1 == s.len) {
                return fail(st, "invalid -size type `{c}'", .{s[end]});
            } else return fail(st, "Invalid argument `{s}' to -size", .{v});
            return n;
        }
        if (eq(u8, a, "-perm")) {
            const v = try p.needArg(a);
            p.setTest(a);
            const n = try p.mk(.perm);
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
            n.perm_bits = parsed orelse return fail(st, "invalid mode {s}", .{try quoteInner(st, v)});
            if (n.perm_kind == '/' and n.perm_bits == 0) {
                warnAlways(st, "warning: you have specified a mode pattern {s} (which is equivalent to /000). The meaning of -perm /000 has now been changed to be consistent with -perm -000; that is, while it used to match no files, it now matches all files.", .{v});
            }
            return n;
        }
        if (eq(u8, a, "-user") or eq(u8, a, "-group")) {
            const v = try p.needArg(a);
            p.setTest(a);
            const n = try p.mk(if (eq(u8, a, "-user")) .user else .group);
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
                n.num = std.fmt.parseInt(i64, v, 10) catch return fail(st, "invalid {s} name or {s} argument to {s}: {s}", .{ if (is_user) "user" else "group", if (is_user) "UID" else "GID", a, try quoteInner(st, v) });
                return n;
            }
            return fail(st, "invalid {s} name or {s} argument to {s}: {s}", .{ if (is_user) "user" else "group", if (is_user) "UID" else "GID", a, try quoteInner(st, v) });
        }
        if (eq(u8, a, "-uid") or eq(u8, a, "-gid") or eq(u8, a, "-inum") or eq(u8, a, "-links")) {
            const v = try p.needArg(a);
            p.setTest(a);
            const kind: Kind = if (eq(u8, a, "-uid")) .uid else if (eq(u8, a, "-gid")) .gid else if (eq(u8, a, "-inum")) .inum else .links;
            const n = try p.mk(kind);
            var s = v;
            if (s.len > 0 and s[0] == '+') {
                n.cmp = .gt;
                s = s[1..];
            } else if (s.len > 0 and s[0] == '-') {
                n.cmp = .lt;
                s = s[1..];
            }
            if (s.len == 0 or !std.ascii.isDigit(s[0])) {
                return fail(st, "non-numeric argument to {s}: {s}", .{ a, try quoteInner(st, v) });
            }
            for (s) |ch| {
                if (!std.ascii.isDigit(ch)) return fail(st, "non-numeric argument to {s}: {s}", .{ a, try quoteInner(st, v) });
            }
            n.num = std.fmt.parseInt(i64, s, 10) catch return fail(st, "invalid argument `{s}' to `{s}'", .{ v, a });
            return n;
        }
        if (eq(u8, a, "-amin") or eq(u8, a, "-cmin") or eq(u8, a, "-mmin") or eq(u8, a, "-atime") or eq(u8, a, "-ctime") or eq(u8, a, "-mtime") or eq(u8, a, "-used")) {
            const v = try p.needArg(a);
            p.setTest(a);
            const kind: Kind = if (eq(u8, a, "-amin")) .amin else if (eq(u8, a, "-cmin")) .cmin else if (eq(u8, a, "-mmin")) .mmin else if (eq(u8, a, "-atime")) .atime else if (eq(u8, a, "-ctime")) .ctime else if (eq(u8, a, "-mtime")) .mtime else .used;
            const n = try p.mk(kind);
            if (kind == .used and (v.len == 0 or !(std.ascii.isDigit(v[0]) or ((v[0] == '+' or v[0] == '-') and v.len > 1 and std.ascii.isDigit(v[1]))))) return fail(st, "Invalid argument {s} to -used", .{v});
            try p.cmpNum(a, v, n);
            return n;
        }
        if (eq(u8, a, "-newer") or eq(u8, a, "-anewer") or eq(u8, a, "-cnewer") or (a.len == 8 and std.mem.startsWith(u8, a, "-newer"))) {
            const v = try p.needArg(a);
            p.setTest(a);
            const n = try p.mk(.newer);
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
                n.x = selOf(a[6]) orelse return fail(st, "invalid predicate `{s}'", .{a});
                if (n.x == .t) return fail(st, "invalid predicate `{s}'", .{a});
                n.y = selOf(a[7]) orelse return fail(st, "invalid predicate `{s}'", .{a});
                if (n.x == .b or n.y == .b) {
                    try st.diagLine("This system does not provide a way to find the birth time of a file.", .{});
                    return fail(st, "invalid predicate `{s}'", .{a});
                }
            }
            if (n.y == .t) {
                const now = datetime.Timespec{ .sec = st.start_sec, .nsec = st.start_nsec };
                ensureZone(st);
                const ts = datetime.parse(st.gpa, st.env.io, v, now, &st.zone) orelse return fail(st, "I cannot figure out how to interpret {s} as a date or time", .{try quoteInner(st, v)});
                n.ref_sec = ts.sec;
                n.ref_nsec = ts.nsec;
            } else {
                var err: LX.E = .SUCCESS;
                const rs = sys.fileStat(v, st.follow == .logical, &err) orelse return fail(st, "{s}: {s}", .{ try quoteInner(st, v), sys.errnoText(err) });
                const t = timeOf(rs, n.y);
                n.ref_sec = t[0];
                n.ref_nsec = t[1];
            }
            return n;
        }
        if (eq(u8, a, "-context")) {
            _ = try p.needArg(a);
            return fail(st, "invalid predicate -context: SELinux is not enabled.", .{});
        }
        if (eq(u8, a, "-samefile")) {
            const v = try p.needArg(a);
            p.setTest(a);
            const n = try p.mk(.samefile);
            var err: LX.E = .SUCCESS;
            const rs = sys.fileStat(v, st.follow == .logical, &err) orelse return fail(st, "{s}: {s}", .{ try quoteInner(st, v), sys.errnoText(err) });
            n.ref_dev = devKey(rs);
            n.ref_ino = rs.ino;
            return n;
        }
        if (eq(u8, a, "-fstype")) {
            const v = try p.needArg(a);
            p.setTest(a);
            const n = try p.mk(.fstype);
            n.str = v;
            return n;
        }
        if (eq(u8, a, "-empty")) {
            p.setTest(a);
            return try p.mk(.empty);
        }
        if (eq(u8, a, "-nouser")) {
            p.setTest(a);
            return try p.mk(.nouser);
        }
        if (eq(u8, a, "-nogroup")) {
            p.setTest(a);
            return try p.mk(.nogroup);
        }
        if (eq(u8, a, "-readable")) {
            p.setTest(a);
            return try p.mk(.readable);
        }
        if (eq(u8, a, "-writable")) {
            p.setTest(a);
            return try p.mk(.writable);
        }
        if (eq(u8, a, "-executable")) {
            p.setTest(a);
            return try p.mk(.executable);
        }
        // actions
        if (eq(u8, a, "-print")) {
            st.has_action = true;
            return try p.mk(.print);
        }
        if (eq(u8, a, "-print0")) {
            st.has_action = true;
            return try p.mk(.print0);
        }
        if (eq(u8, a, "-ls")) {
            st.has_action = true;
            return try p.mk(.ls);
        }
        // Extension (not in GNU find): like -print, but one JSON object per file.
        if (eq(u8, a, "-json")) {
            st.has_action = true;
            return try p.mk(.json);
        }
        if (eq(u8, a, "-prune")) {
            st.saw_prune = true;
            return try p.mk(.prune);
        }
        if (eq(u8, a, "-quit")) {
            return try p.mk(.quit);
        }
        if (eq(u8, a, "-delete")) {
            st.saw_delete = true;
            st.has_action = true;
            st.depth_first = true;
            return try p.mk(.delete);
        }
        if (eq(u8, a, "-printf")) {
            const f = try p.needArg(a);
            st.has_action = true;
            const n = try p.mk(.printf);
            n.fmt_parts = try p.parseFormat(f);
            return n;
        }
        if (eq(u8, a, "-fprint") or eq(u8, a, "-fprint0") or eq(u8, a, "-fls")) {
            const f = try p.needArg(a);
            st.has_action = true;
            const n = try p.mk(if (eq(u8, a, "-fprint")) .fprint else if (eq(u8, a, "-fprint0")) .fprint0 else .fls);
            n.out = try p.openOut(f);
            return n;
        }
        if (eq(u8, a, "-fprintf")) {
            const f = try p.needArg(a);
            if (p.i >= p.args.len) return fail(st, "invalid argument `{s}' to `-fprintf'", .{f});
            const fmt = try p.needArg(a);
            st.has_action = true;
            const n = try p.mk(.fprintf);
            n.out = try p.openOut(f);
            n.fmt_parts = try p.parseFormat(fmt);
            return n;
        }
        if (eq(u8, a, "-exec") or eq(u8, a, "-execdir") or eq(u8, a, "-ok") or eq(u8, a, "-okdir")) {
            const n = try p.mk(.exec);
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
                    return fail(st, "In '{s} ... {{}} +' the '{{}}' must appear by itself, but you specified '{s}'", .{ a, argv.items[argv.items.len - 1] });
                }
                argv.append(st.gpa, x) catch return error.OutOfMemory;
            }
            if (!terminated) return fail(st, "missing argument to `{s}'", .{a});
            if (n.dir) {
                try checkExecDirPath(st, a);
                st.has_execdir = true;
            }
            if (argv.items.len == 0) return fail(st, "invalid argument `;' to `{s}'", .{a});
            if (n.plus) {
                var cnt: usize = 0;
                for (argv.items) |x| {
                    if (std.mem.indexOf(u8, x, "{}") != null) cnt += 1;
                }
                if (cnt > 1) return fail(st, "Only one instance of {{}} is supported with -exec ... +", .{});
            }
            n.argv = argv.items;
            if (n.plus) st.execs.append(st.gpa, n) catch return error.OutOfMemory;
            return n;
        }
        return fail(st, "unknown predicate `{s}'", .{a});
    }

    /// -execdir and -okdir run the program from inside the directory being
    /// searched, and PATH is searched there: an empty or relative entry would
    /// run a program that anyone able to write in the tree put there. Refuse
    /// such a PATH, as GNU find does, in its words.
    fn checkExecDirPath(st: *State, action: []const u8) Error!void {
        const path = st.env.getenv("PATH") orelse return;
        var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
        while (it.next()) |dir| {
            if (dir.len == 0 or std.mem.eql(u8, dir, ".")) {
                return fail(st, "The current directory is included in the PATH environment variable, which is insecure in combination with the {s} action of find.  Please remove the current directory from your $PATH (that is, remove \".\", doubled colons, or leading or trailing colons)", .{action});
            }
            if (!std.fs.path.isAbsolute(dir)) {
                return fail(st, "The relative path {s} is included in the PATH environment variable, which is insecure in combination with the {s} action of find.  Please remove that entry from $PATH", .{ try quoteInner(st, dir), action });
            }
        }
    }

    fn openOut(p: *Parser, name: []const u8) Error!*OutFile {
        const st = p.st;
        for (st.outs.items) |o| {
            if (std.mem.eql(u8, o.path, name)) return o;
        }
        const o = st.gpa.create(OutFile) catch return error.OutOfMemory;
        o.* = .{ .path = name, .fd = sys.invalid_handle };
        if (std.mem.eql(u8, name, "/dev/stdout")) {
            o.fd = std.Io.File.stdout().handle;
        } else if (std.mem.eql(u8, name, "/dev/stderr")) {
            o.fd = std.Io.File.stderr().handle;
        } else {
            var err: LX.E = .SUCCESS;
            o.fd = sys.openFd(name, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, 0o666, &err) orelse return fail(st, "{s}: {s}", .{ try quoteInner(st, name), sys.errnoText(err) });
            o.owned = true;
        }
        st.outs.append(st.gpa, o) catch return error.OutOfMemory;
        return o;
    }

    fn compileRegex(p: *Parser, pat: []const u8, icase: bool) Error!*regex.Regex {
        const st = p.st;
        var failure: fu.RegexFailure = undefined;
        return fu.compileRegex(st.gpa, pat, st.regextype, icase, true, &failure) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadRegex => return fail(st, "failed to compile regular expression '{s}': {s}", .{ pat, failure.text }),
        };
    }

    fn parseFormat(p: *Parser, f: []const u8) Error![]const FmtPart {
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
                    lit.append(st.gpa, '\\') catch return error.OutOfMemory;
                    break;
                }
                const e = f[i];
                i += 1;
                switch (e) {
                    'a' => lit.append(st.gpa, 7) catch return error.OutOfMemory,
                    'b' => lit.append(st.gpa, 8) catch return error.OutOfMemory,
                    'f' => lit.append(st.gpa, 12) catch return error.OutOfMemory,
                    'n' => lit.append(st.gpa, '\n') catch return error.OutOfMemory,
                    'r' => lit.append(st.gpa, '\r') catch return error.OutOfMemory,
                    't' => lit.append(st.gpa, '\t') catch return error.OutOfMemory,
                    'v' => lit.append(st.gpa, 11) catch return error.OutOfMemory,
                    '\\' => lit.append(st.gpa, '\\') catch return error.OutOfMemory,
                    'c' => {
                        parts.append(st.gpa, .{ .lit = lit.toOwnedSlice(st.gpa) catch return error.OutOfMemory, .stop = true }) catch return error.OutOfMemory;
                        return parts.items;
                    },
                    '0'...'7' => {
                        var v: u32 = e - '0';
                        var k: usize = 1;
                        while (k < 3 and i < f.len and f[i] >= '0' and f[i] <= '7') : (k += 1) {
                            v = v * 8 + (f[i] - '0');
                            i += 1;
                        }
                        lit.append(st.gpa, @truncate(v)) catch return error.OutOfMemory;
                    },
                    else => {
                        warnMsg(st, "unrecognized escape `\\{c}'", .{e});
                        lit.append(st.gpa, '\\') catch return error.OutOfMemory;
                        lit.append(st.gpa, e) catch return error.OutOfMemory;
                    },
                }
                continue;
            }
            if (c != '%') {
                lit.append(st.gpa, c) catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            i += 1;
            if (i >= f.len) return fail(st, "error: % at end of format string", .{});
            if (f[i] == '%') {
                lit.append(st.gpa, '%') catch return error.OutOfMemory;
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
            if (i >= f.len) return fail(st, "error: % at end of format string", .{});
            const d = f[i];
            i += 1;
            var tchar: u8 = 0;
            if (d == 'A' or d == 'C' or d == 'T') {
                if (i >= f.len) return fail(st, "error: % at end of format string", .{});
                tchar = f[i];
                i += 1;
            }
            const known = "abcdDfFgGhHiklmMnpPsStuUyYZ";
            if (d == '%') {
                // "%5%" prints "%5": the conversion character itself is dropped
                lit.append(st.gpa, '%') catch return error.OutOfMemory;
                lit.appendSlice(st.gpa, f[fstart .. i - 1]) catch return error.OutOfMemory;
                continue;
            }
            if (d != 'A' and d != 'C' and d != 'T' and std.mem.indexOfScalar(u8, known, d) == null) {
                warnMsg(st, "unrecognized format directive `%{c}'", .{d});
                lit.append(st.gpa, '%') catch return error.OutOfMemory;
                lit.appendSlice(st.gpa, f[fstart..i]) catch return error.OutOfMemory;
                continue;
            }
            parts.append(st.gpa, .{ .lit = lit.toOwnedSlice(st.gpa) catch return error.OutOfMemory, .dir = d, .flags = flags, .width = width, .prec = prec, .tchar = tchar }) catch return error.OutOfMemory;
        }
        if (lit.items.len > 0) parts.append(st.gpa, .{ .lit = lit.toOwnedSlice(st.gpa) catch return error.OutOfMemory }) catch return error.OutOfMemory;
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
        st.db = userdb.Db.load(st.gpa, st.env.io);
        st.db_loaded = true;
    }
}

fn ensureZone(st: *State) void {
    if (!st.zone_loaded) {
        st.zone = tzmod.load(st.gpa, st.env.io, st.env.getenv("TZ"));
        st.zone_loaded = true;
    }
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
    if (!statEntry(st, st.at(), st.cur_cmdline, &lst, &stt, &err)) {
        st.cur_failed = true;
        if (!(st.ignore_race and err == .NOENT)) {
            flushOut(st);
            st.observer.emit(.{ .path_error = .{ .path = st.cur_path, .text = sys.errnoText(err) } });
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
    if (st.mounts == null) st.mounts = fu.Mounts.load(st.gpa) catch blk: {
        st.nomem();
        break :blk fu.Mounts{ .list = &.{} };
    };
    return st.mounts.?.fsType(dev);
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
            const k = sys.readlinkAt(st.at().dir, st.at().name, &buf, &err) orelse return false;
            if (n.kind == .ilname) return fnmatch.match(n.str, buf[0..k], .{ .casefold = true });
            return fnmatch.match(n.str, buf[0..k], .{});
        },
        .regex_ => {
            var sr = rx.searcher(n.re.?, st.gpa) catch {
                st.nomem();
                return false;
            };
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
            const s = sys.fileStatAt(st.at().dir, st.at().name, true, &err) orelse {
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
            if (s.isDir()) return dirIsEmpty(st);
            return false;
        },
        .readable => return sys.accessAt(st.at().dir, st.at().name, 4) == null,
        .writable => return sys.accessAt(st.at().dir, st.at().name, 2) == null,
        .executable => return sys.accessAt(st.at().dir, st.at().name, 1) == null,
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
        .json => {
            printJson(st);
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

fn dirIsEmpty(st: *State) bool {
    var level: dirat.Level = undefined;
    var failure: ?LX.E = dirat.enter(&level, st.cur_parent, st.at().name, .{ .follow = followsHere(st, st.cur_cmdline) });
    if (failure == null) {
        defer _ = dirat.leave(&level);
        var err: LX.E = .SUCCESS;
        if (sys.readDirNamesFd(st.env.gpa, level.fd, &err)) |names| {
            defer sys.freeDirEntries(st.env.gpa, names);
            return names.len == 0;
        }
        failure = err;
    }
    pathError(st, st.cur_path, failure.?);
    return false;
}

fn pathError(st: *State, path: []const u8, errno: LX.E) void {
    flushOut(st);
    st.observer.emit(.{ .path_error = .{ .path = path, .text = sys.errnoText(errno) } });
    st.exit_status = 1;
}

fn outWrite(st: *State, o: *OutFile, bytes: []const u8) void {
    if (o.fd == std.Io.File.stdout().handle) {
        emit(st, bytes);
        return;
    }
    o.buf.appendSlice(st.gpa, bytes) catch st.nomem();
    if (o.buf.items.len > 65536 or o.fd == std.Io.File.stderr().handle) flushFile(st, o);
}

fn flushFile(st: *State, o: *OutFile) void {
    if (o.buf.items.len > 0) {
        if (o.fd == std.Io.File.stderr().handle) {
            // -fprint /dev/stderr goes to the caller's stderr writer.
            if (st.stderr) |w| {
                var written = true;
                w.writeAll(o.buf.items) catch {
                    written = false;
                };
                w.flush() catch {
                    written = false;
                };
                if (!written) o.failure = "write error";
            }
        } else if (o.failure == null) {
            // Nothing more is written after a failure: a later success would
            // leave a gap in the file.
            if (sys.writeAllFd(o.fd, o.buf.items)) |e| o.failure = sys.errnoText(e);
        }
        o.buf.clearRetainingCapacity();
    }
}

/// Write what is left for each output file and report the ones that are
/// incomplete.
fn finishOutputs(st: *State) void {
    for (st.outs.items) |o| {
        flushFile(st, o);
        if (o.owned and o.failure == null) {
            // Some file systems (NFS, quotas) only report at close. The file
            // stays open for `Expr.deinit`, so close a duplicate.
            var err: LX.E = .SUCCESS;
            if (sys.dupFd(o.fd, &err)) |copy| {
                if (sys.closeFd(copy)) |e| o.failure = sys.errnoText(e);
            } else if (err != .NOSYS) o.failure = sys.errnoText(err); // NOSYS: no dup here
        }
        if (o.failure) |text| {
            st.observer.emit(.{ .output_failed = .{ .path = o.path, .text = text } });
            st.exit_status = 1;
            o.failure = null;
        }
    }
}

fn doDelete(st: *State) bool {
    const s = getLst(st) orelse return false;
    // never delete the "." start point name
    if (st.cur_depth == 0 and std.mem.eql(u8, st.cur_path, ".")) return true;
    const is_dir = s.isDir();
    if (sys.unlinkAt(st.at().dir, st.at().name, is_dir)) |e| {
        flushOut(st);
        st.observer.emit(.{ .delete_failed = .{ .path = st.cur_path, .text = sys.errnoText(e) } });
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
            out.appendSlice(st.gpa, repl) catch st.nomem();
            i += 2;
        } else {
            out.append(st.gpa, arg[i]) catch st.nomem();
            i += 1;
        }
    }
    return out.items;
}

/// The directory -execdir uses for the current file: the one it was listed
/// in, or for a start point the one opened before its walk.
fn execDirOf(st: *const State) ?ExecDir {
    if (st.cur_parent) |p| return .{ .fd = p.fd, .dev = p.dev, .ino = p.ino };
    return st.start_dir;
}

/// A second descriptor for the directory `fd`, only good for running in.
fn holdDir(fd: sys.Handle, path: []const u8, err: *LX.E) ?ExecDir {
    const held = sys.openFdAt(fd, path, sys.O.PATH | sys.O.DIRECTORY, 0, err) orelse return null;
    const s = sys.fstatFd(held, err) orelse {
        _ = sys.closeFd(held);
        return null;
    };
    return .{ .fd = held, .dev = devKey(s), .ino = s.ino };
}

/// Run the -execdir batches that belong to another directory than the current
/// file's, as GNU find does when the walk moves on.
fn flushLeftBehind(st: *State) void {
    for (st.execs.items) |n| {
        const held = n.batch_dir orelse continue;
        const now = execDirOf(st);
        if (now == null or now.?.dev != held.dev or now.?.ino != held.ino) flushBatch(st, n);
    }
}

/// Start `argv`. Its program is never looked for in the directory it runs in
/// unless the expression says so with a path (programpath.zig).
fn spawnCommand(st: *State, argv: []const []const u8, cwd: std.process.Child.Cwd, asked: bool) !std.process.Child {
    const resolved = try st.gpa.dupe([]const u8, argv);
    resolved[0] = try programpath.resolve(st.env, st.gpa, argv[0]);
    return std.process.spawn(st.env.io, .{ .argv = resolved, .cwd = cwd, .stdin = if (asked) .ignore else .inherit });
}

/// Run `argv` and wait. A command that was asked about (-ok, -okdir) reads
/// /dev/null: standard input holds the answers to the questions.
fn runCommand(st: *State, argv: []const []const u8, cwd: ?sys.Handle, asked: bool) bool {
    flushOut(st);
    for (st.outs.items) |o| flushFile(st, o);
    const cwd_opt: std.process.Child.Cwd = if (cwd) |fd| .{ .dir = .{ .handle = fd } } else .inherit;
    var child = spawnCommand(st, argv, cwd_opt, asked) catch |e| {
        const text: []const u8 = switch (e) {
            error.FileNotFound => "No such file or directory",
            error.AccessDenied, error.PermissionDenied => "Permission denied",
            error.InvalidExe => "Exec format error",
            else => @errorName(e),
        };
        st.observer.emit(.{ .exec_failed = .{ .program = argv[0], .text = text } });
        return false;
    };
    _ = &child;
    const pid = child.id.?;
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
            break :blk std.fmt.allocPrint(st.gpa, "./{s}", .{baseOf(st.cur_path)}) catch {
                st.nomem();
                break :blk st.cur_path;
            };
        }
        break :blk std.fmt.allocPrint(st.gpa, "./{s}", .{base}) catch {
            st.nomem();
            break :blk st.cur_path;
        };
    };
    var cwd: ?ExecDir = null;
    if (n.dir) {
        cwd = execDirOf(st) orelse {
            // A start point whose directory could not be opened.
            pathError(st, st.cur_path, st.start_dir_errno);
            return false;
        };
    }
    if (n.plus) {
        if (cwd) |c| if (n.batch_dir == null) {
            var err: LX.E = .SUCCESS;
            n.batch_dir = holdDir(c.fd, ".", &err) orelse {
                pathError(st, dirnameOf(st.cur_path), err);
                return false;
            };
        };
        n.batch.append(st.gpa, name_for_dir) catch st.nomem();
        n.batch_len += name_for_dir.len + 1;
        if (n.batch_len > 100000) flushBatch(st, n);
        return true;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    for (n.argv) |a| argv.append(st.gpa, replaceBraces(st, a, name_for_dir)) catch st.nomem();
    if (n.prompt) {
        flushOut(st);
        var pr: std.ArrayList(u8) = .empty;
        pr.append(st.gpa, '<') catch st.nomem();
        for (argv.items[0..1]) |a| {
            pr.append(st.gpa, ' ') catch st.nomem();
            pr.appendSlice(st.gpa, a) catch st.nomem();
        }
        pr.appendSlice(st.gpa, " ... ") catch st.nomem();
        pr.appendSlice(st.gpa, st.cur_path) catch st.nomem();
        pr.appendSlice(st.gpa, " > ? ") catch st.nomem();
        const c = st.confirm orelse return false;
        if (!c.func(c.context, pr.items)) return false;
    }
    return runCommand(st, argv.items, if (cwd) |c| c.fd else null, n.prompt);
}

fn flushBatch(st: *State, n: *Node) void {
    if (n.batch.items.len == 0) return;
    var argv: std.ArrayList([]const u8) = .empty;
    for (n.argv[0 .. n.argv.len - 1]) |a| argv.append(st.gpa, a) catch st.nomem();
    for (n.batch.items) |f| argv.append(st.gpa, f) catch st.nomem();
    // "+" is not accepted after -ok and -okdir.
    if (!runCommand(st, argv.items, if (n.batch_dir) |d| d.fd else null, false)) st.exit_status = 1;
    if (n.batch_dir) |d| _ = sys.closeFd(d.fd);
    n.batch_dir = null;
    n.batch.clearRetainingCapacity();
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
    return std.fmt.allocPrint(st.gpa, "{d}", .{uid}) catch {
        st.nomem();
        return "?";
    };
}

fn groupName(st: *State, gid: u32) []const u8 {
    loadDb(st);
    if (st.db.groupByGid(gid)) |g| return g.name;
    return std.fmt.allocPrint(st.gpa, "{d}", .{gid}) catch {
        st.nomem();
        return "?";
    };
}

/// -json: one JSON object and a newline for the current file, with the same
/// fields as `ls --json` (see fileinfo.zig): `dir` and `name` are the path split
/// at its last slash, so `./a/b` is dir "./a", name "b", and a path with no
/// slash has a null dir. Symbolic links follow the -H/-L/-P setting, as -ls does.
fn printJson(st: *State) void {
    const s = getSt(st) orelse return;
    const path = st.cur_path;
    var dir: ?[]const u8 = null;
    var name: []const u8 = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (path.len > 1) {
            dir = if (i == 0) "/" else path[0..i];
            name = path[i + 1 ..];
            if (name.len == 0) name = path; // a trailing slash: keep the whole path
        }
    }
    loadDb(st);
    const user = if (st.db.userByUid(s.uid)) |u| u.name else null;
    const group = if (st.db.groupByGid(s.gid)) |g| g.name else null;
    var target_buf: [4096]u8 = undefined;
    var target: ?[]const u8 = null;
    if (s.isLink()) {
        var err: LX.E = .SUCCESS;
        if (sys.readlinkAt(st.at().dir, st.at().name, &target_buf, &err)) |k| target = target_buf[0..k];
    }
    var aw: std.Io.Writer.Allocating = .init(st.gpa);
    defer aw.deinit();
    fileinfo.writeJsonIn(&aw.writer, dir, name, &s, target, user, group) catch return;
    aw.writer.writeByte('\n') catch return;
    emit(st, aw.written());
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
    strftime.format(&tbuf, st.gpa, if (recent) "%b %e %H:%M" else "%b %e  %Y", &tm, s.mtime_s, 0) catch st.nomem();
    out.print(st.gpa, "{d: >9} {d: >6} {s} {d: >3} {s: <8} {s: <8} ", .{ s.ino, (s.blocks + 1) / 2, ms[0..], s.nlink, user, group }) catch st.nomem();
    const kind = s.mode & 0o170000;
    if (kind == 0o020000 or kind == 0o060000) {
        out.print(st.gpa, "{d: >3}, {d: >3} ", .{ s.rdev_major, s.rdev_minor }) catch st.nomem();
    } else out.print(st.gpa, "{d: >8} ", .{s.size}) catch st.nomem();
    out.appendSlice(st.gpa, tbuf.items) catch st.nomem();
    out.append(st.gpa, ' ') catch st.nomem();
    quotearg.quote(&out, st.gpa, st.cur_path, .escape, &space_set) catch st.nomem();
    if (s.isLink()) {
        var buf: [4096]u8 = undefined;
        var err: LX.E = .SUCCESS;
        if (sys.readlinkAt(st.at().dir, st.at().name, &buf, &err)) |k| {
            out.appendSlice(st.gpa, " -> ") catch st.nomem();
            quotearg.quote(&out, st.gpa, buf[0..k], .escape, &space_set) catch st.nomem();
        }
    }
    out.append(st.gpa, '\n') catch st.nomem();
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
        '@' => out.print(st.gpa, "{d}.{d:0>10}", .{ sec, @as(u64, @intCast(nsec)) * 10 }) catch st.nomem(),
        '+' => {
            strftime.format(out, st.gpa, "%Y-%m-%d+%H:%M:%S", &tm, sec, @intCast(nsec)) catch st.nomem();
            out.print(st.gpa, ".{d:0>10}", .{@as(u64, @intCast(nsec)) * 10}) catch st.nomem();
            // %Z-less like GNU: "+%T" style has no zone
        },
        else => {
            const f = [_]u8{ '%', tchar };
            if (tchar != 1 and std.mem.indexOfScalar(u8, "aAbBcCdDeFgGhHIjklmMnprRsStTuUVwWxXyYzZEO", tchar) == null) {
                out.appendSlice(st.gpa, &f) catch st.nomem();
            } else if (tchar == 'S') {
                strftime.format(out, st.gpa, "%S", &tm, sec, @intCast(nsec)) catch st.nomem();
                out.print(st.gpa, ".{d:0>10}", .{@as(u64, @intCast(nsec)) * 10}) catch st.nomem();
            } else if (tchar == 'T' or tchar == 'X') {
                strftime.format(out, st.gpa, "%H:%M:%S", &tm, sec, @intCast(nsec)) catch st.nomem();
                out.print(st.gpa, ".{d:0>10}", .{@as(u64, @intCast(nsec)) * 10}) catch st.nomem();
            } else if (tchar == 1) {
                // like ctime with fractional seconds
                strftime.format(out, st.gpa, "%a %b %e %H:%M:%S", &tm, sec, @intCast(nsec)) catch st.nomem();
                out.print(st.gpa, ".{d:0>10}", .{@as(u64, @intCast(nsec)) * 10}) catch st.nomem();
                strftime.format(out, st.gpa, " %Y", &tm, sec, @intCast(nsec)) catch st.nomem();
            } else strftime.format(out, st.gpa, &f, &tm, sec, @intCast(nsec)) catch st.nomem();
        },
    }
}

/// printf("%g"): six significant digits, trailing zeros removed.
fn fmtG(st: *State, out: *std.ArrayList(u8), v: f64) void {
    if (v == 0) {
        out.append(st.gpa, '0') catch st.nomem();
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
    out.appendSlice(st.gpa, txt[0..end]) catch st.nomem();
}

fn printFormat(st: *State, parts: []const FmtPart, o: ?*OutFile) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(st.gpa);
    const s = getSt(st);
    for (parts) |pt| {
        out.appendSlice(st.gpa, pt.lit) catch st.nomem();
        if (pt.stop) break;
        if (pt.dir == 0) continue;
        const left = std.mem.indexOfScalar(u8, pt.flags, '-') != null;
        const zero = std.mem.indexOfScalar(u8, pt.flags, '0') != null;
        var tmp: std.ArrayList(u8) = .empty;
        defer tmp.deinit(st.gpa);
        var is_num = false;
        switch (pt.dir) {
            'p' => tmp.appendSlice(st.gpa, st.cur_path) catch st.nomem(),
            'f' => tmp.appendSlice(st.gpa, baseOf(st.cur_path)) catch st.nomem(),
            'h' => tmp.appendSlice(st.gpa, dirnameOf(st.cur_path)) catch st.nomem(),
            'H' => tmp.appendSlice(st.gpa, st.cur_root) catch st.nomem(),
            'P' => {
                if (st.cur_path.len > st.cur_root.len) {
                    var r = st.cur_path[st.cur_root.len..];
                    if (r.len > 0 and r[0] == '/') r = r[1..];
                    tmp.appendSlice(st.gpa, r) catch st.nomem();
                }
            },
            'd' => {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{st.cur_depth}) catch st.nomem();
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
                        if (sys.fileStatAt(st.at().dir, st.at().name, true, &err)) |t| {
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
                    tmp.append(st.gpa, c) catch st.nomem();
                }
            },
            'l' => {
                if (s) |sv| if (sv.isLink()) {
                    var buf: [4096]u8 = undefined;
                    var err: LX.E = .SUCCESS;
                    if (sys.readlinkAt(st.at().dir, st.at().name, &buf, &err)) |k| tmp.appendSlice(st.gpa, buf[0..k]) catch st.nomem();
                };
            },
            's' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.size}) catch st.nomem();
            },
            'S' => if (s) |sv| {
                is_num = true;
                if (sv.size == 0) {
                    tmp.appendSlice(st.gpa, "1") catch st.nomem();
                } else {
                    const ratio: f64 = @as(f64, @floatFromInt(sv.blocks)) * 512.0 / @as(f64, @floatFromInt(sv.size));
                    fmtG(st, &tmp, ratio);
                }
            },
            'b' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.blocks}) catch st.nomem();
            },
            'k' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{(sv.blocks + 1) / 2}) catch st.nomem();
            },
            'n' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.nlink}) catch st.nomem();
            },
            'i' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.ino}) catch st.nomem();
            },
            'D' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{(@as(u64, sv.dev_major) << 8) | sv.dev_minor}) catch st.nomem();
            },
            'm' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{o}", .{sv.mode & 0o7777}) catch st.nomem();
            },
            'M' => if (s) |sv| {
                var ms: [10]u8 = undefined;
                modeStr(sv.mode, &ms);
                tmp.appendSlice(st.gpa, &ms) catch st.nomem();
            },
            'u' => if (s) |sv| tmp.appendSlice(st.gpa, userName(st, sv.uid)) catch st.nomem(),
            'g' => if (s) |sv| tmp.appendSlice(st.gpa, groupName(st, sv.gid)) catch st.nomem(),
            'U' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.uid}) catch st.nomem();
            },
            'G' => if (s) |sv| {
                is_num = true;
                tmp.print(st.gpa, "{d}", .{sv.gid}) catch st.nomem();
            },
            'F' => if (s) |sv| tmp.appendSlice(st.gpa, fsTypeOf(st, devKey(sv))) catch st.nomem(),
            'Z' => {
                flushOut(st);
                st.observer.emit(.{ .no_security_context = st.cur_path });
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
            if (std.fmt.allocPrint(st.gpa, "0{s}", .{text})) |t2| {
                text = t2;
            } else |_| st.nomem();
        }
        padTo(&out, st.gpa, text, pt.width, left, zero and (pt.dir == 'd' or pt.dir == 'm')) catch st.nomem();
    }
    if (o) |f| outWrite(st, f, out.items) else emit(st, out.items);
}

// -------------------------------------------------------------- traversal

const Ancestor = struct { dev: u64, ino: u64, path: []const u8 };

/// Whether a symbolic link met here is followed (-L, or -H on a start point).
fn followsHere(st: *const State, cmdline: bool) bool {
    return st.follow == .logical or (st.follow == .command_line and cmdline);
}

fn statEntry(st: *State, file: At, cmdline: bool, lst: *?sys.FileStat, stt: *?sys.FileStat, err: *LX.E) bool {
    var e: LX.E = .SUCCESS;
    lst.* = sys.fileStatAt(file.dir, file.name, false, &e);
    if (lst.* == null) {
        err.* = e;
        return false;
    }
    if (followsHere(st, cmdline) and lst.*.?.isLink()) {
        stt.* = sys.fileStatAt(file.dir, file.name, true, &e);
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
    parent: ?*dirat.Level,
};

fn saveCur(st: *State) Cur {
    return .{ .path = st.cur_path, .name_off = st.cur_name_off, .depth = st.cur_depth, .st = st.cur_st, .lst = st.cur_lst, .dtype = st.cur_dtype, .loaded = st.cur_loaded, .failed = st.cur_failed, .cmdline = st.cur_cmdline, .parent = st.cur_parent };
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
    st.cur_parent = c.parent;
}

/// find's type letter for a readdir `d_type`; 0 when it says nothing.
fn dtypeOf(d_type: u8) u8 {
    return switch (d_type) {
        4 => 'd',
        8 => 'f',
        10 => 'l',
        6 => 'b',
        2 => 'c',
        1 => 'p',
        12 => 's',
        else => 0,
    };
}

fn visit(st: *State, path: []const u8, name_off: usize, depth: i64, cmdline: bool, ancestors: *std.ArrayList(Ancestor), root_dev: u64, parent: ?*dirat.Level, dtype: u8) void {
    if (st.quit) return;
    st.cur_path = path;
    st.cur_name_off = name_off;
    st.cur_depth = depth;
    st.cur_dtype = dtype;
    st.cur_cmdline = cmdline;
    st.cur_parent = parent;
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
                st.observer.emit(.{ .loop = .{ .path = path, .ancestor = a.path } });
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
        evalHere(st);
        if (st.quit) return;
        if (st.prune_flag) descend = false;
    }
    if (descend) {
        ancestors.append(st.gpa, .{ .dev = dev, .ino = ino, .path = path }) catch st.nomem();
        walkDir(st, path, depth, ancestors, root_dev);
        _ = ancestors.pop();
        if (st.quit) return;
        restoreCur(st, snap);
        // The directory this entry is in was lost while below it.
        if (parent) |p| if (!p.open) return;
    }
    if (st.depth_first and eval_here) {
        evalHere(st);
    }
}

/// Visit the entries of the current file, a directory.
fn walkDir(st: *State, path: []const u8, depth: i64, ancestors: *std.ArrayList(Ancestor), root_dev: u64) void {
    // The directory opened here must be the one the tests have seen, and a
    // symbolic link now in its place must not be followed.
    var level: dirat.Level = undefined;
    if (dirat.enter(&level, st.cur_parent, st.at().name, .{
        .follow = followsHere(st, st.cur_cmdline),
        .expect = if (st.cur_loaded and !st.cur_failed) st.cur_st else null,
        .same_device = st.xdev,
    })) |e| return pathError(st, path, e);
    defer if (dirat.leave(&level)) |e| pathError(st, dirnameOf(path), e);

    var err: LX.E = .SUCCESS;
    const entries = sys.readDirNamesFd(st.env.gpa, level.fd, &err) orelse return pathError(st, path, err);
    defer sys.freeDirEntries(st.env.gpa, entries);
    var base = path;
    if (base.len > 1 and base[base.len - 1] == '/') {
        // fts: the trailing slash of the parent is not doubled
        base = base[0 .. base.len - 1];
        if (base.len == 0) base = "/";
    }
    for (entries) |entry| {
        // A level that could not be reopened cannot be walked any further.
        if (st.quit or !level.open) return;
        const nm = entry.name;
        const child = (if (std.mem.eql(u8, base, "/"))
            std.fmt.allocPrint(st.gpa, "/{s}", .{nm})
        else
            std.fmt.allocPrint(st.gpa, "{s}/{s}", .{ base, nm })) catch {
            st.nomem();
            continue;
        };
        const off = child.len - nm.len;
        visit(st, child, off, depth + 1, false, ancestors, root_dev, &level, dtypeOf(entry.dtype));
    }
}
// ------------------------------------------------------------------ public API

pub const Settings = struct {
    follow: Follow = .physical,
    /// Deepest level to descend to (-maxdepth); negative: no limit.
    maxdepth: i64 = -1,
    /// Shallowest level at which the visitor/expression is applied.
    mindepth: i64 = 0,
    /// Visit a directory after its contents (-depth).
    depth_first: bool = false,
    /// Do not cross file-system boundaries (-xdev).
    xdev: bool = false,
    /// Treat a file that vanishes during the walk as not an error.
    ignore_race: bool = false,
};

pub const CompileOptions = struct {
    /// -H / -L / -P given before the start points.
    follow: Follow = .physical,
    /// No start point was given (adds a hint to one diagnostic).
    no_starts: bool = false,
    /// UTF-8 locale: curly quotes in messages.
    utf8: bool = false,
    /// "Now" for -mtime, -newerXt, -daystart; null: the current time.
    now: ?datetime.Timespec = null,
};

pub const Result = struct {
    /// What the executable exits with (1 after any error during the walk).
    exit_status: u8 = 0,
    /// A write to the output writer failed (output after it was dropped).
    write_failed: bool = false,
};

pub const RunOptions = struct {
    /// Target of -fprint /dev/stderr (dropped when null).
    stderr: ?*Io.Writer = null,
    confirm: ?Confirm = null,
};

/// A compiled expression plus the settings its options (-maxdepth, -xdev,
/// -depth, -daystart, ...) switched on. Owns its memory and the files opened
/// for -fprint and friends.
pub const Expr = struct {
    arena: *std.heap.ArenaAllocator,
    st: *State,

    pub fn deinit(e: *Expr) void {
        const gpa = e.arena.child_allocator;
        for (e.st.outs.items) |o| {
            if (o.owned and o.fd != sys.invalid_handle) _ = sys.closeFd(o.fd);
        }
        e.arena.deinit();
        gpa.destroy(e.arena);
        e.* = undefined;
    }

    /// The settings the expression carries.
    pub fn settings(e: *const Expr) Settings {
        return .{ .follow = e.st.follow, .maxdepth = e.st.maxdepth, .mindepth = e.st.mindepth, .depth_first = e.st.depth_first, .xdev = e.st.xdev, .ignore_race = e.st.ignore_race };
    }

    /// Walk `starts` (the current directory when empty), apply the expression
    /// to every entry and write the output to `writer`.
    pub fn run(e: *Expr, starts: []const []const u8, writer: *Io.Writer, options: RunOptions, observer: Observer) error{OutOfMemory}!Result {
        const st = e.st;
        st.observer = observer;
        st.writer = writer;
        st.stderr = options.stderr;
        st.confirm = options.confirm;
        defer {
            st.writer = null;
            st.stderr = null;
            st.confirm = null;
        }
        return runWalk(st, starts);
    }
};

fn newState(env: Env, observer: Observer, now: ?datetime.Timespec) error{OutOfMemory}!Expr {
    const gpa = env.gpa;
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const st = try arena.allocator().create(State);
    const ts: datetime.Timespec = now orelse blk: {
        const t = Io.Timestamp.now(env.io, .real);
        break :blk .{ .sec = @intCast(@divFloor(t.nanoseconds, std.time.ns_per_s)), .nsec = @intCast(@mod(t.nanoseconds, std.time.ns_per_s)) };
    };
    st.* = .{ .env = env, .gpa = arena.allocator(), .observer = observer };
    st.start_sec = ts.sec;
    st.start_nsec = @intCast(ts.nsec);
    return .{ .arena = arena, .st = st };
}

/// Compile the expression `args`. On `error.Invalid`, `diag` holds the
/// diagnostic lines (free with `Diagnostic.deinit`).
pub fn compile(env: Env, args: []const []const u8, options: CompileOptions, observer: Observer, diag: *Diagnostic) error{ OutOfMemory, Invalid }!Expr {
    var expr = try newState(env, observer, options.now);
    errdefer expr.deinit();
    const st = expr.st;
    st.follow = options.follow;
    st.utf8 = options.utf8;
    compileInto(st, args, options) catch |err| {
        if (err == error.Invalid) {
            const lines = try env.gpa.alloc([]const u8, st.diag_lines.items.len);
            var n: usize = 0;
            errdefer {
                for (lines[0..n]) |l| env.gpa.free(l);
                env.gpa.free(lines);
            }
            for (st.diag_lines.items) |l| {
                lines[n] = try env.gpa.dupe(u8, l);
                n += 1;
            }
            diag.* = .{ .lines = lines };
        }
        return err;
    };
    return expr;
}

fn compileInto(st: *State, args: []const []const u8, options: CompileOptions) Error!void {
    var p = Parser{ .st = st, .args = args, .i = 0, .no_starts = options.no_starts };
    if (args.len == 0) {
        st.root = try p.mk(.print);
    } else {
        const e = try p.parseComma();
        if (p.i < args.len) {
            // leftover tokens: a stray ')' or an operand
            const a = args[p.i];
            if (std.mem.eql(u8, a, ")")) return fail(st, "you have too many ')'", .{});
            return fail(st, "invalid expression", .{});
        }
        if (st.has_action) {
            st.root = e;
        } else {
            const pr = try p.mk(.print);
            const n = try p.mk(.and_);
            n.a = e;
            n.b = pr;
            st.root = n;
        }
    }
    if (st.saw_delete and st.saw_prune and !st.explicit_depth) return fail(st, "The -delete action automatically turns on -depth, but -prune does nothing when -depth is in effect.  If you want to carry on anyway, just explicitly use the -depth option.", .{});
    if (st.daystart) {
        ensureZone(st);
        const tm = tzmod.localtime(&st.zone, st.start_sec);
        st.day_start = tzmod.mktime(&st.zone, tm.year, @as(i64, tm.mon) - 1, @as(i64, tm.mday) + 1, 0, 0, 0);
    }
}

fn runWalk(st: *State, starts_in: []const []const u8) error{OutOfMemory}!Result {
    const dot = [_][]const u8{"."};
    const starts: []const []const u8 = if (starts_in.len == 0) &dot else starts_in;
    for (starts) |sp| {
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
        if (st.has_execdir) {
            // Opened before anything runs, so that no command can redirect it.
            st.start_dir = holdDir(sys.cwdFd(), dirOf(sp[0..tl]), &st.start_dir_errno);
        }
        defer if (st.start_dir) |d| {
            _ = sys.closeFd(d.fd);
            st.start_dir = null;
        };
        visit(st, sp, off, 0, true, &anc, rdev, null, 0);
    }
    for (st.execs.items) |n| flushBatch(st, n);
    flushOut(st);
    finishOutputs(st);
    if (st.oom) return error.OutOfMemory;
    return .{ .exit_status = st.exit_status, .write_failed = st.write_failed };
}

/// One entry of a `walk`, valid during the visitor call.
pub const Entry = struct {
    st: *State,

    /// The path as find prints it (start point plus the names below it).
    pub fn path(e: Entry) []const u8 {
        return e.st.cur_path;
    }
    /// Distance from the start point (0 for the start point itself).
    pub fn depth(e: Entry) i64 {
        return e.st.cur_depth;
    }
    /// The last path component.
    pub fn name(e: Entry) []const u8 {
        return e.st.cur_path[e.st.cur_name_off..];
    }
    /// The start point the entry was reached from.
    pub fn root(e: Entry) []const u8 {
        return e.st.cur_root;
    }
    /// Metadata, following symbolic links as the walk's `follow` setting says.
    /// Null when it cannot be read (reported once through the Observer).
    pub fn stat(e: Entry) ?FileStat {
        return getSt(e.st);
    }
    /// Metadata of the link itself.
    pub fn lstat(e: Entry) ?FileStat {
        return getLst(e.st);
    }
    /// Do not descend into this directory (no effect with `depth_first`).
    pub fn prune(e: Entry) void {
        if (!e.st.depth_first) e.st.prune_flag = true;
    }
    /// End the walk after this entry.
    pub fn stop(e: Entry) void {
        e.st.quit = true;
    }
};

pub const Visitor = struct {
    context: ?*anyopaque = null,
    func: *const fn (context: ?*anyopaque, entry: *Entry) void,
};

/// Walk `starts` and call `visitor` for every entry deeper than `mindepth`.
pub fn walk(env: Env, settings: Settings, starts: []const []const u8, visitor: Visitor, observer: Observer) error{OutOfMemory}!Result {
    var expr = try newState(env, observer, null);
    defer expr.deinit();
    const st = expr.st;
    st.follow = settings.follow;
    st.maxdepth = settings.maxdepth;
    st.mindepth = settings.mindepth;
    st.depth_first = settings.depth_first;
    st.xdev = settings.xdev;
    st.ignore_race = settings.ignore_race;
    st.visitor = visitor;
    return runWalk(st, starts);
}

pub const localeIsUtf8 = fu.localeIsUtf8;

test "quoteMsg" {
    const gpa = std.testing.allocator;
    const a = try quoteMsg(gpa, "a b", false);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("'a b'", a);
    const b = try quoteMsg(gpa, "a'b", true);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("\u{2018}a\\'b\u{2019}", b);
}

test "typeBit and cmpI" {
    try std.testing.expect(cmpI(.gt, 3, 2));
    try std.testing.expect(!cmpI(.lt, 3, 2));
    try std.testing.expect(typeBit(0o100644) == (@as(u64, 1) << ('f' - 'A')));
}

test "baseOf and dirnameOf follow find for trailing slashes" {
    try std.testing.expectEqualStrings("b", baseOf("a/b"));
    try std.testing.expectEqualStrings("a", dirnameOf("a/b"));
    try std.testing.expectEqualStrings(".", dirnameOf("b"));
}
