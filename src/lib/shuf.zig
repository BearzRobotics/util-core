// SPDX-License-Identifier: GPL-2.0-or-later
//! shuf library — generate random permutations (decision 0004). Argument
//! parsing and the GNU diagnostics are in src/commands/shuf.zig.
//! Reference: GNU coreutils manual "shuf invocation" (9.7). POSIX does not
//! specify shuf.
//!
//! With a random source file the output is reproducible and matches GNU's:
//! random numbers are drawn exactly like gnulib's randint_genmax (bytes are
//! appended to a buffered number until it covers the range, with rejection of
//! the unusable top slice), and permutations use the same partial
//! Fisher-Yates swap sequence as randperm_new (gnulib randint.c / randperm.c,
//! coreutils 9.6 sources, consulted 2026-11-07). Without it the bytes come
//! from the system random generator.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const wsink = @import("wsink.zig");

pub const Env = common.Env;
pub const Input = common.Input;

const reservoir_min_input: u64 = 8192 * 1024;

/// Where the lines to shuffle come from.
pub const Source = union(enum) {
    /// -e: each element is one line.
    echo: []const []const u8,
    /// -i LO-HI: the integers from lo to hi inclusive.
    range: [2]u64,
    /// Lines of a file or standard input.
    file: Input,
};

pub const Options = struct {
    source: Source,
    /// -r: sample with replacement.
    repeat: bool = false,
    /// Line terminator (-z makes it 0).
    eol: u8 = '\n',
    /// -n: at most this many lines.
    head_lines: u64 = std.math.maxInt(u64),
    /// -o: write to this file (created, truncated) instead of `out`.
    output_path: ?[]const u8 = null,
    /// --random-source: file of random bytes (reproducible output).
    random_source: ?[]const u8 = null,
};

/// A fatal problem; `run` returns `error.Failed` after reporting one.
pub const Event = union(enum) {
    /// The input file could not be opened.
    open_input: struct { name: []const u8, err: anyerror },
    /// Reading the input failed.
    read_input,
    /// -r with nothing to choose from.
    no_lines_to_repeat,
    /// The random source could not be opened.
    open_random: struct { name: []const u8, err: anyerror },
    /// Reading the random source failed.
    random_read_error: []const u8,
    /// The random source ran out.
    random_eof: []const u8,
    /// The -o file could not be created.
    open_output: struct { name: []const u8, err: anyerror },
};
pub const Observer = common.Observer(Event);

pub const Error = error{ Failed, OutOfMemory, WriteFailed };

const RandomError = error{RandomFailed};

/// Where random bytes come from: a file (reproducible) or the system RNG.
const RandSource = struct {
    io: Io,
    obs: Observer,
    file: ?Io.File = null,
    name: []const u8 = "",
    buf: [4096]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,

    fn bytes(s: *RandSource, out: []u8) RandomError!void {
        if (s.file == null) {
            s.io.random(out);
            return;
        }
        var got: usize = 0;
        while (got < out.len) {
            if (s.pos == s.len) {
                const n = common.readChunk(s.io, s.file.?, &s.buf) catch {
                    s.obs.emit(.{ .random_read_error = s.name });
                    return error.RandomFailed;
                };
                if (n == 0) {
                    s.obs.emit(.{ .random_eof = s.name });
                    return error.RandomFailed;
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
    src: *RandSource,
    randnum: u64 = 0,
    randmax: u64 = 0,

    fn genmax(r: *RandInt, gm: u64) RandomError!u64 {
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
                try r.src.bytes(buf[0..i]);
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
    fn choose(r: *RandInt, n: u64) RandomError!u64 {
        return r.genmax(n - 1);
    }
};

/// First `h` elements of a random permutation of 0..n-1 (gnulib randperm_new).
fn randperm(gpa: std.mem.Allocator, r: *RandInt, h: usize, n: usize) (RandomError || std.mem.Allocator.Error)![]usize {
    if (h == 0) return &.{};
    if (h == 1) {
        const v = try gpa.alloc(usize, 1);
        errdefer gpa.free(v);
        v[0] = @intCast(try r.choose(n));
        return v;
    }
    const sparse = n >= 128 * 1024 and n / h >= 32;
    if (!sparse) {
        const v = try gpa.alloc(usize, n);
        errdefer gpa.free(v);
        for (v, 0..) |*e, i| e.* = i;
        var i: usize = 0;
        while (i < h) : (i += 1) {
            const j = i + @as(usize, @intCast(try r.choose(n - i)));
            std.mem.swap(usize, &v[i], &v[j]);
        }
        return try gpa.realloc(v, h);
    }
    var map = std.AutoHashMap(usize, usize).init(gpa);
    defer map.deinit();
    const v = try gpa.alloc(usize, h);
    errdefer gpa.free(v);
    var i: usize = 0;
    while (i < h) : (i += 1) {
        const j = i + @as(usize, @intCast(try r.choose(n - i)));
        const vi = map.get(i) orelse i;
        const vj = map.get(j) orelse j;
        try map.put(i, vj);
        try map.put(j, vi);
        v[i] = vj;
    }
    return v;
}

/// Shuffle the source and write the result to `out_w` (or to the file
/// `opts.output_path`). Fatal problems are reported through `obs` and end the
/// run with `error.Failed`.
pub fn run(env: Env, opts: Options, out_w: *Io.Writer, obs: Observer) Error!void {
    const gpa = env.gpa;
    const io = env.io;
    const eol = opts.eol;
    const repeat = opts.repeat;
    const head_lines = opts.head_lines;

    // ---- input ----
    var data: std.ArrayList(u8) = .empty; // line storage (each line ends in eol)
    defer data.deinit(gpa);
    var starts: std.ArrayList(usize) = .empty; // line i = data[starts[i]..starts[i+1]]
    defer starts.deinit(gpa);
    var n_lines: u64 = 0;
    var use_reservoir = false;
    var input_file: ?common.Input.Opened = null;
    defer if (input_file) |f| f.close(io);
    var input_range: ?[2]u64 = null;

    switch (opts.source) {
        .range => |r| input_range = r,
        else => {},
    }

    if (head_lines == 0) {
        n_lines = 0;
    } else switch (opts.source) {
        .echo => |operands| {
            for (operands) |o| {
                try starts.append(gpa, data.items.len);
                try data.appendSlice(gpa, o);
                try data.append(gpa, eol);
            }
            try starts.append(gpa, data.items.len);
            n_lines = operands.len;
        },
        // LO = HI + 1 is an empty range, hence the wrapping arithmetic.
        .range => |r| n_lines = r[1] -% r[0] +% 1,
        .file => |in| {
            const name: []const u8 = in.name orelse "-";
            const f = in.open(io) catch |e| {
                obs.emit(.{ .open_input = .{ .name = name, .err = e } });
                return error.Failed;
            };
            input_file = f;
            var big_known = false;
            if (!(repeat or head_lines == std.math.maxInt(u64))) {
                if (f.file.stat(io)) |st| {
                    if (st.kind == .file) big_known = st.size > reservoir_min_input;
                } else |_| {}
            }
            use_reservoir = big_known;
            if (!use_reservoir) {
                var chunk: [65536]u8 = undefined;
                while (true) {
                    const n = common.readChunk(io, f.file, &chunk) catch {
                        obs.emit(.read_input);
                        return error.Failed;
                    };
                    if (n == 0) break;
                    try data.appendSlice(gpa, chunk[0..n]);
                }
                if (data.items.len > 0 and data.items[data.items.len - 1] != eol) try data.append(gpa, eol);
                var pos: usize = 0;
                while (pos < data.items.len) {
                    try starts.append(gpa, pos);
                    const nl = std.mem.indexOfScalarPos(u8, data.items, pos, eol).?;
                    pos = nl + 1;
                    n_lines += 1;
                }
                try starts.append(gpa, data.items.len);
            } else n_lines = std.math.maxInt(u64);
        },
    }

    var ahead: u64 = if (repeat or head_lines < n_lines) head_lines else n_lines;

    var src: RandSource = .{ .io = io, .obs = obs };
    if (opts.random_source) |rs| {
        src.file = Io.Dir.cwd().openFile(io, rs, .{}) catch |e| {
            obs.emit(.{ .open_random = .{ .name = rs, .err = e } });
            return error.Failed;
        };
        src.name = rs;
    }
    defer if (src.file) |f| f.close(io);
    var rng: RandInt = .{ .src = &src };

    // Reservoir sampling for big inputs with -n.
    var reservoir: std.ArrayList([]u8) = .empty;
    defer {
        for (reservoir.items) |l| gpa.free(l);
        reservoir.deinit(gpa);
    }
    if (use_reservoir) {
        const f = input_file.?.file;
        var lr = ReservoirReader{ .io = io, .file = f, .gpa = gpa, .eol = eol };
        defer lr.deinit();
        var count: u64 = 0;
        const k: usize = @intCast(ahead);
        while (count < k) : (count += 1) {
            const line = lr.next() catch return error.Failed;
            if (line) |l| {
                try reservoir.append(gpa, try gpa.dupe(u8, l));
            } else break;
        }
        if (count == k) {
            while (true) {
                const j = rng.choose(count + 1) catch return error.Failed;
                const line = lr.next() catch return error.Failed;
                const l = line orelse break;
                if (j < k) {
                    gpa.free(reservoir.items[@intCast(j)]);
                    reservoir.items[@intCast(j)] = try gpa.dupe(u8, l);
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
        perm = randperm(gpa, &rng, @intCast(ahead), @intCast(n_lines)) catch |e| switch (e) {
            error.RandomFailed => return error.Failed,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    // ---- output ----
    var out_file: ?Io.File = null;
    if (opts.output_path) |of| {
        out_file = Io.Dir.cwd().createFile(io, of, .{ .truncate = true }) catch |e| {
            obs.emit(.{ .open_output = .{ .name = of, .err = e } });
            return error.Failed;
        };
    }
    defer if (out_file) |f| f.close(io);
    var out = if (out_file) |f| wsink.Sink.initFile(io, f) else wsink.Sink.initWriter(out_w);

    if (repeat) {
        if (head_lines != 0) {
            if (n_lines == 0) {
                obs.emit(.no_lines_to_repeat);
                return error.Failed;
            }
            var i: u64 = 0;
            while (i < ahead) : (i += 1) {
                if (input_range) |r| {
                    const j = r[0] + (rng.choose(r[1] - r[0] + 1) catch return error.Failed);
                    out.print("{d}{c}", .{ j, eol });
                } else {
                    const j: usize = @intCast(rng.choose(n_lines) catch return error.Failed);
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
    if (out.failed) return error.WriteFailed;
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
                r.len = try common.readChunk(r.io, r.file, &r.buf);
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
