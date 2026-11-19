// SPDX-License-Identifier: GPL-2.0-or-later
//! join library (decision 0004): join lines of two sorted inputs on a common
//! field. References: GNU coreutils manual "join invocation" (9.7);
//! POSIX.1-2024 join.
//!
//! The merge follows GNU's structure so that diagnostics appear in the same
//! circumstances: each input holds its current line; when keys are equal the
//! following lines with the same key are read (that is when the next line is
//! order-checked), then the cross product is printed. Order checking is on
//! with `.on`, off with `.off`, and otherwise only once an unpairable line
//! has been seen.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const lines = @import("../lines.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const OrderCheck = enum { default, on, off };

/// One item of an explicit output format: `file` 0 is the join field.
pub const Spec = struct { file: u8, field: usize };

pub const Options = struct {
    /// Join field of the first and second input (1-based).
    f1: usize = 1,
    f2: usize = 1,
    /// Field separator byte; null means blanks (or, with `tab_given`, the
    /// whole line is one field).
    tab: ?u8 = null,
    /// -t '' : the whole line is a field.
    tab_given: bool = false,
    ignore_case: bool = false,
    /// Line terminator for input and output.
    term: u8 = '\n',
    check: OrderCheck = .default,
    /// Treat the first line of each input as a header, joined and printed first.
    header: bool = false,
    /// Print unpairable lines of the first / second input.
    print1: bool = false,
    print2: bool = false,
    /// False with -v: only unpairable lines are printed.
    pairs: bool = true,
    /// Replacement for missing fields.
    empty: ?[]const u8 = null,
    /// Explicit output format (-o); empty means the default format.
    output: []const Spec = &.{},
    /// -o auto: infer the format from the first line of each input.
    auto: bool = false,
};

pub const Kind = enum {
    /// An input could not be opened (`name`, `err`). With `error.IsDir` GNU
    /// words it without the name.
    open_failed,
    read_failed,
    /// A line is out of order: `name`, `lineno`, `text`.
    not_sorted,
    /// Final notice when some input was out of order (check not fatal).
    input_disorder,
};

pub const Event = struct {
    kind: Kind,
    name: []const u8 = "",
    err: ?anyerror = null,
    lineno: u64 = 0,
    text: []const u8 = "",
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

/// One input with one line of lookahead.
const Side = struct {
    name: []const u8,
    file: Io.File,
    owned: bool,
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
    env: Env,
    observer: Observer,
    cfg: *const Options,
    out: *stickyout.Out,
    seen_unpairable: bool = false,
    disorder: bool = false,
    failed_fatal: bool = false,
};

pub fn run(env: Env, options: Options, first: Input, second: Input, writer: *Io.Writer, observer: Observer) error{WriteFailed}!Result {
    var in: [2]Side = undefined;
    var opened: usize = 0;
    defer for (0..opened) |k| {
        in[k].reader.deinit();
        in[k].cur.deinit(env.gpa);
        in[k].prev.deinit(env.gpa);
        if (in[k].owned) in[k].file.close(env.io);
    };
    const ins = [2]Input{ first, second };
    for (ins, 0..) |input, k| {
        const name = input.name orelse "-";
        const o = input.open(env.io) catch |e| {
            observer.emit(.{ .kind = .open_failed, .name = name, .err = e });
            return .{ .failed = true };
        };
        in[k] = .{
            .name = name,
            .file = o.file,
            .owned = o.owned,
            .reader = lines.LineReader.init(env.gpa, env.io, o.file, options.term),
            .which = @intCast(k + 1),
            .key_field = if (k == 0) options.f1 else options.f2,
        };
        opened += 1;
    }

    var out = stickyout.Out.init(writer);
    var st: State = .{ .env = env, .observer = observer, .cfg = &options, .out = &out };
    const ok = merge(&st, &in[0], &in[1]);
    try out.finish();
    if (!ok) return .{ .failed = true };
    if (st.disorder) {
        observer.emit(.{ .kind = .input_disorder });
        return .{ .failed = true };
    }
    return .{};
}

// ------------------------------------------------------------------ fields

fn isBlank(c: u8, term: u8) bool {
    return c == ' ' or c == '\t' or (term == 0 and c == '\n');
}

/// The n-th field (1-based) of `line`, or null when the line has fewer.
fn fieldAt(cfg: *const Options, line: []const u8, n: usize) ?[]const u8 {
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

fn keyOf(cfg: *const Options, line: []const u8, field: usize) []const u8 {
    return fieldAt(cfg, line, field) orelse "";
}

fn cmpKeys(cfg: *const Options, a: []const u8, b: []const u8) i32 {
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
fn readLine(st: *State, i: *Side, ok: *bool) ?[]const u8 {
    const ctx = st.env;
    const r = i.reader.next() catch |e| {
        st.observer.emit(.{ .kind = .read_failed, .name = i.name, .err = e });
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
            st.observer.emit(.{ .kind = .not_sorted, .name = i.name, .lineno = i.lineno, .text = l.text });
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
fn advance(st: *State, i: *Side) bool {
    var ok = true;
    const l = readLine(st, i, &ok);
    if (!ok) return false;
    if (l) |text| {
        i.cur.clearRetainingCapacity();
        i.cur.appendSlice(st.env.gpa, text) catch return false;
        i.have = true;
    } else i.have = false;
    return true;
}

fn merge(st: *State, a: *Side, b: *Side) bool {
    const ctx = st.env;
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
        const inp: *Side = pair[0];
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

fn countFields(cfg: *const Options, line: []const u8) usize {
    var n: usize = 0;
    while (fieldAt(cfg, line, n + 1) != null) n += 1;
    return n;
}

// ------------------------------------------------------------------- output

fn sepByte(cfg: *const Options) u8 {
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
    if (cfg.output.len > 0 or cfg.auto) {
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
    if (cfg.output.len > 0 or cfg.auto) {
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
    for (cfg.output) |sp| {
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

