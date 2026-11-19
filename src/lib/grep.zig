// SPDX-License-Identifier: GPL-2.0-or-later
//! grep library: print lines that match patterns. Reference: GNU grep 3.12
//! (grep.c). Patterns are compiled to the Perl dialect of regex-zig through
//! src/posixre.zig (BRE, ERE, fixed strings) or passed as is (-P).
//!
//! Two entry points (decision 0004):
//!   - `Matcher.compile` turns a newline-separated pattern list into a
//!     compiled `Matcher` usable on any buffer (`isMatch`, `find`);
//!   - `run` walks inputs (files, directories, standard input) with a
//!     `Matcher` and writes grep's output to an `Io.Writer`.
//!
//! Extensions (docs/compatibility/grep.md): none beyond what GNU grep
//! accepts; -P is regex-zig's Perl dialect, not PCRE2.
//!
//! Boundary notes: files and directories are opened and read through `sys.zig`
//! file descriptors (decision 0002); an `Input` with an open `Io.File` (such as
//! standard input) is read through that file's descriptor.

const std = @import("std");
const Io = std.Io;
const LX = std.os.linux;
const common = @import("common.zig");
const posixre = @import("../posixre.zig");
const regex = @import("regex");
const sys = @import("../sys.zig");
const unicode = @import("../unicode.zig");
const fnmatch = @import("../fnmatch.zig");

pub const Env = common.Env;
pub const Input = common.Input;

/// Pattern syntax: -G, -E, -F, -P.
pub const Syntax = enum { basic, extended, fixed, perl };
pub const Binary = enum { binary, text, without_match };
pub const Dirs = enum { read, recurse, skip };
pub const Devs = enum { read_cmdline, read, skip };
pub const ListFiles = enum { none, matching, nonmatching };

pub const Span = struct { start: usize, end: usize };

/// SGR colour capabilities (GREP_COLORS).
pub const Colors = struct {
    ms: []const u8 = "01;31",
    mc: []const u8 = "01;31",
    sl: []const u8 = "",
    cx: []const u8 = "",
    fn_: []const u8 = "35",
    ln: []const u8 = "32",
    bn: []const u8 = "32",
    se: []const u8 = "36",
    rv: bool = false,
    ne: bool = false,

    /// GREP_COLOR / GREP_COLORS from `env`. The returned slices point into
    /// the environment map. A deprecated GREP_COLOR is reported through
    /// `observer` as `.deprecated_grep_color`.
    pub fn fromEnv(env: Env, observer: Observer) Colors {
        var c: Colors = .{};
        applyColors(&c, env, observer);
        return c;
    }
};

pub const Glob = struct { pat: []const u8, include: bool };

pub const Options = struct {
    syntax: Syntax = .basic,
    icase: bool = false,
    invert: bool = false,
    word: bool = false,
    line: bool = false,
    count: bool = false,
    list: ListFiles = .none,
    /// -q: stop at the first selected line, print nothing.
    quiet: bool = false,
    only: bool = false,
    byte_offset: bool = false,
    line_number: bool = false,
    /// -H (true) / -h (false); null: decided by the number of inputs.
    with_filename: ?bool = null,
    null_after_name: bool = false,
    null_data: bool = false,
    initial_tab: bool = false,
    max_count: i64 = std.math.maxInt(i64),
    before: i64 = -1,
    after: i64 = -1,
    binary_files: Binary = .binary,
    directories: Dirs = .read,
    devices: Devs = .read_cmdline,
    deref_recursive: bool = false,
    color: bool = false,
    colors: Colors = .{},
    line_buffered: bool = false,
    /// Name of standard input in output.
    label: []const u8 = "(standard input)",
    group_sep: ?[]const u8 = "--",
    utf8: bool = false,
    /// --include / --exclude, in command-line order.
    globs: []const Glob = &.{},
    exclude_dirs: []const []const u8 = &.{},
    /// The file standard output is writing to, for the "input file is also
    /// the output" check; null disables it.
    output_file: ?Io.File = null,
    /// The directory walk started from an implicit "." (no operands with -r):
    /// names are printed without the "./" prefix.
    implicit_dot: bool = false,

    /// Fold an empty pattern list into the options the way GNU does and
    /// report whether nothing can possibly match (the caller then skips the
    /// search and exits 1). `keys_len` is the length of the pattern list
    /// (patterns joined with newlines); `have_keys` is false when no pattern
    /// was given with -e/-f.
    pub fn prepare(o: *Options, keys_len: usize, have_keys: bool) bool {
        var keycc = keys_len;
        if (have_keys and keys_len == 0) {
            // no keys at all (-f /dev/null): match nothing
            o.invert = !o.invert;
            o.line = false;
            o.word = false;
            keycc = 0;
        }
        return (o.max_count == 0 or (keycc == 0 and o.invert and !o.line and !o.word)) and o.list != .nonmatching;
    }
};

/// Non-fatal problems and warnings; the caller words them.
pub const Event = union(enum) {
    /// `name` could not be opened, read or listed.
    read_error: struct { name: []const u8, errno: LX.E },
    is_directory: []const u8,
    input_is_output: []const u8,
    /// Matches were found in a file with binary data and not printed.
    binary_matches: []const u8,
    /// "warning: X at start of expression" (a '{' is reported as '{').
    leading_operator: u8,
    /// GREP_COLOR is set (deprecated); the payload is its value.
    deprecated_grep_color: []const u8,
};
pub const Observer = common.Observer(Event);

pub const CompileError = struct {
    kind: Kind = .syntax,
    /// The offending pattern.
    pattern: []const u8 = "",
    /// Was it compiled as an ERE (for posixre.diagnoseGrep).
    extended: bool = false,

    pub const Kind = enum {
        /// Invalid regular expression syntax; use `posixre.diagnoseGrep`.
        syntax,
        /// "[:space:]" outside a bracket expression.
        bare_class,
        /// -P pattern regex-zig rejects.
        invalid_perl,
    };
};

pub fn localeIsUtf8(env: Env) bool {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |k| {
        const v = env.getenv(k) orelse continue;
        if (v.len == 0) continue;
        return std.ascii.findIgnoreCase(v, "utf-8") != null or std.ascii.findIgnoreCase(v, "utf8") != null;
    }
    return false;
}

const Pat = struct {
    re: regex.Regex,
    longest: ?*regex.Regex,
    fin: posixre.Finder,
    mb: bool,
};

/// A compiled pattern list. Safe to use on many buffers; not thread-safe
/// (searchers keep scratch state).
pub const Matcher = struct {
    gpa: std.mem.Allocator,
    pats: std.ArrayList(*Pat) = .empty,
    utf8: bool = false,

    pub const Error = error{ OutOfMemory, BadPattern };

    /// Compile `keys` (patterns separated by '\n') under `options` (syntax,
    /// icase, word, line, utf8). On `error.BadPattern`, `diag` says why.
    pub fn compile(gpa: std.mem.Allocator, options: Options, keys: []const u8, observer: Observer, diag: *CompileError) Error!Matcher {
        var m: Matcher = .{ .gpa = gpa, .utf8 = options.utf8 };
        errdefer m.deinit();
        var it = std.mem.splitScalar(u8, keys, '\n');
        while (it.next()) |pt| try m.add(options, pt, observer, diag);
        return m;
    }

    pub fn deinit(m: *Matcher) void {
        for (m.pats.items) |p| {
            p.fin.deinit();
            p.re.deinit(m.gpa);
            if (p.longest) |l| {
                l.deinit(m.gpa);
                m.gpa.destroy(l);
            }
            m.gpa.destroy(p);
        }
        m.pats.deinit(m.gpa);
    }

    /// Leftmost-longest match over all patterns starting at or after `from`.
    pub fn find(m: *Matcher, line: []const u8, from: usize) ?Span {
        var best: ?Span = null;
        for (m.pats.items) |p| {
            const mm = (p.fin.find(line, from) catch null) orelse continue;
            const sp = Span{ .start = mm.start(), .end = mm.end() };
            if (best == null or sp.start < best.?.start or (sp.start == best.?.start and sp.end > best.?.end)) best = sp;
        }
        return best;
    }

    /// Does any pattern match somewhere in `line`?
    pub fn isMatch(m: *Matcher, line: []const u8) bool {
        for (m.pats.items) |p| {
            if ((p.fin.find(line, 0) catch null) != null) return true;
        }
        return false;
    }

    fn translate(m: *Matcher, options: Options, pat: []const u8, flags_out: *posixre.Flags, observer: Observer, diag: *CompileError) Error![]u8 {
        const gpa = m.gpa;
        const opts = posixre.Opts{ .utf8 = options.utf8, .icase = options.icase, .lenient_brace = true };
        switch (options.syntax) {
            .basic, .extended => {
                const ere = options.syntax == .extended;
                const body = posixre.translateFlags(gpa, pat, ere, opts, flags_out) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.BadPattern => {
                        diag.* = .{ .kind = .syntax, .pattern = pat, .extended = ere };
                        return error.BadPattern;
                    },
                };
                if (posixre.bareClass(pat)) {
                    gpa.free(body);
                    diag.* = .{ .kind = .bare_class, .pattern = pat, .extended = ere };
                    return error.BadPattern;
                }
                if (flags_out.leading_op != 0) observer.emit(.{ .leading_operator = flags_out.leading_op });
                return body;
            },
            .fixed => {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(gpa);
                var i: usize = 0;
                while (i < pat.len) {
                    const c = pat[i];
                    if (options.utf8 and c >= 0x80) {
                        const d = unicode.decode(pat, i);
                        if (d.valid) {
                            try posixre.utf8Literal(gpa, &out, d.cp, options.icase);
                            i += d.len;
                            continue;
                        }
                    }
                    if (c < 0x20 or c >= 0x7f) {
                        const hex = "0123456789abcdef";
                        try out.appendSlice(gpa, &.{ '\\', 'x', hex[c >> 4], hex[c & 15] });
                    } else {
                        if (std.mem.indexOfScalar(u8, "\\^$.|?*+()[]{}/#", c) != null) try out.append(gpa, '\\');
                        try out.append(gpa, c);
                    }
                    i += 1;
                }
                return try out.toOwnedSlice(gpa);
            },
            .perl => {
                if (!options.utf8) return try gpa.dupe(u8, pat);
                return try perlUtf8(gpa, pat);
            },
        }
    }

    fn add(m: *Matcher, options: Options, pat: []const u8, observer: Observer, diag: *CompileError) Error!void {
        const gpa = m.gpa;
        var flags: posixre.Flags = .{};
        const body = try m.translate(options, pat, &flags, observer, diag);
        defer gpa.free(body);
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "(?s)");
        if (options.line) {
            try src.print(gpa, "\\A(?:{s})\\z", .{body});
        } else if (options.word and options.utf8) {
            var set: unicode.Set = .{};
            defer set.deinit(gpa);
            try set.addAll(gpa, unicode.classRanges(.alnum));
            try set.add(gpa, '_', '_');
            var wg: std.ArrayList(u8) = .empty;
            defer wg.deinit(gpa);
            try unicode.appendSetRegex(gpa, &wg, &set);
            var wf: std.ArrayList(u8) = .empty;
            defer wf.deinit(gpa);
            try unicode.appendSetFlat(gpa, &wf, &set);
            try src.print(gpa, "(?<!{s})(?:{s})(?!{s})", .{ wf.items, body, wg.items });
        } else if (options.word) {
            try src.print(gpa, "(?<![A-Za-z0-9_])(?:{s})(?![A-Za-z0-9_])", .{body});
        } else try src.appendSlice(gpa, body);
        const re = regex.Regex.compile(gpa, src.items, .{ .dialect = .perl, .ignore_case = options.icase, .limits = posixre.big_limits }, null) catch {
            diag.* = .{ .kind = if (options.syntax == .perl) .invalid_perl else .syntax, .pattern = pat, .extended = options.syntax == .extended };
            return error.BadPattern;
        };
        const p = try gpa.create(Pat);
        errdefer gpa.destroy(p);
        p.re = re;
        errdefer p.re.deinit(gpa);
        p.longest = null;
        if (options.syntax != .perl and !options.line and !options.word) {
            if (posixre.longestSource(gpa, body, "(?s)", flags) catch null) |ls| {
                defer gpa.free(ls);
                if (regex.Regex.compile(gpa, ls, .{ .dialect = .perl, .ignore_case = options.icase, .limits = posixre.big_limits }, null) catch null) |lre| {
                    const keep = try gpa.create(regex.Regex);
                    keep.* = lre;
                    p.longest = keep;
                }
            }
        }
        errdefer if (p.longest) |l| {
            l.deinit(gpa);
            gpa.destroy(l);
        };
        p.fin = try posixre.Finder.initParts(gpa, &p.re, p.longest);
        p.mb = flags.mb;
        try m.pats.append(gpa, p);
    }
};

/// PCRE2 in UTF mode: `.` and negated bracket expressions match characters.
fn perlUtf8(gpa: std.mem.Allocator, pat: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const mb = "[\\xc2-\\xdf][\\x80-\\xbf]|[\\xe0-\\xef][\\x80-\\xbf][\\x80-\\xbf]|[\\xf0-\\xf4][\\x80-\\xbf][\\x80-\\xbf][\\x80-\\xbf]";
    var i: usize = 0;
    while (i < pat.len) {
        const c = pat[i];
        if (c == '\\' and i + 1 < pat.len) {
            try out.appendSlice(gpa, pat[i .. i + 2]);
            i += 2;
            continue;
        }
        if (c == '.') {
            try out.appendSlice(gpa, unicode.any_char);
            i += 1;
            continue;
        }
        if (c == '[') {
            var j = i + 1;
            const neg = j < pat.len and pat[j] == '^';
            if (neg) j += 1;
            if (j < pat.len and pat[j] == ']') j += 1;
            while (j < pat.len and pat[j] != ']') : (j += 1) {
                if (pat[j] == '\\') j += 1;
                if (j < pat.len and pat[j] == '[' and j + 1 < pat.len and pat[j + 1] == ':') {
                    j = (std.mem.indexOfPos(u8, pat, j + 2, ":]") orelse pat.len - 1) + 1;
                }
            }
            if (j >= pat.len) {
                try out.appendSlice(gpa, pat[i..]);
                break;
            }
            if (neg) {
                try out.appendSlice(gpa, "(?:");
                try out.appendSlice(gpa, pat[i..j]);
                try out.appendSlice(gpa, "\\x80-\\xff]|");
                try out.appendSlice(gpa, mb);
                try out.append(gpa, ')');
            } else try out.appendSlice(gpa, pat[i .. j + 1]);
            i = j + 1;
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
    return try out.toOwnedSlice(gpa);
}

fn applyColors(c: *Colors, env: Env, observer: Observer) void {
    if (env.getenv("GREP_COLOR")) |gc| {
        if (gc.len > 0) {
            observer.emit(.{ .deprecated_grep_color = gc });
            c.ms = gc;
            c.mc = gc;
        }
    }
    const val_env = env.getenv("GREP_COLORS") orelse return;
    var it = std.mem.splitScalar(u8, val_env, ':');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        var name = item;
        var val: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, item, '=')) |k| {
            name = item[0..k];
            val = item[k + 1 ..];
        }
        if (std.mem.eql(u8, name, "mt")) {
            if (val) |v| {
                c.ms = v;
                c.mc = v;
            }
        } else if (std.mem.eql(u8, name, "ms")) {
            if (val) |v| c.ms = v;
        } else if (std.mem.eql(u8, name, "mc")) {
            if (val) |v| c.mc = v;
        } else if (std.mem.eql(u8, name, "sl")) {
            if (val) |v| c.sl = v;
        } else if (std.mem.eql(u8, name, "cx")) {
            if (val) |v| c.cx = v;
        } else if (std.mem.eql(u8, name, "fn")) {
            if (val) |v| c.fn_ = v;
        } else if (std.mem.eql(u8, name, "ln")) {
            if (val) |v| c.ln = v;
        } else if (std.mem.eql(u8, name, "bn")) {
            if (val) |v| c.bn = v;
        } else if (std.mem.eql(u8, name, "se")) {
            if (val) |v| c.se = v;
        } else if (std.mem.eql(u8, name, "rv")) {
            c.rv = true;
        } else if (std.mem.eql(u8, name, "ne")) {
            c.ne = true;
        }
    }
}

// ------------------------------------------------------------------- state

pub const Result = struct {
    /// At least one selected line (the wrapper exits 0, else 1).
    matched: bool = false,
    /// A file could not be read or listed (the wrapper exits 2).
    errors: bool = false,
    /// -q found a match and stopped the whole run: exit 0 regardless of
    /// errors.
    early_exit: bool = false,
};

pub const RunError = error{ OutOfMemory, WriteFailed };
const Err = RunError;

const G = struct {
    env: Env,
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    obs: Observer,
    m: *Matcher,
    o: Options,
    eol: u8 = '\n',
    out: std.ArrayList(u8) = .empty,
    errseen: bool = false,
    out_file: i8 = 0, // 0 no, 1 yes, -1 only when recursing into a directory
    out_quiet: bool = false,
    done_on_match: bool = false,
    exit_on_match: bool = false,
    early: bool = false,
    stdout_st: ?sys.FileStat = null,
    colors: Colors = .{},
    // per file
    fname: []const u8 = "",
    show_name: bool = false,
    totalnl: u64 = 0,
    lastout_line: i64 = -1, // line number of the last printed line (-1 none)
    pending: i64 = 0,
    used: bool = false,
    outleft: i64 = 0,
    before_q: std.ArrayList(CtxLine) = .empty,
    line_no: u64 = 0,
    offset: u64 = 0, // byte offset of the current line start
    last_printed_end: ?u64 = null, // offset just after the last printed line
    binary: bool = false,
    nlines_first_null: i64 = -1,
    nlines: u64 = 0,
    enc_error_suppressed: bool = false,
    implicit_dot: bool = false,
    offset_width: usize = 0,
};

const CtxLine = struct { text: []u8, no: u64, off: u64 };

/// Search `inputs` for lines selected by `matcher` under `options` and write
/// grep's report to `writer`. `inputs` is never empty: with no operands the
/// caller passes standard input (or "." with `implicit_dot` for -r). A path
/// is opened relative to the current directory; an `Input` holding an open
/// file (standard input) is read through its descriptor and named by
/// `options.label`.
pub fn run(env: Env, options: Options, matcher: *Matcher, inputs: []const Input, writer: *Io.Writer, observer: Observer) RunError!Result {
    var g = G{ .env = env, .gpa = env.gpa, .w = writer, .obs = observer, .m = matcher, .o = options };
    defer {
        flushBefore(&g);
        g.before_q.deinit(g.gpa);
        g.out.deinit(g.gpa);
    }
    g.eol = if (g.o.null_data) 0 else '\n';
    g.colors = g.o.colors;
    g.exit_on_match = g.o.quiet;
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    g.out_quiet = g.o.count or g.done_on_match;
    if (g.exit_on_match) g.out_quiet = true;
    if (g.o.list != .none) g.out_quiet = true;
    // -q with -c / -l: quiet output wins
    if (g.exit_on_match) {
        g.o.count = false;
        g.o.list = .none;
    }
    if (g.o.max_count < 0) g.o.max_count = std.math.maxInt(i64);

    // stdout identity for the "input file is also the output" check
    if (g.o.output_file) |f| {
        var serr: LX.E = .SUCCESS;
        g.stdout_st = sys.fstatFd(f.handle, &serr);
    }

    g.out_file = if (g.o.with_filename) |h|
        @as(i8, if (h) 1 else 0)
    else if (inputs.len > 1)
        1
    else if (g.o.directories == .recurse)
        -1
    else
        0;
    g.implicit_dot = g.o.implicit_dot;

    var any = false;
    for (inputs) |in| {
        switch (in.source) {
            .file => |f| {
                g.show_name = g.out_file == 1;
                var serr: LX.E = .SUCCESS;
                const seekable = sys.seekFd(f.handle, 0, 1, &serr) != null;
                if (try grepOpened(&g, f.handle, g.o.label, true, seekable)) any = true;
            },
            .path => |p| {
                if (try grepFile(&g, p, p, true, false)) any = true;
            },
        }
        if (g.early) break;
    }
    try flushOut(&g);
    return .{ .matched = any, .errors = g.errseen, .early_exit = g.early };
}

// ----------------------------------------------------------------- output

fn flushOut(g: *G) Err!void {
    if (g.out.items.len == 0) return;
    try g.w.writeAll(g.out.items);
    try g.w.flush();
    g.out.clearRetainingCapacity();
}

fn emit(g: *G, bytes: []const u8) Err!void {
    try g.out.appendSlice(g.gpa, bytes);
    if (g.out.items.len > 65536) try flushOut(g);
}

fn emitByte(g: *G, b: u8) Err!void {
    try g.out.append(g.gpa, b);
}

fn sgrStart(g: *G, color: []const u8) Err!void {
    if (color.len == 0) return;
    try emit(g, "\x1b[");
    try emit(g, color);
    try emit(g, if (g.colors.ne) "m" else "m\x1b[K");
}

fn sgrEnd(g: *G, color: []const u8) Err!void {
    if (color.len == 0) return;
    try emit(g, if (g.colors.ne) "\x1b[m" else "\x1b[m\x1b[K");
}

fn printSep(g: *G, sep: u8) Err!void {
    if (g.o.color) try sgrStart(g, g.colors.se);
    try emitByte(g, sep);
    if (g.o.color) try sgrEnd(g, g.colors.se);
}

fn printFilename(g: *G) Err!void {
    if (g.o.color) try sgrStart(g, g.colors.fn_);
    try emit(g, g.fname);
    if (g.o.color) try sgrEnd(g, g.colors.fn_);
}

fn printOffset(g: *G, n: u64, _: usize, color: []const u8) Err!void {
    const min_width = g.offset_width;
    var buf: [32]u8 = undefined;
    var s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    var pad: [32]u8 = undefined;
    if (g.o.initial_tab and s.len < min_width) {
        const k = min_width - s.len;
        @memset(pad[0..k], ' ');
        @memcpy(pad[k .. k + s.len], s);
        s = pad[0 .. k + s.len];
    }
    if (g.o.color) try sgrStart(g, color);
    try emit(g, s);
    if (g.o.color) try sgrEnd(g, color);
}

fn printLineHead(g: *G, line_no: u64, off: u64, len: usize, sep: u8) Err!void {
    if (g.show_name) {
        try printFilename(g);
        if (g.o.null_after_name) try emitByte(g, 0) else try printSep(g, sep);
    }
    if (g.o.line_number) {
        try printOffset(g, line_no, 4, g.colors.ln);
        try printSep(g, sep);
    }
    if (g.o.byte_offset) {
        try printOffset(g, off, 6, g.colors.bn);
        try printSep(g, sep);
    }
    if (g.o.initial_tab and (g.show_name or g.o.line_number or g.o.byte_offset) and len > 0) try emitByte(g, '\t');
}

// --------------------------------------------------------------- matching
// ----------------------------------------------------------------- lines

fn writeRaw(g: *G, bytes: []const u8) void {
    try emit(g, bytes);
}

/// Print one line (without its terminator) as selected (':') or context ('-').
fn encFail(g: *G, text: []const u8) bool {
    if (g.o.utf8 and g.o.binary_files == .binary and !validUtf8(text)) {
        g.enc_error_suppressed = true;
        return true;
    }
    return false;
}

fn prline(g: *G, text: []const u8, no: u64, off: u64, sep: u8) Err!bool {
    const o = &g.o;
    if (!o.only and encFail(g, text)) return false;
    if (!o.only) try printLineHead(g, no, off, text.len, sep);
    const matching = (sep == ':') != o.invert;
    var line_color: []const u8 = "";
    var match_color: []const u8 = "";
    if (o.color) {
        const sel_line = ((sep == ':') != (o.invert and g.colors.rv));
        line_color = if (sel_line) g.colors.sl else g.colors.cx;
        match_color = if (sep == ':') g.colors.ms else g.colors.mc;
    }
    var beg: usize = 0;
    if ((o.only and matching) or (o.color and (line_color.len > 0 or match_color.len > 0))) {
        if (matching and (o.only or match_color.len > 0)) {
            beg = try printLineMiddle(g, text, no, off, line_color, match_color);
        }
        if (!o.only and line_color.len > 0) {
            // tail: the rest of the line (minus a trailing CR) in the line colour
            var tail = text.len - beg;
            if (tail > 0 and text[text.len - 1] == '\r') tail -= 1;
            if (tail > 0) {
                try sgrStart(g, line_color);
                try emit(g, text[beg .. beg + tail]);
                try sgrEnd(g, line_color);
                beg += tail;
            }
        }
    }
    if (!o.only) {
        try emit(g, text[beg..]);
        try emitByte(g, g.eol);
    }
    if (o.line_buffered) try flushOut(g);
    return true;
}

fn printLineMiddle(g: *G, text: []const u8, no: u64, off: u64, line_color: []const u8, match_color: []const u8) Err!usize {
    var cur: usize = 0;
    var mid: ?usize = null;
    while (cur < text.len) {
        const m = g.m.find(text, cur) orelse break;
        const b = m.start;
        var size = m.end - m.start;
        if (b == text.len) break;
        if (size == 0) {
            size = 1;
            if (mid == null) mid = cur;
            // skip a whole character in UTF-8
            if (g.o.utf8) size = unicode.decode(text, b).len;
            cur = b + size;
            continue;
        }
        if (encFail(g, text[b .. b + size])) {
            cur = b + size;
            continue;
        }
        if (g.o.only) {
            const sep: u8 = if (g.o.invert) '-' else ':';
            try printLineHead(g, no, off + b, size, sep);
        } else {
            try sgrStart(g, line_color);
            if (mid) |md| {
                cur = md;
                mid = null;
            }
            try emit(g, text[cur..b]);
        }
        try sgrStart(g, match_color);
        try emit(g, text[b .. b + size]);
        try sgrEnd(g, match_color);
        if (g.o.only) try emitByte(g, g.eol);
        cur = b + size;
    }
    if (g.o.only) return text.len;
    if (mid) |md| return md;
    return cur;
}

fn flushBefore(g: *G) void {
    for (g.before_q.items) |c| g.gpa.free(c.text);
    g.before_q.clearRetainingCapacity();
}

// --------------------------------------------------------------- scanning

const Stop = enum { cont, stop };

/// Process one input line. Returns .stop when scanning of this file ends.
fn doLine(g: *G, text: []const u8) Err!Stop {
    g.line_no += 1;
    const no = g.line_no;
    const off = g.offset;
    g.offset += text.len + 1;
    const o = &g.o;
    const matched = g.m.isMatch(text);
    const selected = matched != o.invert;

    if (g.outleft == 0) {
        // -m reached: only trailing context remains
        if (g.pending > 0 and !g.out_quiet) {
            if (try prline(g, text, no, off, '-')) g.lastout_line = @intCast(no);
            g.pending -= 1;
            if (g.pending == 0) return .stop;
            return .cont;
        }
        return .stop;
    }

    if (selected) {
        g.nlines += 1;
        if (!g.out_quiet) {
            if (g.binary and o.binary_files == .binary) {
                // matches in a binary file are not printed
                if (g.nlines_first_null < 0) g.nlines_first_null = 0;
            }
        }
        if (g.binary and o.binary_files == .binary and !g.out_quiet) {
            // first match in binary data: stop here, a message follows
            g.outleft -= 1;
            g.done_on_match = true;
            return .stop;
        }
        if (!g.out_quiet) {
            // leading context
            if (g.pending > 0) {
                // (pending trailing context was already printed line by line)
                g.pending = 0;
            }
            var first_ctx_no: u64 = no;
            if (g.before_q.items.len > 0) first_ctx_no = g.before_q.items[0].no;
            if ((o.before >= 0 or o.after >= 0) and g.used and (g.lastout_line < 0 or g.lastout_line + 1 != @as(i64, @intCast(first_ctx_no)))) {
                if (o.group_sep) |gs| {
                    if (o.color) try sgrStart(g, g.colors.se);
                    try emit(g, gs);
                    if (o.color) try sgrEnd(g, g.colors.se);
                    try emitByte(g, '\n');
                }
            }
            for (g.before_q.items) |c| {
                if (try prline(g, c.text, c.no, c.off, '-')) g.lastout_line = @intCast(c.no);
            }
            flushBefore(g);
            if (try prline(g, text, no, off, ':')) g.lastout_line = @intCast(no);
            g.pending = @max(0, o.after);
            g.used = true;
        }
        g.outleft -= 1;
        if (g.exit_on_match) {
            try flushOut(g);
            g.early = true;
            return .stop;
        }
        if (g.done_on_match) return .stop;
        if (g.outleft == 0 and g.pending <= 0) return .stop;
        return .cont;
    }

    // not selected
    if (!g.out_quiet) {
        if (g.pending > 0) {
            if (try prline(g, text, no, off, '-')) g.lastout_line = @intCast(no);
            g.pending -= 1;
        } else if (o.before > 0) {
            const copy = try g.gpa.dupe(u8, text);
            if (g.before_q.items.len >= @as(usize, @intCast(o.before))) {
                g.gpa.free(g.before_q.items[0].text);
                _ = g.before_q.orderedRemove(0);
            }
            try g.before_q.append(g.gpa, .{ .text = copy, .no = no, .off = off });
        }
    }
    return .cont;
}

fn validUtf8(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            i += 1;
            continue;
        }
        const d = unicode.decode(s, i);
        if (!d.valid) return false;
        i += d.len;
    }
    return true;
}

/// Search one open descriptor. Returns the number of selected lines.
fn grepFd(g: *G, fd: i32, seekable_stdin: bool) Err!u64 {
    const o = &g.o;
    g.totalnl = 0;
    g.lastout_line = -1;
    g.pending = 0;
    g.line_no = 0;
    g.offset = 0;
    g.binary = false;
    g.nlines = 0;
    g.nlines_first_null = -1;
    g.enc_error_suppressed = false;
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    g.outleft = o.max_count;
    flushBefore(g);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(g.gpa);
    var pos: usize = 0;
    var eof = false;
    var chunk: [98304]u8 = undefined;
    var stopped = false;
    var consumed_total: u64 = 0;
    const base_quiet = g.out_quiet;
    var extra_nul_split = false;

    while (!stopped) {
        // find next line
        var term: ?usize = null;
        if (pos < buf.items.len) {
            const rest = buf.items[pos..];
            if (extra_nul_split) {
                term = std.mem.indexOfAny(u8, rest, "\n\x00");
            } else term = std.mem.indexOfScalar(u8, rest, g.eol);
        }
        if (term == null) {
            if (eof) {
                if (pos < buf.items.len) {
                    // final line without terminator
                    const text = buf.items[pos..];
                    consumed_total += text.len;
                    pos = buf.items.len;
                    if (try doLine(g, text) == .stop) stopped = true;
                }
                break;
            }
            // read more
            if (pos > 0 and pos == buf.items.len) {
                buf.clearRetainingCapacity();
                pos = 0;
            } else if (pos > (1 << 20)) {
                try buf.replaceRange(g.gpa, 0, pos, &.{});
                pos = 0;
            }
            var err: LX.E = .SUCCESS;
            const n = sys.readFd(fd, &chunk, &err) orelse {
                g.obs.emit(.{ .read_error = .{ .name = g.fname, .errno = err } });
                g.errseen = true;
                break;
            };
            if (n == 0) {
                eof = true;
                continue;
            }
            if (!g.binary and o.binary_files != .text and !o.null_data) {
                if (std.mem.indexOfScalar(u8, chunk[0..n], 0) != null) {
                    g.binary = true;
                    if (o.binary_files == .without_match) {
                        return 0;
                    }
                    extra_nul_split = true;
                    g.nlines_first_null = @intCast(g.nlines);
                    if (!g.out_quiet) {
                        // binary: stop at the first match, no output
                        g.done_on_match = true;
                    }
                }
            }
            try buf.appendSlice(g.gpa, chunk[0..n]);
            continue;
        }
        const text = buf.items[pos .. pos + term.?];
        consumed_total += term.? + 1;
        pos += term.? + 1;
        if (try doLine(g, text) == .stop) stopped = true;
    }
    _ = base_quiet;
    // restore stdin position when stopped early on a seekable stdin
    if (seekable_stdin and stopped and pos < buf.items.len + 0) {
        const unread: i64 = @intCast(buf.items.len - pos);
        var serr: LX.E = .SUCCESS;
        _ = sys.seekFd(fd, -unread, 1, &serr);
    } else if (seekable_stdin and stopped and !eof) {
        // data not yet read stays in the file
    }
    return g.nlines;
}

// ------------------------------------------------------------------ files

fn matchGlobs(g: *G, name: []const u8, base: []const u8, cmdline: bool) bool {
    // returns true when the file is to be skipped
    var has_include = false;
    var included = false;
    for (g.o.globs) |gl| {
        const hit = globHit(gl.pat, name, base, cmdline);
        if (gl.include) {
            has_include = true;
            if (hit) included = true;
        } else if (hit) return true;
    }
    if (has_include and !included) return true;
    return false;
}

fn globHit(pat: []const u8, name: []const u8, base: []const u8, cmdline: bool) bool {
    if (fnmatch.match(pat, base, .{})) return true;
    if (cmdline) {
        if (fnmatch.match(pat, name, .{})) return true;
        // match any trailing sequence of components
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, name, i, '/')) |k| {
            if (fnmatch.match(pat, name[k + 1 ..], .{})) return true;
            i = k + 1;
        }
    }
    return false;
}

fn dirExcluded(g: *G, name: []const u8, base: []const u8, cmdline: bool) bool {
    for (g.o.exclude_dirs) |p| {
        var pp = p;
        while (pp.len > 1 and pp[pp.len - 1] == '/') pp = pp[0 .. pp.len - 1];
        var nm = name;
        while (nm.len > 1 and nm[nm.len - 1] == '/') nm = nm[0 .. nm.len - 1];
        var bs = base;
        while (bs.len > 1 and bs[bs.len - 1] == '/') bs = bs[0 .. bs.len - 1];
        if (globHit(pp, nm, bs, cmdline)) return true;
    }
    return false;
}

fn finishFile(g: *G, count: u64) Err!bool {
    // returns true when the file had a selected line
    const o = &g.o;
    if (o.count) {
        if (g.show_name) {
            try printFilename(g);
            if (o.null_after_name) try emitByte(g, 0) else try printSep(g, ':');
        }
        var b: [24]u8 = undefined;
        try emit(g, std.fmt.bufPrint(&b, "{d}\n", .{count}) catch unreachable);
        if (o.line_buffered) try flushOut(g);
    }
    const status_matched = count > 0;
    const want = (o.list == .matching and status_matched) or (o.list == .nonmatching and !status_matched);
    if (want) {
        try printFilename(g);
        try emitByte(g, if (o.null_after_name) 0 else '\n');
        if (o.line_buffered) try flushOut(g);
    }
    if (g.binary and o.binary_files == .binary and !g.out_quiet and g.nlines > 0 and g.nlines_first_null >= 0 and @as(i64, @intCast(g.nlines)) > g.nlines_first_null) {
        try flushOut(g);
        g.obs.emit(.{ .binary_matches = g.fname });
    } else if (g.enc_error_suppressed) {
        try flushOut(g);
        g.obs.emit(.{ .binary_matches = g.fname });
    }
    return status_matched;
}

fn grepOpened(g: *G, fd: i32, name: []const u8, is_stdin: bool, seekable_stdin: bool) Err!bool {
    _ = is_stdin;
    g.fname = name;
    {
        var serr: LX.E = .SUCCESS;
        g.offset_width = 20;
        if (sys.fstatFd(fd, &serr)) |fst| {
            if (fst.isReg()) {
                var w: usize = 1;
                var sz = fst.size;
                while (sz >= 10) : (sz /= 10) w += 1;
                g.offset_width = w;
            }
        }
    }
    const count = try grepFd(g, fd, seekable_stdin);
    const matched = try finishFile(g, count);
    flushBefore(g);
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    return matched;
}

fn grepFile(g: *G, path: []const u8, display: []const u8, cmdline: bool, in_dir: bool) Err!bool {
    const o = &g.o;
    // status of the file: true = matched
    var err: LX.E = .SUCCESS;
    var st_opt = sys.fileStat(path, cmdline or o.deref_recursive, &err);
    if (st_opt == null) {
        if (!(cmdline and false)) {
            g.obs.emit(.{ .read_error = .{ .name = display, .errno = err } });
            g.errseen = true;
        }
        return false;
    }
    const st = st_opt.?;
    st_opt = null;
    if (st.isDir()) {
        if (o.directories == .skip) return false;
        if (o.directories == .recurse) return try grepDir(g, path, display, cmdline);
        g.obs.emit(.{ .is_directory = display });
        g.errseen = true;
        return false;
    }
    const kind = st.mode & 0o170000;
    const is_dev = kind == 0o020000 or kind == 0o060000 or kind == 0o010000 or kind == 0o140000;
    if (is_dev and (o.devices == .skip or (o.devices == .read_cmdline and in_dir))) return false;
    if (!cmdline or true) {
        const base = if (std.mem.lastIndexOfScalar(u8, display, '/')) |k| display[k + 1 ..] else display;
        if (g.o.globs.len > 0 and matchGlobs(g, display, base, cmdline and !in_dir)) return false;
    }
    var oerr: LX.E = .SUCCESS;
    const fd = sys.openFd(path, sys.O.RDONLY | 0o4000, 0, &oerr) orelse {
        g.obs.emit(.{ .read_error = .{ .name = display, .errno = oerr } });
        g.errseen = true;
        return false;
    };
    defer _ = sys.closeFd(fd);
    // refuse to read the output file
    if (g.stdout_st) |so| {
        if (!g.out_quiet and o.list == .none and so.isReg() and so.ino == st.ino and so.dev_major == st.dev_major and so.dev_minor == st.dev_minor and o.max_count > 1 and !o.count) {
            g.obs.emit(.{ .input_is_output = display });
            g.errseen = true;
            return false;
        }
    }
    g.show_name = switch (g.out_file) {
        1 => true,
        0 => false,
        else => in_dir,
    };
    return try grepOpened(g, fd, display, false, false);
}

fn grepDir(g: *G, path: []const u8, display: []const u8, cmdline: bool) Err!bool {
    const o = &g.o;
    if (dirExcluded(g, display, if (std.mem.lastIndexOfScalar(u8, display, '/')) |k| display[k + 1 ..] else display, cmdline)) return false;
    var any = false;
    const dir_h = Io.Dir.cwd().openDir(g.env.io, path, .{ .iterate = true }) catch |e| {
        const emap: LX.E = switch (e) {
            error.AccessDenied => .ACCES,
            error.FileNotFound => .NOENT,
            error.NotDir => .NOTDIR,
            else => .IO,
        };
        g.obs.emit(.{ .read_error = .{ .name = display, .errno = emap } });
        g.errseen = true;
        return false;
    };
    var dir = dir_h;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| g.gpa.free(n);
        names.deinit(g.gpa);
    }
    var it = dir.iterate();
    while (it.next(g.env.io) catch null) |entry| {
        const dup = try g.gpa.dupe(u8, entry.name);
        try names.append(g.gpa, dup);
    }
    dir.close(g.env.io);
    var pbase = path;
    while (pbase.len > 1 and pbase[pbase.len - 1] == '/') pbase = pbase[0 .. pbase.len - 1];
    var dbase = display;
    while (dbase.len > 1 and dbase[dbase.len - 1] == '/') dbase = dbase[0 .. dbase.len - 1];
    for (names.items) |n| {
        const child = if (std.mem.eql(u8, path, ".") and g.implicit_dot)
            std.fmt.allocPrint(g.gpa, "{s}", .{n}) catch return error.OutOfMemory
        else
            try std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ pbase, n });
        defer g.gpa.free(child);
        const disp = if (g.implicit_dot and std.mem.eql(u8, display, "."))
            std.fmt.allocPrint(g.gpa, "{s}", .{n}) catch return error.OutOfMemory
        else
            try std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ dbase, n });
        defer g.gpa.free(disp);
        var err: LX.E = .SUCCESS;
        const lst = sys.fileStat(child, false, &err);
        if (lst) |l| {
            if (l.isLink() and !o.deref_recursive) continue;
        }
        if (try grepFile(g, child, disp, false, true)) any = true;
        if (g.early) break;
    }
    return any;
}

// ---------------------------------------------------------------- patterns

test "matcher on a buffer" {
    var diag: CompileError = .{};
    var m = try Matcher.compile(std.testing.allocator, .{ .syntax = .extended }, "fo+\nba[rz]", .none, &diag);
    defer m.deinit();
    try std.testing.expect(m.isMatch("xxfooyy"));
    try std.testing.expect(m.isMatch("bar"));
    try std.testing.expect(!m.isMatch("bat"));
    const sp = m.find("a fooo b", 0).?;
    try std.testing.expectEqual(@as(usize, 2), sp.start);
    try std.testing.expectEqual(@as(usize, 6), sp.end);
}

test "bad pattern reports a structured error" {
    var diag: CompileError = .{};
    try std.testing.expectError(error.BadPattern, Matcher.compile(std.testing.allocator, .{ .syntax = .extended }, "a(", .none, &diag));
    try std.testing.expectEqual(CompileError.Kind.syntax, diag.kind);
    try std.testing.expect(diag.extended);
}
