//! sed — stream editor. Reference: GNU sed 4.9 (compile.c, execute.c) and
//! POSIX sed. Regular expressions go through src/posixre.zig (BRE/ERE
//! translated to the regex-zig Perl dialect), so alternation is
//! leftmost-first rather than POSIX leftmost-longest.
//!
//! Layout: a script parser (`Parser`) builds a flat command array; `Exec`
//! runs it over the input files. Input files are read whole into memory.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const posixre = @import("../posixre.zig");
const regex = @import("regex");
const sys = @import("../sys.zig");
const LX = std.os.linux;

const help_text = @embedFile("../help/sed.txt");

const Re = struct { re: regex.Regex, groups: u32, multiline: bool };

const AddrKind = enum { none, line, step, last, re, zero, plus, mult };
const Addr = struct {
    kind: AddrKind = .none,
    n: u64 = 0,
    step: u64 = 0,
    re: ?*Re = null, // null with kind == .re: the empty regex (last one used)
};

const Part = struct {
    lit: []const u8 = "",
    group: i32 = -1, // -1: none; 0: whole match
    case_op: u8 = 0, // 'U' 'L' 'E' 'u' 'l' applied before this part; 0 none
};

const Subst = struct {
    re: ?*Re,
    parts: []Part,
    global: bool = false,
    print: u8 = 0, // count of p flags
    eval: bool = false,
    number: u64 = 1,
    wfile: ?usize = null,
    max_group: u32 = 0,
};

const Cmd = struct {
    a1: Addr = .{},
    a2: Addr = .{},
    negate: bool = false,
    range_active: bool = false,
    range_closed: bool = false,
    range_end: u64 = 0,
    c: u8 = 0,
    text: []const u8 = "",
    int: i64 = -1,
    jump: usize = 0,
    out: usize = 0,
    sub: ?*Subst = null,
    ytab: ?*[256]u8 = null,
};

const Output = struct {
    fd: i32,
    path: []const u8 = "",
    buf: std.ArrayList(u8) = .empty,
    missing_nl: bool = false,
    is_std: bool = false,
    /// Buffer and descriptor are shared with this Output (w /dev/stdout).
    sink: ?*Output = null,
};

const Chunk = struct {
    text: []const u8,
    is_file: bool,
    name: []const u8, // file name for -f
    index: usize, // 1-based -e number
};

const Opts = struct {
    quiet: bool = false,
    ere: bool = false,
    separate: bool = false,
    in_place: bool = false,
    suffix: ?[]const u8 = null,
    line_len: i64 = 70,
    unbuffered: bool = false,
    null_data: bool = false,
    posix: bool = false,
    sandbox: bool = false,
    follow: bool = false,
    debug: bool = false,
};

const ParseError = error{ BadProg, OutOfMemory };

const State = struct {
    ctx: cli.Context,
    arena: std.mem.Allocator,
    opts: Opts,
    cmds: std.ArrayList(Cmd) = .empty,
    outs: std.ArrayList(*Output) = .empty,
    chunks: []Chunk = &.{},
    exit_code: u8 = 0,
    last_re: ?*Re = null,
    // parser
    ci: usize = 0,
    pos: usize = 0,
    blocks: std.ArrayList(usize) = .empty,
    labels: std.ArrayList(struct { name: []const u8, idx: usize }) = .empty,
    stdout_out: *Output = undefined,
    stderr_out: *Output = undefined,
};

fn errnoMsg(e: LX.E) []const u8 {
    return sys.errnoText(e);
}

// ---------------------------------------------------------------- parser

const Parser = struct {
    s: *State,

    fn chunk(p: *Parser) Chunk {
        return p.s.chunks[p.s.ci];
    }

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        const s = p.s;
        const ch = p.chunk();
        if (ch.is_file) {
            var line: usize = 1;
            const end = @min(s.pos, ch.text.len);
            for (ch.text[0..end]) |c| {
                if (c == '\n') line += 1;
            }
            // An error found right after a newline belongs to the previous line.
            if (end > 0 and ch.text[end - 1] == '\n') line -= 1;
            if (line == 0) line = 1;
            cli.warn(s.ctx, "file {s} line {d}: " ++ fmt, .{ ch.name, line } ++ args);
        } else {
            cli.warn(s.ctx, "-e expression #{d}, char {d}: " ++ fmt, .{ ch.index, s.pos } ++ args);
        }
        return error.BadProg;
    }

    fn peek(p: *Parser) ?u8 {
        const t = p.chunk().text;
        if (p.s.pos >= t.len) return null;
        return t[p.s.pos];
    }

    fn get(p: *Parser) ?u8 {
        const t = p.chunk().text;
        if (p.s.pos >= t.len) {
            p.s.pos = t.len + 0;
            return null;
        }
        const c = t[p.s.pos];
        p.s.pos += 1;
        return c;
    }

    fn unget(p: *Parser) void {
        if (p.s.pos > 0) p.s.pos -= 1;
    }

    fn skipBlank(p: *Parser) ?u8 {
        while (p.get()) |c| {
            if (c == ' ' or c == '\t' or c == '\r' or c == 0x0b or c == 0x0c) continue;
            return c;
        }
        return null;
    }

    fn skipSpace(p: *Parser) ?u8 {
        while (p.get()) |c| {
            if (std.ascii.isWhitespace(c)) continue;
            return c;
        }
        return null;
    }

    fn readNumber(p: *Parser, first: u8) u64 {
        var n: u64 = first - '0';
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            n = n *% 10 +% (c - '0');
            _ = p.get();
        }
        return n;
    }

    /// Read up to the unescaped delimiter. Returns null when unterminated.
    /// `is_re`: a backslash-n becomes a newline; `\delim` loses its backslash.
    fn matchSlash(p: *Parser, delim: u8, is_re: bool) ParseError!?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        while (p.get()) |c| {
            if (c == delim) return try out.toOwnedSlice(p.s.arena);
            if (c == '\\') {
                const n = p.get() orelse {
                    try out.append(p.s.arena, '\\');
                    break;
                };
                if (n == delim) {
                    // "s|a\|b|x|": the escaped delimiter is the literal char.
                    try out.append(p.s.arena, n);
                    continue;
                }
                if (n == 'n' and is_re) {
                    try out.append(p.s.arena, '\n');
                    continue;
                }
                if (n == '\n' and !is_re) {
                    try out.appendSlice(p.s.arena, "\\\n");
                    continue;
                }
                try out.append(p.s.arena, '\\');
                try out.append(p.s.arena, n);
                continue;
            }
            if (c == '\n' and is_re) return null;
            if (c == '[' and is_re) {
                // A bracket expression may contain the delimiter.
                try out.append(p.s.arena, c);
                if (p.peek() == '^') try out.append(p.s.arena, p.get().?);
                if (p.peek() == ']') try out.append(p.s.arena, p.get().?);
                var closed = false;
                while (p.get()) |b| {
                    try out.append(p.s.arena, b);
                    if (b == '[' and p.peek() != null and (p.peek().? == ':' or p.peek().? == '.' or p.peek().? == '=')) {
                        const kind = p.get().?;
                        try out.append(p.s.arena, kind);
                        while (p.get()) |q| {
                            try out.append(p.s.arena, q);
                            if (q == kind and p.peek() == ']') {
                                try out.append(p.s.arena, p.get().?);
                                break;
                            }
                        }
                        continue;
                    }
                    if (b == '\n') return null;
                    if (b == ']') {
                        closed = true;
                        break;
                    }
                }
                if (!closed) return null;
                continue;
            }
            try out.append(p.s.arena, c);
        }
        return null;
    }

    fn compileRe(p: *Parser, pat: []const u8, icase: bool, mline: bool) ParseError!?*Re {
        const s = p.s;
        if (pat.len == 0) return null;
        const conv = try convertEscapes(s.arena, pat, true);
        const body = posixre.translate(s.arena, conv, s.opts.ere) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadPattern => return p.fail("{s}", .{posixre.diagnoseMode(conv, s.opts.ere)}),
        };
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(s.arena, if (mline) "(?sm)" else "(?s)");
        try src.appendSlice(s.arena, body);
        const re = regex.Regex.compile(s.arena, src.items, .{ .dialect = .perl, .ignore_case = icase }, null) catch {
            return p.fail("{s}", .{posixre.diagnoseMode(conv, s.opts.ere)});
        };
        const r = try s.arena.create(Re);
        r.* = .{ .re = re, .groups = re.groupCount(), .multiline = mline };
        return r;
    }

    fn readAddr(p: *Parser, first: u8, second: bool) ParseError!?Addr {
        const s = p.s;
        if (std.ascii.isDigit(first)) {
            const n = p.readNumber(first);
            if (p.peek() == '~' and !second) {
                _ = p.get();
                var step: u64 = 0;
                if (p.peek()) |d| {
                    if (std.ascii.isDigit(d)) {
                        _ = p.get();
                        step = p.readNumber(d);
                    }
                }
                if (n == 0 and step == 0) {
                    _ = p.get();
                    return p.fail("invalid usage of line address 0", .{});
                }
                if (false) return p.fail("invalid usage of line address 0", .{});
                return Addr{ .kind = .step, .n = n, .step = step };
            }
            if (n == 0 and !second) return Addr{ .kind = .zero };
            return Addr{ .kind = .line, .n = n };
        }
        if (first == '+' or first == '~') {
            if (!second) {
                _ = p.get();
                return p.fail("invalid usage of +N or ~N as first address", .{});
            }
            const d = p.get() orelse return p.fail("expected newer version of sed", .{});
            if (!std.ascii.isDigit(d)) return p.fail("expected newer version of sed", .{});
            const n = p.readNumber(d);
            return Addr{ .kind = if (first == '+') .plus else .mult, .n = n };
        }
        if (first == '$') return Addr{ .kind = .last };
        if (first == '/' or first == '\\') {
            var delim: u8 = '/';
            if (first == '\\') delim = p.get() orelse return p.fail("unexpected `,'", .{});
            const pat = (try p.matchSlash(delim, true)) orelse return p.fail("unterminated address regex", .{});
            var icase = false;
            var mline = false;
            while (p.peek()) |f| {
                if (f == 'I') icase = true else if (f == 'M') mline = true else break;
                _ = p.get();
            }
            if (pat.len == 0 and (icase or mline)) return p.fail("cannot specify modifiers on empty regexp", .{});
            const re = try p.compileRe(pat, icase, mline);
            if (re) |r| s.last_re = r;
            return Addr{ .kind = .re, .re = re };
        }
        return null;
    }

    fn endOfCmd(p: *Parser) ParseError!void {
        const c = p.skipBlank() orelse return;
        switch (c) {
            '}', '#' => p.unget(),
            '\n', ';' => {},
            else => return p.fail("extra characters after command", .{}),
        }
    }

    fn readLabel(p: *Parser, semi: bool) []const u8 {
        const t = p.chunk().text;
        if (p.skipBlank() != null) p.unget();
        const start = p.s.pos;
        var i = start;
        while (i < t.len) : (i += 1) {
            const c = t[i];
            if (std.ascii.isWhitespace(c)) break;
            if (semi and c == ';') break;
        }
        p.s.pos = i;
        return t[start..i];
    }

    fn readFilename(p: *Parser) ParseError![]const u8 {
        const t = p.chunk().text;
        if (p.skipBlank() != null) p.unget();
        const start = p.s.pos;
        var i = start;
        while (i < t.len and t[i] != '\n') : (i += 1) {}
        p.s.pos = i;
        const name = t[start..i];
        if (name.len == 0) return p.fail("missing filename in r/R/w/W commands", .{});
        return name;
    }

    fn openOut(p: *Parser, name: []const u8) ParseError!usize {
        const s = p.s;
        for (s.outs.items, 0..) |o, i| {
            if (std.mem.eql(u8, o.path, name)) return i;
        }
        const o = try s.arena.create(Output);
        o.* = .{ .fd = -1, .path = name };
        if (std.mem.eql(u8, name, "/dev/stdout")) {
            o.fd = 1;
            o.is_std = true;
        } else if (std.mem.eql(u8, name, "/dev/stderr")) {
            o.fd = 2;
            o.is_std = true;
        } else {
            var err: LX.E = .SUCCESS;
            o.fd = sys.openFd(name, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, 0o666, &err) orelse {
                cli.warn(s.ctx, "couldn't open file {s}: {s}", .{ name, errnoMsg(err) });
                std.process.exit(4);
            };
        }
        try s.outs.append(s.arena, o);
        return s.outs.items.len - 1;
    }

    /// Text argument of a, i, c.
    fn readText(p: *Parser) ParseError![]const u8 {
        const s = p.s;
        var buf: std.ArrayList(u8) = .empty;
        var c = p.skipBlank() orelse return p.fail("expected \\ after `a', `c' or `i'", .{});
        if (c == '\n') return p.fail("expected \\ after `a', `c' or `i'", .{});
        if (c == '\\') {
            c = p.get() orelse {
                // `a\` at the end of an -e chunk: the text is the next chunk.
                if (s.ci + 1 < s.chunks.len) {
                    s.ci += 1;
                    s.pos = 0;
                    return p.readTextBody(&buf);
                }
                return "";
            };
            if (c != '\n') p.unget();
            return p.readTextBody(&buf);
        }
        p.unget();
        return p.readTextBody(&buf);
    }

    fn readTextBody(p: *Parser, buf: *std.ArrayList(u8)) ParseError![]const u8 {
        const s = p.s;
        while (true) {
            const c = p.get() orelse break;
            if (c == '\n') break;
            if (c == '\\') {
                const n = p.get() orelse {
                    if (s.ci + 1 < s.chunks.len) {
                        s.ci += 1;
                        s.pos = 0;
                        try buf.append(s.arena, '\n');
                        continue;
                    }
                    break;
                };
                switch (n) {
                    '\n' => try buf.append(s.arena, '\n'),
                    't' => try buf.append(s.arena, '\t'),
                    'n' => try buf.append(s.arena, '\n'),
                    'f' => try buf.append(s.arena, 12),
                    'v' => try buf.append(s.arena, 11),
                    'a' => try buf.append(s.arena, 7),
                    'r' => try buf.append(s.arena, '\r'),
                    'c' => {
                        if (p.get()) |x| try buf.append(s.arena, std.ascii.toUpper(x) ^ 0x40);
                    },
                    'd', 'o', 'x' => {
                        const base: u8 = if (n == 'd') 10 else if (n == 'o') 8 else 16;
                        const maxd: usize = if (n == 'x') 2 else 3;
                        var v: u32 = 0;
                        var k: usize = 0;
                        while (k < maxd) : (k += 1) {
                            const d = p.peek() orelse break;
                            const dv = std.fmt.charToDigit(d, base) catch break;
                            v = v * base + dv;
                            _ = p.get();
                        }
                        if (k == 0) try buf.append(s.arena, n) else try buf.append(s.arena, @truncate(v));
                    },
                    else => try buf.append(s.arena, n),
                }
                continue;
            }
            try buf.append(s.arena, c);
        }
        try buf.append(s.arena, '\n');
        return buf.items;
    }

    fn parseSubst(p: *Parser, cmd: *Cmd) ParseError!void {
        const s = p.s;
        const delim = p.get() orelse return p.fail("unterminated `s' command", .{});
        if (delim == '\n' or delim == '\\') return p.fail("unterminated `s' command", .{});
        const pat = (try p.matchSlash(delim, true)) orelse return p.fail("unterminated `s' command", .{});
        const rep = (try p.matchSlash(delim, false)) orelse return p.fail("unterminated `s' command", .{});
        const sub = try s.arena.create(Subst);
        sub.* = .{ .re = null, .parts = &.{} };
        var icase = false;
        var mline = false;
        var seen_num = false;
        var seen_p = false;
        flags: while (true) {
            const f = p.get() orelse break;
            switch (f) {
                'i', 'I' => icase = true,
                'm', 'M' => mline = true,
                'e' => {
                    if (s.opts.sandbox) return p.fail("e/r/w commands disabled in sandbox mode", .{});
                    sub.eval = true;
                },
                'p' => {
                    if (seen_p) return p.fail("multiple `p' options to `s' command", .{});
                    seen_p = true;
                    sub.print = 1;
                },
                'g' => {
                    if (sub.global) return p.fail("multiple `g' options to `s' command", .{});
                    sub.global = true;
                },
                'w' => {
                    if (s.opts.sandbox) return p.fail("e/r/w commands disabled in sandbox mode", .{});
                    const name = try p.readFilename();
                    sub.wfile = try p.openOut(name);
                    break :flags;
                },
                '0'...'9' => {
                    if (seen_num) return p.fail("multiple number options to `s' command", .{});
                    const n = p.readNumber(f);
                    if (n == 0) return p.fail("number option to `s' command may not be zero", .{});
                    seen_num = true;
                    sub.number = n;
                },
                '}', '#' => {
                    p.unget();
                    break :flags;
                },
                '\n', ';' => break :flags,
                ' ', '\t', '\r' => {},
                else => return p.fail("unknown option to `s'", .{}),
            }
        }
        if (pat.len == 0 and (icase or mline)) return p.fail("cannot specify modifiers on empty regexp", .{});
        sub.re = try p.compileRe(pat, icase, mline);
        if (sub.re) |r| s.last_re = r;
        sub.parts = try p.parseReplacement(rep, sub);
        if (sub.re) |r| {
            if (sub.max_group > r.groups) {
                return p.fail("invalid reference \\{d} on `s' command's RHS", .{sub.max_group});
            }
        }
        cmd.sub = sub;
    }

    fn parseReplacement(p: *Parser, rep: []const u8, sub: *Subst) ParseError![]Part {
        const s = p.s;
        var parts: std.ArrayList(Part) = .empty;
        var lit: std.ArrayList(u8) = .empty;
        var pending_case: u8 = 0;
        const flush = struct {
            fn go(ps: *std.ArrayList(Part), l: *std.ArrayList(u8), a: std.mem.Allocator, case: *u8) !void {
                if (l.items.len > 0 or case.* != 0) {
                    try ps.append(a, .{ .lit = try l.toOwnedSlice(a), .case_op = case.* });
                    case.* = 0;
                }
            }
        }.go;
        var i: usize = 0;
        while (i < rep.len) {
            const c = rep[i];
            if (c == '&') {
                try flush(&parts, &lit, s.arena, &pending_case);
                try parts.append(s.arena, .{ .group = 0 });
                i += 1;
                continue;
            }
            if (c == '\\' and i + 1 < rep.len) {
                const n = rep[i + 1];
                i += 2;
                switch (n) {
                    '0'...'9' => {
                        try flush(&parts, &lit, s.arena, &pending_case);
                        try parts.append(s.arena, .{ .group = n - '0' });
                        if (n - '0' > sub.max_group) sub.max_group = n - '0';
                    },
                    'U', 'L', 'E', 'u', 'l' => {
                        try flush(&parts, &lit, s.arena, &pending_case);
                        pending_case = n;
                    },
                    'n' => try lit.append(s.arena, '\n'),
                    '\n' => try lit.append(s.arena, '\n'),
                    'a' => try lit.append(s.arena, 7),
                    'f' => try lit.append(s.arena, 12),
                    'r' => try lit.append(s.arena, '\r'),
                    't' => try lit.append(s.arena, '\t'),
                    'v' => try lit.append(s.arena, 11),
                    'c' => {
                        if (i < rep.len) {
                            const x = rep[i];
                            i += 1;
                            try lit.append(s.arena, std.ascii.toUpper(x) ^ 0x40);
                        }
                    },
                    'd', 'o', 'x' => {
                        const base: u8 = if (n == 'd') 10 else if (n == 'o') 8 else 16;
                        const maxd: usize = if (n == 'x') 2 else 3;
                        var v: u32 = 0;
                        var k: usize = 0;
                        while (k < maxd and i < rep.len) : (k += 1) {
                            const dv = std.fmt.charToDigit(rep[i], base) catch break;
                            v = v * base + dv;
                            i += 1;
                        }
                        if (k == 0) try lit.append(s.arena, n) else try lit.append(s.arena, @truncate(v));
                    },
                    else => try lit.append(s.arena, n),
                }
                continue;
            }
            try lit.append(s.arena, c);
            i += 1;
        }
        try flush(&parts, &lit, s.arena, &pending_case);
        return parts.items;
    }

    fn parseY(p: *Parser, cmd: *Cmd) ParseError!void {
        const s = p.s;
        const delim = p.get() orelse return p.fail("unterminated `y' command", .{});
        const a = (try p.matchSlash(delim, false)) orelse return p.fail("unterminated `y' command", .{});
        const b = (try p.matchSlash(delim, false)) orelse return p.fail("unterminated `y' command", .{});
        const src = try yUnescape(p, s.arena, a);
        const dst = try yUnescape(p, s.arena, b);
        if (src.len != dst.len) return p.fail("strings for `y' command are different lengths", .{});
        const t = try s.arena.create([256]u8);
        for (t, 0..) |*x, i| x.* = @intCast(i);
        var i: usize = src.len;
        while (i > 0) {
            i -= 1;
            t[src[i]] = dst[i];
        }
        cmd.ytab = t;
        try p.endOfCmd();
    }

    fn yUnescape(p: *Parser, a: std.mem.Allocator, raw: []const u8) ParseError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\' and i + 1 < raw.len) {
                const n = raw[i + 1];
                i += 2;
                switch (n) {
                    '\\' => try out.append(a, '\\'),
                    'n' => try out.append(a, '\n'),
                    '\n' => try out.append(a, '\n'),
                    't' => try out.append(a, '\t'),
                    'a' => try out.append(a, 7),
                    'f' => try out.append(a, 12),
                    'r' => try out.append(a, '\r'),
                    'v' => try out.append(a, 11),
                    else => {
                        // "\" followed by the delimiter was already reduced by matchSlash.
                        return p.fail("unknown command: `{c}'", .{n});
                    },
                }
                continue;
            }
            try out.append(a, c);
            i += 1;
        }
        return out.items;
    }

    fn parseChunk(p: *Parser) ParseError!void {
        const s = p.s;
        while (true) {
            var c = p.skipSpace() orelse break;
            while (c == ';') c = p.skipSpace() orelse return;
            var cmd = Cmd{};
            // addresses
            if (try p.readAddr(c, false)) |a1| {
                cmd.a1 = a1;
                var nc = p.skipBlank() orelse return p.fail("missing command", .{});
                if (nc == ',') {
                    const x = p.skipBlank() orelse return p.fail("unexpected `,'", .{});
                    const a2 = (try p.readAddr(x, true)) orelse return p.fail("unexpected `,'", .{});
                    cmd.a2 = a2;
                    nc = p.skipBlank() orelse return p.fail("missing command", .{});
                }
                c = nc;
                if (cmd.a1.kind == .zero) {
                    if (cmd.a2.kind != .re) return p.fail("invalid usage of line address 0", .{});
                    cmd.range_active = true;
                }
            }
            if (c == '!') {
                cmd.negate = true;
                c = p.skipBlank() orelse return p.fail("missing command", .{});
                while (c == '!') {
                    return p.fail("multiple `!'s", .{});
                }
            }
            cmd.c = c;
            switch (c) {
                '#' => {
                    if (cmd.a1.kind != .none) return p.fail("comments don't accept any addresses", .{});
                    // Special first line "#n".
                    if (s.ci == 0 and s.pos == 1 and !s.opts.posix) {
                        const t = p.chunk().text;
                        if (t.len >= 2 and t[1] == 'n') s.opts.quiet = true;
                    }
                    while (p.get()) |x| {
                        if (x == '\n') break;
                    }
                    continue;
                },
                '{' => {
                    try s.blocks.append(s.arena, s.cmds.items.len);
                    try s.cmds.append(s.arena, cmd);
                    continue;
                },
                '}' => {
                    if (cmd.a1.kind != .none) return p.fail("}} doesn't want any addresses", .{});
                    const open = s.blocks.pop() orelse return p.fail("unexpected `}}'", .{});
                    s.cmds.items[open].jump = s.cmds.items.len;
                    try s.cmds.append(s.arena, cmd);
                    try p.endOfCmd();
                    continue;
                },
                ':' => {
                    if (cmd.a1.kind != .none) return p.fail(": doesn't want any addresses", .{});
                    const label = p.readLabel(true);
                    if (label.len == 0) return p.fail("\":\" lacks a label", .{});
                    try s.labels.append(s.arena, .{ .name = label, .idx = s.cmds.items.len });
                    cmd.text = label;
                    try s.cmds.append(s.arena, cmd);
                    continue;
                },
                'a', 'i', 'c' => {
                    if (c == 'i' and cmd.a2.kind != .none and s.opts.posix) return p.fail("command only uses one address", .{});
                    cmd.text = try p.readText();
                },
                '=', 'd', 'D', 'F', 'g', 'G', 'h', 'H', 'n', 'N', 'p', 'P', 'x', 'z' => {
                    try p.endOfCmd();
                },
                'e' => {
                    if (s.opts.sandbox) return p.fail("e/r/w commands disabled in sandbox mode", .{});
                    if (p.skipBlank() != null) p.unget();
                    const t = p.chunk().text;
                    const st = s.pos;
                    var i = st;
                    while (i < t.len and t[i] != '\n') : (i += 1) {}
                    s.pos = i;
                    cmd.text = t[st..i];
                },
                'l', 'L', 'q', 'Q' => {
                    if ((c == 'q' or c == 'Q') and cmd.a2.kind != .none) return p.fail("command only uses one address", .{});
                    const x = p.skipBlank();
                    if (x) |d| {
                        if (std.ascii.isDigit(d)) {
                            cmd.int = @intCast(p.readNumber(d));
                        } else p.unget();
                    }
                    try p.endOfCmd();
                },
                'r', 'R', 'w', 'W' => {
                    if (s.opts.sandbox) return p.fail("e/r/w commands disabled in sandbox mode", .{});
                    const name = try p.readFilename();
                    cmd.text = name;
                    if (c == 'w' or c == 'W') cmd.out = try p.openOut(name);
                },
                'b', 't', 'T' => {
                    cmd.text = p.readLabel(true);
                    try p.endOfCmd();
                },
                's' => {
                    try p.parseSubst(&cmd);
                },
                'y' => try p.parseY(&cmd),
                'v' => {
                    const ver = p.readLabel(true);
                    var parts = std.mem.splitScalar(u8, ver, '.');
                    var have = [3]u32{ 0, 0, 0 };
                    var k: usize = 0;
                    while (parts.next()) |part| : (k += 1) {
                        if (k >= 3) break;
                        have[k] = std.fmt.parseInt(u32, part, 10) catch 0;
                    }
                    const want = [3]u32{ 4, 9, 0 };
                    if (ver.len > 0 and std.mem.order(u32, &have, &want) == .gt) return p.fail("expected newer version of sed", .{});
                    try p.endOfCmd();
                    continue;
                },
                else => return p.fail("unknown command: `{c}'", .{c}),
            }
            if (cmd.a2.kind != .none and (c == '=' and false)) {}
            if ((c == ':' or c == '}' or c == '#') and cmd.a1.kind != .none) unreachable;
            try s.cmds.append(s.arena, cmd);
        }
    }
};

/// Expand sed's own escapes (\t \f \v \a \cX \dNNN \oNNN \xHH) in a regex or
/// leave the text alone otherwise.
fn convertEscapes(a: std.mem.Allocator, pat: []const u8, is_re: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_br = false;
    while (i < pat.len) {
        const c = pat[i];
        if (is_re and !in_br and c == '[') {
            in_br = true;
            try out.append(a, c);
            i += 1;
            if (i < pat.len and pat[i] == '^') {
                try out.append(a, '^');
                i += 1;
            }
            if (i < pat.len and pat[i] == ']') {
                try out.append(a, ']');
                i += 1;
            }
            continue;
        }
        if (in_br) {
            if (c == '[' and i + 1 < pat.len and (pat[i + 1] == ':' or pat[i + 1] == '.' or pat[i + 1] == '=')) {
                const kind = pat[i + 1];
                var j = i + 2;
                while (j + 1 < pat.len and !(pat[j] == kind and pat[j + 1] == ']')) : (j += 1) {}
                if (j + 1 < pat.len) {
                    try out.appendSlice(a, pat[i .. j + 2]);
                    i = j + 2;
                    continue;
                }
            }
            if (c == ']') in_br = false;
            if (c == '\\' and i + 1 < pat.len) {
                const n = pat[i + 1];
                const ch: ?u8 = switch (n) {
                    't' => '\t',
                    'f' => 12,
                    'v' => 11,
                    'a' => 7,
                    'r' => '\r',
                    else => null,
                };
                if (ch) |x| {
                    try out.append(a, x);
                    i += 2;
                    continue;
                }
            }
            try out.append(a, c);
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 < pat.len) {
            const n = pat[i + 1];
            var produced: ?u8 = null;
            var used: usize = 2;
            switch (n) {
                't' => produced = '\t',
                'f' => produced = 12,
                'v' => produced = 11,
                'a' => produced = 7,
                'r' => produced = '\r',
                'c' => if (i + 2 < pat.len) {
                    produced = std.ascii.toUpper(pat[i + 2]) ^ 0x40;
                    used = 3;
                },
                'd', 'o', 'x' => {
                    const base: u8 = if (n == 'd') 10 else if (n == 'o') 8 else 16;
                    const maxd: usize = if (n == 'x') 2 else 3;
                    var v: u32 = 0;
                    var k: usize = 0;
                    while (k < maxd and i + 2 + k < pat.len) : (k += 1) {
                        const dv = std.fmt.charToDigit(pat[i + 2 + k], base) catch break;
                        v = v * base + dv;
                    }
                    if (k > 0) {
                        produced = @truncate(v);
                        used = 2 + k;
                    }
                },
                else => {},
            }
            if (produced) |x| {
                if (std.mem.indexOfScalar(u8, "^$.*[]\\+?(){}|/", x) != null) try out.append(a, '\\');
                try out.append(a, x);
                i += used;
                continue;
            }
            try out.append(a, c);
            try out.append(a, n);
            i += 2;
            continue;
        }
        try out.append(a, c);
        i += 1;
    }
    return out.items;
}

// -------------------------------------------------------------- executor

const Input = struct {
    files: []const []const u8,
    next_file: usize = 0,
    data: []const u8 = &.{},
    pos: usize = 0,
    name: []const u8 = "-",
    opened: bool = false,
    line_no: u64 = 0,
    pre: ?[]const u8 = null,
    pre_idx: usize = 0,
};

const Exec = struct {
    s: *State,
    gpa: std.mem.Allocator,
    in: Input,
    ps: std.ArrayList(u8) = .empty,
    hs: std.ArrayList(u8) = .empty,
    ps_chomped: bool = true,
    hs_chomped: bool = true,
    append_q: std.ArrayList(struct { kind: u8, text: []const u8 }) = .empty,
    replaced: bool = false,
    replaced_t: bool = false,
    skip_read: bool = false,
    quit: bool = false,
    cur_out: *Output,
    delim: u8 = '\n',
    in_place_tmp: ?[]const u8 = null,
    in_place_target: []const u8 = "",
    stdout_o: *Output,
    last_re: ?*Re = null,
    r_files: std.ArrayList(struct { name: []const u8, data: []const u8, pos: usize }) = .empty,
    searcher_cache: ?struct { re: *Re, sr: regex.Searcher } = null,

    fn flushOut(e: *Exec, o: *Output) void {
        if (o.buf.items.len == 0) return;
        if (sys.writeAllFd(o.fd, o.buf.items)) |err| {
            if (err != .PIPE) {
                cli.warn(e.s.ctx, "couldn't write {d} items to {s}: {s}", .{ o.buf.items.len, if (o.fd == 1) "stdout" else o.path, errnoMsg(err) });
                std.process.exit(4);
            }
            std.process.exit(4);
        }
        o.buf.clearRetainingCapacity();
    }

    fn flushAll(e: *Exec) void {
        e.flushOut(e.stdout_o);
        for (e.s.outs.items) |o| e.flushOut(o);
    }

    fn emit(e: *Exec, out: *Output, bytes: []const u8) void {
        const o = out.sink orelse out;
        o.buf.appendSlice(e.gpa, bytes) catch oom(e.s.ctx);
        if (o.buf.items.len > 65536 or e.s.opts.unbuffered or o.fd == 2) e.flushOut(o);
    }

    fn missingNl(e: *Exec, o: *Output) void {
        if (o.missing_nl) {
            e.emit(o, &.{e.delim});
            o.missing_nl = false;
        }
    }

    fn writeLine(e: *Exec, o: *Output, text: []const u8, nl: bool) void {
        e.missingNl(o);
        e.emit(o, text);
        if (nl) e.emit(o, &.{e.delim}) else o.missing_nl = true;
    }

    // ---- input

    fn openNext(e: *Exec) bool {
        const in = &e.in;
        while (true) {
            if (in.next_file >= in.files.len) return false;
            const name = in.files[in.next_file];
            in.next_file += 1;
            var data: std.ArrayList(u8) = .empty;
            if (in.pre != null and in.pre_idx == in.next_file - 1) {
                data.appendSlice(e.gpa, in.pre.?) catch oom(e.s.ctx);
                in.pre = null;
                in.name = name;
            } else if (std.mem.eql(u8, name, "-") and !e.s.opts.in_place) {
                if (!e.readAll(0, &data, name)) continue;
                in.name = "-";
            } else {
                var err: LX.E = .SUCCESS;
                const fd = sys.openFd(name, sys.O.RDONLY, 0, &err) orelse {
                    cli.warn(e.s.ctx, "can't read {s}: {s}", .{ name, errnoMsg(err) });
                    e.s.exit_code = 2;
                    continue;
                };
                defer _ = sys.closeFd(fd);
                if (e.s.opts.in_place) {
                    var serr: LX.E = .SUCCESS;
                    const st = sys.fstatFd(fd, &serr);
                    if (st == null or !st.?.isReg()) {
                        cli.warn(e.s.ctx, "couldn't edit {s}: not a regular file", .{name});
                        e.s.exit_code = 4;
                        continue;
                    }
                }
                if (!e.readAll(fd, &data, name)) continue;
                in.name = name;
            }
            in.data = data.items;
            in.pos = 0;
            in.opened = true;
            if (e.s.opts.separate) {
                in.line_no = 0;
                e.resetRanges();
            }
            if (e.s.opts.in_place) {
                if (!e.beginInPlace(if (e.s.opts.follow) e.resolveLink(name) else name)) {
                    in.data = &.{};
                    continue;
                }
            }
            return true;
        }
    }

    fn readAll(e: *Exec, fd: i32, data: *std.ArrayList(u8), name: []const u8) bool {
        var buf: [65536]u8 = undefined;
        while (true) {
            var err: LX.E = .SUCCESS;
            const n = sys.readFd(fd, &buf, &err) orelse {
                cli.warn(e.s.ctx, "read error on {s}: {s}", .{ name, errnoMsg(err) });
                e.flushAll();
                std.process.exit(4);
            };
            if (n == 0) break;
            data.appendSlice(e.gpa, buf[0..n]) catch oom(e.s.ctx);
        }
        return true;
    }

    fn resetRanges(e: *Exec) void {
        for (e.s.cmds.items) |*c| {
            c.range_active = c.a1.kind == .zero;
            c.range_closed = false;
        }
    }

    fn beginInPlace(e: *Exec, name: []const u8) bool {
        const dir_end = std.mem.lastIndexOfScalar(u8, name, '/');
        const dir = if (dir_end) |d| name[0 .. d + 1] else "./";
        var err: LX.E = .SUCCESS;
        const pid: u32 = @intCast(LX.getpid());
        var attempt: u32 = 0;
        while (attempt < 100) : (attempt += 1) {
            const tmp = std.fmt.allocPrint(e.gpa, "{s}sed{x:0>6}", .{ dir, (pid *% 2654435761 +% attempt *% 40503) & 0xffffff }) catch oom(e.s.ctx);
            const fd = sys.openFd(tmp, sys.O.WRONLY | sys.O.CREAT | sys.O.EXCL, 0o600, &err) orelse {
                if (err == .EXIST) continue;
                cli.warn(e.s.ctx, "couldn't open temporary file {s}: {s}", .{ tmp, errnoMsg(err) });
                e.s.exit_code = 4;
                return false;
            };
            const o = e.gpa.create(Output) catch oom(e.s.ctx);
            o.* = .{ .fd = fd, .path = tmp };
            e.cur_out = o;
            e.in_place_tmp = tmp;
            e.in_place_target = name;
            return true;
        }
        return false;
    }

    fn resolveLink(e: *Exec, name: []const u8) []const u8 {
        var cur = name;
        var n: usize = 0;
        while (n < 40) : (n += 1) {
            var buf: [4096]u8 = undefined;
            var err: LX.E = .SUCCESS;
            const len = sys.readlinkPath(cur, &buf, &err) orelse return cur;
            const tgt = buf[0..len];
            if (tgt.len > 0 and tgt[0] == '/') {
                cur = e.gpa.dupe(u8, tgt) catch oom(e.s.ctx);
            } else {
                const slash = std.mem.lastIndexOfScalar(u8, cur, '/');
                cur = if (slash) |sl|
                    std.fmt.allocPrint(e.gpa, "{s}{s}", .{ cur[0 .. sl + 1], tgt }) catch oom(e.s.ctx)
                else
                    e.gpa.dupe(u8, tgt) catch oom(e.s.ctx);
            }
        }
        return cur;
    }

    fn finishInPlace(e: *Exec) void {
        const tmp = e.in_place_tmp orelse return;
        const o = e.cur_out;
        e.flushOut(o);
        // copy mode and owner from the original
        var serr: LX.E = .SUCCESS;
        var ofd: i32 = -1;
        if (sys.openFd(e.in_place_target, sys.O.RDONLY, 0, &serr)) |f| ofd = f;
        if (ofd >= 0) {
            if (sys.fstatFd(ofd, &serr)) |st| {
                _ = sys.fchmodFd(o.fd, st.mode & 0o7777);
                _ = sys.fchownFd(o.fd, st.uid, st.gid);
            }
            _ = sys.closeFd(ofd);
        }
        _ = sys.closeFd(o.fd);
        if (e.s.opts.suffix) |suf| {
            const name = e.in_place_target;
            const slash = std.mem.lastIndexOfScalar(u8, name, '/');
            const base = if (slash) |sl| name[sl + 1 ..] else name;
            const dir = if (slash) |sl| name[0 .. sl + 1] else "";
            var bk: std.ArrayList(u8) = .empty;
            if (std.mem.indexOfScalar(u8, suf, '*') != null) {
                for (suf) |ch| {
                    if (ch == '*') bk.appendSlice(e.gpa, base) catch oom(e.s.ctx) else bk.append(e.gpa, ch) catch oom(e.s.ctx);
                }
            } else {
                bk.appendSlice(e.gpa, base) catch oom(e.s.ctx);
                bk.appendSlice(e.gpa, suf) catch oom(e.s.ctx);
            }
            const full = if (std.mem.indexOfScalar(u8, bk.items, '/') != null)
                bk.items
            else
                std.fmt.allocPrint(e.gpa, "{s}{s}", .{ dir, bk.items }) catch oom(e.s.ctx);
            if (sys.renamePath(name, full, 0)) |er| {
                cli.warn(e.s.ctx, "cannot rename {s}: {s}", .{ name, errnoMsg(er) });
                e.s.exit_code = 4;
            }
        }
        if (sys.renamePath(tmp, e.in_place_target, 0)) |er| {
            cli.warn(e.s.ctx, "cannot rename {s}: {s}", .{ tmp, errnoMsg(er) });
            e.s.exit_code = 4;
            _ = sys.unlinkPath(tmp, false);
        }
        e.in_place_tmp = null;
        e.cur_out = e.stdout_o;
    }

    /// True when the current file (and, unless separate, all later ones) has
    /// no more lines.
    fn atEof(e: *Exec) bool {
        const in = &e.in;
        if (in.pos < in.data.len) return false;
        if (e.s.opts.separate) return true;
        // look ahead: skip to the next file with data without finishing this one
        while (in.next_file < in.files.len) {
            const name = in.files[in.next_file];
            var data: std.ArrayList(u8) = .empty;
            if (std.mem.eql(u8, name, "-")) {
                if (!e.readAll(0, &data, name)) {
                    in.next_file += 1;
                    continue;
                }
            } else {
                var err: LX.E = .SUCCESS;
                const fd = sys.openFd(name, sys.O.RDONLY, 0, &err) orelse {
                    cli.warn(e.s.ctx, "can't read {s}: {s}", .{ name, errnoMsg(err) });
                    e.s.exit_code = 2;
                    in.next_file += 1;
                    continue;
                };
                defer _ = sys.closeFd(fd);
                if (!e.readAll(fd, &data, name)) {
                    in.next_file += 1;
                    continue;
                }
            }
            if (data.items.len == 0) {
                in.next_file += 1;
                continue;
            }
            in.pre = data.items;
            in.pre_idx = in.next_file;
            return false;
        }
        return true;
    }

    fn readLine(e: *Exec) bool {
        const in = &e.in;
        while (in.pos >= in.data.len) {
            if (e.s.opts.in_place and e.in_place_tmp != null) e.finishInPlace();
            if (!e.openNext()) return false;
        }
        const rest = in.data[in.pos..];
        if (std.mem.indexOfScalar(u8, rest, e.delim)) |i| {
            e.ps.clearRetainingCapacity();
            e.ps.appendSlice(e.gpa, rest[0..i]) catch oom(e.s.ctx);
            in.pos += i + 1;
            e.ps_chomped = true;
        } else {
            e.ps.clearRetainingCapacity();
            e.ps.appendSlice(e.gpa, rest) catch oom(e.s.ctx);
            in.pos = in.data.len;
            e.ps_chomped = false;
        }
        in.line_no += 1;
        return true;
    }

    fn readPatternSpace(e: *Exec) bool {
        e.dumpAppend();
        e.replaced_t = false;
        return e.readLine();
    }

    fn dumpAppend(e: *Exec) void {
        for (e.append_q.items) |a| {
            switch (a.kind) {
                'a' => {
                    e.missingNl(e.cur_out);
                    e.emit(e.cur_out, a.text);
                },
                'r' => {
                    e.missingNl(e.cur_out);
                    var data: std.ArrayList(u8) = .empty;
                    if (std.mem.eql(u8, a.text, "/dev/stdin")) {
                        _ = e.readAll(0, &data, a.text);
                    } else {
                        var err: LX.E = .SUCCESS;
                        if (sys.openFd(a.text, sys.O.RDONLY, 0, &err)) |fd| {
                            defer _ = sys.closeFd(fd);
                            _ = e.readAll(fd, &data, a.text);
                        }
                    }
                    e.emit(e.cur_out, data.items);
                },
                'R' => {
                    e.missingNl(e.cur_out);
                    e.emit(e.cur_out, a.text);
                    e.emit(e.cur_out, &.{'\n'});
                },
                else => {},
            }
        }
        e.append_q.clearRetainingCapacity();
    }

    // ---- matching

    fn getSearcher(e: *Exec, re: *Re) *regex.Searcher {
        if (e.searcher_cache) |*c| {
            if (c.re == re) return &c.sr;
            c.sr.deinit();
            e.searcher_cache = null;
        }
        const sr = re.re.searcher(e.gpa) catch oom(e.s.ctx);
        e.searcher_cache = .{ .re = re, .sr = sr };
        return &e.searcher_cache.?.sr;
    }

    fn resolveRe(e: *Exec, r: ?*Re) ?*Re {
        if (r) |x| {
            e.last_re = x;
            return x;
        }
        if (e.last_re == null) {
            e.flushAll();
            const ch = e.s.chunks[0];
            if (ch.is_file) cli.warn(e.s.ctx, "file {s} line 1: no previous regular expression", .{ch.name}) else cli.warn(e.s.ctx, "-e expression #{d}, char 0: no previous regular expression", .{ch.index});
            std.process.exit(1);
        }
        return e.last_re;
    }

    fn reMatch(e: *Exec, r: ?*Re, subject: []const u8, from: usize) ?regex.Match {
        const re = e.resolveRe(r).?;
        const sr = e.getSearcher(re);
        return (sr.find(subject, from) catch null);
    }

    fn matchAddr(e: *Exec, a: Addr) bool {
        switch (a.kind) {
            .none => return true,
            .line => return e.in.line_no == a.n,
            .step => {
                const l = e.in.line_no;
                if (a.step == 0) return l == a.n;
                return l >= a.n and (l - a.n) % a.step == 0;
            },
            .last => return e.atEof(),
            .re => return e.reMatch(a.re, e.ps.items, 0) != null,
            .zero, .plus, .mult => return false,
        }
    }

    fn matchCmd(e: *Exec, c: *Cmd) bool {
        const l = e.in.line_no;
        if (c.a1.kind == .none) return true;
        if (c.a2.kind == .none) return e.matchAddr(c.a1);
        if (c.range_active) {
            switch (c.a2.kind) {
                .line, .plus, .mult => {
                    if (l >= c.range_end) c.range_active = false;
                    if (l > c.range_end) {
                        // end line already passed: this line does not match
                        return false;
                    }
                    return true;
                },
                else => {
                    if (e.matchAddr(c.a2)) c.range_active = false;
                    return true;
                },
            }
        }
        if (c.a1.kind == .line and c.range_closed) return false;
        if (!e.matchAddr(c.a1)) return false;
        // a1 matched: start the range
        switch (c.a2.kind) {
            .line => {
                if (c.a2.n <= l) {
                    c.range_closed = c.a1.kind == .line;
                    return true;
                }
                c.range_end = c.a2.n;
            },
            .plus => {
                if (c.a2.n == 0) return true;
                c.range_end = l + c.a2.n;
            },
            .mult => {
                if (c.a2.n == 0) return true;
                c.range_end = (l / c.a2.n + 1) * c.a2.n;
            },
            else => {},
        }
        c.range_active = true;
        return true;
    }

    // ---- commands

    fn autoprint(e: *Exec) void {
        if (!e.s.opts.quiet) e.writeLine(e.cur_out, e.ps.items, e.ps_chomped);
    }

    fn doList(e: *Exec, width_arg: i64) void {
        const w: i64 = if (width_arg >= 0) width_arg else e.s.opts.line_len;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(e.gpa);
        var col: i64 = 0;
        var buf: [8]u8 = undefined;
        for (e.ps.items) |ch| {
            const rep: []const u8 = switch (ch) {
                '\\' => "\\\\",
                7 => "\\a",
                8 => "\\b",
                12 => "\\f",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                11 => "\\v",
                else => blk: {
                    if (ch >= 0x20 and ch < 0x7f) {
                        buf[0] = ch;
                        break :blk buf[0..1];
                    }
                    break :blk std.fmt.bufPrint(&buf, "\\{o:0>3}", .{ch}) catch unreachable;
                },
            };
            if (w > 0 and col + @as(i64, @intCast(rep.len)) > w - 1) {
                out.appendSlice(e.gpa, "\\\n") catch oom(e.s.ctx);
                col = 0;
            }
            out.appendSlice(e.gpa, rep) catch oom(e.s.ctx);
            col += @intCast(rep.len);
        }
        out.appendSlice(e.gpa, "$") catch oom(e.s.ctx);
        out.append(e.gpa, e.delim) catch oom(e.s.ctx);
        e.missingNl(e.cur_out);
        e.emit(e.cur_out, out.items);
    }

    fn appendCase(e: *Exec, dst: *std.ArrayList(u8), text: []const u8, persist: u8, oneshot: *u8) void {
        for (text) |ch| {
            var x = ch;
            if (oneshot.* != 0) {
                x = if (oneshot.* == 'u') std.ascii.toUpper(x) else std.ascii.toLower(x);
                oneshot.* = 0;
            } else if (persist == 'U') x = std.ascii.toUpper(x) else if (persist == 'L') x = std.ascii.toLower(x);
            dst.append(e.gpa, x) catch oom(e.s.ctx);
        }
    }

    fn doSubst(e: *Exec, sub: *Subst) bool {
        const subj = e.ps.items;
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(e.gpa);
        var start: usize = 0;
        var count: u64 = 0;
        var did = false;
        var prev_end: ?usize = null;
        while (start <= subj.len) {
            const m = e.reMatch(sub.re, subj, start) orelse break;
            const ms = m.start();
            const me = m.end();
            if (me == ms and prev_end != null and prev_end.? == ms) {
                // an empty match right after the previous match does not count
                if (ms >= subj.len) break;
                acc.appendSlice(e.gpa, subj[start..ms]) catch oom(e.s.ctx);
                acc.append(e.gpa, subj[ms]) catch oom(e.s.ctx);
                start = ms + 1;
                prev_end = null;
                continue;
            }
            acc.appendSlice(e.gpa, subj[start..ms]) catch oom(e.s.ctx);
            count += 1;
            if (count < sub.number) {
                acc.appendSlice(e.gpa, subj[ms..me]) catch oom(e.s.ctx);
            } else {
                did = true;
                var persist: u8 = 0;
                var oneshot: u8 = 0;
                for (sub.parts) |part| {
                    switch (part.case_op) {
                        'U', 'L' => {
                            persist = part.case_op;
                            oneshot = 0;
                        },
                        'E' => {
                            persist = 0;
                            oneshot = 0;
                        },
                        'u', 'l' => oneshot = part.case_op,
                        else => {},
                    }
                    e.appendCase(&acc, part.lit, persist, &oneshot);
                    if (part.group >= 0) {
                        if (m.group(@intCast(part.group))) |g| {
                            e.appendCase(&acc, subj[g[0]..g[1]], persist, &oneshot);
                        }
                    }
                }
                if (!sub.global) {
                    start = me;
                    prev_end = me;
                    break;
                }
            }
            prev_end = me;
            if (me == ms) {
                if (ms < subj.len) acc.append(e.gpa, subj[ms]) catch oom(e.s.ctx);
                start = ms + 1;
                prev_end = null;
            } else start = me;
        }
        if (!did) return false;
        if (start < subj.len) acc.appendSlice(e.gpa, subj[start..]) catch oom(e.s.ctx);
        e.ps.clearRetainingCapacity();
        e.ps.appendSlice(e.gpa, acc.items) catch oom(e.s.ctx);
        return true;
    }

    fn runShell(e: *Exec, command: []const u8) []u8 {
        e.flushAll();
        var tmpl: [64]u8 = undefined;
        const pid: u32 = @intCast(LX.getpid());
        const outp = std.fmt.bufPrint(&tmpl, "/tmp/.sed-e-{d}", .{pid}) catch unreachable;
        const sh = std.fmt.allocPrint(e.gpa, "( {s} ) > {s}", .{ command, outp }) catch oom(e.s.ctx);
        defer e.gpa.free(sh);
        const child = std.process.spawn(e.s.ctx.io, .{ .argv = &.{ "/bin/sh", "-c", sh } }) catch return &.{};
        _ = sys.waitPid(@intCast(child.id.?), true);
        var data: std.ArrayList(u8) = .empty;
        var err: LX.E = .SUCCESS;
        if (sys.openFd(outp, sys.O.RDONLY, 0, &err)) |fd| {
            _ = e.readAll(fd, &data, outp);
            _ = sys.closeFd(fd);
        }
        _ = sys.unlinkPath(outp, false);
        return data.items;
    }

    /// Run the script once on the current pattern space. Returns true to quit.
    fn execute(e: *Exec) bool {
        const cmds = e.s.cmds.items;
        var pc: usize = 0;
        var replaced_flag = false;
        _ = &replaced_flag;
        while (pc < cmds.len) {
            const c = &cmds[pc];
            const matched = e.matchCmd(c) != c.negate;
            if (!matched) {
                if (c.c == '{') pc = c.jump + 1 else pc += 1;
                continue;
            }
            pc += 1;
            switch (c.c) {
                '{', '}', ':' => {},
                '=' => {
                    e.missingNl(e.cur_out);
                    var b: [32]u8 = undefined;
                    const t = std.fmt.bufPrint(&b, "{d}{c}", .{ e.in.line_no, e.delim }) catch unreachable;
                    e.emit(e.cur_out, t);
                },
                'a' => e.append_q.append(e.gpa, .{ .kind = 'a', .text = c.text }) catch oom(e.s.ctx),
                'i' => {
                    e.missingNl(e.cur_out);
                    e.emit(e.cur_out, c.text);
                },
                'c' => {
                    if (!c.range_active or c.a2.kind == .none) {
                        e.missingNl(e.cur_out);
                        e.emit(e.cur_out, c.text);
                    }
                    if (c.a2.kind != .none and c.range_active and !c.negate) {
                        // delete without printing; text comes at range end
                    }
                    e.ps.clearRetainingCapacity();
                    return false;
                },
                'd' => {
                    e.ps.clearRetainingCapacity();
                    return false;
                },
                'D' => {
                    if (std.mem.indexOfScalar(u8, e.ps.items, e.delim)) |i| {
                        e.ps.replaceRange(e.gpa, 0, i + 1, &.{}) catch oom(e.s.ctx);
                        e.skip_read = true;
                    } else e.ps.clearRetainingCapacity();
                    return false;
                },
                'e' => {
                    if (c.text.len > 0) {
                        const out = e.runShell(c.text);
                        e.missingNl(e.cur_out);
                        e.emit(e.cur_out, out);
                    } else {
                        const out = e.runShell(e.ps.items);
                        e.ps.clearRetainingCapacity();
                        var o = out;
                        if (o.len > 0 and o[o.len - 1] == '\n') o = o[0 .. o.len - 1];
                        e.ps.appendSlice(e.gpa, o) catch oom(e.s.ctx);
                    }
                },
                'F' => {
                    e.missingNl(e.cur_out);
                    e.emit(e.cur_out, e.in.name);
                    e.emit(e.cur_out, "\n");
                },
                'g' => {
                    e.ps.clearRetainingCapacity();
                    e.ps.appendSlice(e.gpa, e.hs.items) catch oom(e.s.ctx);
                    e.ps_chomped = e.hs_chomped;
                },
                'G' => {
                    e.ps.append(e.gpa, e.delim) catch oom(e.s.ctx);
                    e.ps.appendSlice(e.gpa, e.hs.items) catch oom(e.s.ctx);
                    e.ps_chomped = e.hs_chomped;
                },
                'h' => {
                    e.hs.clearRetainingCapacity();
                    e.hs.appendSlice(e.gpa, e.ps.items) catch oom(e.s.ctx);
                    e.hs_chomped = e.ps_chomped;
                },
                'H' => {
                    e.hs.append(e.gpa, e.delim) catch oom(e.s.ctx);
                    e.hs.appendSlice(e.gpa, e.ps.items) catch oom(e.s.ctx);
                    e.hs_chomped = e.ps_chomped;
                },
                'l' => e.doList(c.int),
                'n' => {
                    if (e.atEof()) {
                        e.autoprint();
                        e.quit = true;
                        return true;
                    }
                    e.autoprint();
                    if (!e.readPatternSpace()) return true;
                },
                'N' => {
                    if (e.atEof()) {
                        if (!e.s.opts.posix) e.autoprint();
                        e.quit = true;
                        return true;
                    }
                    e.dumpAppend();
                    const keep = e.gpa.dupe(u8, e.ps.items) catch oom(e.s.ctx);
                    defer e.gpa.free(keep);
                    e.replaced_t = false;
                    if (!e.readLine()) return true;
                    e.ps.insertSlice(e.gpa, 0, &[_]u8{e.delim}) catch oom(e.s.ctx);
                    e.ps.insertSlice(e.gpa, 0, keep) catch oom(e.s.ctx);
                },
                'p' => e.writeLine(e.cur_out, e.ps.items, e.ps_chomped),
                'P' => {
                    const i = std.mem.indexOfScalar(u8, e.ps.items, e.delim);
                    if (i) |k| e.writeLine(e.cur_out, e.ps.items[0..k], true) else e.writeLine(e.cur_out, e.ps.items, e.ps_chomped);
                },
                'q' => {
                    e.autoprint();
                    e.missingNl(e.cur_out);
                    e.dumpAppend();
                    e.s.exit_code = if (c.int >= 0) @intCast(@as(u64, @intCast(c.int)) & 0xff) else e.s.exit_code;
                    return true;
                },
                'Q' => {
                    e.append_q.clearRetainingCapacity();
                    e.s.exit_code = if (c.int >= 0) @intCast(@as(u64, @intCast(c.int)) & 0xff) else e.s.exit_code;
                    return true;
                },
                'r' => e.append_q.append(e.gpa, .{ .kind = 'r', .text = c.text }) catch oom(e.s.ctx),
                'R' => {
                    var found: ?usize = null;
                    for (e.r_files.items, 0..) |rf, k| {
                        if (std.mem.eql(u8, rf.name, c.text)) found = k;
                    }
                    if (found == null) {
                        var data: std.ArrayList(u8) = .empty;
                        var err: LX.E = .SUCCESS;
                        if (sys.openFd(c.text, sys.O.RDONLY, 0, &err)) |fd| {
                            _ = e.readAll(fd, &data, c.text);
                            _ = sys.closeFd(fd);
                        }
                        e.r_files.append(e.gpa, .{ .name = c.text, .data = data.items, .pos = 0 }) catch oom(e.s.ctx);
                        found = e.r_files.items.len - 1;
                    }
                    const rf = &e.r_files.items[found.?];
                    if (rf.pos < rf.data.len) {
                        const rest = rf.data[rf.pos..];
                        const nl = std.mem.indexOfScalar(u8, rest, '\n');
                        const line = if (nl) |k| rest[0..k] else rest;
                        rf.pos += line.len + @as(usize, if (nl != null) 1 else 0);
                        e.append_q.append(e.gpa, .{ .kind = 'R', .text = line }) catch oom(e.s.ctx);
                    }
                },
                's' => {
                    const sub = c.sub.?;
                    if (e.doSubst(sub)) {
                        e.replaced_t = true;
                        if (sub.eval) {
                            const out = e.runShell(e.ps.items);
                            e.ps.clearRetainingCapacity();
                            var o = out;
                            if (o.len > 0 and o[o.len - 1] == '\n') o = o[0 .. o.len - 1];
                            e.ps.appendSlice(e.gpa, o) catch oom(e.s.ctx);
                        }
                        if (sub.print > 0) e.writeLine(e.cur_out, e.ps.items, e.ps_chomped);
                        if (sub.wfile) |w| e.writeLine(e.s.outs.items[w], e.ps.items, e.ps_chomped);
                    }
                },
                'b' => pc = e.target(c),
                't' => {
                    if (e.replaced_t) {
                        e.replaced_t = false;
                        pc = e.target(c);
                    }
                },
                'T' => {
                    if (!e.replaced_t) pc = e.target(c) else e.replaced_t = false;
                },
                'w' => e.writeLine(e.s.outs.items[c.out], e.ps.items, e.ps_chomped),
                'W' => {
                    const o = e.s.outs.items[c.out];
                    const i = std.mem.indexOfScalar(u8, e.ps.items, e.delim);
                    if (i) |k| e.writeLine(o, e.ps.items[0..k], true) else e.writeLine(o, e.ps.items, e.ps_chomped);
                },
                'x' => {
                    std.mem.swap(std.ArrayList(u8), &e.ps, &e.hs);
                    std.mem.swap(bool, &e.ps_chomped, &e.hs_chomped);
                },
                'y' => {
                    const t = c.ytab.?;
                    for (e.ps.items) |*ch| ch.* = t[ch.*];
                },
                'z' => e.ps.clearRetainingCapacity(),
                else => {},
            }
        }
        e.autoprint();
        return false;
    }

    fn target(e: *Exec, c: *Cmd) usize {
        _ = e;
        return c.jump;
    }
};

fn oom(ctx: cli.Context) noreturn {
    cli.warn(ctx, "couldn't allocate memory", .{});
    std.process.exit(4);
}

fn usage(ctx: cli.Context, to_stderr: bool, status: u8) u8 {
    const text = std.mem.replaceOwned(u8, ctx.gpa, help_text, "@NAME@", ctx.name) catch return 4;
    defer ctx.gpa.free(text);
    if (to_stderr) {
        const mail = std.mem.indexOf(u8, text, "E-mail bug reports") orelse text.len;
        _ = sys.writeAllFd(2, text[0..mail]);
    } else if (!cli.writeStdout(ctx.io, text)) return 4;
    return status;
}

pub fn main(ctx: cli.Context) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var st = State{ .ctx = ctx, .arena = arena, .opts = .{} };

    var p = getopt.Parser.init(ctx, "bsnrzuEe:f:l:i::V:", &.{
        .{ .name = "binary", .id = 'b' },
        .{ .name = "regexp-extended", .id = 'E' },
        .{ .name = "debug", .id = 1100 },
        .{ .name = "in-place", .arg = .optional, .id = 'i' },
        .{ .name = "expression", .arg = .required, .id = 'e' },
        .{ .name = "file", .arg = .required, .id = 'f' },
        .{ .name = "line-length", .arg = .required, .id = 'l' },
        .{ .name = "null-data", .id = 'z' },
        .{ .name = "zero-terminated", .id = 'z' },
        .{ .name = "quiet", .id = 'n' },
        .{ .name = "posix", .id = 1101 },
        .{ .name = "silent", .id = 'n' },
        .{ .name = "sandbox", .id = 1102 },
        .{ .name = "separate", .id = 's' },
        .{ .name = "unbuffered", .id = 'u' },
        .{ .name = "follow-symlinks", .id = 1103 },
    });
    defer p.deinit();
    p.no_try = true;
    var chunks: std.ArrayList(Chunk) = .empty;
    var n_e: usize = 0;
    while (true) switch (p.next()) {
        .done => break,
        .bad => return usage(ctx, true, 1),
        .opt => |o| switch (o.id) {
            'n' => st.opts.quiet = true,
            'E', 'r' => st.opts.ere = true,
            's' => st.opts.separate = true,
            'z' => st.opts.null_data = true,
            'u' => st.opts.unbuffered = true,
            'b' => {},
            'i' => {
                st.opts.in_place = true;
                st.opts.separate = true;
                st.opts.suffix = o.arg;
            },
            'l' => {
                var v: i64 = 0;
                for (o.arg.?) |ch| {
                    if (!std.ascii.isDigit(ch)) break;
                    v = v *| 10 +| (ch - '0');
                }
                st.opts.line_len = v;
            },
            'e' => {
                n_e += 1;
                chunks.append(arena, .{ .text = o.arg.?, .is_file = false, .name = "", .index = n_e }) catch return 4;
            },
            'f' => {
                const name = o.arg.?;
                var data: std.ArrayList(u8) = .empty;
                var err: LX.E = .SUCCESS;
                const fd: i32 = if (std.mem.eql(u8, name, "-")) 0 else sys.openFd(name, sys.O.RDONLY, 0, &err) orelse {
                    cli.warn(ctx, "couldn't open file {s}: {s}", .{ name, errnoMsg(err) });
                    return 4;
                };
                var buf: [65536]u8 = undefined;
                while (true) {
                    const n = sys.readFd(fd, &buf, &err) orelse break;
                    if (n == 0) break;
                    data.appendSlice(arena, buf[0..n]) catch return 4;
                }
                if (fd != 0) _ = sys.closeFd(fd);
                var text = data.items;
                if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
                n_e += 1;
                chunks.append(arena, .{ .text = text, .is_file = true, .name = name, .index = n_e }) catch return 4;
            },
            1100 => st.opts.debug = true,
            1101 => st.opts.posix = true,
            1102 => st.opts.sandbox = true,
            1103 => st.opts.follow = true,
            getopt.help_id => return usage(ctx, false, 0),
            getopt.version_id => {
                const v =
                    \\sed (GNU sed) 4.9
                    \\Copyright (C) 2022 Free Software Foundation, Inc.
                    \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
                    \\This is free software: you are free to change and redistribute it.
                    \\There is NO WARRANTY, to the extent permitted by law.
                    \\
                ;
                return if (cli.writeStdout(ctx.io, v)) 0 else 4;
            },
            else => return usage(ctx, true, 1),
        },
    };

    var operands = p.operands.items;
    if (chunks.items.len == 0) {
        if (operands.len == 0) return usage(ctx, true, 1);
        n_e += 1;
        chunks.append(arena, .{ .text = operands[0], .is_file = false, .name = "", .index = 1 }) catch return 4;
        operands = operands[1..];
    }
    st.chunks = chunks.items;
    const stdout_o = arena.create(Output) catch return 4;
    stdout_o.* = .{ .fd = 1, .path = "/dev/stdout", .is_std = true };
    st.stdout_out = stdout_o;

    var parser = Parser{ .s = &st };
    while (st.ci < st.chunks.len) {
        st.pos = 0;
        parser.parseChunk() catch |e| switch (e) {
            error.BadProg => return 1,
            error.OutOfMemory => return 4,
        };
        st.ci += 1;
    }
    st.ci = st.chunks.len -| 1;
    if (st.blocks.items.len > 0) {
        st.pos = 0;
        cli.warn(ctx, "-e expression #{d}, char 0: unmatched `{{'", .{st.chunks[0].index});
        return 1;
    }
    // resolve labels
    for (st.cmds.items) |*c| {
        if (c.c == 'b' or c.c == 't' or c.c == 'T') {
            if (c.text.len == 0) {
                c.jump = st.cmds.items.len;
            } else {
                var found = false;
                for (st.labels.items) |l| {
                    if (std.mem.eql(u8, l.name, c.text)) {
                        c.jump = l.idx;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    cli.warn(ctx, "can't find label for jump to `{s}'", .{c.text});
                    return 4;
                }
            }
        }
    }

    if (st.opts.in_place and operands.len == 0) {
        cli.warn(ctx, "no input files", .{});
        return 4;
    }
    var files: []const []const u8 = operands;
    const dash = [_][]const u8{"-"};
    if (files.len == 0) files = &dash;
    var ex = Exec{
        .s = &st,
        .gpa = std.heap.smp_allocator,
        .in = .{ .files = files },
        .cur_out = stdout_o,
        .stdout_o = stdout_o,
        .delim = if (st.opts.null_data) 0 else '\n',
    };
    ex.resetRanges();
    // stdout shared with `w /dev/stdout`
    for (st.outs.items) |o| {
        if (o.fd == 1) o.sink = stdout_o;
    }

    while (true) {
        if (ex.skip_read) {
            ex.skip_read = false;
            ex.dumpAppend();
        } else if (!ex.readPatternSpace()) break;
        const quit = ex.execute();
        if (quit) {
            ex.dumpAppend();
            break;
        }
        if (ex.skip_read) {
            // D with a newline: restart without reading, but flush appends
            ex.dumpAppend();
        }
    }
    ex.dumpAppend();
    if (ex.in_place_tmp != null) ex.finishInPlace();
    ex.flushAll();
    return st.exit_code;
}
