//! sort — sort, merge, or check lines of text.
//! References: GNU coreutils manual "sort invocation" (9.7); POSIX.1-2024 sort.
//!
//! Scope of this implementation (see docs/compatibility/sort.md):
//!   * modes: sort, -m merge, -c/-C check; -o, -u, -s, -z, --files0-from;
//!   * keys: -k F[.C][OPTS][,F[.C][OPTS]], -t, -b, global options inherited by
//!     keys that carry no ordering letters of their own;
//!   * orderings: lexicographic (-d -f -i), -n, -g, -h, -M, -V, -R, -r.
//!   * NOT implemented: --debug (rejected with exit status 2). -S -T --parallel --batch-size --compress-program
//!     are validated and then ignored: all input is held in memory.
//!
//! Design: every input is read into one byte buffer; the lines are slices of
//! it; a stable merge sort (std.sort.block) orders the slice array. Keys are
//! located on every comparison, like GNU, rather than precomputed. Bytes are
//! compared as unsigned values (C locale); LC_COLLATE/LC_CTYPE/LC_NUMERIC are
//! not consulted. "Blank" for field splitting is space, tab or newline
//! (GNU's field_sep(), so -z records containing newlines split sensibly).

const std = @import("std");
const cli = @import("../cli.zig");
const linereader = @import("../lines.zig");
const Io = std.Io;

const no_field = std.math.maxInt(usize);

const Mode = enum { lex, numeric, general, human, month, version, random };

/// -R: 16 bytes drawn from --random-source (or the system RNG), prepended to every key before hashing.
var random_seed: [16]u8 = @splat(0);
/// GNU hashes the strxfrm form (NUL-terminated) when the collation locale is not C/POSIX.
var random_nul: bool = false;

/// Ordering options of one key, or of the whole command line ("global").
const Ordering = struct {
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
    fn isPlain(o: Ordering) bool {
        return o.mode == .lex and !o.fold and !o.dict and !o.nonprint and !o.reverse and !o.skip_sblanks and !o.skip_eblanks;
    }
    /// GNU default_key_compare(): nothing but (maybe) -r is set.
    fn isPlainExceptReverse(o: Ordering) bool {
        var c = o;
        c.reverse = false;
        return c.isPlain();
    }
    fn ignores(o: Ordering) bool {
        return o.dict or o.nonprint;
    }
};

const Key = struct {
    sword: usize = 0, // 0-based first field
    schar: usize = 0, // 0-based first character within it
    eword: usize = no_field, // 0-based last field; no_field = end of line
    echar: usize = 0, // 1-based last character; 0 = end of field
    ord: Ordering = .{},
};

const Config = struct {
    gkey: Ordering = .{},
    keys: std.ArrayList(Key) = .empty,
    tab: ?u8 = null,
    unique: bool = false,
    stable: bool = false,
    merge: bool = false,
    check: enum { none, diagnose, quiet } = .none,
    term: u8 = '\n',
    output: ?[]const u8 = null,
    random_source: ?[]const u8 = null,
    files0_from: ?[]const u8 = null,
};

const long_names = [_][]const u8{
    "ignore-leading-blanks", "dictionary-order", "ignore-case", "general-numeric-sort", "ignore-nonprinting", //  0-4
    "month-sort", "human-numeric-sort", "numeric-sort", "random-sort", "reverse", //  5-9
    "sort", "version-sort", "random-source", "batch-size", "check", //  10-14
    "compress-program", "debug", "files0-from", "key", "merge", //  15-19
    "output", "stable", "buffer-size", "field-separator", "temporary-directory", //  20-24
    "parallel", "unique", "zero-terminated", "help", "version", //  25-29
};

/// Short options that take an argument.
fn takesArg(c: u8) bool {
    return switch (c) {
        'k', 't', 'o', 'S', 'T' => true,
        else => false,
    };
}

const fail_status: u8 = 2;

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    defer cfg.keys.deinit(ctx.gpa);
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    var tab_given = false;

    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return fail_status;
                },
            };
            // Options that take a value (required unless noted).
            const needs_value = switch (k) {
                10, 12, 13, 15, 17, 18, 20, 22, 23, 24, 25 => true,
                else => false,
            };
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (needs_value and value == null) {
                i += 1;
                if (i >= args.len) {
                    cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                    return fail_status;
                }
                value = args[i];
            } else if (!needs_value and k != 14 and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return fail_status;
            }
            switch (k) {
                0 => setLetter(&cfg.gkey, 'b', .both),
                1 => setLetter(&cfg.gkey, 'd', .both),
                2 => setLetter(&cfg.gkey, 'f', .both),
                3 => setLetter(&cfg.gkey, 'g', .both),
                4 => setLetter(&cfg.gkey, 'i', .both),
                5 => setLetter(&cfg.gkey, 'M', .both),
                6 => setLetter(&cfg.gkey, 'h', .both),
                7 => setLetter(&cfg.gkey, 'n', .both),
                8 => setLetter(&cfg.gkey, 'R', .both),
                9 => cfg.gkey.reverse = true,
                10 => {
                    const w = value.?;
                    const names = [_][]const u8{ "general-numeric", "human-numeric", "month", "numeric", "random", "version" };
                    const letters = "ghMnRV";
                    var found: ?usize = null;
                    var ambiguous = false;
                    for (names, 0..) |n, idx| {
                        if (std.mem.eql(u8, n, w)) {
                            found = idx;
                            ambiguous = false;
                            break;
                        }
                        if (w.len > 0 and std.mem.startsWith(u8, n, w)) {
                            if (found != null) ambiguous = true;
                            found = idx;
                        }
                    }
                    if (found == null or ambiguous) {
                        cli.warn(ctx, "{s} argument '{s}' for '--sort'\nValid arguments are:\n  - 'general-numeric'\n  - 'human-numeric'\n  - 'month'\n  - 'numeric'\n  - 'random'\n  - 'version'\nTry '{s} --help' for more information.", .{ if (found == null) "invalid" else "ambiguous", w, ctx.name });
                        return 1;
                    }
                    setLetter(&cfg.gkey, letters[found.?], .both);
                },
                11 => setLetter(&cfg.gkey, 'V', .both),
                12 => {
                    if (cfg.random_source) |prev| {
                        if (!std.mem.eql(u8, prev, value.?)) {
                            cli.warn(ctx, "multiple random sources specified", .{});
                            return fail_status;
                        }
                    }
                    cfg.random_source = value.?;
                },
                13 => {
                    if (!validBatchSize(ctx, value.?)) return fail_status;
                },
                14 => {
                    const v = value orelse "diagnose-first";
                    if (std.mem.eql(u8, v, "diagnose-first")) {
                        cfg.check = .diagnose;
                    } else if (std.mem.eql(u8, v, "quiet") or std.mem.eql(u8, v, "silent")) {
                        cfg.check = .quiet;
                    } else {
                        cli.warn(ctx, "invalid argument '{s}' for '--check'\nValid arguments are:\n  - 'quiet', 'silent'\n  - 'diagnose-first'\nTry '{s} --help' for more information.", .{ v, ctx.name });
                        return 1;
                    }
                },
                15 => {}, // --compress-program: temporaries are never written
                16 => return unsupported(ctx, "--debug"),
                17 => cfg.files0_from = value.?,
                18 => {
                    if (!addKey(ctx, &cfg, value.?)) return fail_status;
                },
                19 => cfg.merge = true,
                20 => cfg.output = value.?,
                21 => cfg.stable = true,
                22 => {
                    if (!validBufferSize(ctx, value.?)) return fail_status;
                },
                23 => {
                    if (!setTab(ctx, &cfg, &tab_given, value.?)) return fail_status;
                },
                24 => {}, // --temporary-directory
                25 => {
                    if (!validParallel(ctx, value.?)) return fail_status;
                },
                26 => cfg.unique = true,
                27 => cfg.term = 0,
                28 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            if (takesArg(c)) {
                var value: []const u8 = a[j + 1 ..];
                if (value.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
                        return fail_status;
                    }
                    value = args[i];
                }
                switch (c) {
                    'k' => if (!addKey(ctx, &cfg, value)) return fail_status,
                    't' => if (!setTab(ctx, &cfg, &tab_given, value)) return fail_status,
                    'o' => cfg.output = value,
                    'S' => if (!validBufferSize(ctx, value)) return fail_status,
                    else => {}, // -T
                }
                break;
            }
            switch (c) {
                'b', 'd', 'f', 'g', 'h', 'i', 'M', 'n' => setLetter(&cfg.gkey, c, .both),
                'r' => cfg.gkey.reverse = true,
                'R' => setLetter(&cfg.gkey, 'R', .both),
                'V' => setLetter(&cfg.gkey, 'V', .both),
                'c' => cfg.check = .diagnose,
                'C' => cfg.check = .quiet,
                'm' => cfg.merge = true,
                's' => cfg.stable = true,
                'u' => cfg.unique = true,
                'z' => cfg.term = 0,
                else => {
                    cli.invalidShort(ctx, c);
                    return fail_status;
                },
            }
        }
    }

    if (!finishKeys(ctx, &cfg)) return fail_status;
    if (usesRandom(&cfg)) if (!seedRandom(ctx, cfg.random_source)) return fail_status;

    // Input names.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    var names0: []u8 = &.{}; // storage for --files0-from names
    defer ctx.gpa.free(names0);
    if (cfg.files0_from) |list| {
        if (operands.items.len > 0) {
            cli.warn(ctx, "extra operand '{s}'\nfile operands cannot be combined with --files0-from\nTry '{s} --help' for more information.", .{ operands.items[0], ctx.name });
            return fail_status;
        }
        names0 = readAll(ctx, list) orelse return fail_status;
        var it = std.mem.splitScalar(u8, names0, 0);
        var count: usize = 0;
        while (it.next()) |n| {
            if (n.len == 0) {
                if (it.peek() == null) break; // trailing NUL terminates the last name
                cli.warn(ctx, "{s}:{d}: invalid zero-length file name", .{ list, count + 1 });
                return fail_status;
            }
            count += 1;
            names.append(ctx.gpa, n) catch return oom(ctx);
        }
        if (names.items.len == 0) {
            cli.warn(ctx, "no input from '{s}'", .{list});
            return fail_status;
        }
    } else {
        names.appendSlice(ctx.gpa, operands.items) catch return oom(ctx);
        if (names.items.len == 0) names.append(ctx.gpa, "-") catch return oom(ctx);
    }

    if (cfg.check != .none and names.items.len > 1) {
        cli.warn(ctx, "extra operand '{s}' not allowed with -{c}", .{ names.items[1], @as(u8, if (cfg.check == .quiet) 'C' else 'c') });
        return fail_status;
    }

    const sorter = Sorter.init(&cfg);

    // -c and -m can work one line at a time; only sorting needs the whole input.
    if (cfg.check != .none) return checkStream(ctx, &sorter, &cfg, names.items[0]);
    if (cfg.merge and cfg.output == null and mergeStreamable(names.items)) return mergeStream(ctx, &sorter, &cfg, names.items);

    // Read everything before touching the output file, so `sort -o f f` works.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    var ends: std.ArrayList(usize) = .empty; // buf offset where each input ends
    defer ends.deinit(ctx.gpa);
    for (names.items) |n| {
        readInto(ctx, &buf, n, cfg.term) catch |e| switch (e) {
            error.Reported => return fail_status,
            error.OutOfMemory => return oom(ctx),
        };
        ends.append(ctx.gpa, buf.items.len) catch return oom(ctx);
    }

    var all_lines: std.ArrayList([]const u8) = .empty;
    defer all_lines.deinit(ctx.gpa);
    var run_starts: std.ArrayList(usize) = .empty; // index into all_lines where each input starts
    defer run_starts.deinit(ctx.gpa);
    {
        var pos: usize = 0;
        for (ends.items) |end| {
            run_starts.append(ctx.gpa, all_lines.items.len) catch return oom(ctx);
            while (pos < end) {
                const stop = std.mem.indexOfScalarPos(u8, buf.items[0..end], pos, cfg.term) orelse end;
                all_lines.append(ctx.gpa, buf.items[pos..stop]) catch return oom(ctx);
                pos = stop + 1;
            }
        }
        run_starts.append(ctx.gpa, all_lines.items.len) catch return oom(ctx);
    }

    if (cfg.merge) {
        mergeRuns(ctx, &sorter, all_lines.items, run_starts.items) catch return oom(ctx);
    } else {
        sortLines(ctx, &sorter, all_lines.items) catch return oom(ctx);
    }

    // Output.
    var out_file: ?Io.File = null;
    if (cfg.output) |path| {
        out_file = Io.Dir.cwd().createFile(ctx.io, path, .{}) catch |e| {
            cli.warn(ctx, "open failed: {s}: {s}", .{ path, cli.errText(e) });
            return fail_status;
        };
    }
    defer if (out_file) |f| f.close(ctx.io);
    var out = if (out_file) |f| cli.Out.initFile(ctx.io, f) else cli.Out.init(ctx.io);
    var prev: ?[]const u8 = null;
    for (all_lines.items) |line| {
        if (cfg.unique) {
            if (prev) |p| if (sorter.compare(p, line) == 0) continue;
            prev = line;
        }
        out.write(line);
        out.writeByte(cfg.term);
        if (out.failed) break;
    }
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write failed: '{s}'", .{cfg.output orelse "standard output"});
        return fail_status;
    }
    return 0;
}

// ---------------------------------------------------------------- options

const Where = enum { start, end, both };

fn setLetter(o: *Ordering, c: u8, where: Where) void {
    switch (c) {
        'b' => {
            if (where != .end) o.skip_sblanks = true;
            if (where != .start) o.skip_eblanks = true;
        },
        'd' => o.dict = true,
        'f' => o.fold = true,
        'g' => {
            o.mode = .general;
            o.mode_mask |= 1;
        },
        'h' => {
            o.mode = .human;
            o.mode_mask |= 2;
        },
        'i' => o.nonprint = true,
        'M' => {
            o.mode = .month;
            o.mode_mask |= 4;
        },
        'n' => {
            o.mode = .numeric;
            o.mode_mask |= 8;
        },
        'R' => {
            o.mode = .random;
            o.mode_mask |= 32;
        },
        'V' => {
            if (o.mode != .random) o.mode = .version;
            o.mode_mask |= 16;
        },
        'r' => o.reverse = true,
        else => unreachable,
    }
}

fn usesRandom(cfg: *const Config) bool {
    if (cfg.gkey.mode == .random) return true;
    for (cfg.keys.items) |k| if (k.ord.mode == .random) return true;
    return false;
}

fn seedRandom(ctx: cli.Context, source: ?[]const u8) bool {
    random_nul = false;
    for ([_][]const u8{ "LC_ALL", "LC_COLLATE", "LANG" }) |v| {
        if (cli.getenv(ctx, v)) |val| {
            if (val.len == 0) continue;
            random_nul = !(std.mem.eql(u8, val, "C") or std.mem.eql(u8, val, "POSIX"));
            break;
        }
    }
    const path = source orelse {
        ctx.io.random(&random_seed);
        return true;
    };
    const file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |e| {
        cli.warn(ctx, "open failed: {s}: {s}", .{ path, cli.errText(e) });
        return false;
    };
    defer file.close(ctx.io);
    var got: usize = 0;
    while (got < random_seed.len) {
        const n = file.readStreaming(ctx.io, &.{random_seed[got..]}) catch |e| {
            if (e == error.EndOfStream) {
                cli.warn(ctx, "{f}: end of file", .{cli.quoteA(path)});
            } else cli.warn(ctx, "read failed: {s}: {s}", .{ path, cli.errText(e) });
            return false;
        };
        if (n == 0) {
            cli.warn(ctx, "{f}: end of file", .{cli.quoteA(path)});
            return false;
        }
        got += n;
    }
    return true;
}

fn unsupported(ctx: cli.Context, what: []const u8) u8 {
    cli.warn(ctx, "{s} is not implemented in this build", .{what});
    return fail_status;
}

fn setTab(ctx: cli.Context, cfg: *Config, given: *bool, arg: []const u8) bool {
    var t: u8 = undefined;
    if (arg.len == 1) {
        t = arg[0];
    } else if (std.mem.eql(u8, arg, "\\0")) {
        t = 0;
    } else {
        if (arg.len == 0) {
            cli.warn(ctx, "empty tab", .{});
        } else {
            cli.warn(ctx, "multi-character tab '{s}'", .{arg});
        }
        return false;
    }
    if (given.* and cfg.tab.? != t) {
        cli.warn(ctx, "incompatible tabs", .{});
        return false;
    }
    cfg.tab = t;
    given.* = true;
    return true;
}

fn validParallel(ctx: cli.Context, arg: []const u8) bool {
    const n = std.fmt.parseInt(usize, arg, 10) catch {
        cli.warn(ctx, "invalid --parallel argument '{s}'", .{arg});
        return false;
    };
    if (n == 0) {
        cli.warn(ctx, "number in parallel must be nonzero", .{});
        return false;
    }
    return true;
}

fn validBatchSize(ctx: cli.Context, arg: []const u8) bool {
    const n = std.fmt.parseInt(usize, arg, 10) catch {
        cli.warn(ctx, "invalid --batch-size argument '{s}'", .{arg});
        return false;
    };
    if (n < 2) {
        cli.warn(ctx, "invalid --batch-size argument '{s}'", .{arg});
        cli.warn(ctx, "minimum --batch-size argument is '2'", .{});
        return false;
    }
    return true;
}

/// SIZE is digits followed by one optional suffix; only validated, since the
/// whole input is held in memory regardless.
fn validBufferSize(ctx: cli.Context, arg: []const u8) bool {
    var end: usize = 0;
    while (end < arg.len and std.ascii.isDigit(arg[end])) end += 1;
    const suffix = arg[end..];
    const ok = end > 0 and (suffix.len == 0 or (suffix.len == 1 and std.mem.indexOfScalar(u8, "%bKkMmGTPEZYRQ", suffix[0]) != null));
    if (!ok) {
        cli.warn(ctx, "invalid -S argument '{s}'", .{arg});
        return false;
    }
    return true;
}

fn badSpec(ctx: cli.Context, why: []const u8, spec: []const u8) bool {
    cli.warn(ctx, "{s}: invalid field specification '{s}'", .{ why, spec });
    return false;
}

/// Parse a decimal count at `s`; on success advances `s`. Overflow saturates
/// (GNU: SIZE_MAX), so absurdly large field numbers just select nothing.
fn parseCount(ctx: cli.Context, s: *[]const u8, msg: []const u8) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s.*[i])) : (i += 1) n = n *| 10 +| (s.*[i] - '0');
    if (i == 0) {
        cli.warn(ctx, "{s}: invalid count at start of '{s}'", .{ msg, s.* });
        return null;
    }
    s.* = s.*[i..];
    return n;
}

fn parseLetters(s: *[]const u8, o: *Ordering, where: Where) void {
    while (s.len > 0 and std.mem.indexOfScalar(u8, "bdfghiMnrRV", s.*[0]) != null) {
        setLetter(o, s.*[0], where);
        s.* = s.*[1..];
    }
}

fn addKey(ctx: cli.Context, cfg: *Config, spec: []const u8) bool {
    var key: Key = .{};
    var s = spec;
    const sword = parseCount(ctx, &s, "invalid number at field start") orelse return false;
    if (sword == 0) return badSpec(ctx, "field number is zero", spec);
    key.sword = sword - 1;
    if (s.len > 0 and s[0] == '.') {
        s = s[1..];
        const schar = parseCount(ctx, &s, "invalid number after '.'") orelse return false;
        if (schar == 0) return badSpec(ctx, "character offset is zero", spec);
        key.schar = schar - 1;
    }
    parseLetters(&s, &key.ord, .start);
    if (s.len > 0 and s[0] == ',') {
        s = s[1..];
        const eword = parseCount(ctx, &s, "invalid number after ','") orelse return false;
        if (eword == 0) return badSpec(ctx, "field number is zero", spec);
        key.eword = eword - 1;
        if (s.len > 0 and s[0] == '.') {
            s = s[1..];
            key.echar = parseCount(ctx, &s, "invalid number after '.'") orelse return false;
        }
        parseLetters(&s, &key.ord, .end);
    }
    if (s.len > 0) return badSpec(ctx, "stray character in field spec", spec);
    cfg.keys.append(ctx.gpa, key) catch {
        cli.warn(ctx, "out of memory", .{});
        return false;
    };
    return true;
}

/// Apply inheritance of global options and the compatibility checks that GNU
/// performs after option parsing.
fn finishKeys(ctx: cli.Context, cfg: *Config) bool {
    for (cfg.keys.items) |*k| {
        if (k.ord.isPlain()) k.ord = cfg.gkey;
    }
    if (cfg.keys.items.len == 0 and !cfg.gkey.isPlainExceptReverse()) {
        cfg.keys.append(ctx.gpa, .{ .ord = cfg.gkey }) catch {
            cli.warn(ctx, "out of memory", .{});
            return false;
        };
    }
    // Without keys the global options must still be consistent with each other.
    if (cfg.keys.items.len == 0) return compatible(ctx, cfg.gkey);
    for (cfg.keys.items) |k| if (!compatible(ctx, k.ord)) return false;
    return true;
}

fn compatible(ctx: cli.Context, o: Ordering) bool {
    const n: u8 = @popCount(o.mode_mask & 15) + @as(u8, @intFromBool(o.mode_mask & 48 != 0)) + @as(u8, @intFromBool(o.ignores() and o.mode_mask & 15 != 0));
    if (n <= 1) return true;
    var letters: [12]u8 = undefined;
    var len: usize = 0;
    const add = struct {
        fn f(b: *[12]u8, l: *usize, c: u8) void {
            b[l.*] = c;
            l.* += 1;
        }
    }.f;
    if (o.skip_sblanks or o.skip_eblanks) add(&letters, &len, 'b');
    if (o.dict) add(&letters, &len, 'd');
    if (o.fold) add(&letters, &len, 'f');
    if (o.mode_mask & 1 != 0) add(&letters, &len, 'g');
    if (o.mode_mask & 2 != 0) add(&letters, &len, 'h');
    if (o.nonprint and !o.dict) add(&letters, &len, 'i');
    if (o.mode_mask & 4 != 0) add(&letters, &len, 'M');
    if (o.mode_mask & 8 != 0) add(&letters, &len, 'n');
    if (o.mode_mask & 32 != 0) add(&letters, &len, 'R');
    if (o.reverse) add(&letters, &len, 'r');
    if (o.mode_mask & 16 != 0) add(&letters, &len, 'V');
    cli.warn(ctx, "options '-{s}' are incompatible", .{letters[0..len]});
    return false;
}

// ------------------------------------------------------------------ input

const ReadError = error{ Reported, OutOfMemory };

/// Append the contents of `name` to `buf`, making sure the data ends with a
/// terminator (GNU supplies a missing final newline).
fn readInto(ctx: cli.Context, buf: *std.ArrayList(u8), name: []const u8, term: u8) ReadError!void {
    const start = buf.items.len;
    const file = cli.openInput(ctx.io, name) catch |e| {
        if (e == error.IsDir) {
            cli.warn(ctx, "read failed: {s}: Is a directory", .{name});
        } else {
            cli.warn(ctx, "cannot read: {s}: {s}", .{ name, cli.errText(e) });
        }
        return error.Reported;
    };
    defer cli.closeInput(ctx.io, file);
    while (true) {
        try buf.ensureUnusedCapacity(ctx.gpa, 64 * 1024);
        const n = cli.readChunk(ctx.io, file, buf.unusedCapacitySlice()) catch |e| {
            cli.warn(ctx, "read failed: {s}: {s}", .{ name, cli.errText(e) });
            return error.Reported;
        };
        if (n == 0) break;
        buf.items.len += n;
    }
    if (buf.items.len > start and buf.items[buf.items.len - 1] != term) try buf.append(ctx.gpa, term);
}

/// Whole contents of a file (used for --files0-from). Caller frees.
fn readAll(ctx: cli.Context, name: []const u8) ?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    const file = cli.openInput(ctx.io, name) catch |e| {
        cli.warn(ctx, "open failed: {s}: {s}", .{ name, cli.errText(e) });
        return null;
    };
    defer cli.closeInput(ctx.io, file);
    while (true) {
        buf.ensureUnusedCapacity(ctx.gpa, 4096) catch {
            _ = oom(ctx);
            buf.deinit(ctx.gpa);
            return null;
        };
        const n = cli.readChunk(ctx.io, file, buf.unusedCapacitySlice()) catch |e| {
            cli.warn(ctx, "{s}: read error: {s}", .{ name, cli.errText(e) });
            buf.deinit(ctx.gpa);
            return null;
        };
        if (n == 0) break;
        buf.items.len += n;
    }
    return buf.toOwnedSlice(ctx.gpa) catch {
        _ = oom(ctx);
        return null;
    };
}

// ---------------------------------------------------------------- compare

const Sorter = struct {
    keys: []const Key,
    tab: ?u8,
    unique: bool,
    stable: bool,
    reverse: bool,
    /// No keys at all: plain bytewise comparison (possibly reversed).
    simple: bool,

    fn init(cfg: *const Config) Sorter {
        return .{
            .keys = cfg.keys.items,
            .tab = cfg.tab,
            .unique = cfg.unique,
            .stable = cfg.stable,
            .reverse = cfg.gkey.reverse,
            .simple = cfg.keys.items.len == 0,
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
            var d = compareField(k.ord, fa, fb);
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
            else => compareField(k.ord, c.fields[a.idx * nk + i], c.fields[b.idx * nk + i]),
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
fn sortLines(ctx: cli.Context, s: *const Sorter, lines: [][]const u8) !void {
    const n = lines.len;
    if (n < 2) return;
    if (n > std.math.maxInt(u32)) return error.OutOfMemory;
    const gpa = ctx.gpa;
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

    const run = 12;
    var lo: usize = 0;
    while (lo < n) : (lo += run) {
        const hi = @min(lo + run, n);
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
    var width: usize = run;
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

fn compareField(o: Ordering, a: []const u8, b: []const u8) i32 {
    return switch (o.mode) {
        .lex => compareLex(o, a, b),
        .numeric => compareNumeric(a, b),
        .general => compareGeneral(a, b),
        .human => compareHuman(a, b),
        .month => monthOf(a) - monthOf(b),
        .random => compareRandom(o, a, b),
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
fn randomDigest(text: []const u8, out: *[16]u8) void {
    var h = std.crypto.hash.Md5.init(.{});
    h.update(&random_seed);
    h.update(text);
    if (random_nul) h.update(&.{0});
    h.final(out);
}

fn compareRandom(o: Ordering, a0: []const u8, b0: []const u8) i32 {
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
        randomDigest(a, &da);
        randomDigest(b, &db);
        return sign(orderBytes(&da, &db));
    }
    var da: [16]u8 = undefined;
    var db: [16]u8 = undefined;
    randomDigest(a, &da);
    randomDigest(b, &db);
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

// -------------------------------------------------------- check and merge

/// Open an input for sort's diagnostics: `verb` ("cannot read" when sorting or
/// merging, "open failed" when checking, as GNU words them) when it cannot be
/// opened, "read failed" for a directory (GNU opens it and fails on read).
fn openInput(ctx: cli.Context, name: []const u8, verb: []const u8) ?Io.File {
    return cli.openInput(ctx.io, name) catch |e| {
        if (e == error.IsDir) {
            cli.warn(ctx, "read failed: {s}: Is a directory", .{name});
        } else {
            cli.warn(ctx, "{s}: {s}: {s}", .{ verb, name, cli.errText(e) });
        }
        return null;
    };
}

/// -c / -C: compare each line with the previous one; stops at the first
/// disorder (or duplicate with -u). Memory is one line, not the file.
fn checkStream(ctx: cli.Context, s: *const Sorter, cfg: *const Config, name: []const u8) u8 {
    const file = openInput(ctx, name, "open failed") orelse return fail_status;
    defer cli.closeInput(ctx.io, file);
    var reader = linereader.LineReader.init(ctx.gpa, ctx.io, file, cfg.term);
    defer reader.deinit();
    var prev: std.ArrayList(u8) = .empty;
    defer prev.deinit(ctx.gpa);
    var n: usize = 0;
    while (true) {
        const line = (reader.next() catch |e| {
            cli.warn(ctx, "read failed: {s}: {s}", .{ name, cli.errText(e) });
            return fail_status;
        }) orelse return 0;
        n += 1;
        if (n > 1) {
            const d = s.compare(prev.items, line.text);
            if (d > 0 or (cfg.unique and d == 0)) {
                if (cfg.check == .diagnose) {
                    var out = cli.Out.initFile(ctx.io, Io.File.stderr());
                    out.print("{s}: {s}:{d}: disorder: ", .{ ctx.name, name, n });
                    out.write(line.text);
                    out.writeByte(cfg.term);
                    out.flush();
                }
                return 1;
            }
        }
        prev.clearRetainingCapacity();
        prev.appendSlice(ctx.gpa, line.text) catch return oom(ctx);
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
fn mergeStream(ctx: cli.Context, s: *const Sorter, cfg: *const Config, names: []const []const u8) u8 {
    const k = names.len;
    const gpa = ctx.gpa;
    const files = gpa.alloc(Io.File, k) catch return oom(ctx);
    defer gpa.free(files);
    const readers = gpa.alloc(linereader.LineReader, k) catch return oom(ctx);
    defer gpa.free(readers);
    const heads = gpa.alloc(std.ArrayList(u8), k) catch return oom(ctx);
    defer gpa.free(heads);
    const alive = gpa.alloc(bool, k) catch return oom(ctx);
    defer gpa.free(alive);

    var opened: usize = 0; // inputs whose file, reader and head are initialised
    defer for (0..opened) |i| {
        readers[i].deinit();
        heads[i].deinit(gpa);
        cli.closeInput(ctx.io, files[i]);
    };
    for (names, 0..) |name, i| {
        files[i] = openInput(ctx, name, "cannot read") orelse return fail_status;
        readers[i] = linereader.LineReader.init(gpa, ctx.io, files[i], cfg.term);
        heads[i] = .empty;
        alive[i] = false;
        opened += 1;
    }
    for (0..k) |i| if (!advance(ctx, readers, heads, alive, names, i, cfg)) return fail_status;

    var out = cli.Out.init(ctx.io);
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
            out.write(text);
            out.writeByte(cfg.term);
            if (out.failed) break;
            if (cfg.unique) {
                prev.clearRetainingCapacity();
                prev.appendSlice(gpa, text) catch return oom(ctx);
                have_prev = true;
            }
        }
        if (!advance(ctx, readers, heads, alive, names, b, cfg)) return fail_status;
    }
    out.flush();
    if (out.failed) {
        {
            cli.warn(ctx, "write failed: 'standard output': {s}", .{cli.stdout_err orelse "write error"});
            cli.warn(ctx, "write error", .{});
        }
        return fail_status;
    }
    return 0;
}

/// Load the next line of input `i` into its head slot.
fn advance(ctx: cli.Context, readers: []linereader.LineReader, heads: []std.ArrayList(u8), alive: []bool, names: []const []const u8, i: usize, cfg: *const Config) bool {
    _ = cfg;
    const line = (readers[i].next() catch |e| {
        cli.warn(ctx, "read failed: {s}: {s}", .{ names[i], cli.errText(e) });
        return false;
    }) orelse {
        alive[i] = false;
        return true;
    };
    heads[i].clearRetainingCapacity();
    heads[i].appendSlice(ctx.gpa, line.text) catch {
        _ = oom(ctx);
        return false;
    };
    alive[i] = true;
    return true;
}

/// k-way merge of the already-sorted runs found at `starts[i]..starts[i+1]`
/// of `lines`, in place (the result replaces `lines`). Ties go to the earlier
/// input, as in a stable merge.
fn mergeRuns(ctx: cli.Context, s: *const Sorter, lines: [][]const u8, starts: []const usize) !void {
    const runs = starts.len - 1;
    if (runs <= 1) return;
    const pos = try ctx.gpa.alloc(usize, runs);
    defer ctx.gpa.free(pos);
    for (pos, 0..) |*p, r| p.* = starts[r];
    const merged = try ctx.gpa.alloc([]const u8, lines.len);
    defer ctx.gpa.free(merged);
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

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return fail_status;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: sort [OPTION]... [FILE]...\n" ++
        "  or:  sort [OPTION]... --files0-from=F\n" ++
        "Write sorted concatenation of all FILE(s) to standard output.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "Ordering options:\n\n" ++
        "  -b, --ignore-leading-blanks  ignore leading blanks\n" ++
        "  -d, --dictionary-order      consider only blanks and alphanumeric characters\n" ++
        "  -f, --ignore-case           fold lower case to upper case characters\n" ++
        "  -g, --general-numeric-sort  compare according to general numerical value\n" ++
        "  -i, --ignore-nonprinting    consider only printable characters\n" ++
        "  -M, --month-sort            compare (unknown) < 'JAN' < ... < 'DEC'\n" ++
        "  -h, --human-numeric-sort    compare human readable numbers (e.g., 2K 1G)\n" ++
        "  -n, --numeric-sort          compare according to string numerical value\n" ++
        "  -r, --reverse               reverse the result of comparisons\n" ++
        "      --sort=WORD             sort according to WORD:\n" ++
        "                                general-numeric -g, human-numeric -h, month -M,\n" ++
        "                                numeric -n\n\n" ++
        "Other options:\n\n" ++
        "  -c, --check, --check=diagnose-first  check for sorted input; do not sort\n" ++
        "  -C, --check=quiet, --check=silent  like -c, but do not report first bad line\n" ++
        "      --files0-from=F       read input from the files specified by\n" ++
        "                            NUL-terminated names in file F;\n" ++
        "                            If F is - then read names from standard input\n" ++
        "  -k, --key=KEYDEF          sort via a key; KEYDEF gives location and type\n" ++
        "  -m, --merge               merge already sorted files; do not sort\n" ++
        "  -o, --output=FILE         write result to FILE instead of standard output\n" ++
        "  -s, --stable              stabilize sort by disabling last-resort comparison\n" ++
        "  -S, --buffer-size=SIZE    accepted and ignored (input is held in memory)\n" ++
        "  -t, --field-separator=SEP  use SEP instead of non-blank to blank transition\n" ++
        "  -u, --unique              output only the first of lines with equal keys;\n" ++
        "                              with -c, check for strict ordering\n" ++
        "  -z, --zero-terminated     line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n\n" ++
        "KEYDEF is F[.C][OPTS][,F[.C][OPTS]] for start and stop position, where F is a\n" ++
        "field number and C a character position in the field; both are origin 1, and\n" ++
        "the stop position defaults to the line's end.  OPTS is one or more single-letter\n" ++
        "ordering options [bdfghiMnr], which override global ordering options for that key.\n" ++
        "Not implemented: -R, -V, --debug.\n")) 0 else 1;
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
