// SPDX-License-Identifier: GPL-2.0-or-later
//! sort: thin wrapper over `util_core.sort` (decision 0004). Parses arguments
//! the way GNU sort does (key specifications, obsolete +POS keys,
//! --files0-from, option validation) and words the diagnostics; the ordering
//! engine and the sort/merge/check modes are in src/lib/sort.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const sort = @import("../lib/sort.zig");
const Io = std.Io;

const no_field = sort.no_field;
const Ordering = sort.Ordering;
const Key = sort.Key;

const Config = struct {
    gkey: Ordering = .{},
    keys: std.ArrayList(Key) = .empty,
    tab: ?u8 = null,
    unique: bool = false,
    stable: bool = false,
    merge: bool = false,
    check: sort.Check = .none,
    term: u8 = '\n',
    output: ?[]const u8 = null,
    random_source: ?[]const u8 = null,
    files0_from: ?[]const u8 = null,
    debug: bool = false,
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
        if (!only_operands and a.len >= 2 and a[0] == '+') {
            if (parseObsolete(ctx, &cfg, a, args, &i)) |ok| {
                if (!ok) return fail_status;
                continue;
            }
        }
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
                        if (!setCheck(ctx, &cfg, .diagnose)) return fail_status;
                    } else if (std.mem.eql(u8, v, "quiet") or std.mem.eql(u8, v, "silent")) {
                        if (!setCheck(ctx, &cfg, .quiet)) return fail_status;
                    } else {
                        cli.warn(ctx, "invalid argument '{s}' for '--check'\nValid arguments are:\n  - 'quiet', 'silent'\n  - 'diagnose-first'\nTry '{s} --help' for more information.", .{ v, ctx.name });
                        return 1;
                    }
                },
                15 => {}, // --compress-program: temporaries are never written
                16 => cfg.debug = true,
                17 => cfg.files0_from = value.?,
                18 => {
                    if (!addKey(ctx, &cfg, value.?)) return fail_status;
                },
                19 => cfg.merge = true,
                20 => if (!setOutput(ctx, &cfg, value.?)) return fail_status,
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
                    'o' => if (!setOutput(ctx, &cfg, value)) return fail_status,
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
                'c' => if (!setCheck(ctx, &cfg, .diagnose)) return fail_status,
                'C' => if (!setCheck(ctx, &cfg, .quiet)) return fail_status,
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
    // A check writes no output (--debug has messages of its own).
    if (cfg.check != .none and cfg.output != null and !cfg.debug) {
        cli.warn(ctx, "options '-{c}o' are incompatible", .{@as(u8, if (cfg.check == .quiet) 'C' else 'c')});
        return fail_status;
    }

    var opts: sort.Options = .{
        .gkey = cfg.gkey,
        .keys = cfg.keys.items,
        .tab = cfg.tab,
        .unique = cfg.unique,
        .stable = cfg.stable,
        .merge = cfg.merge,
        .check = cfg.check,
        .term = cfg.term,
        .output = cfg.output,
        .debug = cfg.debug,
    };
    var obuf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &obuf);
    var reporter: Reporter = .{ .ctx = ctx, .stdout = &stdout };
    const obs: sort.Observer = .{ .context = &reporter, .func = report };
    const env: sort.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };

    if (cfg.debug) {
        if (cfg.check != .none) {
            cli.warn(ctx, "options '-{c} --debug' are incompatible", .{@as(u8, if (cfg.check == .quiet) 'C' else 'c')});
            return fail_status;
        }
        if (cfg.output != null) {
            cli.warn(ctx, "options '-o --debug' are incompatible", .{});
            return fail_status;
        }
        sort.debugNotes(&opts, obs);
    }
    if (sort.usesRandom(&opts)) opts.rand = sort.seedRandom(env, cfg.random_source, obs) orelse return fail_status;

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

    return sort.run(env, opts, names.items, &stdout.interface, obs).status;
}

const Reporter = struct { ctx: cli.Context, stdout: *Io.File.Writer };

fn report(context: ?*anyopaque, ev: sort.Event) void {
    const r: *Reporter = @ptrCast(@alignCast(context.?));
    const ctx = r.ctx;
    switch (ev) {
        .note_simple_byte_comparison => cli.warn(ctx, "text ordering performed using simple byte comparison", .{}),
        .note_obsolescent_key => |e| cli.warn(ctx, "obsolescent key '{s}' used; consider '{s}' instead", .{ e.old, e.new }),
        .note_zero_width => |n| cli.warn(ctx, "key {d} has zero width and will be ignored", .{n}),
        .note_leading_blanks => |n| cli.warn(ctx, "leading blanks are significant in key {d}; consider also specifying 'b'", .{n}),
        .note_numeric_multi_field => |n| cli.warn(ctx, "key {d} is numeric and spans multiple fields", .{n}),
        .note_decimal_point => cli.warn(ctx, "numbers use '.' as a decimal point in this locale", .{}),
        .note_options_ignored => |letters| if (letters.len == 1)
            cli.warn(ctx, "option '-{s}' is ignored", .{letters})
        else
            cli.warn(ctx, "options '-{s}' are ignored", .{letters}),
        .note_r_last_resort => cli.warn(ctx, "option '-r' only applies to last-resort comparison", .{}),
        .random_open_failed => |e| cli.warn(ctx, "open failed: {s}: {s}", .{ e.path, cli.errText(e.err) }),
        .random_eof => |path| cli.warn(ctx, "{f}: end of file", .{cli.quoteA(path)}),
        .random_read_failed => |e| cli.warn(ctx, "read failed: {s}: {s}", .{ e.path, cli.errText(e.err) }),
        .open_failed => |e| {
            if (e.err == error.IsDir) {
                cli.warn(ctx, "read failed: {s}: Is a directory", .{e.name});
            } else {
                cli.warn(ctx, "{s}: {s}: {s}", .{ if (e.checking) "open failed" else "cannot read", e.name, cli.errText(e.err) });
            }
        },
        .read_failed => |e| cli.warn(ctx, "read failed: {s}: {s}", .{ e.name, cli.errText(e.err) }),
        .disorder => |e| {
            var out = cli.Out.initFile(ctx.io, Io.File.stderr());
            out.print("{s}: {s}:{d}: disorder: ", .{ ctx.name, e.name, e.line });
            out.write(e.text);
            out.writeByte(e.term);
            out.flush();
        },
        .output_open_failed => |e| cli.warn(ctx, "open failed: {s}: {s}", .{ e.path, cli.errText(e.err) }),
        .write_failed => |e| {
            if (e.output == null) cli.noteStdoutFailure(cli.errText(r.stdout.err orelse error.WriteFailed));
            if (e.streaming) {
                cli.warn(ctx, "write failed: 'standard output': {s}", .{cli.stdout_err orelse "write error"});
                cli.warn(ctx, "write error", .{});
            } else {
                cli.warn(ctx, "write failed: '{s}'", .{e.output orelse "standard output"});
            }
        },
        .out_of_memory => cli.warn(ctx, "memory exhausted", .{}),
    }
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


fn unsupported(ctx: cli.Context, what: []const u8) u8 {
    cli.warn(ctx, "{s} is not implemented in this build", .{what});
    return fail_status;
}

/// -c and -C, in either spelling: both at once is an error.
fn setCheck(ctx: cli.Context, cfg: *Config, mode: sort.Check) bool {
    if (cfg.check != .none and cfg.check != mode) {
        cli.warn(ctx, "options '-cC' are incompatible", .{});
        return false;
    }
    cfg.check = mode;
    return true;
}

fn setOutput(ctx: cli.Context, cfg: *Config, name: []const u8) bool {
    if (cfg.output) |had| if (!std.mem.eql(u8, had, name)) {
        cli.warn(ctx, "multiple output files specified", .{});
        return false;
    };
    cfg.output = name;
    return true;
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

/// Digits (at least one) from the front of `s`; null when there are none.
fn digitsPrefix(s: *[]const u8) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s.*[i])) : (i += 1) n = n *| 10 +| (s.*[i] - '0');
    if (i == 0) return null;
    s.* = s.*[i..];
    return n;
}

/// Obsolete `+POS1 [-POS2]` key. Returns null when `a` is not a possible key (it is then a
/// file name), otherwise whether the key was accepted.
fn parseObsolete(ctx: cli.Context, cfg: *Config, a: []const u8, args: []const []const u8, i: *usize) ?bool {
    var s: []const u8 = a[1..];
    var key: Key = .{};
    key.sword = digitsPrefix(&s) orelse return null;
    if (s.len > 0 and s[0] == '.') {
        s = s[1..];
        key.schar = digitsPrefix(&s) orelse return null;
    }
    var ord: Ordering = .{};
    parseLetters(&s, &ord, .start);
    if (s.len > 0) return null;
    key.ord = ord;
    key.obsolete = true;
    key.obs_s = key.sword;
    if (i.* + 1 < args.len and args[i.* + 1].len >= 2 and args[i.* + 1][0] == '-' and std.ascii.isDigit(args[i.* + 1][1])) {
        i.* += 1;
        const a2 = args[i.*];
        var t: []const u8 = a2[1..];
        key.eword = digitsPrefix(&t) orelse return null;
        if (t.len > 0 and t[0] == '.') {
            t = t[1..];
            key.echar = digitsPrefix(&t) orelse {
                cli.warn(ctx, "{s}: invalid number after '.': invalid count at start of '{s}'", .{ a2, t });
                return false;
            };
        }
        key.obs_e = key.eword +| @intFromBool(key.echar != 0);
        key.obs_has_e = true;
        if (key.echar == 0 and key.eword != 0) key.eword -= 1;
        parseLetters(&t, &key.ord, .end);
        if (t.len > 0) return badSpec(ctx, "stray character in field spec", a2);
    }
    cfg.keys.append(ctx.gpa, key) catch {
        cli.warn(ctx, "out of memory", .{});
        return false;
    };
    return true;
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
        cfg.keys.append(ctx.gpa, .{ .ord = cfg.gkey, .synthetic = true }) catch {
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
        "  -R, --random-sort           shuffle, but group identical keys\n" ++
        "      --random-source=FILE    get random bytes from FILE\n" ++
        "  -r, --reverse               reverse the result of comparisons\n" ++
        "      --sort=WORD             sort according to WORD:\n" ++
        "                                general-numeric -g, human-numeric -h, month -M,\n" ++
        "                                numeric -n, random -R, version -V\n" ++
        "  -V, --version-sort          natural sort of (version) numbers within text\n\n" ++
        "Other options:\n\n" ++
        "      --batch-size=NMERGE   accepted and ignored (no temporary files)\n" ++
        "  -c, --check, --check=diagnose-first  check for sorted input; do not sort\n" ++
        "  -C, --check=quiet, --check=silent  like -c, but do not report first bad line\n" ++
        "      --compress-program=PROG  accepted and ignored (no temporary files)\n" ++
        "      --debug               annotate the part of the line used to sort,\n" ++
        "                              and warn about questionable usage to stderr\n" ++
        "      --files0-from=F       read input from the files specified by\n" ++
        "                            NUL-terminated names in file F;\n" ++
        "                            If F is - then read names from standard input\n" ++
        "  -k, --key=KEYDEF          sort via a key; KEYDEF gives location and type\n" ++
        "  -m, --merge               merge already sorted files; do not sort\n" ++
        "  -o, --output=FILE         write result to FILE instead of standard output\n" ++
        "  -s, --stable              stabilize sort by disabling last-resort comparison\n" ++
        "  -S, --buffer-size=SIZE    accepted and ignored (input is held in memory)\n" ++
        "  -t, --field-separator=SEP  use SEP instead of non-blank to blank transition\n" ++
        "  -T, --temporary-directory=DIR  accepted and ignored (no temporary files)\n" ++
        "      --parallel=N          accepted and ignored (one thread is used)\n" ++
        "  -u, --unique              output only the first of lines with equal keys;\n" ++
        "                              with -c, check for strict ordering\n" ++
        "  -z, --zero-terminated     line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n\n" ++
        "KEYDEF is F[.C][OPTS][,F[.C][OPTS]] for start and stop position, where F is a\n" ++
        "field number and C a character position in the field; both are origin 1, and\n" ++
        "the stop position defaults to the line's end.  OPTS is one or more single-letter\n" ++
        "ordering options [bdfghiMnRrV], which override global ordering options for that key.\n")) 0 else 1;
}
