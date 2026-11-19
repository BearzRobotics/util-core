// SPDX-License-Identifier: GPL-2.0-or-later
//! sort library — sort, merge, or check lines of text (decision 0004). The
//! option grammar (key specifications, obsolete +POS keys, --files0-from, the
//! validation of -S/--parallel/...) and the GNU diagnostics are in
//! src/commands/sort.zig; this module is the ordering engine and the three
//! run modes.
//! References: GNU coreutils manual "sort invocation" (9.7); POSIX.1-2024 sort.
//!
//! Scope of this implementation (see docs/compatibility/sort.md):
//!   * modes: sort, -m merge, -c/-C check; -o, -u, -s, -z;
//!   * keys: -k F[.C][OPTS][,F[.C][OPTS]], -t, -b, global options inherited by
//!     keys that carry no ordering letters of their own;
//!   * orderings: lexicographic (-d -f -i), -n, -g, -h, -M, -V, -R, -r.
//!   * --debug (C locale), obsolete +POS1 -POS2 keys. -S -T --parallel --batch-size --compress-program
//!     are validated and then ignored: all input is held in memory.
//!
//! Design: every input is read into one byte buffer; the lines are slices of
//! it; a stable merge sort orders the slice array. Keys are located on every
//! comparison, like GNU, rather than precomputed. Bytes are compared as
//! unsigned values (C locale); LC_COLLATE/LC_CTYPE/LC_NUMERIC are not
//! consulted. "Blank" for field splitting is space, tab or newline (GNU's
//! field_sep(), so -z records containing newlines split sensibly).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const wsink = @import("wsink.zig");
const linereader = @import("../lines.zig");

pub const Env = common.Env;

pub const no_field = std.math.maxInt(usize);

pub const Mode = enum { lex, numeric, general, human, month, version, random };

/// -R: 16 bytes drawn from --random-source (or the system RNG), prepended to
/// every key before hashing. `nul`: GNU hashes the strxfrm form
/// (NUL-terminated) when the collation locale is not C/POSIX.
pub const Rand = struct {
    seed: [16]u8 = @splat(0),
    nul: bool = false,
};

pub const Check = enum { none, diagnose, quiet };

/// Everything a run needs once the command line is parsed. `keys` is the
/// final key list (global options already inherited, a synthetic key added
/// when only global options were given).
pub const Options = struct {
    gkey: Ordering = .{},
    keys: []const Key = &.{},
    tab: ?u8 = null,
    unique: bool = false,
    stable: bool = false,
    merge: bool = false,
    check: Check = .none,
    term: u8 = '\n',
    /// -o: write here instead of the writer given to `run`.
    output: ?[]const u8 = null,
    debug: bool = false,
    /// Seed for -R; see `seedRandom`.
    rand: Rand = .{},
};

pub const Event = union(enum) {
    // --debug notes (stderr, C locale); `debugNotes` sends these.
    note_simple_byte_comparison,
    note_obsolescent_key: struct { old: []const u8, new: []const u8 },
    note_zero_width: usize,
    note_leading_blanks: usize,
    note_numeric_multi_field: usize,
    note_decimal_point,
    /// One letter: "option '-x' is ignored", several: "options '-xy' are ignored".
    note_options_ignored: []const u8,
    note_r_last_resort,
    // Failures; `run` returns status 2 (1 for a disorder) after one of these.
    /// The random source could not be opened.
    random_open_failed: struct { path: []const u8, err: anyerror },
    /// The random source is too short.
    random_eof: []const u8,
    random_read_failed: struct { path: []const u8, err: anyerror },
    /// An input could not be opened; `checking` is true for -c/-C.
    open_failed: struct { name: []const u8, err: anyerror, checking: bool },
    read_failed: struct { name: []const u8, err: anyerror },
    /// -c: the first line out of order (or duplicate with -u).
    disorder: struct { name: []const u8, line: usize, text: []const u8, term: u8 },
    output_open_failed: struct { path: []const u8, err: anyerror },
    /// Writing the result failed; `streaming` for the -m path that writes as it reads.
    write_failed: struct { output: ?[]const u8, streaming: bool },
    out_of_memory,
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// Process exit status: 0, 1 (unsorted with -c/-C) or 2 (failure).
    status: u8 = 0,
};

const fail_status: u8 = 2;

/// Whether any key (or the global ordering with no keys) is -R.
pub fn usesRandom(cfg: *const Options) bool {
    if (cfg.gkey.mode == .random) return true;
    for (cfg.keys) |k| if (k.ord.mode == .random) return true;
    return false;
}

/// Fill a `Rand` from `source` (a file) or the system random generator. Null
/// after an event when the file cannot supply 16 bytes.
pub fn seedRandom(env: Env, source: ?[]const u8, obs: Observer) ?Rand {
    var r: Rand = .{};
    for ([_][]const u8{ "LC_ALL", "LC_COLLATE", "LANG" }) |v| {
        if (env.getenv(v)) |val| {
            if (val.len == 0) continue;
            r.nul = !(std.mem.eql(u8, val, "C") or std.mem.eql(u8, val, "POSIX"));
            break;
        }
    }
    const path = source orelse {
        env.io.random(&r.seed);
        return r;
    };
    const file = std.Io.Dir.cwd().openFile(env.io, path, .{}) catch |e| {
        obs.emit(.{ .random_open_failed = .{ .path = path, .err = e } });
        return null;
    };
    defer file.close(env.io);
    var got: usize = 0;
    while (got < r.seed.len) {
        const n = file.readStreaming(env.io, &.{r.seed[got..]}) catch |e| {
            if (e == error.EndOfStream) {
                obs.emit(.{ .random_eof = path });
            } else obs.emit(.{ .random_read_failed = .{ .path = path, .err = e } });
            return null;
        };
        if (n == 0) {
            obs.emit(.{ .random_eof = path });
            return null;
        }
        got += n;
    }
    return r;
}

fn openName(io: Io, name: []const u8) !Io.File {
    if (std.mem.eql(u8, name, "-")) return Io.File.stdin();
    return Io.Dir.cwd().openFile(io, name, .{ .allow_directory = false });
}

fn closeName(io: Io, file: Io.File) void {
    if (file.handle != Io.File.stdin().handle) file.close(io);
}

const ReadError = error{ Reported, OutOfMemory };

/// Append the contents of `name` to `buf`, making sure the data ends with a
/// terminator (GNU supplies a missing final newline).
fn readInto(env: Env, obs: Observer, buf: *std.ArrayList(u8), name: []const u8, term: u8) ReadError!void {
    const start = buf.items.len;
    const file = openName(env.io, name) catch |e| {
        obs.emit(.{ .open_failed = .{ .name = name, .err = e, .checking = false } });
        return error.Reported;
    };
    defer closeName(env.io, file);
    while (true) {
        try buf.ensureUnusedCapacity(env.gpa, 64 * 1024);
        const n = common.readChunk(env.io, file, buf.unusedCapacitySlice()) catch |e| {
            obs.emit(.{ .read_failed = .{ .name = name, .err = e } });
            return error.Reported;
        };
        if (n == 0) break;
        buf.items.len += n;
    }
    if (buf.items.len > start and buf.items[buf.items.len - 1] != term) try buf.append(env.gpa, term);
}

/// Sort, merge or check `inputs` ("-" is standard input). The result goes to
/// `out_w` unless `opts.output` names a file. Problems are sent to `obs`; the
/// returned status is the process exit status.
pub fn run(env: Env, opts: Options, inputs: []const []const u8, out_w: *Io.Writer, obs: Observer) Result {
    const gpa = env.gpa;
    const sorter = Sorter.init(&opts);

    // -c and -m can work one line at a time; only sorting needs the whole input.
    if (opts.check != .none) return .{ .status = checkStream(env, obs, &sorter, &opts, inputs[0]) };
    if (opts.merge and opts.output == null and mergeStreamable(inputs)) return .{ .status = mergeStream(env, obs, out_w, &sorter, &opts, inputs) };

    // Read everything before touching the output file, so `sort -o f f` works.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var ends: std.ArrayList(usize) = .empty; // buf offset where each input ends
    defer ends.deinit(gpa);
    for (inputs) |n| {
        readInto(env, obs, &buf, n, opts.term) catch |e| switch (e) {
            error.Reported => return .{ .status = fail_status },
            error.OutOfMemory => return oom(obs),
        };
        ends.append(gpa, buf.items.len) catch return oom(obs);
    }

    var all_lines: std.ArrayList([]const u8) = .empty;
    defer all_lines.deinit(gpa);
    var run_starts: std.ArrayList(usize) = .empty; // index into all_lines where each input starts
    defer run_starts.deinit(gpa);
    {
        var pos: usize = 0;
        for (ends.items) |end| {
            run_starts.append(gpa, all_lines.items.len) catch return oom(obs);
            while (pos < end) {
                const stop = std.mem.indexOfScalarPos(u8, buf.items[0..end], pos, opts.term) orelse end;
                all_lines.append(gpa, buf.items[pos..stop]) catch return oom(obs);
                pos = stop + 1;
            }
        }
        run_starts.append(gpa, all_lines.items.len) catch return oom(obs);
    }

    if (opts.merge) {
        mergeRuns(gpa, &sorter, all_lines.items, run_starts.items) catch return oom(obs);
    } else {
        sortLines(gpa, &sorter, all_lines.items) catch return oom(obs);
    }

    // Output.
    var out_file: ?Io.File = null;
    if (opts.output) |path| {
        out_file = Io.Dir.cwd().createFile(env.io, path, .{}) catch |e| {
            obs.emit(.{ .output_open_failed = .{ .path = path, .err = e } });
            return .{ .status = fail_status };
        };
    }
    defer if (out_file) |f| f.close(env.io);
    var out = if (out_file) |f| wsink.Sink.initFile(env.io, f) else wsink.Sink.initWriter(out_w);
    var prev: ?[]const u8 = null;
    for (all_lines.items) |line| {
        if (opts.unique) {
            if (prev) |p| if (sorter.compare(p, line) == 0) continue;
            prev = line;
        }
        emitRecord(&out, &opts, line);
        if (out.failed) break;
    }
    out.flush();
    if (out.failed) {
        obs.emit(.{ .write_failed = .{ .output = opts.output, .streaming = false } });
        return .{ .status = fail_status };
    }
    return .{ .status = 0 };
}

fn oom(obs: Observer) Result {
    obs.emit(.out_of_memory);
    return .{ .status = fail_status };
}

/// Ordering options of one key, or of the whole command line ("global").
pub const Ordering = struct {
    mode: Mode = .lex,
    /// Bit per numeric-style ordering requested (g, h, M, n); more than one
    /// is an error, as in GNU.
    mode_mask: u6 = 0,
    fold: bool = false, // -f
    dict: bool = false, // -d
    nonprint: bool = false, // -i
    reverse: bool = false, // -r
    skip_sblanks: bool = false, // -b on the start position
    skip_eblanks: bool = false, // -b on the end position

    /// GNU default_key_compare() plus "no -r": a key like this inherits the
    /// global options.
    pub fn isPlain(o: Ordering) bool {
        return o.mode == .lex and !o.fold and !o.dict and !o.nonprint and !o.reverse and !o.skip_sblanks and !o.skip_eblanks;
    }
    /// GNU default_key_compare(): nothing but (maybe) -r is set.
    pub fn isPlainExceptReverse(o: Ordering) bool {
        var c = o;
        c.reverse = false;
        return c.isPlain();
    }
    pub fn ignores(o: Ordering) bool {
        return o.dict or o.nonprint;
    }
};

pub const Key = struct {
    sword: usize = 0, // 0-based first field
    schar: usize = 0, // 0-based first character within it
    eword: usize = no_field, // 0-based last field; no_field = end of line
    echar: usize = 0, // 1-based last character; 0 = end of field
    ord: Ordering = .{},
    synthetic: bool = false, // built from the global options (no -k given)
    obsolete: bool = false, // written as +POS1 [-POS2]
    obs_s: usize = 0, // the POS1 field count as written
    obs_e: usize = 0, // the -POS2 field count as written, plus one when it carries a character offset
    obs_has_e: bool = false,
};

// ---------------------------------------------------------------- compare

const Sorter = struct {
    keys: []const Key,
    tab: ?u8,
    unique: bool,
    stable: bool,
    reverse: bool,
    /// No keys at all: plain bytewise comparison (possibly reversed).
    simple: bool,
    rand: Rand,

    fn init(cfg: *const Options) Sorter {
        return .{
            .keys = cfg.keys,
            .rand = cfg.rand,
            .tab = cfg.tab,
            .unique = cfg.unique,
            .stable = cfg.stable,
            .reverse = cfg.gkey.reverse,
            .simple = cfg.keys.len == 0,
        };
    }

    /// <0, 0, >0 following GNU compare(): keys first, then (unless -s or -u)
    /// a last-resort bytewise comparison of the whole lines.
    fn compare(s: *const Sorter, a: []const u8, b: []const u8) i32 {
        if (!s.simple) {
            const d = s.compareKeys(a, b);
            if (d != 0 or s.unique or s.stable) return d;
        }
        const d = sign(orderBytes(a, b));
        return if (s.reverse) -d else d;
    }

    fn compareKeys(s: *const Sorter, a: []const u8, b: []const u8) i32 {
        for (s.keys) |k| {
            const fa = field(a, k, s.tab);
            const fb = field(b, k, s.tab);
            var d = compareField(&s.rand, k.ord, fa, fb);
            if (k.ord.reverse) d = -d;
            if (d != 0) return d;
        }
        return 0;
    }
};

// ------------------------------------------------------------ fast sorting
//
// Sorting compares O(n log n) pairs, so the work that does not depend on the
// partner line is done once per line: where each key lies, its parsed value
// for -n, and a 64-bit "prefix" of the first key. The sort permutes 16-byte
// Items (prefix + line index) so the merge passes stream through memory; the
// per-line data is only touched when two prefixes tie. Results must equal
// Sorter.compare; test/test_sort.sh checks that against GNU.
//
// Prefix of the first key:
//   * plain lexicographic key (or no keys): its first eight bytes, big-endian,
//     zero padded. Different prefixes decide the order; equal ones do not.
//   * -n key: the value as an IEEE double mapped to an order-preserving
//     integer, but only when the number has at most 15 significant digits.
//     Such a double is the correctly rounded value of the decimal, so
//     different decimals give different, correctly ordered doubles and equal
//     doubles mean equal numbers. Longer numbers are `inexact` and always take
//     the full comparison.

const Item = struct {
    prefix: u64,
    /// The line itself, so a prefix tie costs one memory access, not two.
    ptr: [*]const u8,
    len: u32,
    idx: u32,
    exact: bool,

    fn line(it: Item) []const u8 {
        return it.ptr[0..it.len];
    }
};

const PrefixKind = enum { none, lex, numeric, general };

/// Per-line data of the lines being sorted, indexed by Item.idx.
const Columns = struct {
    nk: usize,
    /// lines.len * nk key slices.
    fields: []const []const u8,
    /// lines.len * nk parsed numbers; valid for -n keys only.
    nums: []const Num,
    /// lines.len * nk parsed floats; valid for -g keys only.
    gens: []const General,
};

fn prefixOf(t: []const u8) u64 {
    const n: usize = @min(@as(usize, 8), t.len); // usize: the shift below must not overflow a narrow type
    if (n == 0) return 0;
    var v: u64 = 0;
    for (t[0..n]) |c| v = (v << 8) | c;
    return v << @intCast(8 * (8 - n));
}

const max_exact_digits = 15;

/// Order-preserving integer for a parsed number; `exact` is false when it has
/// too many digits for the double to be trusted (see above).
fn numericPrefix(n: Num) struct { bits: u64, exact: bool } {
    const digits = n.int.len + n.frac.len;
    if (digits > max_exact_digits) return .{ .bits = 0, .exact = false };
    var m: u64 = 0;
    for (n.int) |c| m = m * 10 + (c - '0');
    for (n.frac) |c| m = m * 10 + (c - '0');
    var scale: f64 = 1;
    for (n.frac) |_| scale *= 10; // powers of ten up to 1e15 are exact doubles
    var v: f64 = @as(f64, @floatFromInt(m)) / scale;
    if (n.neg) v = -v;
    const raw: u64 = @bitCast(v);
    return .{ .bits = if (raw >> 63 != 0) ~raw else raw | (@as(u64, 1) << 63), .exact = true };
}

fn prefixKind(s: *const Sorter) PrefixKind {
    if (s.simple) return .lex;
    const o = s.keys[0].ord;
    if (o.mode == .numeric) return .numeric;
    if (o.mode == .general) return .general;
    if (o.mode == .lex and !o.fold and !o.ignores()) return .lex;
    return .none;
}

fn compareItems(s: *const Sorter, kind: PrefixKind, c: *const Columns, a: Item, b: Item) i32 {
    if (s.simple) {
        var d: i32 = undefined;
        if (a.prefix != b.prefix) {
            d = if (a.prefix < b.prefix) -1 else 1;
        } else {
            d = sign(orderBytes(a.line(), b.line()));
        }
        return if (s.reverse) -d else d;
    }
    var first: usize = 0;
    if (kind != .none and a.exact and b.exact) {
        if (a.prefix != b.prefix) {
            const d: i32 = if (a.prefix < b.prefix) -1 else 1;
            return if (s.keys[0].ord.reverse) -d else d;
        }
        if (kind == .numeric) first = 1; // equal numbers: key 0 is settled
    }
    const nk = c.nk;
    for (s.keys[first..], first..) |k, i| {
        var d = switch (k.ord.mode) {
            .numeric => compareNum(c.nums[a.idx * nk + i], c.nums[b.idx * nk + i]),
            .general => compareGen(c.gens[a.idx * nk + i], c.gens[b.idx * nk + i]),
            else => compareField(&s.rand, k.ord, c.fields[a.idx * nk + i], c.fields[b.idx * nk + i]),
        };
        if (k.ord.reverse) d = -d;
        if (d != 0) return d;
    }
    if (s.unique or s.stable) return 0;
    const d = sign(orderBytes(a.line(), b.line()));
    return if (s.reverse) -d else d;
}

/// Stable merge sort of `lines` (reordered in place). Uses two Item buffers
/// plus the per-line tables; runs of `run` items are insertion sorted, then
/// merged pairwise, alternating between the buffers.
fn sortLines(gpa: std.mem.Allocator, s: *const Sorter, lines: [][]const u8) !void {
    const n = lines.len;
    if (n < 2) return;
    if (n > std.math.maxInt(u32)) return error.OutOfMemory;
    const nk = s.keys.len;

    var any_numeric = false;
    var any_general = false;
    for (s.keys) |k| {
        any_numeric = any_numeric or k.ord.mode == .numeric;
        any_general = any_general or k.ord.mode == .general;
    }
    const fields = try gpa.alloc([]const u8, n * nk);
    defer gpa.free(fields);
    const nums = try gpa.alloc(Num, if (any_numeric) n * nk else 0);
    defer gpa.free(nums);
    const gens = try gpa.alloc(General, if (any_general) n * nk else 0);
    defer gpa.free(gens);

    // -f, -d and -i keys are compared as plain bytes after one transformation
    // per line (folded to upper case, ignorable characters removed), instead
    // of byte by byte with those rules on every comparison. The sort below
    // uses `eff`, whose transformed keys no longer carry those options.
    const eff_keys = try gpa.dupe(Key, s.keys);
    defer gpa.free(eff_keys);
    // A transformed key is never longer than the original, so the sum of the
    // original key lengths bounds the space needed.
    var xtotal: usize = 0;
    for (s.keys) |k| {
        if (k.ord.mode == .lex and (k.ord.fold or k.ord.ignores())) {
            for (lines) |line| xtotal += field(line, k, s.tab).len;
        }
    }
    const xbuf = try gpa.alloc(u8, xtotal);
    defer gpa.free(xbuf);
    var xpos: usize = 0;
    const a = try gpa.alloc(Item, n);
    defer gpa.free(a);
    const b = try gpa.alloc(Item, n);
    defer gpa.free(b);

    for (eff_keys) |*k| {
        if (k.ord.mode == .lex and (k.ord.fold or k.ord.ignores())) {
            // Mark which keys were transformed by clearing their options on the
            // working copy; the per-line pass below tests the original `s.keys`.
            k.ord.fold = false;
            k.ord.dict = false;
            k.ord.nonprint = false;
        }
    }
    var eff = s.*;
    eff.keys = eff_keys;
    const kind = prefixKind(&eff);
    for (lines, 0..) |line, i| {
        if (line.len > std.math.maxInt(u32)) return error.OutOfMemory;
        var item: Item = .{ .prefix = 0, .ptr = line.ptr, .len = @intCast(line.len), .idx = @intCast(i), .exact = true };
        for (s.keys, 0..) |k, j| {
            var f = field(line, k, s.tab);
            switch (k.ord.mode) {
                .numeric => nums[i * nk + j] = parseNum(f),
                .general => gens[i * nk + j] = parseGeneral(f),
                .lex => if (k.ord.fold or k.ord.ignores()) {
                    const start = xpos;
                    for (f) |ch| {
                        if (k.ord.ignores() and ignored(k.ord, ch)) continue;
                        xbuf[xpos] = if (k.ord.fold) std.ascii.toUpper(ch) else ch;
                        xpos += 1;
                    }
                    f = xbuf[start..xpos];
                },
                else => {},
            }
            fields[i * nk + j] = f;
        }
        switch (kind) {
            .none => {},
            .lex => item.prefix = prefixOf(if (s.simple) line else fields[i * nk]),
            .numeric => {
                const p = numericPrefix(nums[i * nk]);
                item.prefix = p.bits;
                item.exact = p.exact;
            },
            .general => item.prefix = generalPrefix(gens[i * nk]),
        }
        a[i] = item;
    }
    const cols: Columns = .{ .nk = nk, .fields = fields, .nums = nums, .gens = gens };

    const run_len = 12;
    var lo: usize = 0;
    while (lo < n) : (lo += run_len) {
        const hi = @min(lo + run_len, n);
        var i = lo + 1;
        while (i < hi) : (i += 1) {
            const x = a[i];
            var j = i;
            while (j > lo and compareItems(&eff, kind, &cols, x, a[j - 1]) < 0) : (j -= 1) a[j] = a[j - 1];
            a[j] = x;
        }
    }

    var src = a;
    var dst = b;
    var width: usize = run_len;
    while (width < n) : (width *= 2) {
        var start: usize = 0;
        while (start < n) : (start += 2 * width) {
            const mid = @min(start + width, n);
            const end = @min(start + 2 * width, n);
            var i = start;
            var j = mid;
            var o = start;
            while (i < mid and j < end) : (o += 1) {
                // Take from the right run only when strictly smaller: stable.
                if (compareItems(&eff, kind, &cols, src[j], src[i]) < 0) {
                    dst[o] = src[j];
                    j += 1;
                } else {
                    dst[o] = src[i];
                    i += 1;
                }
            }
            while (i < mid) : (o += 1) {
                dst[o] = src[i];
                i += 1;
            }
            while (j < end) : (o += 1) {
                dst[o] = src[j];
                j += 1;
            }
        }
        const t = src;
        src = dst;
        dst = t;
    }
    // Items carry their own line, so the caller's slice can be overwritten.
    for (src, 0..) |it, i| lines[i] = it.line();
}

/// Bytewise order like memcmp, eight bytes at a time (std.mem.order is a
/// byte loop).
fn orderBytes(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i + 8 <= n) : (i += 8) {
        const x = std.mem.readInt(u64, a[i..][0..8], .big);
        const y = std.mem.readInt(u64, b[i..][0..8], .big);
        if (x != y) return if (x < y) .lt else .gt;
    }
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

fn sign(o: std.math.Order) i32 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// GNU begfield(): offset where key `k` starts in `line`.
fn begField(line: []const u8, k: Key, tab: ?u8) usize {
    var p: usize = 0;
    var n = k.sword;
    if (tab) |t| {
        while (p < line.len and n > 0) : (n -= 1) {
            while (p < line.len and line[p] != t) p += 1;
            if (p < line.len) p += 1;
        }
    } else {
        while (p < line.len and n > 0) : (n -= 1) {
            while (p < line.len and isBlank(line[p])) p += 1;
            while (p < line.len and !isBlank(line[p])) p += 1;
        }
    }
    if (k.ord.skip_sblanks) while (p < line.len and isBlank(line[p])) {
        p += 1;
    };
    return if (k.schar < line.len - p) p + k.schar else line.len;
}

/// GNU limfield(): offset just past the end of key `k`.
fn limField(line: []const u8, k: Key, tab: ?u8) usize {
    if (k.eword == no_field) return line.len;
    var p: usize = 0;
    var eword = k.eword;
    const echar = k.echar;
    if (echar == 0) eword +%= 1; // skip all of the end field
    if (tab) |t| {
        while (p < line.len and eword > 0) {
            eword -= 1;
            while (p < line.len and line[p] != t) p += 1;
            if (p < line.len and (eword != 0 or echar != 0)) p += 1;
        }
    } else {
        while (p < line.len and eword > 0) {
            eword -= 1;
            while (p < line.len and isBlank(line[p])) p += 1;
            while (p < line.len and !isBlank(line[p])) p += 1;
        }
    }
    if (echar != 0) {
        if (k.ord.skip_eblanks) while (p < line.len and isBlank(line[p])) {
            p += 1;
        };
        p = if (echar < line.len - p) p + echar else line.len;
    }
    return p;
}

fn field(line: []const u8, k: Key, tab: ?u8) []const u8 {
    const beg = begField(line, k, tab);
    const lim = @max(beg, limField(line, k, tab)); // an end before the start is an empty key
    return line[beg..lim];
}

fn compareField(rand: *const Rand, o: Ordering, a: []const u8, b: []const u8) i32 {
    return switch (o.mode) {
        .lex => compareLex(o, a, b),
        .numeric => compareNumeric(a, b),
        .general => compareGeneral(a, b),
        .human => compareHuman(a, b),
        .month => monthOf(a) - monthOf(b),
        .random => compareRandom(rand, o, a, b),
        .version => if (o.fold or o.ignores()) filteredVercmp(o, a, b) else filevercmp(a, b),
    };
}

// -V: gnulib filenvercmp (version comparison that understands file suffixes).
fn vOrder(s: []const u8, pos: usize) i32 {
    if (pos >= s.len) return 0;
    const c = s[pos];
    if (std.ascii.isDigit(c)) return 0;
    if (std.ascii.isAlphabetic(c)) return c;
    if (c == '~') return -1;
    return @as(i32, c) + 256;
}

fn verrevcmp(s1: []const u8, s2: []const u8) i32 {
    var p1: usize = 0;
    var p2: usize = 0;
    while (p1 < s1.len or p2 < s2.len) {
        var first_diff: i32 = 0;
        while ((p1 < s1.len and !std.ascii.isDigit(s1[p1])) or (p2 < s2.len and !std.ascii.isDigit(s2[p2]))) {
            const c1 = vOrder(s1, p1);
            const c2 = vOrder(s2, p2);
            if (c1 != c2) return c1 - c2;
            p1 += 1;
            p2 += 1;
        }
        while (p1 < s1.len and s1[p1] == '0') p1 += 1;
        while (p2 < s2.len and s2[p2] == '0') p2 += 1;
        while (p1 < s1.len and p2 < s2.len and std.ascii.isDigit(s1[p1]) and std.ascii.isDigit(s2[p2])) {
            if (first_diff == 0) first_diff = @as(i32, s1[p1]) - @as(i32, s2[p2]);
            p1 += 1;
            p2 += 1;
        }
        if (p1 < s1.len and std.ascii.isDigit(s1[p1])) return 1;
        if (p2 < s2.len and std.ascii.isDigit(s2[p2])) return -1;
        if (first_diff != 0) return first_diff;
    }
    return 0;
}

fn filePrefixLen(s: []const u8) usize {
    if (s.len == 0) return 0;
    var prefix: usize = 0;
    var i: usize = 0;
    while (true) {
        if (i == s.len) return prefix;
        i += 1;
        prefix = i;
        while (i + 1 < s.len and s[i] == '.' and (std.ascii.isAlphabetic(s[i + 1]) or s[i + 1] == '~')) {
            i += 2;
            while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '~')) i += 1;
        }
    }
}

/// -V with -f/-d/-i: GNU compares copies with ignored characters dropped and
/// letters upper-cased.
fn randomDigest(rand: *const Rand, text: []const u8, out: *[16]u8) void {
    var h = std.crypto.hash.Md5.init(.{});
    h.update(&rand.seed);
    h.update(text);
    if (rand.nul) h.update(&.{0});
    h.final(out);
}

fn compareRandom(rand: *const Rand, o: Ordering, a0: []const u8, b0: []const u8) i32 {
    var a = a0;
    var b = b0;
    if (o.fold or o.ignores()) {
        const gpa = std.heap.page_allocator;
        const ba = gpa.alloc(u8, a.len) catch return 0;
        defer gpa.free(ba);
        const bb = gpa.alloc(u8, b.len) catch return 0;
        defer gpa.free(bb);
        a = filterKey(o, a, ba);
        b = filterKey(o, b, bb);
        var da: [16]u8 = undefined;
        var db: [16]u8 = undefined;
        randomDigest(rand, a, &da);
        randomDigest(rand, b, &db);
        return sign(orderBytes(&da, &db));
    }
    var da: [16]u8 = undefined;
    var db: [16]u8 = undefined;
    randomDigest(rand, a, &da);
    randomDigest(rand, b, &db);
    return sign(orderBytes(&da, &db));
}

fn filteredVercmp(o: Ordering, a: []const u8, b: []const u8) i32 {
    const gpa = std.heap.page_allocator;
    const ca = gpa.alloc(u8, a.len) catch return filevercmp(a, b);
    defer gpa.free(ca);
    const cb = gpa.alloc(u8, b.len) catch return filevercmp(a, b);
    defer gpa.free(cb);
    const fa = filterKey(o, a, ca);
    const fb = filterKey(o, b, cb);
    return filevercmp(fa, fb);
}

fn filterKey(o: Ordering, src: []const u8, dst: []u8) []u8 {
    var n: usize = 0;
    for (src) |c| {
        if (o.ignores() and ignored(o, c)) continue;
        dst[n] = if (o.fold) std.ascii.toUpper(c) else c;
        n += 1;
    }
    return dst[0..n];
}

fn filevercmp(a: []const u8, b: []const u8) i32 {
    if (a.len == 0) return if (b.len == 0) 0 else -1;
    if (b.len == 0) return 1;
    if (a[0] == '.') {
        if (b[0] != '.') return -1;
        const adot = a.len == 1;
        const bdot = b.len == 1;
        if (adot) return if (bdot) 0 else -1;
        if (bdot) return 1;
        const add = a.len == 2 and a[1] == '.';
        const bdd = b.len == 2 and b[1] == '.';
        if (add) return if (bdd) 0 else -1;
        if (bdd) return 1;
    } else if (b[0] == '.') return 1;
    const ap = filePrefixLen(a);
    const bp = filePrefixLen(b);
    const one_pass = ap == a.len and bp == b.len;
    const r = verrevcmp(a[0..ap], b[0..bp]);
    return if (r != 0 or one_pass) r else verrevcmp(a, b);
}

fn ignored(o: Ordering, c: u8) bool {
    if (o.dict) return !(std.ascii.isAlphanumeric(c) or isBlank(c));
    return !(c >= 0x20 and c < 0x7f); // -i: keep printable characters only
}

fn compareLex(o: Ordering, a: []const u8, b: []const u8) i32 {
    if (!o.fold and !o.ignores()) return sign(orderBytes(a, b));
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        if (o.ignores()) {
            while (i < a.len and ignored(o, a[i])) i += 1;
            while (j < b.len and ignored(o, b[j])) j += 1;
        }
        if (!(i < a.len and j < b.len)) break;
        const ca = if (o.fold) std.ascii.toUpper(a[i]) else a[i];
        const cb = if (o.fold) std.ascii.toUpper(b[j]) else b[j];
        if (ca != cb) return if (ca < cb) -1 else 1;
        i += 1;
        j += 1;
    }
    return @as(i32, @intFromBool(i < a.len)) - @as(i32, @intFromBool(j < b.len));
}

// -n: exact decimal comparison without a floating-point conversion.

const Num = struct {
    neg: bool,
    int: []const u8, // integer digits without leading zeros
    frac: []const u8, // fraction digits without trailing zeros

    fn isZero(n: Num) bool {
        return n.int.len == 0 and n.frac.len == 0;
    }
};

/// Leading blanks, optional '-', digits, optional '.' and digits. "-0" and
/// "0" are the same number; no match is zero.
fn parseNum(s: []const u8) Num {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    var st = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    var int = s[st..i];
    while (int.len > 0 and int[0] == '0') int = int[1..];
    var frac: []const u8 = &.{};
    if (i < s.len and s[i] == '.') {
        i += 1;
        st = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        frac = s[st..i];
        while (frac.len > 0 and frac[frac.len - 1] == '0') frac = frac[0 .. frac.len - 1];
    }
    var n: Num = .{ .neg = neg, .int = int, .frac = frac };
    if (n.isZero()) n.neg = false;
    return n;
}

fn compareNum(x: Num, y: Num) i32 {
    if (x.neg != y.neg) return if (x.neg) -1 else 1;
    var d: i32 = 0;
    if (x.int.len != y.int.len) {
        d = if (x.int.len < y.int.len) -1 else 1;
    } else {
        d = sign(orderBytes(x.int, y.int));
        if (d == 0) d = sign(orderBytes(x.frac, y.frac)); // a longer fraction has a nonzero tail
    }
    return if (x.neg) -d else d;
}

fn compareNumeric(a: []const u8, b: []const u8) i32 {
    return compareNum(parseNum(a), parseNum(b));
}

// -h: sign, then SI suffix order, then numeric value.

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

fn unitOrder(c: u8) i32 {
    return switch (c) {
        'k', 'K' => 1,
        'M' => 2,
        'G' => 3,
        'T' => 4,
        'P' => 5,
        'E' => 6,
        'Z' => 7,
        'Y' => 8,
        'R' => 9,
        'Q' => 10,
        else => 0,
    };
}

/// SI suffix order of the number at the start of `s` (which has no leading
/// blanks): the order of the character after the digits, negated for a
/// negative number, and 0 when the number is zero or the unit is unknown.
/// Checked against GNU 9.7 `sort -h`, where "0K" and "x" both count as 0.
fn findUnitOrder(s: []const u8) i32 {
    const minus = at(s, 0) == '-';
    var p: usize = @intFromBool(minus);
    var nonzero = false;
    while (std.ascii.isDigit(at(s, p))) : (p += 1) nonzero = nonzero or s[p] != '0';
    if (at(s, p) == '.') {
        p += 1;
        while (std.ascii.isDigit(at(s, p))) : (p += 1) nonzero = nonzero or s[p] != '0';
    }
    if (!nonzero) return 0;
    const order = unitOrder(at(s, p));
    return if (minus) -order else order;
}

fn compareHuman(a: []const u8, b: []const u8) i32 {
    var i: usize = 0;
    while (i < a.len and isBlank(a[i])) i += 1;
    var j: usize = 0;
    while (j < b.len and isBlank(b[j])) j += 1;
    const ua = findUnitOrder(a[i..]);
    const ub = findUnitOrder(b[j..]);
    if (ua != ub) return if (ua < ub) -1 else 1;
    return compareNum(parseNum(a[i..]), parseNum(b[j..]));
}

// -g: compare as floating point (double here; GNU uses long double).

const General = struct { parsed: bool, value: f64 };

fn isSpaceC(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// strtold-like: the longest valid prefix after optional whitespace.
fn parseGeneral(s: []const u8) General {
    var i: usize = 0;
    while (i < s.len and isSpaceC(s[i])) i += 1;
    const start = i;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    const rest = s[i..];
    if (startsWithNoCase(rest, "infinity")) return .{ .parsed = true, .value = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
    if (startsWithNoCase(rest, "inf")) return .{ .parsed = true, .value = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
    if (startsWithNoCase(rest, "nan")) return .{ .parsed = true, .value = std.math.nan(f64) };
    if (rest.len >= 3 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X') and (std.ascii.isHex(rest[2]) or (rest[2] == '.' and rest.len > 3 and std.ascii.isHex(rest[3])))) {
        var v: f64 = 0;
        var k: usize = 2;
        while (k < rest.len and std.ascii.isHex(rest[k])) : (k += 1) v = v * 16 + @as(f64, @floatFromInt(std.fmt.charToDigit(rest[k], 16) catch 0));
        var scale: f64 = 1;
        if (k < rest.len and rest[k] == '.') {
            k += 1;
            while (k < rest.len and std.ascii.isHex(rest[k])) : (k += 1) {
                scale /= 16;
                v += scale * @as(f64, @floatFromInt(std.fmt.charToDigit(rest[k], 16) catch 0));
            }
        }
        if (k < rest.len and (rest[k] == 'p' or rest[k] == 'P')) {
            var m = k + 1;
            var eneg = false;
            if (m < rest.len and (rest[m] == '+' or rest[m] == '-')) {
                eneg = rest[m] == '-';
                m += 1;
            }
            if (m < rest.len and std.ascii.isDigit(rest[m])) {
                var e: i32 = 0;
                while (m < rest.len and std.ascii.isDigit(rest[m])) : (m += 1) e = @min(e *| 10 +| @as(i32, rest[m] - '0'), 100000);
                v *= std.math.pow(f64, 2, @floatFromInt(if (eneg) -e else e));
            }
        }
        return .{ .parsed = true, .value = if (neg) -v else v };
    }
    // Decimal: digits [. digits] [e [sign] digits], at least one digit.
    var k: usize = 0;
    var digits: usize = 0;
    while (k < rest.len and std.ascii.isDigit(rest[k])) : (k += 1) digits += 1;
    if (k < rest.len and rest[k] == '.') {
        k += 1;
        while (k < rest.len and std.ascii.isDigit(rest[k])) : (k += 1) digits += 1;
    }
    if (digits == 0) return .{ .parsed = false, .value = 0 };
    if (k < rest.len and (rest[k] == 'e' or rest[k] == 'E')) {
        var m = k + 1;
        if (m < rest.len and (rest[m] == '+' or rest[m] == '-')) m += 1;
        if (m < rest.len and std.ascii.isDigit(rest[m])) {
            while (m < rest.len and std.ascii.isDigit(rest[m])) m += 1;
            k = m;
        }
    }
    _ = start;
    const v = std.fmt.parseFloat(f64, rest[0..k]) catch 0;
    return .{ .parsed = true, .value = if (neg) -v else v };
}

fn startsWithNoCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn compareGeneral(a: []const u8, b: []const u8) i32 {
    return compareGen(parseGeneral(a), parseGeneral(b));
}

/// Order-preserving integer for -g keys: numbers by value (-0 equals +0),
/// everything else (conversion failures and NaNs) 0, which is below every
/// number. Ties are settled by compareGen.
fn generalPrefix(g: General) u64 {
    if (!g.parsed or std.math.isNan(g.value)) return 0;
    const raw: u64 = @bitCast(g.value + 0.0); // + 0.0 turns -0 into +0
    return if (raw >> 63 != 0) ~raw else raw | (@as(u64, 1) << 63);
}

fn compareGen(x: General, y: General) i32 {
    // Conversion failures first, then NaNs, then numbers (-0 == +0).
    if (!x.parsed) return if (y.parsed) -1 else 0;
    if (!y.parsed) return 1;
    const xn = std.math.isNan(x.value);
    const yn = std.math.isNan(y.value);
    if (xn or yn) return if (xn and yn) 0 else if (xn) -1 else 1;
    return if (x.value < y.value) -1 else if (x.value > y.value) 1 else 0;
}

// -M: blanks, then a three-letter month abbreviation (case-insensitive).

const months = [_][]const u8{ "APR", "AUG", "DEC", "FEB", "JAN", "JUL", "JUN", "MAR", "MAY", "NOV", "OCT", "SEP" };
const month_numbers = [_]i32{ 4, 8, 12, 2, 1, 7, 6, 3, 5, 11, 10, 9 };

fn monthOf(s: []const u8) i32 {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    if (s.len - i < 3) return 0;
    var up: [3]u8 = undefined;
    for (s[i..][0..3], 0..) |c, n| up[n] = std.ascii.toUpper(c);
    for (months, 0..) |m, n| if (std.mem.eql(u8, m, &up)) return month_numbers[n];
    return 0;
}


// ------------------------------------------------------------------- --debug

fn keyNumeric(o: Ordering) bool {
    return o.mode == .numeric or o.mode == .general or o.mode == .human;
}

/// GNU key_warnings() and the --debug start-up notes (all on stderr, C locale).
pub fn debugNotes(cfg: *const Options, obs: Observer) void {
    obs.emit(.note_simple_byte_comparison);
    const synth = cfg.keys.len > 0 and cfg.keys[0].synthetic;
    for (cfg.keys, 1..) |k, num| {
        if (k.obsolete) {
            var po: [64]u8 = undefined;
            var pn: [64]u8 = undefined;
            const o1 = std.fmt.bufPrint(&po, "+{d}", .{k.obs_s}) catch "";
            const n1 = std.fmt.bufPrint(&pn, "-k {d}", .{k.obs_s + 1}) catch "";
            var ob: [96]u8 = undefined;
            var nb: [96]u8 = undefined;
            var ol: []const u8 = o1;
            var nl: []const u8 = n1;
            if (k.obs_has_e) {
                ol = std.fmt.bufPrint(&ob, "{s} -{d}", .{ o1, k.obs_e }) catch o1;
                nl = std.fmt.bufPrint(&nb, "{s},{d}", .{ n1, k.obs_e }) catch n1;
            }
            obs.emit(.{ .note_obsolescent_key = .{ .old = ol, .new = nl } });
        }
        if (k.synthetic) continue;
        const zero_width = k.eword != no_field and k.eword < k.sword;
        if (zero_width) obs.emit(.{ .note_zero_width = num });
        const o = k.ord;
        const implicit_skip = keyNumeric(o) or o.mode == .month;
        const line_offset = k.eword == 0 and k.echar != 0;
        if (!zero_width and cfg.tab == null and !line_offset and
            ((!o.skip_sblanks and !implicit_skip) or (!o.skip_sblanks and k.schar != 0) or (!o.skip_eblanks and k.echar != 0)))
            obs.emit(.{ .note_leading_blanks = num });
        if (keyNumeric(o) and (k.eword == no_field or k.eword > k.sword))
            obs.emit(.{ .note_numeric_multi_field = num });
    }
    var numeric = keyNumeric(cfg.gkey) and cfg.keys.len == 0;
    for (cfg.keys) |k| numeric = numeric or keyNumeric(k.ord);
    if (numeric) obs.emit(.note_decimal_point);
    // Global ordering options that no key picked up.
    if (!synth and cfg.keys.len > 0) {
        const g = cfg.gkey;
        var used: Ordering = .{};
        var any_rev = false;
        for (cfg.keys) |k| {
            const o = k.ord;
            used.skip_sblanks = used.skip_sblanks or o.skip_sblanks or o.skip_eblanks;
            used.dict = used.dict or o.dict;
            used.fold = used.fold or o.fold;
            used.nonprint = used.nonprint or o.nonprint;
            used.mode_mask |= o.mode_mask;
            any_rev = any_rev or o.reverse;
        }
        var letters: [12]u8 = undefined;
        var n: usize = 0;
        const rev_unused = g.reverse and !any_rev;
        const stable_like = cfg.stable or cfg.unique;
        const checks = [_]struct { c: u8, set: bool }{
            .{ .c = 'b', .set = (g.skip_sblanks or g.skip_eblanks) and !used.skip_sblanks },
            .{ .c = 'd', .set = g.dict and !used.dict },
            .{ .c = 'f', .set = g.fold and !used.fold },
            .{ .c = 'g', .set = g.mode_mask & 1 != 0 and used.mode_mask & 1 == 0 },
            .{ .c = 'h', .set = g.mode_mask & 2 != 0 and used.mode_mask & 2 == 0 },
            .{ .c = 'i', .set = g.nonprint and !g.dict and !used.nonprint },
            .{ .c = 'M', .set = g.mode_mask & 4 != 0 and used.mode_mask & 4 == 0 },
            .{ .c = 'n', .set = g.mode_mask & 8 != 0 and used.mode_mask & 8 == 0 },
            .{ .c = 'R', .set = g.mode_mask & 32 != 0 and used.mode_mask & 32 == 0 },
            .{ .c = 'r', .set = rev_unused and stable_like },
            .{ .c = 'V', .set = g.mode_mask & 16 != 0 and used.mode_mask & 16 == 0 },
        };
        for (checks) |c| if (c.set) {
            letters[n] = c.c;
            n += 1;
        };
        if (n == 1) {
            obs.emit(.{ .note_options_ignored = letters[0..n] });
        } else if (n > 1) obs.emit(.{ .note_options_ignored = letters[0..n] });
        if (rev_unused and !stable_like) obs.emit(.note_r_last_resort);
    }
}

/// Columns a byte range takes in the C locale: tabs are shown as '>', other
/// control bytes take no room.
fn debugWidth(text: []const u8) usize {
    var w: usize = 0;
    for (text) |c| {
        if (c == '\t' or !(c < 0x20 or c == 0x7f)) w += 1;
    }
    return w;
}

/// Length of the longest prefix of `s` that strtold() would accept as a number.
fn strtoldLen(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= 9 and s[i] <= 13))) i += 1;
    const start = i;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const rest = s[i..];
    if (std.ascii.startsWithIgnoreCase(rest, "infinity")) return i + 8;
    if (std.ascii.startsWithIgnoreCase(rest, "inf")) return i + 3;
    if (std.ascii.startsWithIgnoreCase(rest, "nan")) {
        var j = i + 3;
        if (j < s.len and s[j] == '(') {
            var k = j + 1;
            while (k < s.len and (std.ascii.isAlphanumeric(s[k]) or s[k] == '_')) k += 1;
            if (k < s.len and s[k] == ')') j = k + 1;
        }
        return j;
    }
    var hex = false;
    if (rest.len >= 2 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X')) {
        // Needs at least one hex digit (possibly after the point); otherwise only the "0" counts.
        var j = i + 2;
        var digits = false;
        while (j < s.len and std.ascii.isHex(s[j])) : (j += 1) digits = true;
        if (j < s.len and s[j] == '.') {
            j += 1;
            while (j < s.len and std.ascii.isHex(s[j])) : (j += 1) digits = true;
        }
        if (digits) {
            hex = true;
            i = j;
        }
    }
    if (!hex) {
        var digits = false;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits = true;
        if (i < s.len and s[i] == '.') {
            i += 1;
            while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits = true;
        }
        if (!digits) return 0;
    }
    if (i < s.len and ((!hex and (s[i] == 'e' or s[i] == 'E')) or (hex and (s[i] == 'p' or s[i] == 'P')))) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and std.ascii.isDigit(s[j])) {
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            i = j;
        }
    }
    _ = start;
    return i;
}

/// One underline row for key `k` (null = the whole line).
fn debugMark(out: *wsink.Sink, cfg: *const Options, line: []const u8, key: ?Key) void {
    var beg: usize = 0;
    var lim: usize = line.len;
    if (key) |k| {
        beg = begField(line, k, cfg.tab);
        lim = limField(line, k, cfg.tab);
        const o = k.ord;
        if ((o.skip_sblanks and k.synthetic) or o.mode == .month or keyNumeric(o)) {
            const end = @max(beg, @min(lim, line.len));
            while (beg < end and isBlank(line[beg])) beg += 1;
            var tight = beg;
            if (lim < beg) {
                tight = lim;
            } else if (o.mode == .month) {
                if (monthOf(line[beg..lim]) != 0 and lim - beg >= 3) tight = beg + 3;
            } else if (o.mode == .general) {
                tight = beg + strtoldLen(line[beg..lim]);
            } else if (o.mode == .numeric or o.mode == .human) {
                var p = beg;
                if (p < lim and line[p] == '-') p += 1;
                var found = false;
                while (p < lim and std.ascii.isDigit(line[p])) : (p += 1) found = true;
                if (p < lim and line[p] == '.') {
                    p += 1;
                    while (p < lim and std.ascii.isDigit(line[p])) : (p += 1) found = true;
                }
                if (found) {
                    tight = p;
                    if (o.mode == .human and p < lim and std.mem.indexOfScalar(u8, "kKMGTPEZYRQ", line[p]) != null) tight = p + 1;
                }
            } else tight = lim;
            lim = tight;
        }
    }
    const offset = debugWidth(line[0..@min(beg, line.len)]);
    const width = if (lim > beg) debugWidth(line[beg..@min(lim, line.len)]) else 0;
    var i: usize = 0;
    while (i < offset) : (i += 1) out.writeByte(' ');
    if (width == 0) {
        out.write("^ no match for key\n");
    } else {
        i = 0;
        while (i < width) : (i += 1) out.writeByte('_');
        out.writeByte('\n');
    }
}

/// Write one output record. With --debug the text is followed by the key
/// underlines (GNU write_line + debug_line).
fn emitRecord(out: *wsink.Sink, cfg: *const Options, text: []const u8) void {
    if (!cfg.debug) {
        out.write(text);
        out.writeByte(cfg.term);
        return;
    }
    for (text) |c| out.writeByte(if (c == '\t') '>' else c);
    out.writeByte('\n');
    if (cfg.keys.len == 0) {
        debugMark(out, cfg, text, null);
        return;
    }
    for (cfg.keys) |k| debugMark(out, cfg, text, k);
    if (!cfg.stable and !cfg.unique) debugMark(out, cfg, text, null);
}

// -------------------------------------------------------- check and merge

/// Open an input; a directory is reported by the caller as a read failure
/// (GNU opens it and fails on read).
fn openInput(env: Env, obs: Observer, name: []const u8, checking: bool) ?Io.File {
    return openName(env.io, name) catch |e| {
        obs.emit(.{ .open_failed = .{ .name = name, .err = e, .checking = checking } });
        return null;
    };
}

/// -c / -C: compare each line with the previous one; stops at the first
/// disorder (or duplicate with -u). Memory is one line, not the file.
fn checkStream(env: Env, obs: Observer, s: *const Sorter, cfg: *const Options, name: []const u8) u8 {
    const file = openInput(env, obs, name, true) orelse return fail_status;
    defer closeName(env.io, file);
    var reader = linereader.LineReader.init(env.gpa, env.io, file, cfg.term);
    defer reader.deinit();
    var prev: std.ArrayList(u8) = .empty;
    defer prev.deinit(env.gpa);
    var n: usize = 0;
    while (true) {
        const line = (reader.next() catch |e| {
            obs.emit(.{ .read_failed = .{ .name = name, .err = e } });
            return fail_status;
        }) orelse return 0;
        n += 1;
        if (n > 1) {
            const d = s.compare(prev.items, line.text);
            if (d > 0 or (cfg.unique and d == 0)) {
                if (cfg.check == .diagnose) {
                    obs.emit(.{ .disorder = .{ .name = name, .line = n, .text = line.text, .term = cfg.term } });
                }
                return 1;
            }
        }
        prev.clearRetainingCapacity();
        prev.appendSlice(env.gpa, line.text) catch {
            obs.emit(.out_of_memory);
            return fail_status;
        };
    }
}

/// Streaming merge opens every input at once, so it is used for a modest
/// number of inputs and only when standard input is not named twice (two
/// readers on one descriptor would split its lines between them).
fn mergeStreamable(names: []const []const u8) bool {
    if (names.len > 128) return false;
    var stdin_count: usize = 0;
    for (names) |n| stdin_count += @intFromBool(std.mem.eql(u8, n, "-"));
    return stdin_count <= 1;
}

/// -m on standard output: keep one pending line per input and repeatedly emit
/// the smallest, earlier inputs winning ties. Same order as mergeRuns.
fn mergeStream(env: Env, obs: Observer, out_w: *Io.Writer, s: *const Sorter, cfg: *const Options, names: []const []const u8) u8 {
    const k = names.len;
    const gpa = env.gpa;
    const files = gpa.alloc(Io.File, k) catch return oomStatus(obs);
    defer gpa.free(files);
    const readers = gpa.alloc(linereader.LineReader, k) catch return oomStatus(obs);
    defer gpa.free(readers);
    const heads = gpa.alloc(std.ArrayList(u8), k) catch return oomStatus(obs);
    defer gpa.free(heads);
    const alive = gpa.alloc(bool, k) catch return oomStatus(obs);
    defer gpa.free(alive);

    var opened: usize = 0; // inputs whose file, reader and head are initialised
    defer for (0..opened) |i| {
        readers[i].deinit();
        heads[i].deinit(gpa);
        closeName(env.io, files[i]);
    };
    for (names, 0..) |name, i| {
        files[i] = openInput(env, obs, name, false) orelse return fail_status;
        readers[i] = linereader.LineReader.init(gpa, env.io, files[i], cfg.term);
        heads[i] = .empty;
        alive[i] = false;
        opened += 1;
    }
    for (0..k) |i| if (!advance(env, obs, readers, heads, alive, names, i)) return fail_status;

    var out = wsink.Sink.initWriter(out_w);
    var prev: std.ArrayList(u8) = .empty;
    defer prev.deinit(gpa);
    var have_prev = false;
    while (true) {
        var best: ?usize = null;
        for (0..k) |r| {
            if (!alive[r]) continue;
            if (best == null or s.compare(heads[r].items, heads[best.?].items) < 0) best = r;
        }
        const b = best orelse break;
        const text = heads[b].items;
        if (!(cfg.unique and have_prev and s.compare(prev.items, text) == 0)) {
            emitRecord(&out, cfg, text);
            if (out.failed) break;
            if (cfg.unique) {
                prev.clearRetainingCapacity();
                prev.appendSlice(gpa, text) catch return oomStatus(obs);
                have_prev = true;
            }
        }
        if (!advance(env, obs, readers, heads, alive, names, b)) return fail_status;
    }
    out.flush();
    if (out.failed) {
        obs.emit(.{ .write_failed = .{ .output = null, .streaming = true } });
        return fail_status;
    }
    return 0;
}

fn oomStatus(obs: Observer) u8 {
    obs.emit(.out_of_memory);
    return fail_status;
}

/// Load the next line of input `i` into its head slot.
fn advance(env: Env, obs: Observer, readers: []linereader.LineReader, heads: []std.ArrayList(u8), alive: []bool, names: []const []const u8, i: usize) bool {
    const line = (readers[i].next() catch |e| {
        obs.emit(.{ .read_failed = .{ .name = names[i], .err = e } });
        return false;
    }) orelse {
        alive[i] = false;
        return true;
    };
    heads[i].clearRetainingCapacity();
    heads[i].appendSlice(env.gpa, line.text) catch {
        obs.emit(.out_of_memory);
        return false;
    };
    alive[i] = true;
    return true;
}

/// k-way merge of the already-sorted runs found at `starts[i]..starts[i+1]`
/// of `lines`, in place (the result replaces `lines`). Ties go to the earlier
/// input, as in a stable merge.
fn mergeRuns(gpa: std.mem.Allocator, s: *const Sorter, lines: [][]const u8, starts: []const usize) !void {
    const runs = starts.len - 1;
    if (runs <= 1) return;
    const pos = try gpa.alloc(usize, runs);
    defer gpa.free(pos);
    for (pos, 0..) |*p, r| p.* = starts[r];
    const merged = try gpa.alloc([]const u8, lines.len);
    defer gpa.free(merged);
    var n: usize = 0;
    while (n < merged.len) : (n += 1) {
        var best: ?usize = null;
        for (0..runs) |r| {
            if (pos[r] >= starts[r + 1]) continue;
            if (best == null or s.compare(lines[pos[r]], lines[pos[best.?]]) < 0) best = r;
        }
        merged[n] = lines[pos[best.?]];
        pos[best.?] += 1;
    }
    @memcpy(lines, merged);
}

test "begField and limField follow GNU for blank-separated fields" {
    const t = std.testing;
    const k: Key = .{ .sword = 1, .eword = 1 };
    try t.expectEqualStrings(" bb", field("a bb c", k, null));
    const k2: Key = .{ .sword = 1, .schar = 1, .eword = 1, .echar = 2 };
    try t.expectEqualStrings("b", field("a bb c", k2, null));
    try t.expectEqualStrings("bb", field("a:bb:c", .{ .sword = 1, .eword = 1 }, ':'));
    try t.expectEqualStrings("", field("a", .{ .sword = 3 }, null));
}

test "numeric comparison is exact" {
    const t = std.testing;
    try t.expectEqual(@as(i32, -1), compareNumeric("9", "10"));
    try t.expectEqual(@as(i32, 0), compareNumeric("-0", "0.000"));
    try t.expectEqual(@as(i32, -1), compareNumeric("-2", "-1"));
    try t.expectEqual(@as(i32, 1), compareNumeric("1.0000000000000000000001", "1"));
    try t.expectEqual(@as(i32, 0), compareNumeric("abc", ""));
    try t.expectEqual(@as(i32, -1), compareNumeric("-5", "abc"));
}

test "month names" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 1), monthOf("  jan"));
    try t.expectEqual(@as(i32, 12), monthOf("Decx"));
    try t.expectEqual(@as(i32, 0), monthOf("ja"));
}

test "orderBytes agrees with std.mem.order" {
    const t = std.testing;
    const cases = [_][2][]const u8{
        .{ "", "" },                 .{ "a", "" },                              .{ "abc", "abd" },
        .{ "abcdefgh", "abcdefgi" }, .{ "abcdefgh", "abcdefgh1" },              .{ "abcdefghij", "abcdefghik" },
        .{ "\xff\x00", "\x00\xff" }, .{ "same bytes here", "same bytes here" }, .{ "0123456789abcdef", "0123456789abcdeg" },
    };
    for (cases) |c| {
        try t.expectEqual(std.mem.order(u8, c[0], c[1]), orderBytes(c[0], c[1]));
        try t.expectEqual(std.mem.order(u8, c[1], c[0]), orderBytes(c[1], c[0]));
    }
}

test "numericPrefix orders like compareNum for exact numbers" {
    const t = std.testing;
    const nums = [_][]const u8{ "-1000", "-1.5", "-0.1", "0", "0.000000000000001", "0.1", "0.10", "1", "1.5", "999999999999999", "123456789012345", "1e5" };
    for (nums) |x| for (nums) |y| {
        const px = numericPrefix(parseNum(x));
        const py = numericPrefix(parseNum(y));
        if (!px.exact or !py.exact) continue;
        const want = compareNumeric(x, y);
        const got: i32 = if (px.bits < py.bits) -1 else if (px.bits > py.bits) 1 else 0;
        try t.expectEqual(want, got);
    };
    try t.expect(!numericPrefix(parseNum("1234567890123456")).exact);
}
