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
const ign = @import("grep_ignore.zig");
const scan = @import("grep_scan.zig");
const vec = @import("../bytes.zig");

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

/// How recursion treats symbolic links (FreeBSD -O, -p, -S).
pub const Symlinks = enum {
    /// GNU: -r follows command-line links only and skips links met while
    /// walking; -R (`deref_recursive`) follows all.
    gnu,
    /// -O: directory links are followed only on the command line; links to
    /// files met while walking are read.
    cmdline,
    /// -p: directory links are never followed; links to files are read.
    none,
};

/// `--sort` / `--sortr` keys.
pub const SortKey = enum { none, path, modified, accessed, created, size };

/// One term of a boolean query (--and, --not, --andnot): patterns separated
/// by newlines, ORed with each other.
pub const BoolTerm = struct { keys: []const u8, negate: bool = false, and_next: bool = false };

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

    // ---- extensions (decision 0006); every default is GNU behaviour.
    /// --smart-case: ignore case when no pattern has an uppercase letter.
    smart_case: bool = false,
    /// --json: ripgrep's JSON Lines messages instead of text.
    json: bool = false,
    /// --stats: print search statistics after the results.
    stats: bool = false,
    /// --count-matches: per file, the number of matches (not lines); files
    /// without matches are not listed.
    count_matches: bool = false,
    /// --replace: output with every match replaced (groups `$1`, `${name}`).
    replace: ?[]const u8 = null,
    /// --max-columns: omit longer lines (0 = off); --max-columns-preview
    /// shows their start.
    max_columns: usize = 0,
    max_columns_preview: bool = false,
    /// GNU grep -r searches hidden files; --no-hidden skips them.
    search_hidden: bool = true,
    /// --ignore-vcs: honour .gitignore and .ignore files while recursing.
    ignore_vcs: bool = false,
    /// --glob (ripgrep rules: later globs win, `!` excludes).
    rg_globs: []const ign.Pattern = &.{},
    /// --type / --type-not: glob lists (file names).
    type_include: []const []const u8 = &.{},
    type_exclude: []const []const u8 = &.{},
    sort: SortKey = .none,
    sort_reverse: bool = false,
    symlinks: Symlinks = .gnu,
    /// --include-dir (FreeBSD): descend only into directories matching.
    include_dirs: []const []const u8 = &.{},
    /// --decompress: read gzip, zlib, xz and zstd input decompressed.
    decompress: bool = false,

    /// Fold an empty pattern list into the options the way GNU does and
    /// report whether nothing can possibly match (the caller then skips the
    /// search and exits 1). `keys_len` is the length of the pattern list
    /// (patterns joined with newlines, without the trailing newline);
    /// `no_keys` is true when -e/-f were given but supplied no pattern at all
    /// (-f /dev/null), which is different from one empty pattern (-e '').
    pub fn prepare(o: *Options, keys_len: usize, no_keys: bool) bool {
        var keycc = keys_len;
        if (no_keys) {
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
    /// --decompress met a format it cannot read (bzip2); the file is searched
    /// as is.
    unsupported_compression: struct { name: []const u8, format: []const u8 },
    /// --decompress: the compressed data is damaged.
    decompress_failed: []const u8,
    /// A regex search gave up on a line (backtracking or stack limit). GNU
    /// -P reports this as an error; the line counts as not matching.
    search_limit: struct { name: []const u8, line: u64 },
};
pub const Observer = common.Observer(Event);

pub const CompileError = struct {
    kind: Kind = .syntax,
    /// The offending pattern.
    pattern: []const u8 = "",
    /// Was it compiled as an ERE (for posixre.diagnoseGrep).
    extended: bool = false,
    /// regex-zig's explanation and its position in the pattern (-P).
    detail: []const u8 = "",
    offset: usize = 0,

    pub const Kind = enum {
        /// Invalid regular expression syntax; use `posixre.diagnoseGrep`.
        syntax,
        /// "[:space:]" outside a bracket expression.
        bare_class,
        /// -P pattern regex-zig rejects (`detail` says why).
        invalid_perl,
        /// Malformed --bool query; `offset` is where parsing stopped.
        bool_syntax,
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

/// Pattern count from which `Matcher` builds the combined search set.
const set_threshold = 4;
const set_limits: regex.Limits = blk: {
    var l = posixre.big_limits;
    l.max_dfa_cache = 256 << 20;
    break :blk l;
};

const Pat = struct {
    re: regex.Regex,
    longest: ?*regex.Regex,
    fin: posixre.Finder,
    mb: bool,
};

/// A compiled pattern list. Safe to use on many buffers; not thread-safe
/// (searchers keep scratch state).
pub const BoolNode = union(enum) {
    leaf: usize,
    not: usize,
    both: [2]usize,
    either: [2]usize,
};

pub const Matcher = struct {
    gpa: std.mem.Allocator,
    pats: std.ArrayList(*Pat) = .empty,
    utf8: bool = false,
    /// Translated patterns, compiled one by one only when a match position
    /// is needed (see `ensure`).
    staged: std.ArrayList(Staged) = .empty,
    /// All patterns as one DFA-backed search: answers "does any pattern match
    /// this line" without trying each pattern (large -f lists).
    set: ?*regex.Regex = null,
    set_sr: ?regex.Searcher = null,
    options: Options = .{},
    /// Searches that hit a regex limit (the line was treated as no match).
    limit_hits: u64 = 0,
    /// Boolean query (--and, --not, --bool): leaves and expression.
    bool_nodes: []BoolNode = &.{},
    bool_root: usize = 0,
    bool_subs: std.ArrayList(*Matcher) = .empty,
    /// Buffer-wide pre-filter (see `candidate`): a required literal, or a DFA
    /// over the patterns, finds the next line worth running the regex on.
    pre_kind: enum { none, lit, multi, scan } = .none,
    pre_needle: vec.Needle = undefined,
    pre_text: []u8 = &.{},
    /// Several required literals (an alternation or a short -F list): the
    /// nearest hit of any of them.
    pre_multi: std.ArrayList(vec.Needle) = .empty,
    pre_multi_mem: std.ArrayList([]u8) = .empty,
    pre_store: []u8 = &.{},
    pre_re: ?*regex.Regex = null,
    pre_sr: ?regex.Searcher = null,
    /// The scan DFA is the combined `set`.
    pre_use_set: bool = false,
    /// A candidate line is certainly selected (the pattern is just the
    /// literal(s)); no regex run is needed.
    pre_exact: bool = false,
    /// The only pattern is one literal and -w / -x applies: `isMatch` checks
    /// the literal's neighbours (or the line length) without a regex.
    lit_mode: enum { none, word, line, start, end, both } = .none,

    pub const Error = error{ OutOfMemory, BadPattern };

    /// Compile `keys` (patterns separated by '\n') under `options` (syntax,
    /// icase, word, line, utf8). On `error.BadPattern`, `diag` says why.
    pub fn compile(gpa: std.mem.Allocator, options: Options, keys: []const u8, observer: Observer, diag: *CompileError) Error!Matcher {
        var opts = options;
        if (opts.smart_case and !opts.icase and !hasUpper(keys, opts.syntax)) opts.icase = true;
        var m: Matcher = .{ .gpa = gpa, .utf8 = opts.utf8, .options = opts };
        errdefer m.deinit();
        var it = std.mem.splitScalar(u8, keys, '\n');
        while (it.next()) |pt| try m.stage(opts, pt, observer, diag);
        m.buildSet(opts);
        if (m.set == null) try m.realize(diag);
        m.buildPre(opts);
        return m;
    }

    /// Where the next line that can match starts, looking at `hay[from..]`
    /// (`hay` ends at a line boundary or at end of input). `.none`: no line
    /// there matches; `.at(i)`: the lines before the one holding byte `i`
    /// do not match; `.unknown`: no pre-filter, look at every line.
    pub const Cand = union(enum) { none, at: usize, unknown };

    pub fn candidate(m: *Matcher, hay: []const u8, from: usize) Cand {
        switch (m.pre_kind) {
            .none => return .unknown,
            .lit => return if (m.pre_needle.find(hay, from)) |p| .{ .at = p } else .none,
            .multi => {
                var best: ?usize = null;
                for (m.pre_multi.items) |*nd| {
                    // only a hit before the best one so far matters
                    const lim = if (best) |b| @min(hay.len, b + nd.bytes.len - 1) else hay.len;
                    if (nd.find(hay[0..lim], from)) |p| best = p;
                }
                return if (best) |p| .{ .at = p } else .none;
            },
            .scan => {
                const sr: *regex.Searcher = if (m.pre_use_set) &m.set_sr.? else &m.pre_sr.?;
                const f = &(sr.fwd orelse {
                    m.pre_kind = .none;
                    return .unknown;
                });
                const e = (f.findEnd(hay, from, true) catch {
                    m.pre_kind = .none;
                    return .unknown;
                }) orelse return .none;
                return .{ .at = if (e > from) e - 1 else e };
            },
        }
    }

    /// Up to `multi_max` required literals (each at least two bytes) cover
    /// every pattern: search for them directly.
    const multi_max = 8;

    fn buildMulti(m: *Matcher, options: Options, ao: scan.Opts) bool {
        const gpa = m.gpa;
        var lits: std.ArrayList(scan.Lit) = .empty;
        defer {
            for (lits.items) |l| gpa.free(l.text);
            lits.deinit(gpa);
        }
        for (m.staged.items) |st| {
            const ok = scan.literals(gpa, st.body, ao, &lits) catch return false;
            if (!ok or lits.items.len > multi_max) return false;
        }
        if (lits.items.len < 2) return false;
        var all_exact = !options.word and !options.line;
        for (lits.items) |l| {
            if (l.text.len < 2) return false;
            if (!l.exact) all_exact = false;
        }
        for (lits.items) |l| {
            const fold = options.icase;
            const mem = gpa.alloc(u8, l.text.len * 2) catch return false;
            m.pre_multi_mem.append(gpa, mem) catch {
                gpa.free(mem);
                return false;
            };
            @memcpy(mem[0..l.text.len], l.text);
            m.pre_multi.append(gpa, vec.Needle.init(mem[0..l.text.len], fold, mem[l.text.len..])) catch return false;
        }
        m.pre_kind = .multi;
        m.pre_exact = all_exact;
        return true;
    }

    fn buildPre(m: *Matcher, options: Options) void {
        if (m.staged.items.len == 0) return;
        const gpa = m.gpa;
        const ao: scan.Opts = .{ .icase = options.icase, .utf8 = options.utf8, .eol = if (options.null_data) 0 else '\n' };
        var all_scan = true;
        var all_exact = !options.word and !options.line;
        var first: scan.Info = .{};
        defer first.deinit(gpa);
        for (m.staged.items, 0..) |st, k| {
            var info = scan.analyze(gpa, st.body, ao) catch return;
            if (!info.scannable) all_scan = false;
            if (!info.exact or info.anchor_start or info.anchor_end) all_exact = false;
            if (k == 0) first = info else info.deinit(gpa);
        }
        if (m.staged.items.len == 1) {
            const lit = first.lit;
            const exact = first.exact and !first.anchor_start and !first.anchor_end and !options.word and !options.line;
            const anchored = first.exact and (first.anchor_start or first.anchor_end) and !options.word and !options.line and !options.null_data;
            const whole = ((first.exact and !first.anchor_start and !first.anchor_end) and (options.word or options.line) and !(options.word and options.line)) or anchored;
            const use_lit = lit.len > 0 and (exact or whole or lit.len >= 2 or !(all_scan and !options.line));
            if (use_lit) {
                const text = gpa.dupe(u8, lit) catch return;
                var store: []u8 = &.{};
                if (options.icase) store = gpa.alloc(u8, text.len) catch {
                    gpa.free(text);
                    return;
                };
                m.pre_text = text;
                m.pre_store = store;
                m.pre_needle = vec.Needle.init(text, options.icase, store);
                m.pre_kind = .lit;
                m.pre_exact = exact;
                if (whole) m.lit_mode = if (anchored)
                    (if (first.anchor_start and first.anchor_end) .both else if (first.anchor_start) .start else .end)
                else if (options.line) .line else .word;
                return;
            }
        }
        if (m.buildMulti(options, ao)) return;
        if (!all_scan or options.line) return;
        if (m.set != null) {
            // The combined set is exactly the alternation of the bodies.
            if (options.word) return;
            m.pre_use_set = true;
            m.pre_kind = .scan;
            m.pre_exact = all_exact;
            return;
        }
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        src.appendSlice(gpa, "(?s)") catch return;
        for (m.staged.items, 0..) |st, i| {
            if (i > 0) src.append(gpa, '|') catch return;
            src.appendSlice(gpa, "(?:") catch return;
            src.appendSlice(gpa, st.body) catch return;
            src.append(gpa, ')') catch return;
        }
        var lim = posixre.big_limits;
        lim.max_dfa_cache = 16 << 20;
        const re = gpa.create(regex.Regex) catch return;
        re.* = regex.Regex.compile(gpa, src.items, .{ .dialect = .perl, .ignore_case = options.icase, .limits = lim, .engine = .dfa }, null) catch {
            gpa.destroy(re);
            return;
        };
        m.pre_sr = re.searcher(gpa) catch {
            re.deinit(gpa);
            gpa.destroy(re);
            return;
        };
        m.pre_re = re;
        m.pre_kind = .scan;
        m.pre_exact = all_exact;
    }

    pub fn deinit(m: *Matcher) void {
        m.gpa.free(m.pre_text);
        for (m.pre_multi_mem.items) |mem| m.gpa.free(mem);
        m.pre_multi_mem.deinit(m.gpa);
        m.pre_multi.deinit(m.gpa);
        m.gpa.free(m.pre_store);
        if (m.pre_sr) |*x| x.deinit();
        if (m.pre_re) |re| {
            re.deinit(m.gpa);
            m.gpa.destroy(re);
        }
        if (m.set_sr) |*x| x.deinit();
        if (m.set) |st| {
            st.deinit(m.gpa);
            m.gpa.destroy(st);
        }
        for (m.bool_subs.items) |sub| {
            sub.deinit();
            m.gpa.destroy(sub);
        }
        m.bool_subs.deinit(m.gpa);
        m.gpa.free(m.bool_nodes);
        for (m.staged.items) |x| {
            m.gpa.free(x.inner);
            m.gpa.free(x.body);
        }
        m.staged.deinit(m.gpa);
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

    /// A boolean query from --and/--not/--andnot terms: the groups (a term
    /// with `and_next` starts a new one) are ANDed, the terms inside a group
    /// are ORed.
    pub fn compileTerms(gpa: std.mem.Allocator, options: Options, terms: []const BoolTerm, observer: Observer, diag: *CompileError) Error!Matcher {
        var b = BoolBuilder{ .m = .{ .gpa = gpa, .utf8 = options.utf8, .options = options }, .options = options, .observer = observer, .diag = diag };
        errdefer b.m.deinit();
        var nodes: std.ArrayList(BoolNode) = .empty;
        errdefer nodes.deinit(gpa);
        b.nodes = &nodes;
        var group: ?usize = null;
        var root: ?usize = null;
        for (terms) |t| {
            if (t.and_next and group != null) {
                root = if (root) |r| try b.add(.{ .both = .{ r, group.? } }) else group;
                group = null;
            }
            var leaf = try b.leaf(t.keys);
            if (t.negate) leaf = try b.add(.{ .not = leaf });
            group = if (group) |g| try b.add(.{ .either = .{ g, leaf } }) else leaf;
        }
        if (group) |g| root = if (root) |r| try b.add(.{ .both = .{ r, g } }) else g;
        b.m.bool_root = root orelse return error.BadPattern;
        b.m.bool_nodes = try nodes.toOwnedSlice(gpa);
        return b.m;
    }

    /// A --bool query: terms separated by spaces (AND), `|` or OR, `-` or
    /// NOT, parentheses, and "quoted" literals. A syntax error is reported
    /// as `error.BadPattern` with `diag.kind == .bool_syntax`.
    pub fn compileQuery(gpa: std.mem.Allocator, options: Options, query: []const u8, observer: Observer, diag: *CompileError) Error!Matcher {
        var b = BoolBuilder{ .m = .{ .gpa = gpa, .utf8 = options.utf8, .options = options }, .options = options, .observer = observer, .diag = diag };
        errdefer b.m.deinit();
        var nodes: std.ArrayList(BoolNode) = .empty;
        errdefer nodes.deinit(gpa);
        b.nodes = &nodes;
        var ps = QueryParser{ .b = &b, .src = query };
        const root = try ps.expr();
        ps.skipSpace();
        if (ps.pos < query.len) return ps.fail();
        b.m.bool_root = root;
        b.m.bool_nodes = try nodes.toOwnedSlice(gpa);
        return b.m;
    }

    /// Compile the individual patterns if only the combined set exists.
    fn ensure(m: *Matcher) void {
        if (m.pats.items.len == m.staged.items.len) return;
        var diag: CompileError = .{};
        m.realize(&diag) catch {};
    }

    /// Leftmost-longest match over all patterns starting at or after `from`.
    pub fn find(m: *Matcher, line: []const u8, from: usize) ?Span {
        var best: ?Span = null;
        m.ensure();
        if (m.bool_nodes.len > 0) return m.boolFind(line, from);
        for (m.pats.items) |p| {
            const mm = (p.fin.find(line, from) catch {
                m.noteLimit();
                continue;
            }) orelse continue;
            const sp = Span{ .start = mm.start(), .end = mm.end() };
            if (best == null or sp.start < best.?.start or (sp.start == best.?.start and sp.end > best.?.end)) best = sp;
        }
        return best;
    }

    fn isWordByte(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_';
    }

    /// -w / -x with a single literal pattern; null: needs the regex (a
    /// neighbour byte is part of a multibyte character).
    fn litCheck(m: *const Matcher, line: []const u8) ?bool {
        const n = m.pre_needle.bytes.len;
        switch (m.lit_mode) {
            .line => return line.len == n and m.pre_needle.find(line, 0) != null,
            .start => return m.pre_needle.matchesAt(line, 0),
            .end => return line.len >= n and m.pre_needle.matchesAt(line, line.len - n),
            .both => return line.len == n and m.pre_needle.matchesAt(line, 0),
            else => {},
        }
        var from: usize = 0;
        while (m.pre_needle.find(line, from)) |p| {
            const before: ?u8 = if (p > 0) line[p - 1] else null;
            const after: ?u8 = if (p + n < line.len) line[p + n] else null;
            if (m.utf8 and ((before orelse 0) >= 0x80 or (after orelse 0) >= 0x80)) return null;
            if (!(before != null and isWordByte(before.?)) and !(after != null and isWordByte(after.?))) return true;
            from = p + 1;
        }
        return false;
    }

    /// Does any pattern match somewhere in `line`?
    pub fn isMatch(m: *Matcher, line: []const u8) bool {
        if (m.bool_nodes.len > 0) return m.boolEval(m.bool_root, line);
        if (m.lit_mode != .none) {
            if (m.litCheck(line)) |r| return r;
        }
        if (m.set_sr) |*sr| return sr.matchesAnywhere(line) catch {
            m.noteLimit();
            return false;
        };
        for (m.pats.items) |p| {
            if (p.fin.find(line, 0) catch {
                m.noteLimit();
                return false;
            }) |_| return true;
        }
        return false;
    }

    /// Find the leftmost-longest match at or after `at` (it must start at
    /// `at`) and append the --replace template expanded for it to `out`.
    /// Returns the matched span.
    pub fn replaceAt(m: *Matcher, gpa: std.mem.Allocator, line: []const u8, at: usize, tmpl: []const u8, out: *std.ArrayList(u8)) ?Span {
        if (m.bool_nodes.len > 0) {
            var best: ?*Matcher = null;
            var bsp: Span = undefined;
            for (m.bool_subs.items, 0..) |sub, k| {
                if (!m.leafPositive(k)) continue;
                const sp = sub.find(line, at) orelse continue;
                if (best == null or sp.start < bsp.start or (sp.start == bsp.start and sp.end > bsp.end)) {
                    best = sub;
                    bsp = sp;
                }
            }
            if (best) |b| return b.replaceAt(gpa, line, at, tmpl, out);
            return null;
        }
        m.ensure();
        var bi: ?usize = null;
        var bsp: Span = undefined;
        for (m.pats.items, 0..) |p, i| {
            const mm = (p.fin.find(line, at) catch continue) orelse continue;
            const sp = Span{ .start = mm.start(), .end = mm.end() };
            if (bi == null or sp.start < bsp.start or (sp.start == bsp.start and sp.end > bsp.end)) {
                bi = i;
                bsp = sp;
            }
        }
        const i = bi orelse return null;
        const p = m.pats.items[i];
        const mm = (p.fin.find(line, at) catch return null) orelse return null;
        expandTemplate(gpa, tmpl, line, mm, &p.re, out);
        return bsp;
    }

    fn noteLimit(m: *Matcher) void {
        m.limit_hits += 1;
    }

    /// Total limit hits including sub-matchers of a boolean query.
    pub fn limitHits(m: *const Matcher) u64 {
        var n = m.limit_hits;
        for (m.bool_subs.items) |sub| n += sub.limit_hits;
        return n;
    }

    fn boolEval(m: *Matcher, idx: usize, line: []const u8) bool {
        const n = m.bool_nodes[idx];
        return switch (n) {
            .leaf => |k| m.bool_subs.items[k].isMatch(line),
            .not => |a| !m.boolEval(a, line),
            .both => |ab| m.boolEval(ab[0], line) and m.boolEval(ab[1], line),
            .either => |ab| m.boolEval(ab[0], line) or m.boolEval(ab[1], line),
        };
    }

    /// Leftmost-longest match over the positive leaves of a boolean query.
    fn boolFind(m: *Matcher, line: []const u8, from: usize) ?Span {
        var best: ?Span = null;
        for (m.bool_subs.items, 0..) |sub, k| {
            if (!m.leafPositive(k)) continue;
            const sp = sub.find(line, from) orelse continue;
            if (best == null or sp.start < best.?.start or (sp.start == best.?.start and sp.end > best.?.end)) best = sp;
        }
        return best;
    }

    /// A leaf is shown as a match unless every path to it is negated.
    fn leafPositive(m: *const Matcher, leaf: usize) bool {
        return m.positiveIn(m.bool_root, leaf, true);
    }

    fn positiveIn(m: *const Matcher, idx: usize, leaf: usize, pos: bool) bool {
        return switch (m.bool_nodes[idx]) {
            .leaf => |k| k == leaf and pos,
            .not => |a| m.positiveIn(a, leaf, !pos),
            .both, .either => |ab| m.positiveIn(ab[0], leaf, pos) or m.positiveIn(ab[1], leaf, pos),
        };
    }

    /// With many patterns, compile them as one alternation (a lazy DFA runs
    /// it); any failure (back references, limits) leaves the per-pattern
    /// search in place.
    fn buildSet(m: *Matcher, options: Options) void {
        if (m.staged.items.len == 0) return;
        // A few patterns also get the combined DFA when it applies (no
        // look-around or back-reference): "does the line match" is then one
        // linear scan instead of a per-pattern regex run.
        const small = m.staged.items.len < set_threshold;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(m.gpa);
        src.appendSlice(m.gpa, "(?s)") catch return;
        for (m.staged.items, 0..) |st, i| {
            if (hasBackref(st.inner)) return;
            if (i > 0) src.append(m.gpa, '|') catch return;
            src.appendSlice(m.gpa, "(?:") catch return;
            src.appendSlice(m.gpa, st.inner) catch return;
            src.append(m.gpa, ')') catch return;
        }
        const re = m.gpa.create(regex.Regex) catch return;
        re.* = regex.Regex.compile(m.gpa, src.items, .{ .dialect = .perl, .ignore_case = options.icase, .limits = set_limits, .engine = if (small) .dfa else .auto }, null) catch {
            m.gpa.destroy(re);
            return;
        };
        m.set_sr = re.searcher(m.gpa) catch {
            re.deinit(m.gpa);
            m.gpa.destroy(re);
            return;
        };
        m.set = re;
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

    fn stage(m: *Matcher, options: Options, pat: []const u8, observer: Observer, diag: *CompileError) Error!void {
        const gpa = m.gpa;
        var flags: posixre.Flags = .{};
        const body = try m.translate(options, pat, &flags, observer, diag);
        errdefer gpa.free(body);
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
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
        const inner = try src.toOwnedSlice(gpa);
        errdefer gpa.free(inner);
        try m.staged.append(gpa, .{ .pat = pat, .body = body, .inner = inner, .flags = flags });
    }

    /// Compile every staged pattern separately (the search for match
    /// positions, and the whole search when there is no combined set).
    fn realize(m: *Matcher, diag: *CompileError) Error!void {
        for (m.pats.items) |p| {
            p.fin.deinit();
            p.re.deinit(m.gpa);
            if (p.longest) |l| {
                l.deinit(m.gpa);
                m.gpa.destroy(l);
            }
            m.gpa.destroy(p);
        }
        m.pats.clearRetainingCapacity();
        for (m.staged.items) |st| try m.addOne(m.options, st, diag);
    }

    fn addOne(m: *Matcher, options: Options, st: Staged, diag: *CompileError) Error!void {
        const gpa = m.gpa;
        const body = st.body;
        const flags = st.flags;
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(gpa);
        try src.appendSlice(gpa, "(?s)");
        try src.appendSlice(gpa, st.inner);
        var rd: regex.Diagnostic = .{};
        const re = regex.Regex.compile(gpa, src.items, .{ .dialect = .perl, .ignore_case = options.icase, .limits = posixre.big_limits }, &rd) catch {
            diag.* = .{ .kind = if (options.syntax == .perl) .invalid_perl else .syntax, .pattern = st.pat, .extended = options.syntax == .extended, .detail = rd.message, .offset = rd.pos -| 4 };
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

/// Append `tmpl` with `$N`, `${name}` and `$name` expanded (names take the
/// longest run of letters, digits and underscores, as in Rust's regex);
/// `$$` is a dollar sign; an unknown group is empty.
fn expandTemplate(gpa: std.mem.Allocator, tmpl: []const u8, line: []const u8, mm: regex.Match, re: *const regex.Regex, out: *std.ArrayList(u8)) void {
    var i: usize = 0;
    while (i < tmpl.len) {
        const c = tmpl[i];
        if (c != '$') {
            out.append(gpa, c) catch return;
            i += 1;
            continue;
        }
        if (i + 1 < tmpl.len and tmpl[i + 1] == '$') {
            out.append(gpa, '$') catch return;
            i += 2;
            continue;
        }
        var name: []const u8 = "";
        var next = i + 1;
        if (i + 1 < tmpl.len and tmpl[i + 1] == '{') {
            if (std.mem.indexOfScalarPos(u8, tmpl, i + 2, '}')) |close| {
                name = tmpl[i + 2 .. close];
                next = close + 1;
            }
        } else {
            var j = i + 1;
            while (j < tmpl.len and (std.ascii.isAlphanumeric(tmpl[j]) or tmpl[j] == '_')) j += 1;
            name = tmpl[i + 1 .. j];
            next = j;
        }
        if (name.len == 0) {
            out.append(gpa, '$') catch return;
            i += 1;
            continue;
        }
        i = next;
        var idx: ?u32 = null;
        if (std.fmt.parseInt(u32, name, 10)) |n| {
            idx = n;
        } else |_| {
            for (re.prog.names) |nm| if (std.mem.eql(u8, nm.name, name)) {
                idx = nm.index;
            };
        }
        const gi = idx orelse continue;
        if (gi > re.prog.group_count) continue;
        if (mm.group(gi)) |sp| out.appendSlice(gpa, line[sp[0]..sp[1]]) catch return;
    }
}

const BoolBuilder = struct {
    m: Matcher,
    options: Options,
    observer: Observer,
    diag: *CompileError,
    nodes: *std.ArrayList(BoolNode) = undefined,

    fn add(b: *BoolBuilder, n: BoolNode) Matcher.Error!usize {
        try b.nodes.append(b.m.gpa, n);
        return b.nodes.items.len - 1;
    }

    fn leafWith(b: *BoolBuilder, keys: []const u8, opts: Options) Matcher.Error!usize {
        const sub = try b.m.gpa.create(Matcher);
        errdefer b.m.gpa.destroy(sub);
        sub.* = try Matcher.compile(b.m.gpa, opts, keys, b.observer, b.diag);
        errdefer sub.deinit();
        try b.m.bool_subs.append(b.m.gpa, sub);
        return try b.add(.{ .leaf = b.m.bool_subs.items.len - 1 });
    }

    fn leaf(b: *BoolBuilder, keys: []const u8) Matcher.Error!usize {
        return b.leafWith(keys, b.options);
    }
};

const QueryParser = struct {
    b: *BoolBuilder,
    src: []const u8,
    pos: usize = 0,

    fn fail(p: *QueryParser) Matcher.Error {
        p.b.diag.* = .{ .kind = .bool_syntax, .pattern = p.src, .offset = p.pos };
        return error.BadPattern;
    }

    fn skipSpace(p: *QueryParser) void {
        while (p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t')) p.pos += 1;
    }

    fn word(p: *QueryParser) ?[]const u8 {
        p.skipSpace();
        const start = p.pos;
        while (p.pos < p.src.len and p.src[p.pos] != ' ' and p.src[p.pos] != '\t' and p.src[p.pos] != '(' and p.src[p.pos] != ')' and p.src[p.pos] != '|') p.pos += 1;
        if (p.pos == start) return null;
        return p.src[start..p.pos];
    }

    fn keyword(p: *QueryParser, kw: []const u8) bool {
        p.skipSpace();
        const rest = p.src[p.pos..];
        if (rest.len < kw.len or !std.mem.eql(u8, rest[0..kw.len], kw)) return false;
        if (rest.len > kw.len and rest[kw.len] != ' ' and rest[kw.len] != '\t' and rest[kw.len] != '(') return false;
        p.pos += kw.len;
        return true;
    }

    fn expr(p: *QueryParser) Matcher.Error!usize {
        var left = try p.orExpr();
        while (true) {
            p.skipSpace();
            if (p.pos >= p.src.len or p.src[p.pos] == ')') return left;
            _ = p.keyword("AND");
            const right = try p.orExpr();
            left = try p.b.add(.{ .both = .{ left, right } });
        }
    }

    fn orExpr(p: *QueryParser) Matcher.Error!usize {
        var left = try p.unary();
        while (true) {
            p.skipSpace();
            if (p.pos < p.src.len and p.src[p.pos] == '|') {
                p.pos += 1;
            } else if (!p.keyword("OR")) return left;
            const right = try p.unary();
            left = try p.b.add(.{ .either = .{ left, right } });
        }
    }

    fn unary(p: *QueryParser) Matcher.Error!usize {
        p.skipSpace();
        if (p.pos >= p.src.len) return p.fail();
        const c = p.src[p.pos];
        if (c == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ' ') {
            p.pos += 1;
            return try p.b.add(.{ .not = try p.unary() });
        }
        if (p.keyword("NOT")) return try p.b.add(.{ .not = try p.unary() });
        if (c == '(') {
            p.pos += 1;
            const e = try p.expr();
            p.skipSpace();
            if (p.pos >= p.src.len or p.src[p.pos] != ')') return p.fail();
            p.pos += 1;
            return e;
        }
        if (c == '"') {
            const start = p.pos + 1;
            const end = std.mem.indexOfScalarPos(u8, p.src, start, '"') orelse return p.fail();
            p.pos = end + 1;
            var o = p.b.options;
            o.syntax = .fixed;
            return try p.b.leafWith(p.src[start..end], o);
        }
        const w = p.word() orelse return p.fail();
        return try p.b.leaf(w);
    }
};

/// Does the pattern list contain an uppercase letter that counts for
/// --smart-case? Escaped characters (`\S`, `\W`) do not, as in ripgrep.
fn hasUpper(keys: []const u8, syntax: Syntax) bool {
    var i: usize = 0;
    while (i < keys.len) : (i += 1) {
        const c = keys[i];
        if (c == '\\' and syntax != .fixed) {
            i += 1;
            continue;
        }
        if (c >= 0x80) {
            const d = unicode.decode(keys, i);
            if (d.valid) {
                if (unicode.toLower(d.cp) != d.cp) return true;
                i += d.len - 1;
            }
            continue;
        }
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

const Staged = struct { pat: []const u8, body: []u8, inner: []u8, flags: posixre.Flags };

/// A back-reference (\1..\9, \k<..>, (?P=..)) would be renumbered when
/// patterns are joined.
fn hasBackref(src: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < src.len) : (i += 1) {
        if (src[i] == '\\') {
            const c = src[i + 1];
            if ((c >= '1' and c <= '9') or c == 'k' or c == 'g') return true;
            i += 1;
        } else if (src[i] == '(' and std.mem.startsWith(u8, src[i..], "(?P=")) return true;
    }
    return false;
}

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
    // extensions
    t0_ns: i128 = 0,
    tfile_ns: i128 = 0,
    tot: Stats = .{},
    fstat: Stats = .{}, // current file
    file_printed: u64 = 0,
    json_begun: bool = false,
    cur_noeol: bool = false,
    json_printed: u64 = 0,
    is_stdin: bool = false,
    ign_stack: std.ArrayList(IgnLevel) = .empty,
    file_mem: ?[]const u8 = null,
    /// Read buffer, kept across files.
    buf: std.ArrayList(u8) = .empty,
    /// Stat of the file about to be opened by grepOpened (saves an fstat).
    pre_stat: ?sys.FileStat = null,
    /// Size of the regular file being read: reaching it ends the read loop
    /// without a final read that returns 0.
    cur_size: ?u64 = null,
};

const Stats = struct {
    matches: u64 = 0,
    matched_lines: u64 = 0,
    files_with: u64 = 0,
    files: u64 = 0,
    bytes_searched: u64 = 0,
    bytes_printed: u64 = 0,
    elapsed_ns: i128 = 0,
};

const IgnLevel = struct { prefix_len: usize, pats: []ign.Pattern, data: []u8 };

fn nowNs() i128 {
    return sys.monotonicNs();
}

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
        g.buf.deinit(g.gpa);
    }
    g.eol = if (g.o.null_data) 0 else '\n';
    g.t0_ns = nowNs();
    if (g.o.json) g.o.binary_files = .text;
    defer {
        for (g.ign_stack.items) |lv| {
            g.gpa.free(lv.pats);
            g.gpa.free(lv.data);
        }
        g.ign_stack.deinit(g.gpa);
    }
    g.colors = g.o.colors;
    // GNU: -q, or output to /dev/null, stops at the first selected line and
    // exits 0 even if an earlier file could not be read.
    var to_dev_null = false;
    if (g.o.output_file) |f| {
        var nerr: LX.E = .SUCCESS;
        if (sys.fstatFd(f.handle, &nerr)) |fs| {
            to_dev_null = fs.mode & 0o170000 == 0o020000 and fs.rdev_major == 1 and fs.rdev_minor == 3;
        }
    }
    g.exit_on_match = g.o.quiet or to_dev_null;
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    g.out_quiet = g.o.count or g.o.count_matches or g.done_on_match;
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
                g.is_stdin = true;
                const seekable = sys.seekFd(f.handle, 0, 1, &serr) != null;
                if (try grepOpened(&g, f.handle, g.o.label, true, seekable)) any = true;
            },
            .path => |p| {
                g.is_stdin = false;
                if (try grepFile(&g, p, p, true, false)) any = true;
            },
        }
        if (g.early) break;
    }
    if (g.o.json) try jsonSummary(&g);
    if (g.o.stats and !g.exit_on_match) try printStats(&g);
    try flushOut(&g);
    if (matcher.limitHits() > 0 and !g.early) g.errseen = true;
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
    g.tot.bytes_printed += bytes.len;
    g.file_printed += bytes.len;
    try g.out.appendSlice(g.gpa, bytes);
    if (g.out.items.len > 65536) try flushOut(g);
}

fn emitByte(g: *G, b: u8) Err!void {
    g.tot.bytes_printed += 1;
    g.file_printed += 1;
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
    if (o.json) {
        try jsonLine(g, text, no, off, sep);
        return true;
    }
    if (!o.only and encFail(g, text)) return false;
    if (!o.only) try printLineHead(g, no, off, text.len, sep);
    if (!o.only and o.max_columns > 0 and text.len + 1 > o.max_columns) {
        if (o.max_columns_preview) {
            try emit(g, text[0..o.max_columns]);
            try emit(g, " [... omitted end of long line]");
        } else try emit(g, if (sep == ':') "[Omitted long matching line]" else "[Omitted long context line]");
        try emitByte(g, g.eol);
        if (o.line_buffered) try flushOut(g);
        return true;
    }
    if (!o.only and o.replace != null and (sep == ':') != o.invert) {
        try printReplaced(g, text);
        try emitByte(g, g.eol);
        if (o.line_buffered) try flushOut(g);
        return true;
    }
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
            if (g.o.max_columns > 0 and size + 1 > g.o.max_columns) {
                try emit(g, "[Omitted long matching line]");
                try emitByte(g, g.eol);
                cur = b + size;
                continue;
            }
            if (g.o.replace) |tmpl| {
                var rep_out: std.ArrayList(u8) = .empty;
                defer rep_out.deinit(g.gpa);
                _ = g.m.replaceAt(g.gpa, text, b, tmpl, &rep_out);
                try emit(g, rep_out.items);
                try emitByte(g, g.eol);
                cur = b + size;
                continue;
            }
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

/// The line with every match replaced by the --replace template.
fn printReplaced(g: *G, text: []const u8) Err!void {
    const tmpl = g.o.replace.?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(g.gpa);
    var cur: usize = 0;
    var from: usize = 0;
    while (from <= text.len) {
        const sp = g.m.find(text, from) orelse break;
        if (sp.end == sp.start) {
            if (sp.start >= text.len) break;
            from = sp.start + 1;
            continue;
        }
        try out.appendSlice(g.gpa, text[cur..sp.start]);
        _ = g.m.replaceAt(g.gpa, text, sp.start, tmpl, &out);
        cur = sp.end;
        from = sp.end;
    }
    try out.appendSlice(g.gpa, text[cur..]);
    try emit(g, out.items);
}

/// Number of non-empty matches in `text`.
fn countMatches(g: *G, text: []const u8) u64 {
    var n: u64 = 0;
    var from: usize = 0;
    while (from <= text.len) {
        const sp = g.m.find(text, from) orelse break;
        if (sp.end == sp.start) {
            from = sp.start + 1;
            continue;
        }
        n += 1;
        from = sp.end;
    }
    return n;
}

// ------------------------------------------------------------------- JSON

fn jsonName(g: *const G) []const u8 {
    return if (g.is_stdin) "<stdin>" else g.fname;
}

fn jsonBegin(g: *G) Err!void {
    if (g.json_begun) return;
    g.json_begun = true;
    var aw: Io.Writer.Allocating = .init(g.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    jsonBeginMsg(w, jsonName(g)) catch return error.OutOfMemory;
    try emit(g, aw.written());
}

fn jsonBeginMsg(w: *Io.Writer, name: []const u8) Io.Writer.Error!void {
    try w.writeAll("{\"type\":\"begin\",\"data\":{\"path\":");
    try ign.jsonData(w, name);
    try w.writeAll("}}\n");
}

fn jsonLine(g: *G, text: []const u8, no: u64, off: u64, sep: u8) Err!void {
    try jsonBegin(g);
    var aw: Io.Writer.Allocating = .init(g.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    const is_match = sep == ':';
    w.writeAll(if (is_match) "{\"type\":\"match\",\"data\":{\"path\":" else "{\"type\":\"context\",\"data\":{\"path\":") catch return error.OutOfMemory;
    ign.jsonData(w, jsonName(g)) catch return error.OutOfMemory;
    w.writeAll(",\"lines\":") catch return error.OutOfMemory;
    const eol: []const u8 = if (g.cur_noeol) "" else if (g.eol == 0) "\x00" else "\n";
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(g.gpa);
    try full.appendSlice(g.gpa, text);
    try full.appendSlice(g.gpa, eol);
    ign.jsonData(w, full.items) catch return error.OutOfMemory;
    w.print(",\"line_number\":{d},\"absolute_offset\":{d},\"submatches\":[", .{ no, off }) catch return error.OutOfMemory;
    if (is_match and !g.o.invert) {
        var from: usize = 0;
        var first = true;
        while (from <= text.len) {
            const sp = g.m.find(text, from) orelse break;
            if (sp.end == sp.start) {
                from = sp.start + 1;
                continue;
            }
            if (!first) w.writeByte(',') catch return error.OutOfMemory;
            first = false;
            w.writeAll("{\"match\":") catch return error.OutOfMemory;
            ign.jsonData(w, text[sp.start..sp.end]) catch return error.OutOfMemory;
            w.print(",\"start\":{d},\"end\":{d}}}", .{ sp.start, sp.end }) catch return error.OutOfMemory;
            from = sp.end;
        }
    }
    w.writeAll("]}}\n") catch return error.OutOfMemory;
    try emit(g, aw.written());
}

fn writeElapsed(w: *Io.Writer, ns: i128, sorted: bool) Io.Writer.Error!void {
    const n: u64 = @intCast(@max(ns, 0));
    const secs = n / 1_000_000_000;
    const nanos = n % 1_000_000_000;
    if (sorted) {
        try w.print("{{\"human\":\"{d}.{d:0>6}s\",\"nanos\":{d},\"secs\":{d}}}", .{ secs, nanos / 1000, nanos, secs });
    } else {
        try w.print("{{\"secs\":{d},\"nanos\":{d},\"human\":\"{d}.{d:0>6}s\"}}", .{ secs, nanos, secs, nanos / 1000 });
    }
}

fn jsonEnd(g: *G, matched: bool) Err!void {
    if (!g.json_begun) return;
    var aw: Io.Writer.Allocating = .init(g.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    const el = nowNs() - g.tfile_ns;
    g.fstat.elapsed_ns = el;
    // bytes_printed counts what was written for this file before the end message
    const printed = g.file_printed;
    g.json_printed += printed;
    w.writeAll("{\"type\":\"end\",\"data\":{\"path\":") catch return error.OutOfMemory;
    ign.jsonData(w, jsonName(g)) catch return error.OutOfMemory;
    w.writeAll(",\"binary_offset\":null,\"stats\":{\"elapsed\":") catch return error.OutOfMemory;
    writeElapsed(w, el, false) catch return error.OutOfMemory;
    w.print(",\"searches\":1,\"searches_with_match\":{d},\"bytes_searched\":{d},\"bytes_printed\":{d},\"matched_lines\":{d},\"matches\":{d}}}}}}}\n", .{ @intFromBool(matched), g.fstat.bytes_searched, printed, g.fstat.matched_lines, g.fstat.matches }) catch return error.OutOfMemory;
    try emit(g, aw.written());
}

fn jsonSummary(g: *G) Err!void {
    var aw: Io.Writer.Allocating = .init(g.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    const total = nowNs() - g.t0_ns;
    w.writeAll("{\"data\":{\"elapsed_total\":") catch return error.OutOfMemory;
    writeElapsed(w, total, true) catch return error.OutOfMemory;
    w.print(",\"stats\":{{\"bytes_printed\":{d},\"bytes_searched\":{d},\"elapsed\":", .{ g.json_printed, g.tot.bytes_searched }) catch return error.OutOfMemory;
    writeElapsed(w, g.tot.elapsed_ns, true) catch return error.OutOfMemory;
    w.print(",\"matched_lines\":{d},\"matches\":{d},\"searches\":{d},\"searches_with_match\":{d}}}}},\"type\":\"summary\"}}\n", .{ g.tot.matched_lines, g.tot.matches, g.tot.files, g.tot.files_with }) catch return error.OutOfMemory;
    try emit(g, aw.written());
}

fn printStats(g: *G) Err!void {
    var aw: Io.Writer.Allocating = .init(g.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    const total: u64 = @intCast(@max(nowNs() - g.t0_ns, 0));
    const spent: u64 = @intCast(@max(g.tot.elapsed_ns, 0));
    w.print("\n{d} matches\n{d} matched lines\n{d} files contained matches\n{d} files searched\n{d} bytes printed\n{d} bytes searched\n{d}.{d:0>6} seconds spent searching\n{d}.{d:0>6} seconds total\n", .{
        g.tot.matches,         g.tot.matched_lines,       g.tot.files_with, g.tot.files,
        g.tot.bytes_printed,   g.tot.bytes_searched,      spent / 1_000_000_000, (spent % 1_000_000_000) / 1000,
        total / 1_000_000_000, (total % 1_000_000_000) / 1000,
    }) catch return error.OutOfMemory;
    // the byte count in the report excludes the report itself
    try emit(g, aw.written());
}

fn flushBefore(g: *G) void {
    for (g.before_q.items) |c| g.gpa.free(c.text);
    g.before_q.clearRetainingCapacity();
}

// --------------------------------------------------------------- scanning

const Stop = enum { cont, stop };

/// Process one input line. Returns .stop when scanning of this file ends.
fn doLine(g: *G, text: []const u8, known_match: bool) Err!Stop {
    g.line_no += 1;
    const no = g.line_no;
    const off = g.offset;
    g.offset += text.len + 1;
    const o = &g.o;
    const matched = known_match or g.m.isMatch(text);
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
        if (o.count_matches or o.stats or o.json) {
            g.fstat.matched_lines += 1;
            g.fstat.matches += if (o.invert) 0 else countMatches(g, text);
        }
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
const chunk_len = 256 * 1024;

fn grepFd(g: *G, fd: sys.Handle, seekable_stdin: bool) Err!u64 {
    const o = &g.o;
    g.cur_noeol = false;
    var mem_pos: usize = 0;
    const hits_before = g.m.limitHits();
    defer {
        const now_hits = g.m.limitHits();
        if (now_hits > hits_before) {
            g.obs.emit(.{ .search_limit = .{ .name = g.fname, .line = g.line_no } });
            g.errseen = true;
        }
    }
    g.totalnl = 0;
    g.lastout_line = -1;
    g.pending = 0;
    g.line_no = 0;
    g.offset = 0;
    g.binary = false;
    g.nlines = 0;
    g.nlines_first_null = -1;
    g.enc_error_suppressed = false;
    g.fstat = .{};
    g.file_printed = 0;
    g.json_begun = false;
    g.tfile_ns = nowNs();
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    g.outleft = o.max_count;
    flushBefore(g);

    const buf = &g.buf;
    buf.clearRetainingCapacity();
    defer if (buf.capacity > (4 << 20)) buf.clearAndFree(g.gpa);
    var pos: usize = 0;
    var eof = false;
    var stopped = false;
    var consumed_total: u64 = 0;
    const base_quiet = g.out_quiet;
    var extra_nul_split = false;

    // Whole-buffer skipping (Matcher.candidate) is valid only while no
    // non-selected line has to be seen: no -v, no leading context.
    // With -v only counting (-c, -q is handled by exit_on_match) the skipped
    // lines are all selected: they are added to the count in bulk.
    const inv_count = o.invert and g.out_quiet and !g.done_on_match and o.max_count == std.math.maxInt(i64) and !(o.count_matches or o.stats or o.json);
    const can_skip = (inv_count or (!o.invert and o.before <= 0)) and g.m.bool_nodes.len == 0 and g.m.pre_kind != .none;
    var known_match = false;
    var total_read: u64 = 0;
    var size_reached = false;
    while (!stopped) {
        known_match = false;
        if (can_skip and !extra_nul_split and g.outleft != 0 and g.pending <= 0 and pos < buf.items.len and g.m.pre_kind != .none) skip: {
            const rest = buf.items[pos..];
            const limit = if (eof) buf.items.len else if (vec.lastIndexOf(rest, g.eol)) |k| pos + k + 1 else break :skip;
            if (limit <= pos) break :skip;
            const hay = buf.items[0..limit];
            switch (g.m.candidate(hay, pos)) {
                .unknown => {},
                .none => {
                    if (inv_count) g.nlines += vec.count(hay[pos..], g.eol) + @intFromBool(eof and hay[limit - 1] != g.eol);
                    g.line_no += vec.count(hay[pos..], g.eol);
                    g.offset += limit - pos;
                    consumed_total += limit - pos;
                    pos = limit;
                    continue;
                },
                .at => |idx| {
                    const start = if (vec.lastIndexOf(hay[pos..idx], g.eol)) |k| pos + k + 1 else pos;
                    if (inv_count) g.nlines += vec.count(hay[pos..start], g.eol);
                    g.line_no += vec.count(hay[pos..start], g.eol);
                    g.offset += start - pos;
                    consumed_total += start - pos;
                    pos = start;
                    known_match = g.m.pre_exact;
                },
            }
        }
        // find next line
        var term: ?usize = null;
        if (pos < buf.items.len) {
            const rest = buf.items[pos..];
            if (extra_nul_split) {
                term = std.mem.indexOfAny(u8, rest, "\n\x00");
            } else term = vec.indexOf(rest, g.eol, 0);
        }
        if (term == null) {
            if (eof) {
                if (pos < buf.items.len) {
                    // final line without terminator
                    const text = buf.items[pos..];
                    consumed_total += text.len;
                    pos = buf.items.len;
                    g.cur_noeol = true;
                    if (try doLine(g, text, known_match) == .stop) stopped = true;
                }
                break;
            }
            // read more
            if (size_reached) {
                eof = true;
                continue;
            }
            if (pos > 0 and pos == buf.items.len) {
                buf.clearRetainingCapacity();
                pos = 0;
            } else if (pos > chunk_len) {
                try buf.replaceRange(g.gpa, 0, pos, &.{});
                pos = 0;
            }
            var err: LX.E = .SUCCESS;
            try buf.ensureUnusedCapacity(g.gpa, chunk_len);
            const room = buf.unusedCapacitySlice()[0..chunk_len];
            const n = if (g.file_mem) |mem| blk: {
                const k = @min(room.len, mem.len - mem_pos);
                @memcpy(room[0..k], mem[mem_pos .. mem_pos + k]);
                mem_pos += k;
                break :blk k;
            } else sys.readFd(fd, room, &err) orelse {
                g.obs.emit(.{ .read_error = .{ .name = g.fname, .errno = err } });
                g.errseen = true;
                break;
            };
            if (n == 0) {
                eof = true;
                continue;
            }
            total_read += n;
            if (g.file_mem == null) if (g.cur_size) |sz| {
                if (total_read >= sz) size_reached = true;
            };
            if (!g.binary and o.binary_files != .text and !o.null_data) {
                if (vec.indexOf(room[0..n], 0, 0) != null) {
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
            buf.items.len += n;
            continue;
        }
        const text = buf.items[pos .. pos + term.?];
        consumed_total += term.? + 1;
        pos += term.? + 1;
        if (try doLine(g, text, known_match) == .stop) stopped = true;
    }
    _ = base_quiet;
    g.fstat.bytes_searched = consumed_total;
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
    if (o.count_matches and g.fstat.matches > 0) {
        if (g.show_name) {
            try printFilename(g);
            if (o.null_after_name) try emitByte(g, 0) else try printSep(g, ':');
        }
        var b: [24]u8 = undefined;
        try emit(g, std.fmt.bufPrint(&b, "{d}\n", .{g.fstat.matches}) catch unreachable);
    }
    const status_matched = count > 0;
    if (o.json) {
        try jsonEnd(g, status_matched);
        g.json_begun = false;
    }
    g.fstat.elapsed_ns = nowNs() - g.tfile_ns;
    g.tot.matches += g.fstat.matches;
    g.tot.matched_lines += g.fstat.matched_lines;
    g.tot.files += 1;
    g.tot.elapsed_ns += g.fstat.elapsed_ns;
    g.tot.bytes_searched += g.fstat.bytes_searched;
    if (status_matched) g.tot.files_with += 1;
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

fn grepOpened(g: *G, fd: sys.Handle, name: []const u8, is_stdin: bool, seekable_stdin: bool) Err!bool {

    _ = is_stdin;
    g.fname = name;
    {
        var serr: LX.E = .SUCCESS;
        g.offset_width = 20;
        g.cur_size = null;
        const fst_opt = g.pre_stat orelse sys.fstatFd(fd, &serr);
        g.pre_stat = null;
        if (fst_opt) |fst| {
            if (fst.isReg()) {
                var w: usize = 1;
                var sz = fst.size;
                while (sz >= 10) : (sz /= 10) w += 1;
                g.offset_width = w;
                if (fst.size > 0) g.cur_size = @intCast(fst.size);
            }
        }
    }
    const count = try grepFd(g, fd, seekable_stdin);
    const matched = try finishFile(g, count);
    flushBefore(g);
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    return matched;
}

fn rgFileOk(g: *G, display: []const u8, is_dir: bool) bool {
    const o = &g.o;
    var rel = display;
    while (std.mem.startsWith(u8, rel, "./")) rel = rel[2..];
    if (o.rg_globs.len > 0) {
        var last: ?bool = null;
        var white = false;
        for (o.rg_globs) |gp| {
            if (!gp.negate) white = true;
            if (gp.matches(rel, is_dir)) last = !gp.negate;
        }
        if (is_dir) {
            if (last != null and !last.?) return false;
        } else if (last) |l| {
            if (!l) return false;
        } else if (white) return false;
    }
    if (!is_dir) {
        const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |k| rel[k + 1 ..] else rel;
        if (o.type_include.len > 0 and !ign.nameHasGlob(base, o.type_include)) return false;
        if (o.type_exclude.len > 0 and ign.nameHasGlob(base, o.type_exclude)) return false;
    }
    return true;
}

fn ignored(g: *G, display: []const u8, is_dir: bool) bool {
    var i = g.ign_stack.items.len;
    while (i > 0) {
        i -= 1;
        const lv = g.ign_stack.items[i];
        if (display.len < lv.prefix_len) continue;
        const rel = display[lv.prefix_len..];
        const l: ign.PatternList = .{ .items = lv.pats };
        if (l.verdict(rel, is_dir)) |v| return v;
    }
    return false;
}

/// Read `path` fully; null on error.
fn slurp(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var err: LX.E = .SUCCESS;
    const fd = sys.openFd(path, sys.O.RDONLY, 0, &err) orelse return null;
    defer _ = sys.closeFd(fd);
    var data: std.ArrayList(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = sys.readFd(fd, &buf, &err) orelse {
            data.deinit(gpa);
            return null;
        };
        if (n == 0) break;
        data.appendSlice(gpa, buf[0..n]) catch {
            data.deinit(gpa);
            return null;
        };
    }
    return data.toOwnedSlice(gpa) catch null;
}

fn pushIgnore(g: *G, dir_path: []const u8, prefix_len: usize) Err!void {
    for ([_][]const u8{ ".gitignore", ".ignore" }) |nm| {
        const fp = try std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ dir_path, nm });
        defer g.gpa.free(fp);
        const data = slurp(g.gpa, fp) orelse continue;
        var pats: std.ArrayList(ign.Pattern) = .empty;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |ln| {
            if (ign.Pattern.parse(ln, true)) |pt| try pats.append(g.gpa, pt);
        }
        try g.ign_stack.append(g.gpa, .{ .prefix_len = prefix_len, .pats = try pats.toOwnedSlice(g.gpa), .data = data });
    }
}

const Decompressed = union(enum) { raw, data: []u8, failed };

/// Decompress gzip, zlib, xz or zstd data (by magic number).
fn decompressBuf(gpa: std.mem.Allocator, data: []const u8, g: *G) Decompressed {
    const std_c = std.compress;
    var in = Io.Reader.fixed(data);
    if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b) {
        var win: [std_c.flate.max_window_len]u8 = undefined;
        var d = std_c.flate.Decompress.init(&in, .gzip, &win);
        const out = d.reader.allocRemaining(gpa, .unlimited) catch return .failed;
        return .{ .data = out };
    }
    if (data.len >= 2 and data[0] == 0x78 and (data[1] == 0x01 or data[1] == 0x5e or data[1] == 0x9c or data[1] == 0xda) and ((@as(u16, data[0]) << 8) | data[1]) % 31 == 0) {
        var win: [std_c.flate.max_window_len]u8 = undefined;
        var d = std_c.flate.Decompress.init(&in, .zlib, &win);
        const out = d.reader.allocRemaining(gpa, .unlimited) catch return .failed;
        return .{ .data = out };
    }
    if (data.len >= 6 and std.mem.eql(u8, data[0..6], &.{ 0xFD, '7', 'z', 'X', 'Z', 0x00 })) {
        const b0 = gpa.alloc(u8, 0) catch return .failed;
        var d = std_c.xz.Decompress.init(&in, gpa, b0) catch {
            gpa.free(b0);
            return .failed;
        };
        defer d.deinit();
        const out = d.reader.allocRemaining(gpa, .unlimited) catch return .failed;
        return .{ .data = out };
    }
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], &.{ 0x28, 0xb5, 0x2f, 0xfd })) {
        const zbuf = gpa.alloc(u8, std_c.zstd.default_window_len + std_c.zstd.block_size_max) catch return .failed;
        defer gpa.free(zbuf);
        var d = std_c.zstd.Decompress.init(&in, zbuf, .{});
        const out = d.reader.allocRemaining(gpa, .unlimited) catch return .failed;
        return .{ .data = out };
    }
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "BZh")) {
        g.obs.emit(.{ .unsupported_compression = .{ .name = g.fname, .format = "bzip2" } });
    }
    return .raw;
}

fn grepFile(g: *G, path: []const u8, display: []const u8, cmdline: bool, in_dir: bool) Err!bool {
    const o = &g.o;
    // status of the file: true = matched
    var err: LX.E = .SUCCESS;
    var st_opt = sys.fileStat(path, cmdline or o.deref_recursive or o.symlinks != .gnu, &err);
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
        if (o.directories == .recurse) {
            if (cmdline and o.symlinks == .none) {
                var e2: LX.E = .SUCCESS;
                if (sys.fileStat(path, false, &e2)) |l| if (l.isLink()) return false;
            }
            return try grepDir(g, path, display, cmdline);
        }
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
    if (in_dir and !rgFileOk(g, display, false)) return false;
    var oerr: LX.E = .SUCCESS;
    const fd = sys.openFd(path, sys.O.RDONLY | sys.O.NONBLOCK, 0, &oerr) orelse {
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
    if (o.decompress and st.isReg()) {
        const raw = slurp(g.gpa, path) orelse {
            g.obs.emit(.{ .read_error = .{ .name = display, .errno = .IO } });
            g.errseen = true;
            return false;
        };
        g.fname = display;
        switch (decompressBuf(g.gpa, raw, g)) {
            .raw => {
                g.file_mem = raw;
                defer {
                    g.file_mem = null;
                    g.gpa.free(raw);
                }
                return try grepOpened(g, fd, display, false, false);
            },
            .data => |d| {
                g.gpa.free(raw);
                g.file_mem = d;
                defer {
                    g.file_mem = null;
                    g.gpa.free(d);
                }
                return try grepOpened(g, fd, display, false, false);
            },
            .failed => {
                g.gpa.free(raw);
                g.obs.emit(.{ .decompress_failed = display });
                g.errseen = true;
                return false;
            },
        }
    }
    g.pre_stat = st;
    return try grepOpened(g, fd, display, false, false);
}

const SortEnt = struct { name: []u8, key: i128 };

fn entLess(ctx: *const G, a: SortEnt, b: SortEnt) bool {
    if (ctx.o.sort != .path and a.key != b.key) return a.key < b.key;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn sortEntLess(ctx: *const G, a: SortEnt, b: SortEnt) bool {
    return if (ctx.o.sort_reverse) entLess(ctx, b, a) else entLess(ctx, a, b);
}

fn grepDir(g: *G, path: []const u8, display: []const u8, cmdline: bool) Err!bool {
    const o = &g.o;
    if (dirExcluded(g, display, if (std.mem.lastIndexOfScalar(u8, display, '/')) |k| display[k + 1 ..] else display, cmdline)) return false;
    if (o.include_dirs.len > 0) {
        var nm = display;
        while (nm.len > 1 and nm[nm.len - 1] == '/') nm = nm[0 .. nm.len - 1];
        if (!dirIncluded(g, if (std.mem.lastIndexOfScalar(u8, nm, '/')) |k| nm[k + 1 ..] else nm)) return false;
    }
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
    var kinds: std.ArrayList(Io.File.Kind) = .empty;
    defer {
        for (names.items) |n| g.gpa.free(n);
        names.deinit(g.gpa);
        kinds.deinit(g.gpa);
    }
    var it = dir.iterate();
    while (it.next(g.env.io) catch null) |entry| {
        const dup = try g.gpa.dupe(u8, entry.name);
        try names.append(g.gpa, dup);
        try kinds.append(g.gpa, entry.kind);
    }
    dir.close(g.env.io);
    var pbase = path;
    while (pbase.len > 1 and pbase[pbase.len - 1] == '/') pbase = pbase[0 .. pbase.len - 1];
    var dbase = display;
    while (dbase.len > 1 and dbase[dbase.len - 1] == '/') dbase = dbase[0 .. dbase.len - 1];
    const implicit = g.implicit_dot and std.mem.eql(u8, display, ".");
    const ign_mark = g.ign_stack.items.len;
    defer {
        while (g.ign_stack.items.len > ign_mark) {
            const lv = g.ign_stack.pop().?;
            g.gpa.free(lv.pats);
            g.gpa.free(lv.data);
        }
    }
    if (o.ignore_vcs) try pushIgnore(g, pbase, if (implicit) 0 else dbase.len + 1);
    if (o.sort != .none) {
        var ents: std.ArrayList(SortEnt) = .empty;
        defer ents.deinit(g.gpa);
        for (names.items) |n| {
            var key: i128 = 0;
            if (o.sort != .path) {
                const child = try std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ pbase, n });
                defer g.gpa.free(child);
                var e3: LX.E = .SUCCESS;
                if (sys.fileStat(child, true, &e3)) |fs| {
                    key = switch (o.sort) {
                        .modified => @as(i128, fs.mtime_s) * 1_000_000_000 + fs.mtime_ns,
                        .accessed => @as(i128, fs.atime_s) * 1_000_000_000 + fs.atime_ns,
                        .created => if (fs.has_btime) @as(i128, fs.btime_s) * 1_000_000_000 + fs.btime_ns else @as(i128, fs.ctime_s) * 1_000_000_000 + fs.ctime_ns,
                        .size => fs.size,
                        else => 0,
                    };
                }
            }
            try ents.append(g.gpa, .{ .name = n, .key = key });
        }
        std.mem.sort(SortEnt, ents.items, g, sortEntLess);
        for (ents.items, 0..) |e, i| names.items[i] = e.name;
    }
    for (names.items, 0..) |n, name_idx| {
        if (!o.search_hidden and n.len > 0 and n[0] == '.') continue;
        const child = if (implicit)
            std.fmt.allocPrint(g.gpa, "{s}", .{n}) catch return error.OutOfMemory
        else
            try std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ pbase, n });
        defer g.gpa.free(child);
        const disp = if (implicit)
            std.fmt.allocPrint(g.gpa, "{s}", .{n}) catch return error.OutOfMemory
        else
            try std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ dbase, n });
        defer g.gpa.free(disp);
        var err: LX.E = .SUCCESS;
        // The directory entry already says "regular file" or "directory";
        // only other kinds (symlinks, unknown) need an lstat. (Sorting
        // permutes `names`, so the kinds are not used then.)
        const known_kind: Io.File.Kind = if (o.sort == .none) kinds.items[name_idx] else .unknown;
        const lst = if (known_kind == .file or known_kind == .directory) null else sys.fileStat(child, false, &err);
        var is_dir = known_kind == .directory;
        if (lst) |l| {
            if (l.isLink() and !o.deref_recursive) {
                if (o.symlinks == .gnu) continue;
                var e4: LX.E = .SUCCESS;
                const tgt = sys.fileStat(child, true, &e4);
                if (tgt == null or tgt.?.isDir()) continue;
            }
            is_dir = l.isDir();
        }
        if (o.ignore_vcs and ignored(g, disp, is_dir)) continue;
        if (is_dir) {
            if (!rgFileOk(g, disp, true)) continue;
        }
        if (try grepFile(g, child, disp, false, true)) any = true;
        if (g.early) break;
    }
    return any;
}

fn dirIncluded(g: *G, base: []const u8) bool {
    for (g.o.include_dirs) |p| if (fnmatch.match(p, base, .{})) return true;
    return false;
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
