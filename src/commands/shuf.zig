//! shuf — generate random permutations.
//! Reference: GNU coreutils manual "shuf invocation" (9.7). POSIX does not
//! specify shuf.
//!
//! With --random-source=FILE the output is reproducible and matches GNU's:
//! random numbers are drawn exactly like gnulib's randint_genmax (bytes are
//! appended to a buffered number until it covers the range, with rejection of
//! the unusable top slice), and permutations use the same partial
//! Fisher-Yates swap sequence as randperm_new (gnulib randint.c / randperm.c,
//! coreutils 9.6 sources, consulted 2026-11-07). Without it the bytes come
//! from the system random generator.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const Io = std.Io;

const help_text = @embedFile("../help/shuf.txt");

const reservoir_min_input: u64 = 8192 * 1024;

/// Where random bytes come from: a file (reproducible) or the system RNG.
const Source = struct {
    io: Io,
    ctx: cli.Context,
    file: ?Io.File = null,
    name: []const u8 = "",
    buf: [4096]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,

    fn bytes(s: *Source, out: []u8) void {
        if (s.file == null) {
            s.io.random(out);
            return;
        }
        var got: usize = 0;
        while (got < out.len) {
            if (s.pos == s.len) {
                const n = cli.readChunk(s.io, s.file.?, &s.buf) catch {
                    cli.warn(s.ctx, "{f}: read error", .{cli.quoteC(s.name)});
                    std.process.exit(1);
                };
                if (n == 0) {
                    cli.warn(s.ctx, "{f}: end of file", .{cli.quoteC(s.name)});
                    std.process.exit(1);
                }
                s.pos = 0;
                s.len = n;
            }
            const take = @min(out.len - got, s.len - s.pos);
            @memcpy(out[got .. got + take], s.buf[s.pos .. s.pos + take]);
            s.pos += take;
            got += take;
        }
    }
};

/// gnulib randint: a uniformly distributed integer in 0..genmax, consuming the
/// byte source in the same pattern as randint_genmax.
const RandInt = struct {
    src: *Source,
    randnum: u64 = 0,
    randmax: u64 = 0,

    fn genmax(r: *RandInt, gm: u64) u64 {
        var randnum = r.randnum;
        var randmax = r.randmax;
        const choices = gm +% 1;
        while (true) {
            if (randmax < gm) {
                var i: usize = 0;
                var rmax = randmax;
                while (true) {
                    rmax = (rmax << 8) +% 255;
                    i += 1;
                    if (rmax >= gm) break;
                }
                var buf: [8]u8 = undefined;
                r.src.bytes(buf[0..i]);
                i = 0;
                while (true) {
                    randnum = (randnum << 8) +% buf[i];
                    randmax = (randmax << 8) +% 255;
                    i += 1;
                    if (randmax >= gm) break;
                }
            }
            if (randmax == gm) {
                r.randnum = 0;
                r.randmax = 0;
                return randnum;
            }
            const excess = randmax - gm;
            const unusable = excess % choices;
            const last_usable = randmax - unusable;
            const reduced = randnum % choices;
            if (randnum <= last_usable) {
                r.randnum = randnum / choices;
                r.randmax = excess / choices;
                return reduced;
            }
            randnum = reduced;
            randmax = unusable - 1;
        }
    }

    /// randint_choose(n): uniform in 0..n-1.
    fn choose(r: *RandInt, n: u64) u64 {
        return r.genmax(n - 1);
    }
};

/// First `h` elements of a random permutation of 0..n-1 (gnulib randperm_new).
fn randperm(gpa: std.mem.Allocator, r: *RandInt, h: usize, n: usize) ![]usize {
    if (h == 0) return &.{};
    if (h == 1) {
        const v = try gpa.alloc(usize, 1);
        v[0] = @intCast(r.choose(n));
        return v;
    }
    const sparse = n >= 128 * 1024 and n / h >= 32;
    if (!sparse) {
        const v = try gpa.alloc(usize, n);
        for (v, 0..) |*e, i| e.* = i;
        var i: usize = 0;
        while (i < h) : (i += 1) {
            const j = i + @as(usize, @intCast(r.choose(n - i)));
            std.mem.swap(usize, &v[i], &v[j]);
        }
        return try gpa.realloc(v, h);
    }
    var map = std.AutoHashMap(usize, usize).init(gpa);
    defer map.deinit();
    const v = try gpa.alloc(usize, h);
    var i: usize = 0;
    while (i < h) : (i += 1) {
        const j = i + @as(usize, @intCast(r.choose(n - i)));
        const vi = map.get(i) orelse i;
        const vj = map.get(j) orelse j;
        try map.put(i, vj);
        try map.put(j, vi);
        v[i] = vj;
    }
    return v;
}

fn parseU64(text: []const u8) error{ Invalid, Overflow }!u64 {
    if (text.len == 0 or !std.ascii.isDigit(text[0])) {
        if (text.len > 0 and text[0] == '+' and text.len > 1) {} else return error.Invalid;
    }
    return std.fmt.parseInt(u64, text, 10) catch |e| switch (e) {
        error.Overflow => error.Overflow,
        else => error.Invalid,
    };
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var echo = false;
    var repeat = false;
    var eol: u8 = '\n';
    var input_range: ?[2]u64 = null;
    var head_lines: u64 = std.math.maxInt(u64);
    var outfile: ?[]const u8 = null;
    var random_source: ?[]const u8 = null;
    var range_text: []const u8 = "";

    var p = getopt.Parser.init(ctx, "ei:n:o:rz", &.{
        .{ .name = "echo", .id = 'e' },
        .{ .name = "input-range", .arg = .required, .id = 'i' },
        .{ .name = "head-count", .arg = .required, .id = 'n' },
        .{ .name = "output", .arg = .required, .id = 'o' },
        .{ .name = "random-source", .arg = .required, .id = 1100 },
        .{ .name = "repeat", .id = 'r' },
        .{ .name = "zero-terminated", .id = 'z' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'e' => echo = true,
            'r' => repeat = true,
            'z' => eol = 0,
            'i' => {
                if (input_range != null) {
                    cli.warn(ctx, "multiple -i options specified", .{});
                    return 1;
                }
                const a = o.arg.?;
                range_text = a;
                const dash = std.mem.indexOfScalar(u8, a, '-');
                var ok = dash != null;
                var overflow = false;
                var lo: u64 = 0;
                var hi: u64 = 0;
                if (dash) |d| {
                    lo = parseU64(a[0..d]) catch |e| blk: {
                        ok = false;
                        overflow = e == error.Overflow;
                        break :blk 0;
                    };
                    hi = parseU64(a[d + 1 ..]) catch |e| blk: {
                        ok = false;
                        overflow = overflow or e == error.Overflow;
                        break :blk 0;
                    };
                }
                const n = hi -% lo +% 1;
                if (!ok or (lo <= hi) == (n == 0)) {
                    cli.warn(ctx, "invalid input range: {f}{s}", .{ cli.quoteC(a), if (overflow) ": Value too large for defined data type" else "" });
                    return 1;
                }
                input_range = .{ lo, hi };
            },
            'n' => {
                const v = parseU64(o.arg.?) catch |e| {
                    if (e == error.Overflow) continue;
                    cli.warn(ctx, "invalid line count: {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                };
                head_lines = @min(head_lines, v);
            },
            'o' => {
                if (outfile != null and !std.mem.eql(u8, outfile.?, o.arg.?)) {
                    cli.warn(ctx, "multiple output files specified", .{});
                    return 1;
                }
                outfile = o.arg;
            },
            1100 => {
                if (random_source != null and !std.mem.eql(u8, random_source.?, o.arg.?)) {
                    cli.warn(ctx, "multiple random sources specified", .{});
                    return 1;
                }
                random_source = o.arg;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const operands = p.operands.items;
    if (echo and input_range != null) {
        getopt.usageError(ctx, "cannot combine -e and -i options", .{});
        return 1;
    }
    if (if (input_range != null) operands.len > 0 else (!echo and operands.len > 1)) {
        const idx: usize = if (input_range != null) 0 else 1;
        getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(operands[idx])});
        return 1;
    }

    // ---- input ----
    var data: std.ArrayList(u8) = .empty; // line storage (each line ends in eol)
    defer data.deinit(gpa);
    var starts: std.ArrayList(usize) = .empty; // line i = data[starts[i]..starts[i+1]]
    defer starts.deinit(gpa);
    var n_lines: u64 = 0;
    var use_reservoir = false;
    var input_file: ?Io.File = null;
    defer if (input_file) |f| cli.closeInput(ctx.io, f);

    if (head_lines == 0) {
        n_lines = 0;
    } else if (echo) {
        for (operands) |o| {
            starts.append(gpa, data.items.len) catch return 1;
            data.appendSlice(gpa, o) catch return 1;
            data.append(gpa, eol) catch return 1;
        }
        starts.append(gpa, data.items.len) catch return 1;
        n_lines = operands.len;
    } else if (input_range) |r| {
        n_lines = r[1] - r[0] + 1;
    } else {
        const name: []const u8 = if (operands.len == 1) operands[0] else "-";
        const f = cli.openInput(ctx.io, name) catch |e| {
            // GNU opens a directory fine and fails on the first read.
            if (e == error.IsDir) cli.warn(ctx, "read error: Is a directory", .{}) else cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
            return 1;
        };
        input_file = f;
        var big_known = false;
        if (!(repeat or head_lines == std.math.maxInt(u64))) {
            if (f.stat(ctx.io)) |st| {
                if (st.kind == .file) big_known = st.size > reservoir_min_input;
            } else |_| {}
        }
        use_reservoir = big_known;
        if (!use_reservoir) {
            var chunk: [65536]u8 = undefined;
            while (true) {
                const n = cli.readChunk(ctx.io, f, &chunk) catch {
                    cli.warn(ctx, "read error", .{});
                    return 1;
                };
                if (n == 0) break;
                data.appendSlice(gpa, chunk[0..n]) catch return 1;
            }
            if (data.items.len > 0 and data.items[data.items.len - 1] != eol) data.append(gpa, eol) catch return 1;
            var pos: usize = 0;
            while (pos < data.items.len) {
                starts.append(gpa, pos) catch return 1;
                const nl = std.mem.indexOfScalarPos(u8, data.items, pos, eol).?;
                pos = nl + 1;
                n_lines += 1;
            }
            starts.append(gpa, data.items.len) catch return 1;
        } else n_lines = std.math.maxInt(u64);
    }

    var ahead: u64 = if (repeat or head_lines < n_lines) head_lines else n_lines;

    var src: Source = .{ .io = ctx.io, .ctx = ctx };
    if (random_source) |rs| {
        src.file = Io.Dir.cwd().openFile(ctx.io, rs, .{}) catch |e| {
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(rs), cli.errText(e) });
            return 1;
        };
        src.name = rs;
    }
    defer if (src.file) |f| f.close(ctx.io);
    var rng: RandInt = .{ .src = &src };

    // Reservoir sampling for big inputs with -n.
    var reservoir: std.ArrayList([]u8) = .empty;
    defer {
        for (reservoir.items) |l| gpa.free(l);
        reservoir.deinit(gpa);
    }
    if (use_reservoir) {
        const f = input_file.?;
        var lr = ReservoirReader{ .io = ctx.io, .file = f, .gpa = gpa, .eol = eol };
        defer lr.deinit();
        var count: u64 = 0;
        const k: usize = @intCast(ahead);
        while (count < k) : (count += 1) {
            const line = lr.next() catch return 1;
            if (line) |l| {
                reservoir.append(gpa, gpa.dupe(u8, l) catch return 1) catch return 1;
            } else break;
        }
        if (count == k) {
            while (true) {
                const j = rng.choose(count + 1);
                const line = lr.next() catch return 1;
                const l = line orelse break;
                if (j < k) {
                    gpa.free(reservoir.items[@intCast(j)]);
                    reservoir.items[@intCast(j)] = gpa.dupe(u8, l) catch return 1;
                }
                count += 1;
            }
        }
        n_lines = @min(@as(u64, k), count);
        ahead = n_lines;
    }

    var perm: []usize = &.{};
    defer if (perm.len > 0) gpa.free(perm);
    if (!repeat) {
        perm = randperm(gpa, &rng, @intCast(ahead), @intCast(n_lines)) catch return 1;
    }

    // ---- output ----
    var out_file: ?Io.File = null;
    if (outfile) |of| {
        out_file = Io.Dir.cwd().createFile(ctx.io, of, .{ .truncate = true }) catch |e| {
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(of), cli.errText(e) });
            return 1;
        };
    }
    defer if (out_file) |f| f.close(ctx.io);
    var out = if (out_file) |f| cli.Out.initFile(ctx.io, f) else cli.Out.init(ctx.io);

    if (repeat) {
        if (head_lines != 0) {
            if (n_lines == 0) {
                cli.warn(ctx, "no lines to repeat", .{});
                return 1;
            }
            var i: u64 = 0;
            while (i < ahead) : (i += 1) {
                if (input_range) |r| {
                    const j = r[0] + rng.choose(r[1] - r[0] + 1);
                    out.print("{d}{c}", .{ j, eol });
                } else {
                    const j: usize = @intCast(rng.choose(n_lines));
                    out.write(data.items[starts.items[j]..starts.items[j + 1]]);
                }
                if (out.failed) break;
            }
        }
    } else if (use_reservoir) {
        for (perm) |idx| {
            out.write(reservoir.items[idx]);
            if (out.failed) break;
        }
    } else if (input_range) |r| {
        for (perm) |idx| {
            out.print("{d}{c}", .{ r[0] + idx, eol });
            if (out.failed) break;
        }
    } else {
        for (perm) |idx| {
            out.write(data.items[starts.items[idx]..starts.items[idx + 1]]);
            if (out.failed) break;
        }
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return 0;
}

/// Reads lines including their terminator, appending a missing final one.
const ReservoirReader = struct {
    io: Io,
    file: Io.File,
    gpa: std.mem.Allocator,
    eol: u8,
    buf: [65536]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,
    line: std.ArrayList(u8) = .empty,

    fn deinit(r: *ReservoirReader) void {
        r.line.deinit(r.gpa);
    }

    fn next(r: *ReservoirReader) !?[]const u8 {
        r.line.clearRetainingCapacity();
        while (true) {
            if (r.pos == r.len) {
                r.len = try cli.readChunk(r.io, r.file, &r.buf);
                r.pos = 0;
                if (r.len == 0) {
                    if (r.line.items.len == 0) return null;
                    try r.line.append(r.gpa, r.eol);
                    return r.line.items;
                }
            }
            if (std.mem.indexOfScalar(u8, r.buf[r.pos..r.len], r.eol)) |i| {
                try r.line.appendSlice(r.gpa, r.buf[r.pos .. r.pos + i + 1]);
                r.pos += i + 1;
                return r.line.items;
            }
            try r.line.appendSlice(r.gpa, r.buf[r.pos..r.len]);
            r.pos = r.len;
        }
    }
};
