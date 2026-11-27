// SPDX-License-Identifier: GPL-2.0-or-later
//! time library: run a command and report the resources it used, and (an
//! extension, decision 0005) benchmark commands the way the `poop` tool does.
//! Reference: GNU time 1.9 (`/usr/bin/time`, compared in test/test_time.sh);
//! the benchmark view is modelled on poop / crap (ziggit.dev thread 13400),
//! reproduced from memory of its output, not from its source.
//!
//! Decision 0004: nothing here parses arguments, prints to a terminal or
//! exits. `run` starts one command and waits for it with `sys.waitUsage`;
//! `writeFormat` and friends write to a caller-supplied writer; `bench`
//! repeats `run` and returns statistics, `writeBenchmark` draws each result.

const std = @import("std");
const numparse = @import("../numparse.zig");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

// ------------------------------------------------------------------ one run

/// What one run of a command cost.
pub const Measurement = struct {
    wall_ns: u64 = 0,
    usage: sys.Usage = .{},
    result: sys.WaitResult = .none,
    /// Hardware counters, when `RunOptions.perf` was given and the system
    /// could count them.
    perf: sys.Perf.Sample = @splat(null),

    /// The status GNU time reports: the command's own, or 128 + signal.
    pub fn exitStatus(m: Measurement) u8 {
        return switch (m.result) {
            .exited => |c| c,
            .signaled => |s| 128 +| s,
            .none => 1,
        };
    }
};

pub const StdIo = std.process.SpawnOptions.StdIo;

/// Standard error captured from a benchmark run (the first 4 KiB).
pub const Capture = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,

    pub fn text(c: *const Capture) []const u8 {
        return c.buf[0..c.len];
    }
};

pub const RunOptions = struct {
    stdin: StdIo = .inherit,
    stdout: StdIo = .inherit,
    stderr: StdIo = .inherit,
    /// With `stderr = .pipe`: read it into this (first 4 KiB, rest dropped).
    capture: ?*Capture = null,
    /// Count hardware events of the command (Linux, when permitted).
    perf: bool = false,
    /// Replaces the command's environment when given.
    environ_map: ?*const std.process.Environ.Map = null,
};

fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).nanoseconds;
}

/// Start `argv`, wait for it, and measure. Spawn errors are returned; the
/// caller words them (GNU time still prints a summary after one).
pub fn run(env: Env, argv: []const []const u8, opts: RunOptions) std.process.SpawnError!Measurement {
    var perf: sys.Perf = if (opts.perf) sys.Perf.open() else .{};
    defer perf.close();
    const t0 = nowNs(env.io);
    var child = try std.process.spawn(env.io, .{
        .argv = argv,
        .stdin = opts.stdin,
        .stdout = opts.stdout,
        .stderr = opts.stderr,
        .environ_map = opts.environ_map,
    });
    if (child.stderr) |*err_file| {
        if (opts.capture) |cap| {
            cap.len = 0;
            cap.truncated = false;
            var rbuf: [4096]u8 = undefined;
            var r = err_file.readerStreaming(env.io, &rbuf);
            var w: Io.Writer = .fixed(&cap.buf);
            while (true) _ = r.interface.stream(&w, .unlimited) catch |e| switch (e) {
                error.ReadFailed => break,
                error.WriteFailed => {
                    cap.truncated = true;
                    _ = r.interface.discardRemaining() catch {};
                    break;
                },
                error.EndOfStream => break,
            };
            cap.len = w.end;
        }
        err_file.close(env.io);
        child.stderr = null;
    }
    const w = sys.waitUsage(child.id.?);
    const t1 = nowNs(env.io);
    var m: Measurement = .{
        .wall_ns = @intCast(@max(t1 - t0, 0)),
        .usage = w.usage,
        .result = w.result,
    };
    if (opts.perf) m.perf = perf.read();
    return m;
}

// --------------------------------------------------------- GNU time output

pub const default_format =
    "%Uuser %Ssystem %Eelapsed %PCPU (%Xavgtext+%Davgdata %Mmaxresident)k\n" ++
    "%Iinputs+%Ooutputs (%Fmajor+%Rminor)pagefaults %Wswaps";
pub const portable_format = "real %e\nuser %U\nsys %S";
pub const verbose_format =
    "\tCommand being timed: \"%C\"\n" ++
    "\tUser time (seconds): %U\n" ++
    "\tSystem time (seconds): %S\n" ++
    "\tPercent of CPU this job got: %P\n" ++
    "\tElapsed (wall clock) time (h:mm:ss or m:ss): %E\n" ++
    "\tAverage shared text size (kbytes): %X\n" ++
    "\tAverage unshared data size (kbytes): %D\n" ++
    "\tAverage stack size (kbytes): %p\n" ++
    "\tAverage total size (kbytes): %K\n" ++
    "\tMaximum resident set size (kbytes): %M\n" ++
    "\tAverage resident set size (kbytes): %t\n" ++
    "\tMajor (requiring I/O) page faults: %F\n" ++
    "\tMinor (reclaiming a frame) page faults: %R\n" ++
    "\tVoluntary context switches: %w\n" ++
    "\tInvoluntary context switches: %c\n" ++
    "\tSwaps: %W\n" ++
    "\tFile system inputs: %I\n" ++
    "\tFile system outputs: %O\n" ++
    "\tSocket messages sent: %s\n" ++
    "\tSocket messages received: %r\n" ++
    "\tSignals delivered: %k\n" ++
    "\tPage size (bytes): %Z\n" ++
    "\tExit status: %x";

pub const Info = struct {
    argv: []const []const u8,
    m: Measurement,
    page_size: usize = 4096,
};

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e9;
}

/// Expand a GNU time format: `%` conversions as in the GNU manual, and the
/// backslash escapes `\n`, `\t` and `\\`. An unknown conversion or escape
/// prints `?` and the character, as GNU does. No trailing newline is written;
/// the result says whether the caller should add one (GNU does not after a
/// format that ends in a lone `%` or `\`).
pub fn writeFormat(w: *Io.Writer, fmt: []const u8, info: Info) Io.Writer.Error!bool {
    const m = info.m;
    const u = m.usage;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c == '\\') {
            i += 1;
            if (i >= fmt.len) {
                try w.writeAll("?\\");
                return false;
            }
            switch (fmt[i]) {
                'n' => try w.writeByte('\n'),
                't' => try w.writeByte('\t'),
                '\\' => try w.writeByte('\\'),
                else => |o| try w.print("?\\{c}", .{o}),
            }
        } else if (c == '%') {
            i += 1;
            if (i >= fmt.len) {
                try w.writeAll("?");
                return false;
            }
            switch (fmt[i]) {
                '%' => try w.writeByte('%'),
                'C' => for (info.argv, 0..) |a, k| {
                    if (k > 0) try w.writeByte(' ');
                    try w.writeAll(a);
                },
                'D', 'K', 'X', 'p', 't' => try w.writeByte('0'), // not reported by Linux
                'E' => try writeElapsed(w, m.wall_ns),
                'F' => try w.print("{d}", .{u.major_faults}),
                'I' => try w.print("{d}", .{u.in_blocks}),
                'M' => try w.print("{d}", .{u.max_rss_kb}),
                'O' => try w.print("{d}", .{u.out_blocks}),
                'P' => {
                    if (m.wall_ns == 0) {
                        try w.writeAll("?%");
                    } else {
                        const cpu = @as(u128, u.user_ns) + u.sys_ns;
                        try w.print("{d}%", .{cpu * 100 / m.wall_ns});
                    }
                },
                'R' => try w.print("{d}", .{u.minor_faults}),
                'S' => try w.print("{d:.2}", .{seconds(u.sys_ns)}),
                'U' => try w.print("{d:.2}", .{seconds(u.user_ns)}),
                'W' => try w.print("{d}", .{u.swaps}),
                'Z' => try w.print("{d}", .{info.page_size}),
                'c' => try w.print("{d}", .{u.invol_switches}),
                'e' => try w.print("{d:.2}", .{seconds(m.wall_ns)}),
                'k' => try w.print("{d}", .{u.signals}),
                'r' => try w.print("{d}", .{u.msgs_received}),
                's' => try w.print("{d}", .{u.msgs_sent}),
                'w' => try w.print("{d}", .{u.vol_switches}),
                'x' => try w.print("{d}", .{switch (m.result) {
                    .exited => |code| code,
                    else => 0,
                }}),
                else => |o| try w.print("?{c}", .{o}),
            }
        } else try w.writeByte(c);
    }
    return true;
}

/// `[h:]mm:ss.cc`, GNU's %E.
fn writeElapsed(w: *Io.Writer, ns: u64) Io.Writer.Error!void {
    const total = seconds(ns);
    const whole: u64 = @intFromFloat(total);
    const hours = whole / 3600;
    const mins = (whole % 3600) / 60;
    const secs = total - @as(f64, @floatFromInt(hours * 3600 + mins * 60));
    if (hours > 0) {
        try w.print("{d}:{d:0>2}:{d:0>5.2}", .{ hours, mins, secs });
    } else {
        try w.print("{d}:{d:0>5.2}", .{ mins, secs });
    }
}

/// The line GNU time prints before the summary when the command did not
/// succeed (and `quiet` is off); null for a clean exit.
pub fn writeAbnormal(w: *Io.Writer, m: Measurement) Io.Writer.Error!void {
    switch (m.result) {
        .exited => |c| if (c != 0) try w.print("Command exited with non-zero status {d}\n", .{c}),
        .signaled => |s| try w.print("Command terminated by signal {d}\n", .{s}),
        .none => {},
    }
}

// ---------------------------------------------------------------- statistics

pub const Unit = enum { nanoseconds, bytes, count };

pub const Summary = struct {
    n: usize = 0,
    mean: f64 = 0,
    stddev: f64 = 0,
    min: f64 = 0,
    max: f64 = 0,
    q1: f64 = 0,
    q3: f64 = 0,
    /// Samples outside Tukey's fences (1.5 x IQR beyond the quartiles).
    outliers: usize = 0,
    unit: Unit = .count,
};

/// Statistics of `samples`, computed as crap does (quartiles taken by index,
/// sample standard deviation). Sorts the samples in place.
pub fn summarize(samples: []f64, unit: Unit) Summary {
    if (samples.len == 0) return .{ .unit = unit };
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    var total: f64 = 0;
    for (samples) |s| total += s;
    const n: f64 = @floatFromInt(samples.len);
    const mean = total / n;
    var sq: f64 = 0;
    for (samples) |s| sq += (s - mean) * (s - mean);
    const stddev = if (samples.len > 1) @sqrt(sq / (n - 1)) else 0;
    const q1 = samples[samples.len / 4];
    const q3 = if (samples.len < 4) samples[samples.len - 1] else samples[samples.len - samples.len / 4];
    const iqr = q3 - q1;
    var out: usize = 0;
    for (samples) |s| {
        if (s < q1 - 1.5 * iqr or s > q3 + 1.5 * iqr) out += 1;
    }
    return .{
        .n = samples.len,
        .mean = mean,
        .stddev = stddev,
        .min = samples[0],
        .max = samples[samples.len - 1],
        .q1 = q1,
        .q3 = q3,
        .outliers = out,
        .unit = unit,
    };
}

// ---------------------------------------------------------------- benchmark

/// The rows of the report. The first, the memory row and the counters are
/// crap's; the CPU-time rows (hyperfine's "time" metrics) come from rusage.
pub const Metric = enum {
    wall_time,
    cpu_time,
    user_time,
    system_time,
    peak_rss,
    cpu_cycles,
    instructions,
    cache_references,
    cache_misses,
    branch_misses,

    pub const count = 10;
    const first_counter = 5;

    fn unit(m: Metric) Unit {
        return switch (m) {
            .wall_time, .cpu_time, .user_time, .system_time => .nanoseconds,
            .peak_rss => .bytes,
            else => .count,
        };
    }
};

/// Which rows to draw.
pub const Shown = [Metric.count]bool;

/// crap's rows: wall time and memory, plus the counters when the system
/// gave any.
pub const default_shown: Shown = .{ true, false, false, false, true, true, true, true, true, true };

/// Parse `--metrics`: a preset (`default`, `time`, `all`) or a comma list of
/// row names. hyperfine's names (`time_wall_clock`, `time_cpu`, `time_user`,
/// `time_system`, `memory_peak_resident`) are accepted too. Rows are always
/// drawn in the fixed order above. Null when a name is unknown.
pub fn parseMetrics(list: []const u8) ?Shown {
    if (std.mem.eql(u8, list, "default")) return default_shown;
    if (std.mem.eql(u8, list, "time")) return .{ true, true, true, true, false, false, false, false, false, false };
    if (std.mem.eql(u8, list, "all")) return @splat(true);
    const aliases = [_]struct { []const u8, Metric }{
        .{ "time_wall_clock", .wall_time },
        .{ "time_cpu", .cpu_time },
        .{ "time_user", .user_time },
        .{ "time_system", .system_time },
        .{ "memory_peak_resident", .peak_rss },
    };
    var out: Shown = @splat(false);
    var it = std.mem.splitScalar(u8, list, ',');
    outer: while (it.next()) |name| {
        for (aliases) |al| if (std.mem.eql(u8, name, al[0])) {
            out[@intFromEnum(al[1])] = true;
            continue :outer;
        };
        inline for (0..Metric.count) |k| {
            const m: Metric = @enumFromInt(k);
            if (std.mem.eql(u8, name, @tagName(m))) {
                out[k] = true;
                continue :outer;
            }
        }
        return null;
    }
    return out;
}

pub const min_samples = 3;
pub const max_samples = 10_000;

/// A command run around the measured ones (argv, already wrapped in a shell).
pub const Hook = []const []const u8;

pub const Hooks = struct {
    /// Once before the first run of a command.
    setup: ?Hook = null,
    /// Before every run, warm-ups included.
    prepare: ?Hook = null,
    /// After every run.
    conclude: ?Hook = null,
    /// Once after the last run (also after a failure).
    cleanup: ?Hook = null,
};

pub const BenchOptions = struct {
    /// Keep sampling until this much wall time has passed (and at least
    /// `min_runs` runs were made).
    duration_ns: u64 = 5 * std.time.ns_per_s,
    min_runs: usize = min_samples,
    max_runs: usize = max_samples,
    /// Run exactly this many times instead (overrides duration and the limits).
    runs: ?usize = null,
    /// Runs before sampling starts, not measured.
    warmup: u32 = 0,
    /// Compare commands that exit non-zero.
    allow_failures: bool = false,
    /// Count hardware events (rows are shown only when the system gave counts).
    perf: bool = false,
    hooks: Hooks = .{},
    /// Standard input of the command: a file opened fresh for every run, or
    /// the null device when empty.
    input_path: ?[]const u8 = null,
    /// Standard output of the command: discarded by default.
    stdout: StdIo = .ignore,
    environ_map: ?*const std.process.Environ.Map = null,
};

pub const BenchResult = struct {
    runs: usize = 0,
    metrics: [Metric.count]Summary = @splat(.{}),
    /// Raw samples in run order, per metric (seconds are derived by the
    /// exporters); empty slices when nothing was counted.
    samples: [Metric.count][]const f64 = @splat(&.{}),
    exit_codes: []const u8 = &.{},
    /// Median of the wall times, in nanoseconds.
    median_wall: f64 = 0,
};

/// Why `bench` stopped early.
pub const Failure = struct {
    /// Exit status of the failing run (error.CommandFailed or HookFailed).
    code: u8 = 0,
    /// What the failing run wrote to standard error.
    capture: Capture = .{},
    /// For error.HookFailed: which hook ("setup", "prepare", ...).
    hook: []const u8 = "",
};

pub const BenchError = error{ OutOfMemory, CommandFailed, Terminated, HookFailed } || std.process.SpawnError || Io.File.OpenError;

fn runHook(env: Env, hook: ?Hook, name: []const u8, opts: BenchOptions, fail: *Failure) BenchError!void {
    const argv = hook orelse return;
    const m = try run(env, argv, .{ .stdin = .ignore, .stdout = .ignore, .environ_map = opts.environ_map });
    switch (m.result) {
        .exited => |c| if (c == 0) return,
        else => {},
    }
    fail.code = m.exitStatus();
    fail.hook = name;
    return error.HookFailed;
}

/// Run `argv` repeatedly: setup, warm-ups, then samples with standard error
/// captured (shown by the caller on failure), then cleanup. `alloc` owns the
/// slices in the returned result.
pub fn bench(env: Env, alloc: std.mem.Allocator, argv: []const []const u8, opts: BenchOptions, fail: *Failure) BenchError!BenchResult {
    var samples: [Metric.count]std.ArrayList(f64) = @splat(.empty);
    defer for (&samples) |*s| s.deinit(env.gpa);
    var codes: std.ArrayList(u8) = .empty;
    defer codes.deinit(env.gpa);

    try runHook(env, opts.hooks.setup, "setup", opts, fail);
    defer if (opts.hooks.cleanup) |_| {
        var ignored: Failure = .{};
        runHook(env, opts.hooks.cleanup, "cleanup", opts, &ignored) catch {};
    };

    for (0..opts.warmup) |_| {
        try runHook(env, opts.hooks.prepare, "prepare", opts, fail);
        _ = try run(env, argv, .{ .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .environ_map = opts.environ_map });
        try runHook(env, opts.hooks.conclude, "conclude", opts, fail);
    }

    const start = nowNs(env.io);
    var n: usize = 0;
    while (true) : (n += 1) {
        if (opts.runs) |r| {
            if (n >= r) break;
        } else {
            const spent: u64 = @intCast(@max(nowNs(env.io) - start, 0));
            if ((n >= opts.min_runs and spent >= opts.duration_ns) or n >= opts.max_runs) break;
        }
        try runHook(env, opts.hooks.prepare, "prepare", opts, fail);
        var input: ?Io.File = null;
        defer if (input) |f| f.close(env.io);
        if (opts.input_path) |path| input = try Io.Dir.cwd().openFile(env.io, path, .{});
        const m = try run(env, argv, .{
            .stdin = if (input) |f| .{ .file = f } else .ignore,
            .stdout = opts.stdout,
            .stderr = .pipe,
            .capture = &fail.capture,
            .perf = opts.perf,
            .environ_map = opts.environ_map,
        });
        switch (m.result) {
            .exited => |c| if (c != 0 and !opts.allow_failures) {
                fail.code = c;
                return error.CommandFailed;
            },
            else => return error.Terminated,
        }
        try codes.append(env.gpa, m.exitStatus());
        const u = m.usage;
        try samples[@intFromEnum(Metric.wall_time)].append(env.gpa, @floatFromInt(m.wall_ns));
        try samples[@intFromEnum(Metric.cpu_time)].append(env.gpa, @floatFromInt(u.user_ns + u.sys_ns));
        try samples[@intFromEnum(Metric.user_time)].append(env.gpa, @floatFromInt(u.user_ns));
        try samples[@intFromEnum(Metric.system_time)].append(env.gpa, @floatFromInt(u.sys_ns));
        try samples[@intFromEnum(Metric.peak_rss)].append(env.gpa, @floatFromInt(u.max_rss_kb * 1024));
        for (m.perf, 0..) |maybe, k| {
            try samples[Metric.first_counter + k].append(env.gpa, @floatFromInt(maybe orelse 0));
        }
        try runHook(env, opts.hooks.conclude, "conclude", opts, fail);
    }
    var res: BenchResult = .{ .runs = n };
    res.exit_codes = try alloc.dupe(u8, codes.items);
    inline for (0..Metric.count) |k| {
        const metric: Metric = @enumFromInt(k);
        res.samples[k] = try alloc.dupe(f64, samples[k].items);
        res.metrics[k] = summarize(samples[k].items, metric.unit()); // sorts the scratch copy
        if (k == 0 and samples[k].items.len > 0) {
            const v = samples[k].items; // sorted now
            res.median_wall = if (v.len % 2 == 1) v[v.len / 2] else (v[v.len / 2 - 1] + v[v.len / 2]) / 2;
        }
    }
    return res;
}

// --------------------------------------------------------------- the report

const esc_reset = "\x1b[0m";
const esc_bold = "\x1b[1m";
const esc_dim = "\x1b[2m";
const esc_white = "\x1b[37m";
const esc_green = "\x1b[32m";
const esc_cyan = "\x1b[36m";
const esc_magenta = "\x1b[35m";
const esc_yellow = "\x1b[33m";
const esc_bright_green = "\x1b[92m";
const esc_bright_yellow = "\x1b[93m";
const esc_bright_red = "\x1b[91m";

fn sc(w: *Io.Writer, ansi: bool, code: []const u8) Io.Writer.Error!void {
    if (ansi) try w.writeAll(code);
}

/// A number with about three significant digits, right-aligned to 4 columns
/// (crap's rule).
fn num3(buf: []u8, num: f64) []const u8 {
    const r = if (num >= 1000 or @round(num) == num)
        std.fmt.bufPrint(buf, "{d: >4.0}", .{num})
    else if (num >= 100)
        std.fmt.bufPrint(buf, "{d: >4.0}", .{num})
    else if (num >= 10)
        std.fmt.bufPrint(buf, "{d: >3.1}", .{num})
    else
        std.fmt.bufPrint(buf, "{d: >3.2}", .{num});
    return r catch buf[0..0];
}

/// Value and two-column unit: `24.3ms`, `1.52MB`, `21.3M `. Always 6 columns
/// wide for values below 1000 of the next unit. Returns the columns used.
fn writeUnit(w: *Io.Writer, ansi: bool, x: f64, unit: Unit) Io.Writer.Error!usize {
    var val: f64 = x;
    var ustr: []const u8 = "  ";
    const steps = [_]struct { div: f64, c: []const u8, ns: []const u8, b: []const u8 }{
        .{ .div = 1e12, .c = "T ", .ns = "ks", .b = "TB" },
        .{ .div = 1e9, .c = "G ", .ns = "s ", .b = "GB" },
        .{ .div = 1e6, .c = "M ", .ns = "ms", .b = "MB" },
        .{ .div = 1e3, .c = "K ", .ns = "us", .b = "KB" },
    };
    var scaled = false;
    for (steps) |st| if (x >= st.div) {
        val = x / st.div;
        ustr = switch (unit) {
            .count => st.c,
            .nanoseconds => st.ns,
            .bytes => st.b,
        };
        scaled = true;
        break;
    };
    if (!scaled) ustr = switch (unit) {
        .count => "  ",
        .nanoseconds => "ns",
        .bytes => "  ",
    };
    var b: [32]u8 = undefined;
    const text = num3(&b, val);
    try w.writeAll(text);
    if (ansi) {
        try w.print("{s}{s}{s}{s}", .{ esc_dim, esc_white, ustr, esc_reset });
    } else try w.writeAll(ustr);
    return text.len + ustr.len;
}

/// Student's t for 95% confidence, as crap's tables give it (the z score
/// 1.96 beyond 120 degrees of freedom).
fn statScore95(df: u64) f64 {
    const t1to30 = [_]f64{
        12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
        2.201,  2.179, 2.16,  2.145, 2.131, 2.12,  2.11,  2.101, 2.093, 2.086,
        2.08,   2.074, 2.069, 2.064, 2.06,  2.056, 2.052, 2.045, 2.048, 2.042,
    };
    const t10s = [_]f64{ 2.228, 2.086, 2.042, 2.021, 2.009, 2, 1.994, 1.99, 1.987, 1.984, 1.982, 1.98 };
    if (df == 0) return t1to30[0];
    if (df <= 30) return t1to30[df - 1];
    if (df <= 120) return t10s[df / 10 - 1];
    return 1.96;
}

pub const Verdict = enum { better, worse, same };

pub const Delta = struct {
    /// Change of the mean against the first command, in percent.
    pct: f64,
    /// Half-width of the 95% interval of that change, in percent.
    half: f64,
    verdict: Verdict,
};

/// Compare `m` with the first command's `f` as crap does: pooled two-sample
/// t interval; significant only when the whole interval is beyond 1% on one
/// side.
pub fn delta(f: Summary, m: Summary) Delta {
    const n1: f64 = @floatFromInt(m.n);
    const n2: f64 = @floatFromInt(f.n);
    const z = statScore95(m.n + f.n -| 2);
    const normer = @sqrt(1.0 / n1 + 1.0 / n2);
    const numer1 = (n1 - 1) * (m.stddev * m.stddev);
    const numer2 = (n2 - 1) * (f.stddev * f.stddev);
    const df = n1 + n2 - 2;
    const sp = @sqrt((numer1 + numer2) / df);
    const half = (z * sp * normer) * 100 / f.mean;
    const diff = (m.mean - f.mean) * 100 / f.mean;
    const sig = (diff >= 1 and diff - half >= 1) or (diff <= -1 and diff + half <= -1);
    return .{
        .pct = diff,
        .half = half,
        .verdict = if (!sig) .same else if (m.mean > f.mean) .worse else .better,
    };
}

fn writeMeasurement(w: *Io.Writer, ansi: bool, m: Summary, name: []const u8, first: ?Summary, command_count: usize) Io.Writer.Error!void {
    // A CPU time of 0 is a measurement. A memory or counter row that is 0
    // throughout was not available (no permission, no such counter).
    if (m.n == 0 or (m.max == 0 and m.unit != .nanoseconds)) return;
    try w.print("  {s}", .{name});
    try w.splatByteAll(' ', 19 -| name.len);
    try sc(w, ansi, esc_bright_green);
    _ = try writeUnit(w, ansi, m.mean, m.unit);
    try sc(w, ansi, esc_reset);
    try w.writeAll(" ± ");
    try sc(w, ansi, esc_green);
    _ = try writeUnit(w, ansi, m.stddev, m.unit);
    try sc(w, ansi, esc_reset);
    try w.splatByteAll(' ', 4);
    try sc(w, ansi, esc_cyan);
    _ = try writeUnit(w, ansi, m.min, m.unit);
    try sc(w, ansi, esc_reset);
    try w.writeAll(" … ");
    try sc(w, ansi, esc_magenta);
    _ = try writeUnit(w, ansi, m.max, m.unit);
    try sc(w, ansi, esc_reset);
    try w.splatByteAll(' ', 7);

    const pct = @as(f64, @floatFromInt(m.outliers)) / @as(f64, @floatFromInt(m.n)) * 100;
    try sc(w, ansi, if (pct >= 10) esc_yellow else esc_dim);
    try w.print("{d: >4.0} ({d: >2.0}%)", .{ @as(f64, @floatFromInt(m.outliers)), pct });
    try sc(w, ansi, esc_reset);
    try w.splatByteAll(' ', 8);

    if (command_count > 1) {
        if (first) |f| {
            if (f.mean == 0) {
                // No base to compare with (a measurement that was 0 for the first command).
                try sc(w, ansi, esc_dim);
                try w.writeAll("   n/a");
                try sc(w, ansi, esc_reset);
                try w.writeAll("\n");
                return;
            }
            const d = delta(f, m);
            if (m.mean > f.mean) {
                if (d.verdict == .worse) {
                    try w.writeAll("💩");
                    try sc(w, ansi, esc_bright_red);
                } else {
                    try sc(w, ansi, esc_dim);
                    try w.writeAll("  ");
                }
                try w.writeAll("+");
            } else {
                if (d.verdict == .better) {
                    try sc(w, ansi, esc_bright_yellow);
                    try w.writeAll("⚡");
                    try sc(w, ansi, esc_bright_green);
                } else {
                    try sc(w, ansi, esc_dim);
                    try w.writeAll("  ");
                }
                try w.writeAll("-");
            }
            try w.print("{d: >5.1}% ± {d: >4.1}%", .{ @abs(d.pct), d.half });
        } else {
            try sc(w, ansi, esc_dim);
            try w.writeAll("0%");
        }
    }
    try sc(w, ansi, esc_reset);
    try w.writeAll("\n");
}

/// Draw one benchmark in crap's layout: a header line, the column titles
/// and a row per measurement that has data. `number` counts from 1; `first`
/// is the first benchmark's result (null for the first itself) and
/// `command_count` all commands, which switches the delta column on.
/// `ansi` turns on colour, bold and dim.
pub fn writeBenchmark(
    w: *Io.Writer,
    ansi: bool,
    number: usize,
    argv: []const []const u8,
    result: BenchResult,
    first: ?BenchResult,
    command_count: usize,
    shown: Shown,
) Io.Writer.Error!void {
    try sc(w, ansi, esc_bold);
    try w.print("Benchmark {d}", .{number});
    try sc(w, ansi, esc_dim);
    try w.print(" ({d} runs)", .{result.runs});
    try sc(w, ansi, esc_reset);
    try w.writeAll(":");
    for (argv) |a| try w.print(" {s}", .{a});
    try w.writeAll("\n");

    try sc(w, ansi, esc_bold);
    try w.writeAll("  measurement");
    try w.splatByteAll(' ', 23 - "  measurement".len);
    try sc(w, ansi, esc_bright_green);
    try w.writeAll("mean");
    try sc(w, ansi, esc_reset);
    try sc(w, ansi, esc_bold);
    try w.writeAll(" ± ");
    try sc(w, ansi, esc_green);
    try w.writeAll("σ");
    try sc(w, ansi, esc_reset);
    try sc(w, ansi, esc_bold);
    try w.splatByteAll(' ', 12);
    try sc(w, ansi, esc_cyan);
    try w.writeAll("min");
    try sc(w, ansi, esc_reset);
    try sc(w, ansi, esc_bold);
    try w.writeAll(" … ");
    try sc(w, ansi, esc_magenta);
    try w.writeAll("max");
    try sc(w, ansi, esc_reset);
    try sc(w, ansi, esc_bold);
    try w.splatByteAll(' ', 20 - " outliers".len);
    try sc(w, ansi, esc_bright_yellow);
    try w.writeAll("outliers");
    try sc(w, ansi, esc_reset);
    if (command_count >= 2) {
        try sc(w, ansi, esc_bold);
        try w.splatByteAll(' ', 9);
        try w.writeAll("delta");
        try sc(w, ansi, esc_reset);
    }
    try w.writeAll("\n");

    inline for (0..Metric.count) |k| {
        const metric: Metric = @enumFromInt(k);
        if (shown[k]) try writeMeasurement(w, ansi, result.metrics[k], @tagName(metric), if (first) |f| f.metrics[k] else null, command_count);
    }
}

// ------------------------------------------------------------- parameters

pub const Pair = struct { name: []const u8, value: []const u8 };
pub const Param = struct { name: []const u8, values: []const []const u8 };

/// `NAME=v1,v2,...` (a list of values for `{NAME}`).
pub fn parseParameterList(arena: std.mem.Allocator, spec: []const u8) error{ OutOfMemory, Invalid }!Param {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.Invalid;
    const name = spec[0..eq];
    if (name.len == 0) return error.Invalid;
    var values: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, spec[eq + 1 ..], ',');
    while (it.next()) |v| try values.append(arena, v);
    return .{ .name = name, .values = try values.toOwnedSlice(arena) };
}

/// `NAME:MIN:MAX[:STEP]`: numbers from MIN to MAX in steps (default 1),
/// integers unless one of the three has a fraction.
pub fn parseParameterScan(arena: std.mem.Allocator, spec: []const u8) error{ OutOfMemory, Invalid }!Param {
    var it = std.mem.splitScalar(u8, spec, ':');
    const name = it.next() orelse return error.Invalid;
    const lo_s = it.next() orelse return error.Invalid;
    const hi_s = it.next() orelse return error.Invalid;
    const step_s = it.next() orelse "1";
    if (name.len == 0 or it.next() != null) return error.Invalid;
    const lo = numparse.parseFloat(f64, lo_s) catch return error.Invalid;
    const hi = numparse.parseFloat(f64, hi_s) catch return error.Invalid;
    const step = numparse.parseFloat(f64, step_s) catch return error.Invalid;
    // Past 2^53 a float no longer counts in ones, and a step that does not
    // move the value would repeat it.
    const exact: f64 = 1 << 53;
    if (!(@abs(lo) <= exact and @abs(hi) <= exact)) return error.Invalid;
    if (!(step > 0 and step <= 2 * exact) or hi < lo or lo + step == lo) return error.Invalid;
    const frac = std.mem.indexOfScalar(u8, lo_s, '.') != null or std.mem.indexOfScalar(u8, hi_s, '.') != null or std.mem.indexOfScalar(u8, step_s, '.') != null;
    var values: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) : (i += 1) {
        const v = lo + @as(f64, @floatFromInt(i)) * step;
        if (v > hi + step * 1e-9) break;
        if (i >= 100_000) return error.Invalid;
        try values.append(arena, if (frac)
            try std.fmt.allocPrint(arena, "{d}", .{v})
        else
            try std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(v))}));
    }
    return .{ .name = name, .values = try values.toOwnedSlice(arena) };
}

/// Replace every `{NAME}` in `text` by its value.
pub fn substitute(arena: std.mem.Allocator, text: []const u8, pairs: []const Pair) error{OutOfMemory}![]const u8 {
    var cur = text;
    for (pairs) |p| {
        const key = try std.fmt.allocPrint(arena, "{{{s}}}", .{p.name});
        cur = try std.mem.replaceOwned(u8, arena, cur, key, p.value);
    }
    return cur;
}

pub const Expanded = struct {
    line: []const u8,
    pairs: []const Pair,
};

/// Every command line with every combination of parameter values (the first
/// parameter varies slowest). Without parameters the lines come back as they are.
pub fn expand(arena: std.mem.Allocator, lines: []const []const u8, params: []const Param) error{OutOfMemory}![]const Expanded {
    var out: std.ArrayList(Expanded) = .empty;
    const idx = try arena.alloc(usize, params.len);
    for (lines) |line| {
        @memset(idx, 0);
        var empty = false;
        for (params) |p| if (p.values.len == 0) {
            empty = true;
        };
        if (empty) continue;
        while (true) {
            const pairs = try arena.alloc(Pair, params.len);
            for (params, 0..) |p, k| pairs[k] = .{ .name = p.name, .value = p.values[idx[k]] };
            try out.append(arena, .{ .line = try substitute(arena, line, pairs), .pairs = pairs });
            // Odometer: the last parameter varies fastest.
            var k = params.len;
            while (k > 0) {
                k -= 1;
                idx[k] += 1;
                if (idx[k] < params[k].values.len) break;
                idx[k] = 0;
                if (k == 0) {
                    k = std.math.maxInt(usize);
                    break;
                }
            }
            if (params.len == 0 or k == std.math.maxInt(usize)) break;
        }
    }
    return out.toOwnedSlice(arena);
}

// ------------------------------------------------------------------- export

pub const ExportEntry = struct {
    command: []const u8,
    pairs: []const Pair,
    result: BenchResult,
};

fn toSecs(ns: f64) f64 {
    return ns / 1e9;
}

fn writeJsonString(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeJsonArray(w: *Io.Writer, items: []const f64, scale: f64) Io.Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{d}", .{v / scale});
    }
    try w.writeByte(']');
}

/// hyperfine-shaped JSON: `{"results": [...]}`, times in seconds, memory in
/// bytes, one object per command with its raw samples and exit codes.
pub fn writeJson(w: *Io.Writer, entries: []const ExportEntry) Io.Writer.Error!void {
    try w.writeAll("{\n  \"results\": [\n");
    for (entries, 0..) |e, i| {
        const r = e.result;
        const wall = r.metrics[@intFromEnum(Metric.wall_time)];
        try w.writeAll("    {\n      \"command\": ");
        try writeJsonString(w, e.command);
        try w.print(",\n      \"mean\": {d},\n      \"stddev\": {d},\n      \"median\": {d},\n", .{ toSecs(wall.mean), toSecs(wall.stddev), toSecs(r.median_wall) });
        try w.print("      \"user\": {d},\n      \"system\": {d},\n", .{ toSecs(r.metrics[@intFromEnum(Metric.user_time)].mean), toSecs(r.metrics[@intFromEnum(Metric.system_time)].mean) });
        try w.print("      \"min\": {d},\n      \"max\": {d},\n", .{ toSecs(wall.min), toSecs(wall.max) });
        try w.writeAll("      \"times\": ");
        try writeJsonArray(w, r.samples[@intFromEnum(Metric.wall_time)], 1e9);
        try w.writeAll(",\n      \"memory_usage_byte\": ");
        try writeJsonArray(w, r.samples[@intFromEnum(Metric.peak_rss)], 1);
        try w.writeAll(",\n      \"exit_codes\": [");
        for (r.exit_codes, 0..) |c, k| {
            if (k > 0) try w.writeAll(", ");
            try w.print("{d}", .{c});
        }
        try w.writeAll("]");
        if (e.pairs.len > 0) {
            try w.writeAll(",\n      \"parameters\": {");
            for (e.pairs, 0..) |p, k| {
                if (k > 0) try w.writeAll(", ");
                try writeJsonString(w, p.name);
                try w.writeAll(": ");
                try writeJsonString(w, p.value);
            }
            try w.writeAll("}");
        }
        try w.writeAll("\n    }");
        try w.writeAll(if (i + 1 < entries.len) ",\n" else "\n");
    }
    try w.writeAll("  ]\n}\n");
}

fn writeCsvField(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    if (std.mem.indexOfAny(u8, text, ",\"\n\r") == null) return w.writeAll(text);
    try w.writeByte('"');
    for (text) |c| {
        if (c == '"') try w.writeByte('"');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

/// CSV with hyperfine's columns (seconds): command, mean, stddev, median,
/// user, system, min, max, then one `parameter_NAME` column per parameter.
pub fn writeCsv(w: *Io.Writer, entries: []const ExportEntry) Io.Writer.Error!void {
    try w.writeAll("command,mean,stddev,median,user,system,min,max");
    if (entries.len > 0) for (entries[0].pairs) |p| {
        try w.writeAll(",parameter_");
        try writeCsvField(w, p.name);
    };
    try w.writeByte('\n');
    for (entries) |e| {
        const r = e.result;
        const wall = r.metrics[@intFromEnum(Metric.wall_time)];
        try writeCsvField(w, e.command);
        try w.print(",{d},{d},{d},{d},{d},{d},{d}", .{
            toSecs(wall.mean),                                       toSecs(wall.stddev),
            toSecs(r.median_wall),                                   toSecs(r.metrics[@intFromEnum(Metric.user_time)].mean),
            toSecs(r.metrics[@intFromEnum(Metric.system_time)].mean), toSecs(wall.min),
            toSecs(wall.max),
        });
        for (e.pairs) |p| {
            try w.writeByte(',');
            try writeCsvField(w, p.value);
        }
        try w.writeByte('\n');
    }
}

/// Split a command line into words: whitespace separates, single and double
/// quotes group, backslash escapes the next character outside single quotes.
/// Returns slices owned by `arena`.
pub fn splitCommand(arena: std.mem.Allocator, line: []const u8) error{ OutOfMemory, UnterminatedQuote }![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var have = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else if (c == '\\' and quote == '"' and i + 1 < line.len) {
                i += 1;
                try cur.append(arena, line[i]);
            } else try cur.append(arena, c);
        } else switch (c) {
            ' ', '\t', '\n' => if (have) {
                try words.append(arena, try cur.toOwnedSlice(arena));
                have = false;
            },
            '\'', '"' => {
                quote = c;
                have = true;
            },
            '\\' => if (i + 1 < line.len) {
                i += 1;
                try cur.append(arena, line[i]);
                have = true;
            },
            else => {
                try cur.append(arena, c);
                have = true;
            },
        }
    }
    if (quote != 0) return error.UnterminatedQuote;
    if (have) try words.append(arena, try cur.toOwnedSlice(arena));
    return words.toOwnedSlice(arena);
}

// -------------------------------------------------------------------- tests

fn fmtToString(fmt: []const u8, info: Info) ![]u8 {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer aw.deinit();
    _ = try writeFormat(&aw.writer, fmt, info);
    return aw.toOwnedSlice();
}

test "writeFormat: conversions, escapes and GNU's ? for unknown" {
    const argv = [_][]const u8{ "ls", "-l" };
    const info: Info = .{ .argv = &argv, .m = .{
        .wall_ns = 3_723_450_000_000, // 3723.45 s
        .usage = .{ .user_ns = 1_500_000_000, .sys_ns = 500_000_000, .max_rss_kb = 2048, .minor_faults = 7 },
        .result = .{ .exited = 3 },
    } };
    const s = try fmtToString("%C|%U|%S|%e|%E|%P|%M|%R|%x|%%|\\t|\\\\|%q|%", info);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("ls -l|1.50|0.50|3723.45|1:02:03.45|0%|2048|7|3|%|\t|\\|?q|?", s);
}

test "writeFormat: elapsed under an hour and percent" {
    const info: Info = .{ .argv = &.{"x"}, .m = .{
        .wall_ns = 61_230_000_000,
        .usage = .{ .user_ns = 30_000_000_000, .sys_ns = 0 },
    } };
    const s = try fmtToString("%E %P", info);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1:01.23 48%", s);
}

test "summarize: crap's statistics" {
    var data = [_]f64{ 10, 11, 12, 10, 11, 12, 11, 10, 100 };
    const s = summarize(&data, .count);
    try std.testing.expectEqual(@as(usize, 9), s.n);
    try std.testing.expectEqual(@as(usize, 1), s.outliers);
    try std.testing.expectEqual(@as(f64, 10), s.min);
    try std.testing.expectEqual(@as(f64, 100), s.max);
    try std.testing.expectEqual(@as(f64, 10), s.q1);
    try std.testing.expectEqual(@as(f64, 12), s.q3);
    try std.testing.expect(s.mean > 20 and s.mean < 21);
}

test "writeUnit: three significant digits and a two-column unit" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const cases = [_]struct { x: f64, u: Unit, want: []const u8 }{
        .{ .x = 24.3e6, .u = .nanoseconds, .want = "24.3ms" },
        .{ .x = 950, .u = .nanoseconds, .want = " 950ns" },
        .{ .x = 1.5e9, .u = .nanoseconds, .want = "1.50s " },
        .{ .x = 1.5 * 1e6, .u = .bytes, .want = "1.50MB" },
        .{ .x = 21.3e6, .u = .count, .want = "21.3M " },
        .{ .x = 812, .u = .count, .want = " 812  " },
    };
    for (cases) |c| {
        aw.clearRetainingCapacity();
        const n = try writeUnit(&aw.writer, false, c.x, c.u);
        try std.testing.expectEqualStrings(c.want, aw.written());
        try std.testing.expectEqual(@as(usize, 6), n);
    }
}

test "delta: significance needs the whole interval beyond 1%" {
    const base: Summary = .{ .n = 100, .mean = 100, .stddev = 5 };
    try std.testing.expectEqual(Verdict.same, delta(base, .{ .n = 100, .mean = 100.5, .stddev = 5 }).verdict);
    try std.testing.expectEqual(Verdict.better, delta(base, .{ .n = 100, .mean = 80, .stddev = 5 }).verdict);
    try std.testing.expectEqual(Verdict.worse, delta(base, .{ .n = 100, .mean = 120, .stddev = 5 }).verdict);
}

test "writeBenchmark: crap's column layout" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a: BenchResult = .{ .runs = 10 };
    a.metrics[0] = .{ .n = 10, .mean = 20.5e6, .stddev = 1.25e6, .min = 19.5e6, .max = 22.5e6, .outliers = 1, .unit = .nanoseconds };
    var b: BenchResult = .{ .runs = 8 };
    b.metrics[0] = .{ .n = 8, .mean = 10.5e6, .stddev = 0.5e6, .min = 9.5e6, .max = 11.5e6, .unit = .nanoseconds };
    try writeBenchmark(&aw.writer, false, 1, &.{ "slow", "x" }, a, null, 2, default_shown);
    try std.testing.expectEqualStrings(
        "Benchmark 1 (10 runs): slow x\n" ++
            "  measurement          mean ± σ            min … max           outliers         delta\n" ++
            "  wall_time          20.5ms ± 1.25ms    19.5ms … 22.5ms          1 (10%)        0%\n",
        aw.written(),
    );
    aw.clearRetainingCapacity();
    try writeBenchmark(&aw.writer, false, 2, &.{"fast"}, b, a, 2, default_shown);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "⚡-") != null);
    aw.clearRetainingCapacity();
    try writeBenchmark(&aw.writer, false, 1, &.{"only"}, a, null, 1, default_shown);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "delta") == null);
}

test "writeBenchmark: a time of 0 is shown, an unavailable counter is not" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var r: BenchResult = .{ .runs = 2 };
    r.metrics[@intFromEnum(Metric.user_time)] = .{ .n = 2, .unit = .nanoseconds };
    r.metrics[@intFromEnum(Metric.system_time)] = .{ .n = 2, .unit = .nanoseconds };
    r.metrics[@intFromEnum(Metric.peak_rss)] = .{ .n = 2, .unit = .bytes };
    r.metrics[@intFromEnum(Metric.instructions)] = .{ .n = 2, .unit = .count };
    const all: Shown = @splat(true);
    try writeBenchmark(&aw.writer, false, 1, &.{"x"}, r, null, 1, all);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\n  user_time ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n  system_time ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "peak_rss") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "instructions") == null);
    // Metrics without samples draw nothing.
    try std.testing.expect(std.mem.indexOf(u8, out, "wall_time") == null);
}

test "splitCommand: quotes and escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const w = try splitCommand(arena_state.allocator(), "sh -c 'echo  hi' \"a b\" c\\ d \"\"");
    try std.testing.expectEqual(@as(usize, 6), w.len);
    try std.testing.expectEqualStrings("echo  hi", w[2]);
    try std.testing.expectEqualStrings("a b", w[3]);
    try std.testing.expectEqualStrings("c d", w[4]);
    try std.testing.expectEqualStrings("", w[5]);
    try std.testing.expectError(error.UnterminatedQuote, splitCommand(arena_state.allocator(), "a 'b"));
}

test "parameters: lists, scans and expansion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const l = try parseParameterList(arena, "n=a,b");
    try std.testing.expectEqualStrings("n", l.name);
    try std.testing.expectEqual(@as(usize, 2), l.values.len);
    const sc_ = try parseParameterScan(arena, "t:1:3");
    try std.testing.expectEqual(@as(usize, 3), sc_.values.len);
    try std.testing.expectEqualStrings("3", sc_.values[2]);
    const sc2 = try parseParameterScan(arena, "x:0:1:0.5");
    try std.testing.expectEqual(@as(usize, 3), sc2.values.len);
    try std.testing.expectEqualStrings("0.5", sc2.values[1]);
    try std.testing.expectError(error.Invalid, parseParameterScan(arena, "x:3:1"));
    try std.testing.expectError(error.Invalid, parseParameterList(arena, "nope"));

    const ex = try expand(arena, &.{ "run {n} {t}", "other" }, &.{ l, sc_ });
    try std.testing.expectEqual(@as(usize, 12), ex.len);
    try std.testing.expectEqualStrings("run a 1", ex[0].line);
    try std.testing.expectEqualStrings("run a 2", ex[1].line);
    try std.testing.expectEqualStrings("run b 1", ex[3].line);
    const plain = try expand(arena, &.{"x"}, &.{});
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    try std.testing.expectEqualStrings("x", plain[0].line);
}

test "parseMetrics: presets, crap names and hyperfine names" {
    try std.testing.expect(parseMetrics("default").?[@intFromEnum(Metric.peak_rss)]);
    try std.testing.expect(parseMetrics("time").?[@intFromEnum(Metric.user_time)]);
    const m = parseMetrics("time_cpu,memory_peak_resident,instructions").?;
    try std.testing.expect(m[@intFromEnum(Metric.cpu_time)] and m[@intFromEnum(Metric.peak_rss)] and m[@intFromEnum(Metric.instructions)]);
    try std.testing.expect(!m[@intFromEnum(Metric.wall_time)]);
    try std.testing.expect(parseMetrics("bogus") == null);
}

test "export: JSON and CSV shapes" {
    var wall = [_]f64{ 1e9, 2e9 };
    var res: BenchResult = .{ .runs = 2, .exit_codes = &.{ 0, 0 }, .median_wall = 1.5e9 };
    res.metrics[0] = summarize(&wall, .nanoseconds);
    res.samples[0] = &.{ 1e9, 2e9 };
    const entry: ExportEntry = .{ .command = "echo \"a,b\"", .pairs = &.{.{ .name = "n", .value = "1" }}, .result = res };
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, &.{entry});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"command\": \"echo \\\"a,b\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"times\": [1, 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"parameters\": {\"n\": \"1\"}") != null);
    aw.clearRetainingCapacity();
    try writeCsv(&aw.writer, &.{entry});
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), "command,mean,stddev,median,user,system,min,max,parameter_n\n\"echo \"\"a,b\"\"\",1.5,"));
}
