// SPDX-License-Identifier: GPL-2.0-or-later
//! sed library: stream editor. Reference: GNU sed 4.9 (compile.c, execute.c)
//! and POSIX sed. Regular expressions go through src/posixre.zig (BRE/ERE
//! translated to the regex-zig Perl dialect); `posixre.Finder` gives
//! alternation its POSIX leftmost-longest meaning.
//!
//! Two steps (decision 0004):
//!   - `compile` turns script chunks (-e text, -f file contents) into a
//!     `Program`; a script error comes back as a structured `CompileError`;
//!   - `run` executes a `Program` over `common.Input`s and writes the result to
//!     an `Io.Writer`. One Program can be run many times (not concurrently:
//!     range state lives in the Program).
//!
//! The parser builds a flat command array; the executor runs it over the
//! input files. Input files are read whole into memory.
//!
//! Library-boundary notes: `w FILE` outputs are opened (and truncated) at
//! compile time exactly as GNU does, so a Program owns file descriptors until
//! `deinit`; files, in-place editing (rename/chmod/chown) and the `e` command
//! (runs /bin/sh) use `sys.zig` and `std.process.spawn`.
//!
//! Extensions beyond GNU sed 4.9: none (docs/compatibility/sed.md).

const std = @import("std");
const common = @import("common.zig");
const posixre = @import("../posixre.zig");
const regex = @import("regex");
const sys = @import("../sys.zig");
const posixacl = @import("../posixacl.zig");
const unicode = @import("../unicode.zig");
const Io = std.Io;
const LX = std.os.linux;

pub const Env = common.Env;
pub const Input = common.Input;

/// One piece of script: an -e argument or the contents of an -f file.
pub const Chunk = struct {
    text: []const u8,
    is_file: bool,
    /// File name for -f.
    name: []const u8,
    /// 1-based -e / -f number.
    index: usize,
};

pub const Options = struct {
    /// -n
    quiet: bool = false,
    /// -E / -r (compile)
    ere: bool = false,
    /// -s
    separate: bool = false,
    /// -i; implies `separate`.
    in_place: bool = false,
    /// -i SUFFIX
    suffix: ?[]const u8 = null,
    /// -l N
    line_len: i64 = 70,
    /// -u
    unbuffered: bool = false,
    /// -z
    null_data: bool = false,
    /// --posix (compile and run)
    posix: bool = false,
    /// --sandbox (compile)
    sandbox: bool = false,
    /// --follow-symlinks
    follow: bool = false,
    /// --debug
    debug: bool = false,
    /// UTF-8 locale (compile and run); see `localeIsUtf8`.
    utf8: bool = false,
    /// Where `w /dev/stderr` goes. Null discards it.
    stderr: ?*Io.Writer = null,
    /// What `r /dev/stdin` reads. Null reads nothing.
    stdin: ?Io.File = null,
};

pub fn localeIsUtf8(env: Env) bool {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |k| {
        const v = env.getenv(k) orelse continue;
        if (v.len == 0) continue;
        return std.ascii.findIgnoreCase(v, "utf-8") != null or std.ascii.findIgnoreCase(v, "utf8") != null;
    }
    return false;
}

/// Why a script did not compile. For `.syntax` the caller builds GNU's
/// "-e expression #N, char P: MESSAGE" or "file F line L: MESSAGE" from the
/// fields; the exit status is 1. The other kinds exit with status 4.
pub const CompileError = struct {
    kind: Kind = .syntax,
    /// The chunk the error was found in (`Chunk.index`, `.is_file`, `.name`).
    chunk: Chunk = .{ .text = "", .is_file = false, .name = "", .index = 0 },
    /// 1-based byte position within an -e chunk.
    pos: usize = 0,
    /// 1-based line within an -f chunk.
    line: usize = 0,
    /// GNU's message without position (`.syntax`).
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,
    /// `.open_output`: the file; `.missing_label`: the label.
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    errno: LX.E = .SUCCESS,

    pub const Kind = enum {
        syntax,
        /// "unmatched `{'" (reported against the first chunk, char 0).
        unmatched_brace,
        /// A `w` file could not be created: "couldn't open file NAME: ERRNO".
        open_output,
        /// "can't find label for jump to `NAME'".
        missing_label,
    };

    pub fn message(e: *const CompileError) []const u8 {
        return e.message_buf[0..e.message_len];
    }
    pub fn name(e: *const CompileError) []const u8 {
        return e.name_buf[0..e.name_len];
    }
    fn setName(e: *CompileError, n: []const u8) void {
        e.name_len = @min(n.len, e.name_buf.len);
        @memcpy(e.name_buf[0..e.name_len], n[0..e.name_len]);
    }
};

/// Non-fatal problems and the messages of fatal ones; the caller words them.
pub const Event = union(enum) {
    /// "can't read NAME: ERRNO" (status 2, continues).
    cant_read: struct { name: []const u8, errno: LX.E },
    /// "couldn't edit NAME: not a regular file" (status 4, continues).
    cant_edit: []const u8,
    /// "error in subprocess": /bin/sh could not be run for `e` or `s///e`
    /// (fatal, status 4).
    subprocess_failed,
    /// "read error on NAME: ERRNO" (fatal, status 4).
    read_error: struct { name: []const u8, errno: LX.E },
    /// "couldn't write ITEMS items to NAME: ERRNO" (fatal, status 4). `name`
    /// is "stdout" for the output writer, whose errno the caller knows
    /// (`errno` null). A broken pipe is not reported for descriptors the
    /// library owns.
    write_error: struct { name: []const u8, items: usize, errno: ?LX.E },
    /// "couldn't open temporary file PATH: ERRNO" (status 4, continues).
    temp_open_failed: struct { path: []const u8, errno: LX.E },
    /// "cannot rename NAME: ERRNO" (fatal, status 4). The original is not
    /// replaced.
    rename_failed: struct { name: []const u8, errno: LX.E },
    /// An in-place edit could not give the new file the old one's group (the
    /// edit goes on; the group gets no more than others had).
    group_not_kept: struct { name: []const u8, errno: LX.E },
    /// An in-place edit could not give the new file all of the old one's
    /// mode and access ACL (the edit goes on; it allows nobody more).
    permissions_not_kept: struct { name: []const u8, errno: LX.E },
    /// "couldn't close NAME: ERRNO" (fatal, status 4). Some file systems only
    /// report a failed write here. An in-place original is not replaced.
    close_failed: struct { name: []const u8, errno: LX.E },
    /// An empty regex with no previous one (fatal, status 1). The chunk is
    /// the script's first.
    no_previous_regex: Chunk,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// GNU sed's exit status: 0, 1 (fatal script problem found at run time),
    /// 2 (an input could not be read), 4 (I/O error), or the `q`/`Q` status.
    exit_code: u8 = 0,
};

pub const RunError = error{OutOfMemory};
const Err = error{ OutOfMemory, Abort };
pub const CompileFailure = error{ OutOfMemory, BadProgram };

/// A compiled script. Owns its memory and the descriptors of `w` files.
pub const Program = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    st: *State,

    /// Close the `w` files after the last run, reporting through `observer`.
    /// False if any close failed, which means output may be missing. The
    /// program cannot run again if it has `w` files.
    pub fn closeFiles(p: *Program, observer: Observer) bool {
        var ok = true;
        for (p.st.outs.items) |o| {
            if (isStdFd(o.fd) or o.fd == sys.invalid_handle) continue;
            if (sys.closeFd(o.fd)) |er| {
                observer.emit(.{ .close_failed = .{ .name = o.path, .errno = er } });
                ok = false;
            }
            o.fd = sys.invalid_handle;
        }
        return ok;
    }

    pub fn deinit(p: *Program) void {
        for (p.st.outs.items) |o| {
            if (!isStdFd(o.fd) and o.fd != sys.invalid_handle) _ = sys.closeFd(o.fd);
        }
        const gpa = p.gpa;
        p.arena.deinit();
        gpa.destroy(p.arena);
    }
};

/// Compile `chunks` (at least one). On `error.BadProgram` `diag` says why.
pub fn compile(env: Env, options: Options, chunks: []const Chunk, diag: *CompileError) CompileFailure!Program {
    const arena_ptr = try env.gpa.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(env.gpa);
    errdefer {
        arena_ptr.deinit();
        env.gpa.destroy(arena_ptr);
    }
    const arena = arena_ptr.allocator();
    const st = try arena.create(State);
    st.* = .{ .env = env, .arena = arena, .opts = options, .chunks = chunks, .diag = diag };
    errdefer for (st.outs.items) |o| {
        if (!isStdFd(o.fd)) _ = sys.closeFd(o.fd);
    };
    const stdout_o = try arena.create(Output);
    stdout_o.* = .{ .fd = std.Io.File.stdout().handle, .path = "/dev/stdout", .is_std = true };
    st.stdout_out = stdout_o;

    var parser = Parser{ .s = st };
    while (st.ci < st.chunks.len) {
        st.pos = 0;
        parser.parseChunk() catch |e| switch (e) {
            error.BadProg => return error.BadProgram,
            error.OutOfMemory => return error.OutOfMemory,
        };
        st.ci += 1;
    }
    st.ci = st.chunks.len -| 1;
    if (st.blocks.items.len > 0) {
        st.pos = 0;
        diag.* = .{ .kind = .unmatched_brace, .chunk = st.chunks[0] };
        return error.BadProgram;
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
                    diag.* = .{ .kind = .missing_label };
                    diag.setName(c.text);
                    return error.BadProgram;
                }
            }
        }
    }
    return .{ .arena = arena_ptr, .gpa = env.gpa, .st = st };
}

/// Execute `program` over `inputs` (never empty: pass standard input as an
/// `Input` with a file source and no name or "-") writing to `out`. The
/// runtime parts of `options` (quiet, separate, in_place, suffix, line_len,
/// unbuffered, null_data, follow, debug, stderr, stdin) apply to this run;
/// `posix` and `utf8` should equal what the program was compiled with.
pub fn run(env: Env, program: *Program, options: Options, inputs: []const Input, out: *Io.Writer, observer: Observer) RunError!Result {
    const st = program.st;
    const script_quiet = st.script_quiet;
    st.env = env;
    st.obs = observer;
    st.opts = options;
    st.opts.quiet = options.quiet or script_quiet;
    st.exit_code = 0;
    st.out_w = out;
    st.err_w = options.stderr;
    for (st.outs.items) |o| {
        o.buf.clearRetainingCapacity();
        o.sink = null;
        o.missing_nl = false;
        o.sim_fill = 0;
        o.fail_n = 0;
    }
    const stdout_o = try env.gpa.create(Output);
    defer env.gpa.destroy(stdout_o);
    stdout_o.* = .{ .fd = std.Io.File.stdout().handle, .path = "/dev/stdout", .is_std = true };
    defer stdout_o.buf.deinit(env.gpa);
    st.stdout_out = stdout_o;

    var ex = Exec{
        .s = st,
        .gpa = env.gpa,
        .arena = std.heap.ArenaAllocator.init(env.gpa),
        .in = .{ .files = inputs },
        .cur_out = stdout_o,
        .stdout_o = stdout_o,
        .delim = if (st.opts.null_data) 0 else '\n',
    };
    defer ex.deinit();
    ex.resetRanges();
    // stdout shared with `w /dev/stdout`
    for (st.outs.items) |o| {
        if (o.fd == std.Io.File.stdout().handle) o.sink = stdout_o;
    }
    ex.loop() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Abort => {},
    };
    return .{ .exit_code = st.exit_code };
}

const ParseError = error{ BadProg, OutOfMemory };

/// The compiled script plus the state of the current run.
const State = struct {
    env: Env,
    obs: Observer = .none,
    arena: std.mem.Allocator,
    opts: Options,
    cmds: std.ArrayList(Cmd) = .empty,
    outs: std.ArrayList(*Output) = .empty,
    chunks: []const Chunk = &.{},
    exit_code: u8 = 0,
    last_re: ?*Re = null,
    /// "#n" on the script's first line.
    script_quiet: bool = false,
    diag: *CompileError,
    out_w: *Io.Writer = undefined,
    err_w: ?*Io.Writer = null,
    // parser
    ci: usize = 0,
    pos: usize = 0,
    blocks: std.ArrayList(usize) = .empty,
    labels: std.ArrayList(struct { name: []const u8, idx: usize }) = .empty,
    stdout_out: *Output = undefined,
};

fn errnoMsg(e: LX.E) []const u8 {
    return sys.errnoText(e);
}

const Re = struct { re: regex.Regex, groups: u32, multiline: bool, longest: ?posixre.Longest = null, src: []const u8 = "", icase: bool = false, mb: bool = false };

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
    num_set: bool = false,
    icase: bool = false,
    mline: bool = false,
    pat_src: []const u8 = "",
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
    ypairs: ?[]const [2]u32 = null,
    ysrc: []const u8 = "",
    ydst: []const u8 = "",
};

fn isStdFd(fd: sys.Handle) bool {
    return fd == std.Io.File.stdout().handle or fd == std.Io.File.stderr().handle or fd == std.Io.File.stdin().handle;
}

const Output = struct {
    fd: sys.Handle,
    path: []const u8 = "",
    buf: std.ArrayList(u8) = .empty,
    missing_nl: bool = false,
    is_std: bool = false,
    /// Buffer and descriptor are shared with this Output (w /dev/stdout).
    sink: ?*Output = null,
    /// Simulated stdio buffer fill and the size of the first fwrite that would have overflowed it
    /// (GNU's "couldn't write N items" reports that call's length).
    sim_fill: usize = 0,
    fail_n: usize = 0,
};

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
            s.diag.* = .{ .kind = .syntax, .chunk = ch, .line = line };
        } else {
            s.diag.* = .{ .kind = .syntax, .chunk = ch, .pos = s.pos };
        }
        const msg = std.fmt.bufPrint(&s.diag.message_buf, fmt, args) catch s.diag.message_buf[0..0];
        s.diag.message_len = msg.len;
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
        var rflags: posixre.Flags = .{};
        const body = posixre.translateFlags(s.arena, conv, s.opts.ere, .{ .utf8 = s.opts.utf8, .icase = icase }, &rflags) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadPattern => return p.fail("{s}", .{posixre.diagnoseMode(conv, s.opts.ere)}),
        };
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(s.arena, if (mline) "(?sm)" else "(?s)");
        try src.appendSlice(s.arena, body);
        const re = regex.Regex.compile(s.arena, src.items, .{ .dialect = .perl, .ignore_case = icase, .limits = posixre.big_limits }, null) catch {
            return p.fail("{s}", .{posixre.diagnoseMode(conv, s.opts.ere)});
        };
        const r = try s.arena.create(Re);
        r.* = .{ .re = re, .groups = re.groupCount(), .multiline = mline, .src = pat, .icase = icase, .mb = rflags.mb };
        r.longest = try posixre.Longest.compile(s.arena, .{ .pattern = conv, .ere = s.opts.ere, .body = body, .prefix = if (mline) "(?sm)" else "(?s)", .flags = rflags, .ignore_case = icase, .utf8 = s.opts.utf8, .multiline = mline });
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
        o.* = .{ .fd = sys.invalid_handle, .path = name };
        if (std.mem.eql(u8, name, "/dev/stdout")) {
            o.fd = std.Io.File.stdout().handle;
            o.is_std = true;
        } else if (std.mem.eql(u8, name, "/dev/stderr")) {
            o.fd = std.Io.File.stderr().handle;
            o.is_std = true;
        } else {
            var err: LX.E = .SUCCESS;
            o.fd = sys.openFd(name, sys.O.WRONLY | sys.O.CREAT | sys.O.TRUNC, 0o666, &err) orelse {
                s.diag.* = .{ .kind = .open_output, .errno = err };
                s.diag.setName(name);
                return error.BadProg;
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
                    sub.num_set = true;
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
        sub.icase = icase;
        sub.mline = mline;
        sub.pat_src = pat;
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
        if (s.opts.utf8) {
            var sp: std.ArrayList(u32) = .empty;
            var dp: std.ArrayList(u32) = .empty;
            var k: usize = 0;
            while (k < src.len) {
                const d = unicode.decode(src, k);
                try sp.append(s.arena, d.cp);
                k += d.len;
            }
            k = 0;
            while (k < dst.len) {
                const d = unicode.decode(dst, k);
                try dp.append(s.arena, d.cp);
                k += d.len;
            }
            if (sp.items.len != dp.items.len) return p.fail("strings for `y' command are different lengths", .{});
            var multi = false;
            for (sp.items) |cp| if (cp >= 0x80) {
                multi = true;
            };
            for (dp.items) |cp| if (cp >= 0x80) {
                multi = true;
            };
            if (multi) {
                const pairs = try s.arena.alloc([2]u32, sp.items.len);
                for (sp.items, dp.items, 0..) |a2, b2, idx| pairs[idx] = .{ a2, b2 };
                cmd.ypairs = pairs;
                cmd.ysrc = src;
                cmd.ydst = dst;
                const t0 = try s.arena.create([256]u8);
                for (t0, 0..) |*x, ii| x.* = @intCast(ii);
                cmd.ytab = t0;
                try p.endOfCmd();
                return;
            }
        }
        if (src.len != dst.len) return p.fail("strings for `y' command are different lengths", .{});
        const t = try s.arena.create([256]u8);
        for (t, 0..) |*x, i| x.* = @intCast(i);
        var i: usize = src.len;
        while (i > 0) {
            i -= 1;
            t[src[i]] = dst[i];
        }
        cmd.ytab = t;
        cmd.ysrc = src;
        cmd.ydst = dst;
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
                        if (t.len >= 2 and t[1] == 'n') s.script_quiet = true;
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
                            const n = p.readNumber(d);
                            // A width too large to hold wraps no line. An
                            // exit status is the low byte, which masking keeps.
                            cmd.int = @intCast(if (c == 'l') @min(n, std.math.maxInt(i64)) else n & std.math.maxInt(i64));
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
                if (n == 'x' or n == 'o' or n == 'd') {
                    const base: u8 = if (n == 'd') 10 else if (n == 'o') 8 else 16;
                    const maxd: usize = if (n == 'x') 2 else 3;
                    var v: u32 = 0;
                    var k: usize = 0;
                    while (k < maxd and i + 2 + k < pat.len) : (k += 1) {
                        const dv = std.fmt.charToDigit(pat[i + 2 + k], base) catch break;
                        v = v * base + dv;
                    }
                    if (k > 0) {
                        try out.append(a, @truncate(v));
                        i += 2 + k;
                        continue;
                    }
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

/// One input being read: only what has not been used yet is held, so that a
/// stream is processed as it arrives and memory does not grow with its length.
const Reader = struct {
    fd: sys.Handle = sys.invalid_handle,
    /// Opened here, to be closed here; otherwise the caller's descriptor.
    owned: bool = false,
    /// `buf.items[pos..]` is read but not used; no delimiter is before
    /// `scanned`.
    buf: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    scanned: usize = 0,
    eof: bool = true,
    /// Reading may wait (a pipe, a terminal): write what is pending first.
    may_wait: bool = false,
    name: []const u8 = "-",
    /// Which of the inputs this is.
    index: usize = 0,

    fn unused(r: *const Reader) usize {
        return r.buf.items.len - r.pos;
    }

    /// Done with the input. A caller's descriptor that can seek is left
    /// just after what was used, for whoever reads it next (`q` in a
    /// shell's `{ sed 1q; cat; } < file`).
    fn close(r: *Reader, gpa: std.mem.Allocator) void {
        if (r.owned) {
            _ = sys.closeFd(r.fd);
        } else if (r.fd != sys.invalid_handle and r.unused() > 0) {
            var e: LX.E = .SUCCESS;
            _ = sys.seekFd(r.fd, -@as(i64, @intCast(r.unused())), 1, &e);
        }
        r.buf.deinit(gpa);
        r.* = .{};
    }
};

const Cursor = struct {
    files: []const Input,
    next_file: usize = 0,
    cur: Reader = .{},
    /// The next input with anything in it, opened to find out whether the
    /// current line is the last one.
    ahead: ?Reader = null,
    name: []const u8 = "-",
    opened: bool = false,
    line_no: u64 = 0,
};

const Exec = struct {
    s: *State,
    gpa: std.mem.Allocator,
    in: Cursor,
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
    /// Of the descriptor being edited, from before anything ran: the name may
    /// lead to another file by the time the edit is done.
    in_place_st: ?sys.FileStat = null,
    stdout_o: *Output,
    last_re: ?*Re = null,
    dbg_level: usize = 0,
    r_files: std.ArrayList(struct { name: []const u8, data: []const u8, pos: usize }) = .empty,
    searcher_cache: ?struct { re: *Re, sr: posixre.Finder } = null,
    arena: std.heap.ArenaAllocator,

    fn ar(e: *Exec) std.mem.Allocator {
        return e.arena.allocator();
    }

    fn deinit(e: *Exec) void {
        // The run stopped inside an in-place edit: drop the unfinished copy and
        // leave the original as it was.
        if (e.in_place_tmp) |tmp| {
            if (e.cur_out.fd != sys.invalid_handle) _ = sys.closeFd(e.cur_out.fd);
            _ = sys.unlinkPath(tmp, false);
            e.cur_out.buf.deinit(e.gpa);
            e.cur_out.buf = .empty;
        }
        if (e.in.ahead) |*r| r.close(e.gpa);
        e.in.cur.close(e.gpa);
        e.ps.deinit(e.gpa);
        e.hs.deinit(e.gpa);
        e.append_q.deinit(e.gpa);
        e.r_files.deinit(e.gpa);
        if (e.searcher_cache) |*c| c.sr.deinit();
        for (e.s.outs.items) |o| o.buf.clearRetainingCapacity();
        e.arena.deinit();
    }

    fn writeFailed(e: *Exec, name: []const u8, items: usize, errno: ?LX.E) Err {
        e.s.obs.emit(.{ .write_error = .{ .name = name, .items = items, .errno = errno } });
        e.s.exit_code = 4;
        return error.Abort;
    }

    fn flushOut(e: *Exec, o: *Output) Err!void {
        if (o.buf.items.len == 0) return;
        const items = if (o.fail_n != 0) o.fail_n else o.buf.items.len;
        if (o.fd == std.Io.File.stdout().handle) {
            e.s.out_w.writeAll(o.buf.items) catch return e.writeFailed("stdout", items, null);
            e.s.out_w.flush() catch return e.writeFailed("stdout", items, null);
        } else if (o.fd == std.Io.File.stderr().handle) {
            if (e.s.err_w) |w| {
                w.writeAll(o.buf.items) catch return e.writeFailed(o.path, items, null);
                w.flush() catch return e.writeFailed(o.path, items, null);
            }
        } else if (sys.writeAllFd(o.fd, o.buf.items)) |err| {
            return e.writeFailed(o.path, items, err);
        }
        o.buf.clearRetainingCapacity();
    }

    fn flushAll(e: *Exec) Err!void {
        try e.flushOut(e.stdout_o);
        for (e.s.outs.items) |o| try e.flushOut(o);
    }

    /// The main loop: read, execute, repeat; then the closing flushes.
    fn loop(e: *Exec) Err!void {
        const st = e.s;
        if (st.opts.debug) try e.dbgProgram();
        while (true) {
            if (e.skip_read) {
                e.skip_read = false;
                try e.dumpAppend();
                if (st.opts.debug) try e.dbgPattern();
            } else {
                if (!try e.readPatternSpace()) break;
                if (st.opts.debug) {
                    try e.dbgOut("INPUT:   '{s}' line {d}\n", .{ if (std.mem.eql(u8, e.in.name, "-")) "STDIN" else e.in.name, e.in.line_no });
                    try e.dbgPattern();
                }
            }
            const quit = try e.execute();
            if (quit) {
                try e.dumpAppend();
                break;
            }
            if (e.skip_read) {
                // D with a newline: restart without reading, but flush appends
                try e.dumpAppend();
            }
        }
        try e.dumpAppend();
        if (e.in_place_tmp != null) try e.finishInPlace();
        try e.flushAll();
    }

    fn emit(e: *Exec, out: *Output, bytes: []const u8) Err!void {
        const o = out.sink orelse out;
        if (o.fail_n == 0) {
            if (o.sim_fill + bytes.len > 4096) o.fail_n = bytes.len else o.sim_fill += bytes.len;
        }
        o.buf.appendSlice(e.gpa, bytes) catch return error.OutOfMemory;
        if (o.buf.items.len > 65536 or e.s.opts.unbuffered or o.fd == std.Io.File.stderr().handle) try e.flushOut(o);
    }

    fn missingNl(e: *Exec, o: *Output) Err!void {
        if (o.missing_nl) {
            try e.emit(o, &.{e.delim});
            o.missing_nl = false;
        }
    }

    fn writeLine(e: *Exec, o: *Output, text: []const u8, nl: bool) Err!void {
        try e.missingNl(o);
        try e.emit(o, text);
        if (nl) try e.emit(o, &.{e.delim}) else o.missing_nl = true;
    }

    // ---- input

    fn inputName(input: Input) []const u8 {
        return input.name orelse switch (input.source) {
            .path => |p| p,
            .file => "-",
        };
    }

    /// Open input `index`. Null, after the diagnostic, when it cannot be.
    fn openReader(e: *Exec, index: usize) ?Reader {
        const input = e.in.files[index];
        const name = inputName(input);
        var r: Reader = .{ .eof = false, .name = name, .index = index };
        var err: LX.E = .SUCCESS;
        switch (input.source) {
            .file => |f| r.fd = f.handle,
            .path => |path| {
                r.fd = sys.openFd(path, sys.O.RDONLY, 0, &err) orelse {
                    e.s.obs.emit(.{ .cant_read = .{ .name = name, .errno = err } });
                    e.s.exit_code = 2;
                    return null;
                };
                r.owned = true;
            },
        }
        const st = sys.fstatFd(r.fd, &err);
        r.may_wait = st == null or !st.?.isReg();
        return r;
    }

    /// Read some more of `r`, at its end noting that. With -u no more is
    /// taken than is used, as with GNU sed.
    fn fill(e: *Exec, r: *Reader) Err!void {
        const left = r.unused();
        if (r.pos > 0) {
            std.mem.copyForwards(u8, r.buf.items[0..left], r.buf.items[r.pos..]);
            r.buf.shrinkRetainingCapacity(left);
            r.scanned -|= r.pos;
            r.pos = 0;
        }
        const want: usize = if (e.s.opts.unbuffered) 1 else 65536;
        r.buf.ensureUnusedCapacity(e.gpa, want) catch return error.OutOfMemory;
        // Whoever writes the input may be waiting to see our output.
        if (r.may_wait) try e.flushAll();
        var err: LX.E = .SUCCESS;
        const n = sys.readFd(r.fd, r.buf.unusedCapacitySlice()[0..want], &err) orelse {
            e.s.obs.emit(.{ .read_error = .{ .name = r.name, .errno = err } });
            try e.flushAll();
            e.s.exit_code = 4;
            return error.Abort;
        };
        if (n == 0) r.eof = true else r.buf.items.len += n;
    }

    /// Read until `r` has something unused or is at its end.
    fn peek(e: *Exec, r: *Reader) Err!bool {
        while (r.unused() == 0 and !r.eof) try e.fill(r);
        return r.unused() > 0;
    }

    fn openNext(e: *Exec) Err!bool {
        const in = &e.in;
        while (true) {
            if (in.next_file >= in.files.len) return false;
            const index = in.next_file;
            const input = in.files[index];
            in.next_file += 1;
            var r: Reader = undefined;
            if (in.ahead != null and in.ahead.?.index == index) {
                r = in.ahead.?;
                in.ahead = null;
            } else r = e.openReader(index) orelse continue;
            var in_place_st: ?sys.FileStat = null;
            if (e.s.opts.in_place) {
                var serr: LX.E = .SUCCESS;
                in_place_st = sys.fstatFd(r.fd, &serr);
                if (input.source == .path and (in_place_st == null or !in_place_st.?.isReg())) {
                    e.s.obs.emit(.{ .cant_edit = r.name });
                    e.s.exit_code = 4;
                    r.close(e.gpa);
                    continue;
                }
            }
            in.cur.close(e.gpa);
            in.cur = r;
            e.in_place_st = in_place_st;
            in.name = r.name;
            in.opened = true;
            if (e.s.opts.separate) {
                in.line_no = 0;
                e.resetRanges();
            }
            if (e.s.opts.in_place) {
                const path = if (input.source == .path) input.source.path else in.name;
                if (!try e.beginInPlace(if (e.s.opts.follow) try e.resolveLink(path) else path)) {
                    in.cur.close(e.gpa);
                    continue;
                }
            }
            return true;
        }
    }

    fn readAll(e: *Exec, fd: sys.Handle, data: *std.ArrayList(u8), name: []const u8) Err!bool {
        var buf: [65536]u8 = undefined;
        while (true) {
            var err: LX.E = .SUCCESS;
            const n = sys.readFd(fd, &buf, &err) orelse {
                e.s.obs.emit(.{ .read_error = .{ .name = name, .errno = err } });
                try e.flushAll();
                e.s.exit_code = 4;
                return error.Abort;
            };
            if (n == 0) break;
            try data.appendSlice(e.ar(), buf[0..n]);
        }
        return true;
    }

    fn resetRanges(e: *Exec) void {
        for (e.s.cmds.items) |*c| {
            c.range_active = c.a1.kind == .zero;
            c.range_closed = false;
        }
    }

    fn beginInPlace(e: *Exec, name: []const u8) Err!bool {
        const dir_end = std.mem.lastIndexOfScalar(u8, name, '/');
        const dir = if (dir_end) |d| name[0 .. d + 1] else "./";
        var err: LX.E = .SUCCESS;
        var attempt: u32 = 0;
        while (attempt < 100) : (attempt += 1) {
            // Random, so that nobody can take all the names in advance.
            var random: [4]u8 = undefined;
            e.s.env.io.random(&random);
            const tmp = std.fmt.allocPrint(e.ar(), "{s}sed{x:0>6}", .{ dir, std.mem.readInt(u32, &random, .little) & 0xffffff }) catch return error.OutOfMemory;
            const fd = sys.openFd(tmp, sys.O.WRONLY | sys.O.CREAT | sys.O.EXCL, 0o600, &err) orelse {
                if (err == .EXIST) continue;
                e.s.obs.emit(.{ .temp_open_failed = .{ .path = tmp, .errno = err } });
                e.s.exit_code = 4;
                return false;
            };
            const o = try e.ar().create(Output);
            o.* = .{ .fd = fd, .path = tmp };
            e.cur_out = o;
            e.in_place_tmp = tmp;
            e.in_place_target = name;
            return true;
        }
        e.s.obs.emit(.{ .temp_open_failed = .{ .path = dir, .errno = .EXIST } });
        e.s.exit_code = 4;
        return false;
    }

    fn resolveLink(e: *Exec, name: []const u8) Err![]const u8 {
        var cur = name;
        var n: usize = 0;
        while (n < 40) : (n += 1) {
            var buf: [4096]u8 = undefined;
            var err: LX.E = .SUCCESS;
            const len = sys.readlinkPath(cur, &buf, &err) orelse return cur;
            const tgt = buf[0..len];
            if (tgt.len > 0 and tgt[0] == '/') {
                cur = e.ar().dupe(u8, tgt) catch return error.OutOfMemory;
            } else {
                const slash = std.mem.lastIndexOfScalar(u8, cur, '/');
                cur = if (slash) |sl|
                    std.fmt.allocPrint(e.ar(), "{s}{s}", .{ cur[0 .. sl + 1], tgt }) catch return error.OutOfMemory
                else
                    e.ar().dupe(u8, tgt) catch return error.OutOfMemory;
            }
        }
        return cur;
    }

    fn finishInPlace(e: *Exec) Err!void {
        const tmp = e.in_place_tmp orelse return;
        const o = e.cur_out;
        try e.flushOut(o);
        if (e.in_place_st) |st| e.keepAttributes(e.in.cur.fd, o.fd, st);
        const close_error = sys.closeFd(o.fd);
        o.fd = sys.invalid_handle;
        o.buf.deinit(e.gpa);
        o.buf = .empty;
        if (close_error) |er| {
            e.s.obs.emit(.{ .close_failed = .{ .name = tmp, .errno = er } });
            try e.flushAll();
            e.s.exit_code = 4;
            return error.Abort;
        }
        if (e.s.opts.suffix) |suf| {
            const name = e.in_place_target;
            const slash = std.mem.lastIndexOfScalar(u8, name, '/');
            const base = if (slash) |sl| name[sl + 1 ..] else name;
            const dir = if (slash) |sl| name[0 .. sl + 1] else "";
            var bk: std.ArrayList(u8) = .empty;
            if (std.mem.indexOfScalar(u8, suf, '*') != null) {
                for (suf) |ch| {
                    if (ch == '*') bk.appendSlice(e.ar(), base) catch return error.OutOfMemory else bk.append(e.ar(), ch) catch return error.OutOfMemory;
                }
            } else {
                bk.appendSlice(e.ar(), base) catch return error.OutOfMemory;
                bk.appendSlice(e.ar(), suf) catch return error.OutOfMemory;
            }
            const full = if (std.mem.indexOfScalar(u8, bk.items, '/') != null)
                bk.items
            else
                std.fmt.allocPrint(e.ar(), "{s}{s}", .{ dir, bk.items }) catch return error.OutOfMemory;
            // Without the backup the original must not be replaced.
            if (sys.renamePath(name, full, 0)) |er| return e.renameFailed(name, er);
        }
        if (sys.renamePath(tmp, e.in_place_target, 0)) |er| return e.renameFailed(tmp, er);
        e.in_place_tmp = null;
        e.cur_out = e.stdout_o;
    }

    /// Give the finished copy `fd` the owner, group, mode and access ACL of
    /// the file `from` that it replaces, as far as this user may.
    fn keepAttributes(e: *Exec, from: sys.Handle, fd: sys.Handle, old: sys.FileStat) void {
        var mode = old.mode & 0o7777;
        var same_group = true;
        // The owner first: changing it clears the set-ID bits.
        if (sys.fchownFd(fd, old.uid, old.gid) != null) {
            // Only a privileged user can give a file away; the group alone
            // can be set by any of its members.
            const group_error = sys.fchownFd(fd, std.math.maxInt(u32), old.gid);
            var serr: LX.E = .SUCCESS;
            const new = sys.fstatFd(fd, &serr);
            // A set-ID bit must not pass to another user or group.
            if (new == null or new.?.uid != old.uid) mode &= ~@as(u32, 0o4000);
            if (new == null or new.?.gid != old.gid) {
                mode &= ~@as(u32, 0o2000);
                same_group = false;
                e.s.obs.emit(.{ .group_not_kept = .{ .name = e.in_place_target, .errno = group_error orelse serr } });
            }
        }
        if (posixacl.replacement(from, fd, mode, same_group)) |er| {
            e.s.obs.emit(.{ .permissions_not_kept = .{ .name = e.in_place_target, .errno = er } });
        }
    }

    /// Fatal, as in GNU sed. `deinit` removes the temporary file.
    fn renameFailed(e: *Exec, name: []const u8, errno: LX.E) Err {
        e.s.obs.emit(.{ .rename_failed = .{ .name = name, .errno = errno } });
        try e.flushAll();
        e.s.exit_code = 4;
        return error.Abort;
    }

    /// True when the current file (and, unless separate, all later ones) has
    /// no more lines.
    fn atEof(e: *Exec) Err!bool {
        const in = &e.in;
        if (try e.peek(&in.cur)) return false;
        if (e.s.opts.separate) return true;
        // look ahead: skip to the next file with data without finishing this one
        if (in.ahead != null) return false;
        while (in.next_file < in.files.len) : (in.next_file += 1) {
            var r = e.openReader(in.next_file) orelse continue;
            const found = e.peek(&r) catch |err| {
                r.close(e.gpa);
                return err;
            };
            if (found) {
                in.ahead = r;
                return false;
            }
            r.close(e.gpa);
        }
        return true;
    }

    fn readLine(e: *Exec) Err!bool {
        const in = &e.in;
        while (true) {
            const r = &in.cur;
            if (std.mem.indexOfScalarPos(u8, r.buf.items, @max(r.scanned, r.pos), e.delim)) |i| {
                e.ps.clearRetainingCapacity();
                e.ps.appendSlice(e.gpa, r.buf.items[r.pos..i]) catch return error.OutOfMemory;
                r.pos = i + 1;
                r.scanned = r.pos;
                e.ps_chomped = true;
                break;
            }
            r.scanned = r.buf.items.len;
            if (!r.eof) {
                try e.fill(r);
                continue;
            }
            if (r.unused() > 0) {
                e.ps.clearRetainingCapacity();
                e.ps.appendSlice(e.gpa, r.buf.items[r.pos..]) catch return error.OutOfMemory;
                r.pos = r.buf.items.len;
                e.ps_chomped = false;
                break;
            }
            if (e.s.opts.in_place and e.in_place_tmp != null) try e.finishInPlace();
            if (!try e.openNext()) return false;
        }
        in.line_no += 1;
        return true;
    }

    fn readPatternSpace(e: *Exec) Err!bool {
        try e.dumpAppend();
        e.replaced_t = false;
        return try e.readLine();
    }

    fn dumpAppend(e: *Exec) Err!void {
        for (e.append_q.items) |a| {
            switch (a.kind) {
                'a' => {
                    try e.missingNl(e.cur_out);
                    try e.emit(e.cur_out, a.text);
                },
                'r' => {
                    try e.missingNl(e.cur_out);
                    var data: std.ArrayList(u8) = .empty;
                    // As in GNU, /dev/stdin is opened like any name: a file
                    // is read from its start, a pipe from where it is.
                    var err: LX.E = .SUCCESS;
                    if (sys.openFd(a.text, sys.O.RDONLY, 0, &err)) |fd| {
                        defer _ = sys.closeFd(fd);
                        _ = try e.readAll(fd, &data, a.text);
                    } else if (std.mem.eql(u8, a.text, "/dev/stdin")) {
                        _ = try e.readAll(std.Io.File.stdin().handle, &data, a.text);
                    }
                    try e.emit(e.cur_out, data.items);
                },
                'R' => {
                    try e.missingNl(e.cur_out);
                    try e.emit(e.cur_out, a.text);
                },
                else => {},
            }
        }
        e.append_q.clearRetainingCapacity();
    }

    // ---- matching

    fn getSearcher(e: *Exec, re: *Re) Err!*posixre.Finder {
        if (e.searcher_cache) |*c| {
            if (c.re == re) return &c.sr;
            c.sr.deinit();
            e.searcher_cache = null;
        }
        const sr = posixre.Finder.initParts(e.gpa, &re.re, if (re.longest) |*l| l else null) catch return error.OutOfMemory;
        e.searcher_cache = .{ .re = re, .sr = sr };
        return &e.searcher_cache.?.sr;
    }

    fn resolveRe(e: *Exec, r: ?*Re) Err!?*Re {
        if (r) |x| {
            e.last_re = x;
            return x;
        }
        if (e.last_re == null) {
            try e.flushAll();
            e.s.obs.emit(.{ .no_previous_regex = e.s.chunks[0] });
            e.s.exit_code = 1;
            return error.Abort;
        }
        return e.last_re;
    }

    fn reMatch(e: *Exec, r: ?*Re, subject: []const u8, from: usize) Err!?regex.Match {
        const re = (try e.resolveRe(r)).?;
        const sr = try e.getSearcher(re);
        return (sr.find(subject, from) catch null);
    }

    fn matchAddr(e: *Exec, a: Addr) Err!bool {
        switch (a.kind) {
            .none => return true,
            .line => return e.in.line_no == a.n,
            .step => {
                const l = e.in.line_no;
                if (a.step == 0) return l == a.n;
                return l >= a.n and (l - a.n) % a.step == 0;
            },
            .last => return try e.atEof(),
            .re => return try e.reMatch(a.re, e.ps.items, 0) != null,
            .zero, .plus, .mult => return false,
        }
    }

    fn matchCmd(e: *Exec, c: *Cmd) Err!bool {
        const l = e.in.line_no;
        if (c.a1.kind == .none) return true;
        if (c.a2.kind == .none) return try e.matchAddr(c.a1);
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
                    if (try e.matchAddr(c.a2)) c.range_active = false;
                    return true;
                },
            }
        }
        if (c.a1.kind == .line and c.range_closed) return false;
        if (!try e.matchAddr(c.a1)) return false;
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
                // A range that ends past any line number goes to the end.
                c.range_end = l +| c.a2.n;
            },
            .mult => {
                if (c.a2.n == 0) return true;
                c.range_end = (l / c.a2.n + 1) *| c.a2.n;
            },
            else => {},
        }
        c.range_active = true;
        return true;
    }

    // ---- --debug

    fn translateUtf8(e: *Exec, pairs: []const [2]u32) Err!void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(e.gpa);
        const src = e.ps.items;
        var i: usize = 0;
        while (i < src.len) {
            const d = unicode.decode(src, i);
            if (!d.valid) {
                out.append(e.gpa, src[i]) catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            var cp = d.cp;
            // the first pair listing the character wins, as in GNU
            for (pairs) |pr| {
                if (pr[0] == cp) {
                    cp = pr[1];
                    break;
                }
            }
            var buf: [4]u8 = undefined;
            out.appendSlice(e.gpa, unicode.encode(cp, &buf)) catch return error.OutOfMemory;
            i += d.len;
        }
        e.ps.clearRetainingCapacity();
        e.ps.appendSlice(e.gpa, out.items) catch return error.OutOfMemory;
    }

    fn dbgOut(e: *Exec, comptime fmt: []const u8, args: anytype) Err!void {
        const text = std.fmt.allocPrint(e.gpa, fmt, args) catch return error.OutOfMemory;
        defer e.gpa.free(text);
        try e.emit(e.stdout_o, text);
    }

    fn dbgEscaped(e: *Exec, out: *std.ArrayList(u8), text: []const u8, slash: bool) Err!void {
        for (text) |ch| {
            switch (ch) {
                '\\' => out.appendSlice(e.gpa, "\\\\") catch return error.OutOfMemory,
                '\n' => out.appendSlice(e.gpa, "\\n") catch return error.OutOfMemory,
                '\t' => out.appendSlice(e.gpa, "\\t") catch return error.OutOfMemory,
                7 => out.appendSlice(e.gpa, "\\a") catch return error.OutOfMemory,
                12 => out.appendSlice(e.gpa, "\\f") catch return error.OutOfMemory,
                '\r' => out.appendSlice(e.gpa, "\\r") catch return error.OutOfMemory,
                11 => out.appendSlice(e.gpa, "\\v") catch return error.OutOfMemory,
                '/' => if (slash) out.appendSlice(e.gpa, "\\/") catch return error.OutOfMemory else out.append(e.gpa, ch) catch return error.OutOfMemory,
                else => if (ch < 0x20 or ch >= 0x7f) {
                    var b: [8]u8 = undefined;
                    out.appendSlice(e.gpa, std.fmt.bufPrint(&b, "\\o{o:0>3}", .{ch}) catch unreachable) catch return error.OutOfMemory;
                } else out.append(e.gpa, ch) catch return error.OutOfMemory,
            }
        }
    }

    fn dbgPattern(e: *Exec) Err!void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(e.gpa);
        out.appendSlice(e.gpa, "PATTERN: ") catch return error.OutOfMemory;
        try e.dbgEscaped(&out, e.ps.items, false);
        out.append(e.gpa, '\n') catch return error.OutOfMemory;
        try e.emit(e.stdout_o, out.items);
    }

    fn dbgHold(e: *Exec) Err!void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(e.gpa);
        out.appendSlice(e.gpa, "HOLD:    ") catch return error.OutOfMemory;
        try e.dbgEscaped(&out, e.hs.items, false);
        out.append(e.gpa, '\n') catch return error.OutOfMemory;
        try e.emit(e.stdout_o, out.items);
    }

    fn dbgAddr(e: *Exec, out: *std.ArrayList(u8), a: Addr) Err!void {
        switch (a.kind) {
            .none => {},
            .line => out.print(e.gpa, "{d}", .{a.n}) catch return error.OutOfMemory,
            .step => if (a.step == 0) out.print(e.gpa, "{d}", .{a.n}) catch return error.OutOfMemory else out.print(e.gpa, "{d}~{d}", .{ a.n, a.step }) catch return error.OutOfMemory,
            .last => out.append(e.gpa, '$') catch return error.OutOfMemory,
            .zero => out.append(e.gpa, '0') catch return error.OutOfMemory,
            .plus => out.print(e.gpa, "+{d}", .{a.n}) catch return error.OutOfMemory,
            .mult => out.print(e.gpa, "~{d}", .{a.n}) catch return error.OutOfMemory,
            .re => {
                out.append(e.gpa, '/') catch return error.OutOfMemory;
                if (a.re) |r| {
                    try e.dbgEscaped(out, r.src, true);
                }
                out.append(e.gpa, '/') catch return error.OutOfMemory;
                if (a.re) |r| {
                    if (r.icase) out.append(e.gpa, 'I') catch return error.OutOfMemory;
                    if (r.multiline) out.append(e.gpa, 'M') catch return error.OutOfMemory;
                }
            },
        }
    }

    fn dbgCmdText(e: *Exec, out: *std.ArrayList(u8), c: *const Cmd) Err!void {
        const gpa = e.gpa;
        const has_addr = c.a1.kind != .none;
        try e.dbgAddr(out, c.a1);
        if (c.a2.kind != .none) {
            out.append(gpa, ',') catch return error.OutOfMemory;
            try e.dbgAddr(out, c.a2);
        }
        if (c.negate) out.append(gpa, '!') catch return error.OutOfMemory;
        if (has_addr or c.negate) out.append(gpa, ' ') catch return error.OutOfMemory;
        switch (c.c) {
            ':' => out.print(gpa, ":{s}", .{c.text}) catch return error.OutOfMemory,
            'b', 't', 'T' => {
                out.append(gpa, c.c) catch return error.OutOfMemory;
                if (c.text.len > 0) out.print(gpa, " {s}", .{c.text}) catch return error.OutOfMemory;
            },
            'a', 'i', 'c' => out.print(gpa, "{c}\\{s}", .{ c.c, c.text }) catch return error.OutOfMemory,
            'r', 'R' => out.print(gpa, "{c} {s}", .{ c.c, c.text }) catch return error.OutOfMemory,
            'w', 'W' => out.print(gpa, "{c}{s}", .{ c.c, c.text }) catch return error.OutOfMemory,
            'e' => {
                out.print(gpa, "e {s}", .{c.text}) catch return error.OutOfMemory;
                if (c.text.len > 0) out.append(gpa, '\n') catch return error.OutOfMemory;
            },
            'l', 'q', 'Q' => {
                out.append(gpa, c.c) catch return error.OutOfMemory;
                if (c.int >= 0) out.print(gpa, " {d}", .{c.int}) catch return error.OutOfMemory;
            },
            'y' => out.print(gpa, "y/{s}/{s}/", .{ c.ysrc, c.ydst }) catch return error.OutOfMemory,
            's' => {
                const sub = c.sub.?;
                out.append(gpa, 's') catch return error.OutOfMemory;
                out.append(gpa, '/') catch return error.OutOfMemory;
                try e.dbgEscaped(out, sub.pat_src, true);
                out.append(gpa, '/') catch return error.OutOfMemory;
                for (sub.parts) |part| {
                    if (part.case_op != 0) {
                        out.append(gpa, '\\') catch return error.OutOfMemory;
                        out.append(gpa, part.case_op) catch return error.OutOfMemory;
                    }
                    out.appendSlice(gpa, part.lit) catch return error.OutOfMemory;
                    if (part.group == 0) out.append(gpa, '&') catch return error.OutOfMemory else if (part.group > 0) out.print(gpa, "\\{d}", .{part.group}) catch return error.OutOfMemory;
                }
                out.append(gpa, '/') catch return error.OutOfMemory;
                if (sub.icase) out.append(gpa, 'i') catch return error.OutOfMemory;
                if (sub.mline) out.append(gpa, 'm') catch return error.OutOfMemory;
                if (sub.global) out.append(gpa, 'g') catch return error.OutOfMemory;
                if (sub.eval) out.append(gpa, 'e') catch return error.OutOfMemory;
                if (sub.print > 0) out.append(gpa, 'p') catch return error.OutOfMemory;
                if (sub.num_set) out.print(gpa, "{d}", .{sub.number}) catch return error.OutOfMemory;
                if (sub.wfile) |w| out.print(gpa, "w{s}", .{e.s.outs.items[w].path}) catch return error.OutOfMemory;
            },
            else => out.append(gpa, c.c) catch return error.OutOfMemory,
        }
    }

    /// Pattern source as `s` prints it: only the slash is escaped.
    fn dbgEscaped2(e: *Exec, out: *std.ArrayList(u8), text: []const u8) Err!void {
        for (text) |ch| {
            if (ch == '/') out.appendSlice(e.gpa, "\\/") catch return error.OutOfMemory else if (ch == '\n') out.appendSlice(e.gpa, "\\n") catch return error.OutOfMemory else out.append(e.gpa, ch) catch return error.OutOfMemory;
        }
    }

    fn dbgProgram(e: *Exec) Err!void {
        try e.emit(e.stdout_o, "SED PROGRAM:\n");
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(e.gpa);
        for (e.s.cmds.items) |*c| {
            out.clearRetainingCapacity();
            if (c.c == '}' and e.dbg_level > 0) e.dbg_level -= 1;
            out.appendNTimes(e.gpa, ' ', 2 + 2 * e.dbg_level) catch return error.OutOfMemory;
            if (c.c == '{') e.dbg_level += 1;
            try e.dbgCmdText(&out, c);
            out.append(e.gpa, '\n') catch return error.OutOfMemory;
            try e.emit(e.stdout_o, out.items);
        }
    }

    fn dbgCommand(e: *Exec, c: *const Cmd) Err!void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(e.gpa);
        out.appendSlice(e.gpa, "COMMAND: ") catch return error.OutOfMemory;
        if (c.c == '}' and e.dbg_level > 0) e.dbg_level -= 1;
        out.appendNTimes(e.gpa, ' ', 2 * e.dbg_level) catch return error.OutOfMemory;
        if (c.c == '{') e.dbg_level += 1;
        try e.dbgCmdText(&out, c);
        out.append(e.gpa, '\n') catch return error.OutOfMemory;
        try e.emit(e.stdout_o, out.items);
    }

    fn dbgRegisters(e: *Exec, m: regex.Match, subj: []const u8, groups: u32) Err!void {
        try e.emit(e.stdout_o, "MATCHED REGEX REGISTERS\n");
        var i: u32 = 0;
        while (i <= groups) : (i += 1) {
            const g = m.group(i) orelse break;
            try e.dbgOut("  regex[{d}] = {d}-{d} '{s}'\n", .{ i, g[0], g[1], subj[g[0]..g[1]] });
        }
    }

    fn dbgEnd(e: *Exec) Err!void {
        if (e.s.opts.debug) try e.emit(e.stdout_o, "END-OF-CYCLE:\n");
    }

    // ---- commands

    fn autoprint(e: *Exec) Err!void {
        if (!e.s.opts.quiet) try e.writeLine(e.cur_out, e.ps.items, e.ps_chomped);
    }

    fn doList(e: *Exec, width_arg: i64) Err!void {
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
                out.appendSlice(e.gpa, "\\\n") catch return error.OutOfMemory;
                col = 0;
            }
            out.appendSlice(e.gpa, rep) catch return error.OutOfMemory;
            col += @intCast(rep.len);
        }
        out.appendSlice(e.gpa, "$") catch return error.OutOfMemory;
        out.append(e.gpa, e.delim) catch return error.OutOfMemory;
        try e.missingNl(e.cur_out);
        try e.emit(e.cur_out, out.items);
    }

    fn appendCase(e: *Exec, dst: *std.ArrayList(u8), text: []const u8, persist: u8, oneshot: *u8) Err!void {
        if (e.s.opts.utf8) {
            var i: usize = 0;
            while (i < text.len) {
                const d = unicode.decode(text, i);
                if (!d.valid) {
                    dst.append(e.gpa, text[i]) catch return error.OutOfMemory;
                    i += 1;
                    continue;
                }
                var cp = d.cp;
                if (oneshot.* != 0) {
                    cp = if (oneshot.* == 'u') unicode.toUpper(cp) else unicode.toLower(cp);
                    oneshot.* = 0;
                } else if (persist == 'U') cp = unicode.toUpper(cp) else if (persist == 'L') cp = unicode.toLower(cp);
                var buf: [4]u8 = undefined;
                dst.appendSlice(e.gpa, unicode.encode(cp, &buf)) catch return error.OutOfMemory;
                i += d.len;
            }
            return;
        }
        for (text) |ch| {
            var x = ch;
            if (oneshot.* != 0) {
                x = if (oneshot.* == 'u') std.ascii.toUpper(x) else std.ascii.toLower(x);
                oneshot.* = 0;
            } else if (persist == 'U') x = std.ascii.toUpper(x) else if (persist == 'L') x = std.ascii.toLower(x);
            dst.append(e.gpa, x) catch return error.OutOfMemory;
        }
    }

    fn charLen(e: *Exec, s: []const u8, i: usize) usize {
        // glibc steps over characters when the pattern has multibyte-aware
        // constructs and over bytes otherwise.
        if (!e.s.opts.utf8) return 1;
        const re = e.last_re orelse return 1;
        if (!re.mb) return 1;
        return unicode.decode(s, i).len;
    }

    fn doSubst(e: *Exec, sub: *Subst) Err!bool {
        const subj = e.ps.items;
        var acc: std.ArrayList(u8) = .empty;
        defer acc.deinit(e.gpa);
        var start: usize = 0;
        var count: u64 = 0;
        var did = false;
        var prev_end: ?usize = null;
        while (start <= subj.len) {
            const m = try e.reMatch(sub.re, subj, start) orelse break;
            if (e.s.opts.debug and start == 0 and count == 0 and prev_end == null) try e.dbgRegisters(m, subj, if (sub.re) |r| r.groups else if (e.last_re) |r| r.groups else 0);
            const ms = m.start();
            const me = m.end();
            if (me == ms and prev_end != null and prev_end.? == ms) {
                // an empty match right after the previous match does not count
                if (ms >= subj.len) break;
                acc.appendSlice(e.gpa, subj[start..ms]) catch return error.OutOfMemory;
                const cl = e.charLen(subj, ms);
                acc.appendSlice(e.gpa, subj[ms .. ms + cl]) catch return error.OutOfMemory;
                start = ms + cl;
                prev_end = null;
                continue;
            }
            acc.appendSlice(e.gpa, subj[start..ms]) catch return error.OutOfMemory;
            count += 1;
            if (count < sub.number) {
                acc.appendSlice(e.gpa, subj[ms..me]) catch return error.OutOfMemory;
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
                    try e.appendCase(&acc, part.lit, persist, &oneshot);
                    if (part.group >= 0) {
                        if (m.group(@intCast(part.group))) |g| {
                            try e.appendCase(&acc, subj[g[0]..g[1]], persist, &oneshot);
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
                const cl = if (ms < subj.len) e.charLen(subj, ms) else 1;
                if (ms < subj.len) acc.appendSlice(e.gpa, subj[ms .. ms + cl]) catch return error.OutOfMemory;
                start = ms + cl;
                prev_end = null;
            } else start = me;
        }
        if (!did) return false;
        if (start < subj.len) acc.appendSlice(e.gpa, subj[start..]) catch return error.OutOfMemory;
        e.ps.clearRetainingCapacity();
        e.ps.appendSlice(e.gpa, acc.items) catch return error.OutOfMemory;
        return true;
    }

    /// What `/bin/sh -c COMMAND` writes to its standard output, for `e` and
    /// `s///e`. As with GNU sed's popen, the command is passed unchanged, the
    /// text comes through a pipe and the shell's exit status is ignored.
    fn runShell(e: *Exec, command: []const u8) Err![]u8 {
        try e.flushAll();
        const io = e.s.env.io;
        var child = std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", command }, .stdout = .pipe }) catch return e.subprocessFailed();
        var data: std.ArrayList(u8) = .empty;
        // Closing the pipe in wait() ends a child still writing after a
        // failed read.
        errdefer _ = child.wait(io) catch {};
        _ = try e.readAll(child.stdout.?.handle, &data, "subprocess");
        _ = child.wait(io) catch return e.subprocessFailed();
        return data.items;
    }

    fn subprocessFailed(e: *Exec) Err {
        e.s.obs.emit(.subprocess_failed);
        e.flushAll() catch {};
        e.s.exit_code = 4;
        return error.Abort;
    }

    /// Run the script once on the current pattern space. Returns true to quit.
    fn execute(e: *Exec) Err!bool {
        const cmds = e.s.cmds.items;
        var pc: usize = 0;
        var replaced_flag = false;
        _ = &replaced_flag;
        while (pc < cmds.len) {
            const c = &cmds[pc];
            if (e.s.opts.debug) try e.dbgCommand(c);
            const matched = try e.matchCmd(c) != c.negate;
            if (!matched) {
                if (c.c == '{') pc = c.jump else pc += 1;
                continue;
            }
            pc += 1;
            switch (c.c) {
                '{', '}', ':' => {},
                '=' => {
                    try e.missingNl(e.cur_out);
                    var b: [32]u8 = undefined;
                    const t = std.fmt.bufPrint(&b, "{d}{c}", .{ e.in.line_no, e.delim }) catch unreachable;
                    try e.emit(e.cur_out, t);
                },
                'a' => e.append_q.append(e.gpa, .{ .kind = 'a', .text = c.text }) catch return error.OutOfMemory,
                'i' => {
                    try e.missingNl(e.cur_out);
                    try e.emit(e.cur_out, c.text);
                },
                'c' => {
                    if (!c.range_active or c.a2.kind == .none) {
                        try e.missingNl(e.cur_out);
                        try e.emit(e.cur_out, c.text);
                    }
                    if (c.a2.kind != .none and c.range_active and !c.negate) {
                        // delete without printing; text comes at range end
                    }
                    try e.dbgEnd();
                    e.ps.clearRetainingCapacity();
                    return false;
                },
                'd' => {
                    try e.dbgEnd();
                    e.ps.clearRetainingCapacity();
                    return false;
                },
                'D' => {
                    if (std.mem.indexOfScalar(u8, e.ps.items, e.delim)) |i| {
                        e.ps.replaceRange(e.gpa, 0, i + 1, &.{}) catch return error.OutOfMemory;
                        e.skip_read = true;
                    } else e.ps.clearRetainingCapacity();
                    return false;
                },
                'e' => {
                    if (c.text.len > 0) {
                        const out = try e.runShell(c.text);
                        try e.missingNl(e.cur_out);
                        try e.emit(e.cur_out, out);
                    } else {
                        const out = try e.runShell(e.ps.items);
                        e.ps.clearRetainingCapacity();
                        var o = out;
                        if (o.len > 0 and o[o.len - 1] == '\n') o = o[0 .. o.len - 1];
                        e.ps.appendSlice(e.gpa, o) catch return error.OutOfMemory;
                    }
                },
                'F' => {
                    try e.missingNl(e.cur_out);
                    try e.emit(e.cur_out, e.in.name);
                    try e.emit(e.cur_out, &.{e.delim});
                },
                'g' => {
                    e.ps.clearRetainingCapacity();
                    e.ps.appendSlice(e.gpa, e.hs.items) catch return error.OutOfMemory;
                    e.ps_chomped = e.hs_chomped;
                },
                'G' => {
                    e.ps.append(e.gpa, e.delim) catch return error.OutOfMemory;
                    e.ps.appendSlice(e.gpa, e.hs.items) catch return error.OutOfMemory;
                    e.ps_chomped = e.hs_chomped;
                },
                'h' => {
                    e.hs.clearRetainingCapacity();
                    e.hs.appendSlice(e.gpa, e.ps.items) catch return error.OutOfMemory;
                    e.hs_chomped = e.ps_chomped;
                },
                'H' => {
                    e.hs.append(e.gpa, e.delim) catch return error.OutOfMemory;
                    e.hs.appendSlice(e.gpa, e.ps.items) catch return error.OutOfMemory;
                    e.hs_chomped = e.ps_chomped;
                },
                'l' => try e.doList(c.int),
                'n' => {
                    if (try e.atEof()) {
                        try e.autoprint();
                        try e.dbgEnd();
                        e.quit = true;
                        return true;
                    }
                    try e.autoprint();
                    if (!try e.readPatternSpace()) return true;
                },
                'N' => {
                    if (try e.atEof()) {
                        try e.dbgEnd();
                        if (!e.s.opts.posix) try e.autoprint();
                        e.quit = true;
                        return true;
                    }
                    try e.dumpAppend();
                    const keep = e.gpa.dupe(u8, e.ps.items) catch return error.OutOfMemory;
                    defer e.gpa.free(keep);
                    e.replaced_t = false;
                    if (!try e.readLine()) return true;
                    e.ps.insertSlice(e.gpa, 0, &[_]u8{e.delim}) catch return error.OutOfMemory;
                    e.ps.insertSlice(e.gpa, 0, keep) catch return error.OutOfMemory;
                },
                'p' => try e.writeLine(e.cur_out, e.ps.items, e.ps_chomped),
                'P' => {
                    const i = std.mem.indexOfScalar(u8, e.ps.items, e.delim);
                    if (i) |k| try e.writeLine(e.cur_out, e.ps.items[0..k], true) else try e.writeLine(e.cur_out, e.ps.items, e.ps_chomped);
                },
                'q' => {
                    try e.autoprint();
                    try e.missingNl(e.cur_out);
                    try e.dumpAppend();
                    e.s.exit_code = if (c.int >= 0) @intCast(@as(u64, @intCast(c.int)) & 0xff) else e.s.exit_code;
                    return true;
                },
                'Q' => {
                    e.append_q.clearRetainingCapacity();
                    e.s.exit_code = if (c.int >= 0) @intCast(@as(u64, @intCast(c.int)) & 0xff) else e.s.exit_code;
                    return true;
                },
                'r' => e.append_q.append(e.gpa, .{ .kind = 'r', .text = c.text }) catch return error.OutOfMemory,
                'R' => {
                    var found: ?usize = null;
                    for (e.r_files.items, 0..) |rf, k| {
                        if (std.mem.eql(u8, rf.name, c.text)) found = k;
                    }
                    if (found == null) {
                        var data: std.ArrayList(u8) = .empty;
                        var err: LX.E = .SUCCESS;
                        if (sys.openFd(c.text, sys.O.RDONLY, 0, &err)) |fd| {
                            _ = try e.readAll(fd, &data, c.text);
                            _ = sys.closeFd(fd);
                        }
                        e.r_files.append(e.gpa, .{ .name = c.text, .data = data.items, .pos = 0 }) catch return error.OutOfMemory;
                        found = e.r_files.items.len - 1;
                    }
                    const rf = &e.r_files.items[found.?];
                    if (rf.pos < rf.data.len) {
                        const rest = rf.data[rf.pos..];
                        const nl = std.mem.indexOfScalar(u8, rest, e.delim);
                        // With its delimiter, if the file gives it one.
                        const line = if (nl) |k| rest[0 .. k + 1] else rest;
                        rf.pos += line.len;
                        e.append_q.append(e.gpa, .{ .kind = 'R', .text = line }) catch return error.OutOfMemory;
                    }
                },
                's' => {
                    const sub = c.sub.?;
                    if (try e.doSubst(sub)) {
                        e.replaced_t = true;
                        if (sub.eval) {
                            const out = try e.runShell(e.ps.items);
                            e.ps.clearRetainingCapacity();
                            var o = out;
                            if (o.len > 0 and o[o.len - 1] == '\n') o = o[0 .. o.len - 1];
                            e.ps.appendSlice(e.gpa, o) catch return error.OutOfMemory;
                        }
                        if (sub.print > 0) try e.writeLine(e.cur_out, e.ps.items, e.ps_chomped);
                        if (sub.wfile) |w| try e.writeLine(e.s.outs.items[w], e.ps.items, e.ps_chomped);
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
                'w' => try e.writeLine(e.s.outs.items[c.out], e.ps.items, e.ps_chomped),
                'W' => {
                    const o = e.s.outs.items[c.out];
                    const i = std.mem.indexOfScalar(u8, e.ps.items, e.delim);
                    if (i) |k| try e.writeLine(o, e.ps.items[0..k], true) else try e.writeLine(o, e.ps.items, e.ps_chomped);
                },
                'x' => {
                    std.mem.swap(std.ArrayList(u8), &e.ps, &e.hs);
                    std.mem.swap(bool, &e.ps_chomped, &e.hs_chomped);
                },
                'y' => {
                    if (c.ypairs) |pairs| {
                        try e.translateUtf8(pairs);
                    } else {
                        const t = c.ytab.?;
                        for (e.ps.items) |*ch| ch.* = t[ch.*];
                    }
                },
                'z' => e.ps.clearRetainingCapacity(),
                else => {},
            }
            if (e.s.opts.debug) switch (c.c) {
                's', 'y', 'G', 'z', 'n', 'N' => try e.dbgPattern(),
                'g', 'h', 'H' => try e.dbgHold(),
                'x' => {
                    try e.dbgPattern();
                    try e.dbgHold();
                },
                else => {},
            };
        }
        try e.dbgEnd();
        try e.autoprint();
        return false;
    }

    fn target(e: *Exec, c: *Cmd) usize {
        _ = e;
        return c.jump;
    }
};

test "compile errors are structured" {
    const env: Env = .{ .io = std.testing.io, .gpa = std.testing.allocator };
    var diag: CompileError = .{};
    try std.testing.expectError(error.BadProgram, compile(env, .{}, &.{.{ .text = "k", .is_file = false, .name = "", .index = 1 }}, &diag));
    try std.testing.expectEqual(CompileError.Kind.syntax, diag.kind);
    try std.testing.expectEqual(@as(usize, 1), diag.pos);
    try std.testing.expectEqualStrings("unknown command: `k'", diag.message());
    try std.testing.expectError(error.BadProgram, compile(env, .{}, &.{.{ .text = "b nowhere", .is_file = false, .name = "", .index = 1 }}, &diag));
    try std.testing.expectEqual(CompileError.Kind.missing_label, diag.kind);
    try std.testing.expectEqualStrings("nowhere", diag.name());
}

test "compile once, run many" {
    const env: Env = .{ .io = std.testing.io, .gpa = std.testing.allocator };
    var diag: CompileError = .{};
    var prog = try compile(env, .{}, &.{.{ .text = "s/a/X/;2q", .is_file = false, .name = "", .index = 1 }}, &diag);
    defer prog.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in", .data = "a1\na2\na3\n" });
    for (0..2) |_| {
        const f = try tmp.dir.openFile(std.testing.io, "in", .{});
        defer f.close(std.testing.io);
        var out: Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        const r = try run(env, &prog, .{}, &.{.{ .name = "in", .source = .{ .file = f } }}, &out.writer, .none);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expectEqualStrings("X1\nX2\n", out.written());
    }
}
