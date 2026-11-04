//! Developer tool: load .sublime-syntax grammars, highlight a file with the
//! first one, print a summary (warnings, rejected patterns, timing).
//!
//!   zig-out/bin/syntax-probe [-v] GRAMMAR... -- SOURCE
//! The first grammar is used for SOURCE; the others are loaded so cross
//! references resolve.

const std = @import("std");
const Io = std.Io;
const syntax = @import("root.zig");

const Counter = struct {
    tokens: usize = 0,
    bytes: usize = 0,
    dump: ?*Io.Writer = null,
    reg: *syntax.definition.Registry,
    line: []const u8 = "",

    pub fn token(c: *Counter, s: usize, e: usize, scopes: []const syntax.definition.ScopeId) void {
        c.tokens += 1;
        c.bytes += e - s;
        const w = c.dump orelse return;
        w.print("{s}\t", .{std.mem.trimEnd(u8, c.line[s..e], "\n")}) catch return;
        for (scopes) |id| w.print("{s} ", .{c.reg.scopeName(id)}) catch return;
        w.writeByte('\n') catch return;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var verbose = false;
    var grammars: std.ArrayList([]const u8) = .empty;
    var source: ?[]const u8 = null;
    var after_sep = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--")) {
            after_sep = true;
        } else if (std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (after_sep) {
            source = a;
        } else try grammars.append(init.arena.allocator(), a);
    }
    if (grammars.items.len == 0 or source == null) {
        std.debug.print("usage: probe [-v] GRAMMAR... -- SOURCE\n", .{});
        return 2;
    }

    var reg = syntax.definition.Registry.init(gpa);
    defer reg.deinit();
    var first: ?*syntax.definition.Syntax = null;
    for (grammars.items) |path| {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
        defer gpa.free(text);
        const syn = reg.load(text, path) catch |e| {
            std.debug.print("{s}: load failed: {s} ({s}) line {d}\n", .{ path, @errorName(e), reg.last_error, reg.diag.line });
            return 1;
        };
        if (first == null) first = syn;
    }

    const src = try Io.Dir.cwd().readFileAlloc(io, source.?, gpa, .limited(256 << 20));
    defer gpa.free(src);

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);

    var hl = syntax.engine.Highlighter.init(&reg);
    defer hl.deinit();
    var st = try syntax.engine.State.init(gpa, first.?);
    defer st.deinit(gpa);
    var counter: Counter = .{ .reg = &reg, .dump = if (verbose) &stdout.interface else null };

    const t0 = Io.Clock.awake.now(io);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| {
        if (it.peek() == null and l.len == 0) break;
        counter.line = l;
        // Lines need their newline; re-slice from the source buffer.
        const start = @intFromPtr(l.ptr) - @intFromPtr(src.ptr);
        const end = @min(start + l.len + 1, src.len);
        const full = src[start..end];
        counter.line = full;
        try hl.highlightLine(&st, full, &counter);
        lines += 1;
    }
    const elapsed = t0.untilNow(io, .awake);
    try stdout.interface.flush();

    var rejected: usize = 0;
    for (reg.syntaxes.items) |s| {
        for (s.warnings.items) |w| {
            std.debug.print("warning [{s}]: {s}\n", .{ s.name, w });
            rejected += 1;
        }
    }
    const ns: u64 = @intCast(elapsed.toNanoseconds());
    std.debug.print(
        "{d} lines, {d} bytes, {d} tokens, {d} warnings, {d} ms\n",
        .{ lines, src.len, counter.tokens, rejected, ns / std.time.ns_per_ms },
    );
    return 0;
}
