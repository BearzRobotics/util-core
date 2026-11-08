//! join — join lines of two sorted files on a common field.
//! References: GNU coreutils manual "join invocation" (9.7); POSIX.1-2024 join.
//!
//! The merge follows GNU's structure so that diagnostics appear in the same
//! circumstances: each input holds its current line; when keys are equal the
//! following lines with the same key are read (that is when the next line is
//! order-checked), then the cross product is printed. Order checking is on
//! with --check-order, off with --nocheck-order, and otherwise only once an
//! unpairable line has been seen.

const std = @import("std");
const cli = @import("../cli.zig");
const lines = @import("../lines.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "ignore-case", "zero-terminated", "check-order", "nocheck-order", "header", "help", "version" };

const OrderCheck = enum { default, on, off };

const Spec = struct { file: u8, field: usize }; // file 0 = the join field

const Config = struct {
    f1: usize = 1,
    f2: usize = 1,
    tab: ?u8 = null,
    tab_given: bool = false, // -t '' (whole line is a field)
    ignore_case: bool = false,
    term: u8 = '\n',
    check: OrderCheck = .default,
    header: bool = false,
    print1: bool = false, // -a1 or -v1
    print2: bool = false,
    pairs: bool = true, // false with -v
    empty: ?[]const u8 = null,
    out_spec: std.ArrayList(Spec) = .empty,
    auto: bool = false,
};

/// One input file with one line of lookahead.
const Input = struct {
    name: []const u8,
    file: Io.File,
    reader: lines.LineReader,
    cur: std.ArrayList(u8) = .empty,
    have: bool = false,
    prev: std.ArrayList(u8) = .empty,
    have_prev: bool = false,
    lineno: u64 = 0,
    warned: bool = false,
    which: u8,
    key_field: usize,
};

const State = struct {
    ctx: cli.Context,
    cfg: *const Config,
    out: *cli.Out,
    seen_unpairable: bool = false,
    disorder: bool = false,
    failed_fatal: bool = false,
};

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    defer cfg.out_spec.deinit(ctx.gpa);
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var o_arg: ?[]const u8 = null;

    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
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
                    return 1;
                },
            };
            if (eq != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => cfg.ignore_case = true,
                1 => cfg.term = 0,
                2 => cfg.check = .on,
                3 => cfg.check = .off,
                4 => cfg.header = true,
                5 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            switch (c) {
                'i' => cfg.ignore_case = true,
                'z' => cfg.term = 0,
                'a', 'v', 'e', 'j', 'o', 't', '1', '2' => {
                    var value: []const u8 = a[j + 1 ..];
                    // Obsolete -j1 N and -j2 N.
                    var obsolete: u8 = 0;
                    if (c == 'j' and value.len == 1 and (value[0] == '1' or value[0] == '2')) {
                        obsolete = value[0];
                        value = "";
                    }
                    if (value.len == 0) {
                        i += 1;
                        if (i >= ctx.args.len) {
                            cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
                            return 1;
                        }
                        value = ctx.args[i];
                    }
                    switch (c) {
                        'a', 'v' => {
                            const n = fileNumber(ctx, value) orelse return 1;
                            if (n == 1) cfg.print1 = true else cfg.print2 = true;
                            if (c == 'v') cfg.pairs = false;
                        },
                        'e' => cfg.empty = value,
                        'j' => {
                            const f = fieldNumber(ctx, value) orelse return 1;
                            if (obsolete == '1') cfg.f1 = f else if (obsolete == '2') cfg.f2 = f else {
                                cfg.f1 = f;
                                cfg.f2 = f;
                            }
                        },
                        '1' => cfg.f1 = fieldNumber(ctx, value) orelse return 1,
                        '2' => cfg.f2 = fieldNumber(ctx, value) orelse return 1,
                        'o' => o_arg = value,
                        else => { // 't'
                            if (value.len == 0) {
                                cfg.tab = null;
                                cfg.tab_given = true;
                            } else if (value.len == 1) {
                                cfg.tab = value[0];
                                cfg.tab_given = true;
                            } else if (std.mem.eql(u8, value, "\\0")) {
                                cfg.tab = 0;
                                cfg.tab_given = true;
                            } else {
                                cli.warn(ctx, "multi-character tab '{s}'", .{value});
                                return 1;
                            }
                        },
                    }
                    j = a.len;
                },
                else => {
                    cli.invalidShort(ctx, c);
                    return 1;
                },
            }
        }
    }
    if (o_arg) |spec| if (!parseOutput(ctx, &cfg, spec)) return 1;

    if (files.items.len < 2) {
        if (files.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        } else {
            cli.warn(ctx, "missing operand after '{s}'\nTry '{s} --help' for more information.", .{ files.items[0], ctx.name });
        }
        return 1;
    }
    if (files.items.len > 2) {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ files.items[2], ctx.name });
        return 1;
    }
    const both_stdin = std.mem.eql(u8, files.items[0], "-") and std.mem.eql(u8, files.items[1], "-");
    if (both_stdin) {
        cli.warn(ctx, "both files cannot be standard input", .{});
        return 1;
    }

    var in: [2]Input = undefined;
    var opened: usize = 0;
    defer for (0..opened) |k| {
        in[k].reader.deinit();
        in[k].cur.deinit(ctx.gpa);
        in[k].prev.deinit(ctx.gpa);
        cli.closeInput(ctx.io, in[k].file);
    };
    for (files.items, 0..) |name, k| {
        const f = cli.openInput(ctx.io, name) catch |e| {
            if (e == error.IsDir) {
                cli.warn(ctx, "read error: Is a directory", .{});
            } else cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
            return 1;
        };
        in[k] = .{
            .name = name,
            .file = f,
            .reader = lines.LineReader.init(ctx.gpa, ctx.io, f, cfg.term),
            .which = @intCast(k + 1),
            .key_field = if (k == 0) cfg.f1 else cfg.f2,
        };
        opened += 1;
    }

    var out = cli.Out.init(ctx.io);
    var st: State = .{ .ctx = ctx, .cfg = &cfg, .out = &out };
    const ok = run(&st, &in[0], &in[1]);
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    if (!ok) return 1;
    if (st.disorder) {
        cli.warn(ctx, "input is not in sorted order", .{});
        return 1;
    }
    return 0;
}

fn fileNumber(ctx: cli.Context, v: []const u8) ?u8 {
    if (std.mem.eql(u8, v, "1")) return 1;
    if (std.mem.eql(u8, v, "2")) return 2;
    cli.warn(ctx, "invalid file number: '{s}'", .{v});
    return null;
}

fn fieldNumber(ctx: cli.Context, v: []const u8) ?usize {
    const n = std.fmt.parseInt(usize, v, 10) catch {
        cli.warn(ctx, "invalid field number: '{s}'", .{v});
        return null;
    };
    if (n == 0) {
        cli.warn(ctx, "invalid field number: '{s}'", .{v});
        return null;
    }
    return n;
}

fn parseOutput(ctx: cli.Context, cfg: *Config, text: []const u8) bool {
    if (std.mem.eql(u8, text, "auto")) {
        cfg.auto = true;
        return true;
    }
    var it = std.mem.tokenizeAny(u8, text, ", \t");
    while (it.next()) |item| {
        if (std.mem.eql(u8, item, "0")) {
            cfg.out_spec.append(ctx.gpa, .{ .file = 0, .field = 0 }) catch return false;
            continue;
        }
        if (item.len >= 2 and (item[0] == '1' or item[0] == '2') and item[1] == '.') {
            const n = std.fmt.parseInt(usize, item[2..], 10) catch {
                cli.warn(ctx, "invalid field number: '{s}'", .{item[2..]});
                return false;
            };
            if (n == 0) {
                cli.warn(ctx, "invalid field number: '{s}'", .{item[2..]});
                return false;
            }
            cfg.out_spec.append(ctx.gpa, .{ .file = item[0] - '0', .field = n }) catch return false;
            continue;
        }
        cli.warn(ctx, "invalid file number in field spec: '{s}'", .{item});
        return false;
    }
    return true;
}

// ------------------------------------------------------------------ fields

fn isBlank(c: u8, term: u8) bool {
    return c == ' ' or c == '\t' or (term == 0 and c == '\n');
}

/// The n-th field (1-based) of `line`, or null when the line has fewer.
fn fieldAt(cfg: *const Config, line: []const u8, n: usize) ?[]const u8 {
    if (cfg.tab_given and cfg.tab == null) return if (n == 1) line else null; // -t '': whole line
    var count: usize = 0;
    var p: usize = 0;
    if (cfg.tab) |t| {
        while (true) {
            count += 1;
            const end = std.mem.indexOfScalarPos(u8, line, p, t) orelse line.len;
            if (count == n) return line[p..end];
            if (end >= line.len) return null;
            p = end + 1;
        }
    }
    while (p < line.len) {
        while (p < line.len and isBlank(line[p], cfg.term)) p += 1;
        if (p >= line.len) break;
        const start = p;
        while (p < line.len and !isBlank(line[p], cfg.term)) p += 1;
        count += 1;
        if (count == n) return line[start..p];
    }
    return null;
}

fn keyOf(cfg: *const Config, line: []const u8, field: usize) []const u8 {
    return fieldAt(cfg, line, field) orelse "";
}

fn cmpKeys(cfg: *const Config, a: []const u8, b: []const u8) i32 {
    if (!cfg.ignore_case) return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const ux = std.ascii.toUpper(x);
        const uy = std.ascii.toUpper(y);
        if (ux != uy) return if (ux < uy) -1 else 1;
    }
    return if (a.len < b.len) -1 else if (a.len > b.len) 1 else 0;
}

// -------------------------------------------------------------------- merge

/// Read the next physical line of `i`, order-checking it against the one read
/// before. The text stays valid until the next call. Returns null at end of
/// input; `ok` is cleared on a read error or a fatal disorder.
fn readLine(st: *State, i: *Input, ok: *bool) ?[]const u8 {
    const ctx = st.ctx;
    const r = i.reader.next() catch |e| {
        cli.warn(ctx, "{f}: read error: {s}", .{ cli.quote(i.name), cli.errText(e) });
        ok.* = false;
        return null;
    };
    const l = r orelse return null;
    i.lineno += 1;
    const cfg = st.cfg;
    if (i.have_prev and cfg.check != .off and (cfg.check == .on or st.seen_unpairable) and !i.warned) {
        const d = cmpKeys(cfg, keyOf(cfg, i.prev.items, i.key_field), keyOf(cfg, l.text, i.key_field));
        if (d > 0) {
            st.out.flush();
            cli.warn(ctx, "{f}:{d}: is not sorted: {s}", .{ cli.quote(i.name), i.lineno, l.text });
            i.warned = true;
            st.disorder = true;
            if (cfg.check == .on) {
                st.failed_fatal = true;
                ok.* = false;
                return null;
            }
        }
    }
    i.prev.clearRetainingCapacity();
    i.prev.appendSlice(ctx.gpa, l.text) catch {
        ok.* = false;
        return null;
    };
    i.have_prev = true;
    return l.text;
}

/// Load the next line of `i` into `cur` (`have` is false at end of input),
/// order-checked by readLine. Returns false on a fatal error.
fn advance(st: *State, i: *Input) bool {
    var ok = true;
    const l = readLine(st, i, &ok);
    if (!ok) return false;
    if (l) |text| {
        i.cur.clearRetainingCapacity();
        i.cur.appendSlice(st.ctx.gpa, text) catch return false;
        i.have = true;
    } else i.have = false;
    return true;
}

fn run(st: *State, a: *Input, b: *Input) bool {
    const ctx = st.ctx;
    const cfg = st.cfg;
    var g1: Group = .{};
    defer g1.deinit(ctx.gpa);
    var g2: Group = .{};
    defer g2.deinit(ctx.gpa);

    if (!advance(st, a) or !advance(st, b)) return false;

    var fmt_auto: [2]usize = .{ 0, 0 };
    if (cfg.auto) {
        fmt_auto[0] = if (a.have) countFields(cfg, a.cur.items) else 0;
        fmt_auto[1] = if (b.have) countFields(cfg, b.cur.items) else 0;
    }

    if (cfg.header and (a.have or b.have)) {
        // Header lines are joined and printed first; they are not order-checked.
        printPair(st, if (a.have) a.cur.items else null, if (b.have) b.cur.items else null, fmt_auto);
        a.have_prev = false;
        b.have_prev = false;
        if (a.have and !advance(st, a)) return false;
        if (b.have and !advance(st, b)) return false;
        a.have_prev = a.have;
        b.have_prev = b.have;
    }

    while (a.have and b.have) {
        const ka = keyOf(cfg, a.cur.items, a.key_field);
        const d = cmpKeys(cfg, ka, keyOf(cfg, b.cur.items, b.key_field));
        if (d < 0) {
            if (cfg.print1) printUnpaired(st, a.cur.items, 1, fmt_auto);
            if (!advance(st, a)) return false;
            st.seen_unpairable = true; // set after the advance, as GNU does
            continue;
        }
        if (d > 0) {
            if (cfg.print2) printUnpaired(st, b.cur.items, 2, fmt_auto);
            if (!advance(st, b)) return false;
            st.seen_unpairable = true;
            continue;
        }
        // Equal keys: gather every following line with the same key in each file.
        g1.clear();
        g2.clear();
        g1.add(ctx.gpa, a.cur.items) catch return false;
        g2.add(ctx.gpa, b.cur.items) catch return false;
        const key = ctx.gpa.dupe(u8, ka) catch return false;
        defer ctx.gpa.free(key);
        while (true) {
            if (!advance(st, a)) return false;
            if (!a.have or cmpKeys(cfg, keyOf(cfg, a.cur.items, a.key_field), key) != 0) break;
            g1.add(ctx.gpa, a.cur.items) catch return false;
        }
        while (true) {
            if (!advance(st, b)) return false;
            if (!b.have or cmpKeys(cfg, keyOf(cfg, b.cur.items, b.key_field), key) != 0) break;
            g2.add(ctx.gpa, b.cur.items) catch return false;
        }
        if (cfg.pairs) {
            for (0..g1.count()) |x| {
                for (0..g2.count()) |y| printPair(st, g1.get(x), g2.get(y), fmt_auto);
            }
        }
        if (st.out.failed) return true;
    }

    // One input is exhausted: whatever is left of the other is unpairable.
    inline for (.{ .{ a, @as(u8, 1) }, .{ b, @as(u8, 2) } }) |pair| {
        const inp: *Input = pair[0];
        const which: u8 = pair[1];
        const print = if (which == 1) cfg.print1 else cfg.print2;
        while (inp.have) {
            if (print) printUnpaired(st, inp.cur.items, which, fmt_auto);
            if (!advance(st, inp)) return false;
            if (st.out.failed) return true;
        }
    }
    return true;
}

const Group = struct {
    buf: std.ArrayList(u8) = .empty,
    spans: std.ArrayList([2]usize) = .empty,

    fn deinit(g: *Group, gpa: std.mem.Allocator) void {
        g.buf.deinit(gpa);
        g.spans.deinit(gpa);
    }
    fn clear(g: *Group) void {
        g.buf.clearRetainingCapacity();
        g.spans.clearRetainingCapacity();
    }
    fn add(g: *Group, gpa: std.mem.Allocator, text: []const u8) !void {
        try g.spans.append(gpa, .{ g.buf.items.len, text.len });
        try g.buf.appendSlice(gpa, text);
    }
    fn count(g: *const Group) usize {
        return g.spans.items.len;
    }
    fn get(g: *const Group, k: usize) []const u8 {
        const sp = g.spans.items[k];
        return g.buf.items[sp[0]..][0..sp[1]];
    }
};

fn countFields(cfg: *const Config, line: []const u8) usize {
    var n: usize = 0;
    while (fieldAt(cfg, line, n + 1) != null) n += 1;
    return n;
}

// ------------------------------------------------------------------- output

fn sepByte(cfg: *const Config) u8 {
    return cfg.tab orelse ' ';
}

fn writeField(st: *State, f: ?[]const u8) void {
    const cfg = st.cfg;
    if (f) |s| {
        if (s.len == 0) {
            if (cfg.empty) |e| st.out.write(e);
        } else st.out.write(s);
    } else if (cfg.empty) |e| st.out.write(e);
}

/// Output line for a pair (either side may be missing only for headers).
fn printPair(st: *State, l1: ?[]const u8, l2: ?[]const u8, fmt_auto: [2]usize) void {
    const cfg = st.cfg;
    const out = st.out;
    if (cfg.out_spec.items.len > 0 or cfg.auto) {
        printSpecified(st, l1, l2, fmt_auto);
        return;
    }
    // Default: join field, rest of file 1, rest of file 2.
    const key: []const u8 = if (l1) |x| keyOf(cfg, x, cfg.f1) else if (l2) |y| keyOf(cfg, y, cfg.f2) else "";
    out.write(key);
    if (l1) |x| writeRest(st, x, cfg.f1);
    if (l2) |y| writeRest(st, y, cfg.f2);
    out.writeByte(cfg.term);
}

fn writeRest(st: *State, line: []const u8, skip: usize) void {
    const cfg = st.cfg;
    var n: usize = 1;
    while (fieldAt(cfg, line, n)) |f| : (n += 1) {
        if (n == skip) continue;
        st.out.writeByte(sepByte(cfg));
        st.out.write(f);
    }
}

fn printUnpaired(st: *State, line: []const u8, which: u8, fmt_auto: [2]usize) void {
    const cfg = st.cfg;
    if (cfg.out_spec.items.len > 0 or cfg.auto) {
        if (which == 1) printSpecified(st, line, null, fmt_auto) else printSpecified(st, null, line, fmt_auto);
        return;
    }
    const field = if (which == 1) cfg.f1 else cfg.f2;
    st.out.write(keyOf(cfg, line, field));
    writeRest(st, line, field);
    st.out.writeByte(cfg.term);
}

fn printSpecified(st: *State, l1: ?[]const u8, l2: ?[]const u8, fmt_auto: [2]usize) void {
    const cfg = st.cfg;
    const out = st.out;
    var first = true;
    if (cfg.auto) {
        // 0, then the other fields of file 1 and of file 2 as inferred from
        // the first line of each.
        const key = if (l1) |x| keyOf(cfg, x, cfg.f1) else if (l2) |y| keyOf(cfg, y, cfg.f2) else "";
        writeField(st, key);
        first = false;
        inline for (.{ .{ l1, cfg.f1, fmt_auto[0] }, .{ l2, cfg.f2, fmt_auto[1] } }) |t| {
            var n: usize = 1;
            while (n <= t[2]) : (n += 1) {
                if (n == t[1]) continue;
                out.writeByte(sepByte(cfg));
                writeField(st, if (t[0]) |line| fieldAt(cfg, line, n) else null);
            }
        }
        out.writeByte(cfg.term);
        return;
    }
    for (cfg.out_spec.items) |sp| {
        if (!first) out.writeByte(sepByte(cfg));
        first = false;
        if (sp.file == 0) {
            const key = if (l1) |x| keyOf(cfg, x, cfg.f1) else if (l2) |y| keyOf(cfg, y, cfg.f2) else "";
            writeField(st, key);
        } else {
            const line = if (sp.file == 1) l1 else l2;
            writeField(st, if (line) |ln| fieldAt(cfg, ln, sp.field) else null);
        }
    }
    out.writeByte(cfg.term);
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: join [OPTION]... FILE1 FILE2\n" ++
        "For each pair of input lines with identical join fields, write a line to\n" ++
        "standard output.  The default join field is the first, delimited by blanks.\n\n" ++
        "When FILE1 or FILE2 (not both) is -, read standard input.\n\n" ++
        "  -a FILENUM        also print unpairable lines from file FILENUM, where\n" ++
        "                      FILENUM is 1 or 2, corresponding to FILE1 or FILE2\n" ++
        "  -e STRING         replace missing input fields with STRING\n" ++
        "  -i, --ignore-case  ignore differences in case when comparing fields\n" ++
        "  -j FIELD          equivalent to '-1 FIELD -2 FIELD'\n" ++
        "  -o FORMAT         obey FORMAT while constructing output line\n" ++
        "  -t CHAR           use CHAR as input and output field separator\n" ++
        "  -v FILENUM        like -a FILENUM, but suppress joined output lines\n" ++
        "  -1 FIELD          join on this FIELD of file 1\n" ++
        "  -2 FIELD          join on this FIELD of file 2\n" ++
        "      --check-order     check that the input is correctly sorted, even\n" ++
        "                          if all input lines are pairable\n" ++
        "      --nocheck-order   do not check that the input is correctly sorted\n" ++
        "      --header      treat the first line in each file as field headers,\n" ++
        "                      print them without trying to pair them\n" ++
        "  -z, --zero-terminated     line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
