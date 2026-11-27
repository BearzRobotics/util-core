// SPDX-License-Identifier: GPL-2.0-or-later
//! time — run a command and report the resources it used.
//! Reference: GNU time 1.9 (`/usr/bin/time`). Extension (decision 0005):
//! `--bench` repeats commands and prints a crap-style comparison, with
//! hyperfine-style hooks, parameters and export.
//!
//! The measuring and drawing are in src/lib/time.zig; this wrapper parses
//! arguments, words the diagnostics and chooses where the report goes.

const std = @import("std");
const numparse = @import("../numparse.zig");
const builtin = @import("builtin");
const Io = std.Io;
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const time = @import("../lib/time.zig");

const help_text = @embedFile("../help/time.txt");

const o_bench: u32 = 2000;
const o_duration: u32 = 2001;
const o_runs: u32 = 2002;
const o_allow: u32 = 2003;
const o_color: u32 = 2004;
const o_shell: u32 = 2005;
const o_warmup: u32 = 2006;
const o_min_runs: u32 = 2007;
const o_max_runs: u32 = 2008;
const o_setup: u32 = 2009;
const o_prepare: u32 = 2010;
const o_conclude: u32 = 2011;
const o_cleanup: u32 = 2012;
const o_export_json: u32 = 2013;
const o_export_csv: u32 = 2014;
const o_param_list: u32 = 2015;
const o_param_scan: u32 = 2016;
const o_input: u32 = 2017;
const o_output: u32 = 2018;
const o_env: u32 = 2019;
const o_metrics: u32 = 2020;

const longs = [_]getopt.Long{
    .{ .name = "append", .id = 'a' },
    .{ .name = "format", .arg = .required, .id = 'f' },
    .{ .name = "output", .arg = .required, .id = 'o' },
    .{ .name = "portability", .id = 'p' },
    .{ .name = "quiet", .id = 'q' },
    .{ .name = "verbose", .id = 'v' },
    .{ .name = "bench", .id = o_bench },
    .{ .name = "duration", .arg = .required, .id = o_duration },
    .{ .name = "runs", .arg = .required, .id = o_runs },
    .{ .name = "min-runs", .arg = .required, .id = o_min_runs },
    .{ .name = "max-runs", .arg = .required, .id = o_max_runs },
    .{ .name = "warmup", .arg = .required, .id = o_warmup },
    .{ .name = "allow-failures", .id = o_allow },
    .{ .name = "color", .arg = .required, .id = o_color },
    .{ .name = "shell", .arg = .required, .id = o_shell },
    .{ .name = "setup", .arg = .required, .id = o_setup },
    .{ .name = "prepare", .arg = .required, .id = o_prepare },
    .{ .name = "conclude", .arg = .required, .id = o_conclude },
    .{ .name = "cleanup", .arg = .required, .id = o_cleanup },
    .{ .name = "export-json", .arg = .required, .id = o_export_json },
    .{ .name = "export-csv", .arg = .required, .id = o_export_csv },
    .{ .name = "parameter-list", .arg = .required, .id = o_param_list },
    .{ .name = "parameter-scan", .arg = .required, .id = o_param_scan },
    .{ .name = "input", .arg = .required, .id = o_input },
    .{ .name = "bench-output", .arg = .required, .id = o_output },
    .{ .name = "env", .arg = .required, .id = o_env },
    .{ .name = "metrics", .arg = .required, .id = o_metrics },
};

const ColorMode = enum { auto, never, ansi };

const BenchSettings = struct {
    duration_ns: u64 = 5 * std.time.ns_per_s,
    runs: ?usize = null,
    min_runs: usize = time.min_samples,
    max_runs: usize = time.max_samples,
    warmup: u32 = 0,
    shell: ?[]const u8 = null,
    allow_failures: bool = false,
    color: ColorMode = .auto,
    setup: std.ArrayList([]const u8) = .empty,
    prepare: std.ArrayList([]const u8) = .empty,
    conclude: std.ArrayList([]const u8) = .empty,
    cleanup: std.ArrayList([]const u8) = .empty,
    export_json: ?[]const u8 = null,
    export_csv: ?[]const u8 = null,
    params: std.ArrayList(time.Param) = .empty,
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    env: ?[]const u8 = null,
    metrics: time.Shown = time.default_shown,
};

pub fn main(ctx: cli.Context) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var format: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var append = false;
    var quiet = false;
    var bench = false;
    var ext_used = false; // a benchmark-only option was given
    var st: BenchSettings = .{};

    var p = getopt.Parser.init(ctx, "+af:o:pqvhV", &longs);
    p.ext_min = o_bench;
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 125,
        .opt => |o| {
            if (o.id > o_bench) ext_used = true;
            switch (o.id) {
                'a' => append = true,
                'f' => format = o.arg.?,
                'o' => out_path = o.arg.?,
                'p' => format = time.portable_format,
                'v' => format = time.verbose_format,
                'q' => quiet = true,
                o_bench => bench = true,
                'h', getopt.help_id => return if (cli.writeStdout(ctx.io, help_text)) 0 else 125,
                'V', getopt.version_id => return if (cli.printVersion(ctx)) 0 else 125,
                o_duration => {
                    const ms = numparse.parseInt(u64, o.arg.?, 10) catch {
                        getopt.usageError(ctx, "invalid duration {f}: expected milliseconds", .{cli.quoteC(o.arg.?)});
                        return 125;
                    };
                    st.duration_ns = std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
                },
                o_runs, o_min_runs, o_max_runs => {
                    const n = numparse.parseInt(usize, o.arg.?, 10) catch 0;
                    if (n == 0) {
                        getopt.usageError(ctx, "invalid number of runs {f}", .{cli.quoteC(o.arg.?)});
                        return 125;
                    }
                    switch (o.id) {
                        o_runs => st.runs = n,
                        o_min_runs => st.min_runs = n,
                        else => st.max_runs = n,
                    }
                },
                o_warmup => st.warmup = numparse.parseInt(u32, o.arg.?, 10) catch {
                    getopt.usageError(ctx, "invalid warm-up count {f}", .{cli.quoteC(o.arg.?)});
                    return 125;
                },
                o_shell => st.shell = o.arg.?,
                o_allow => st.allow_failures = true,
                o_color => st.color = std.meta.stringToEnum(ColorMode, o.arg.?) orelse blk: {
                    if (std.mem.eql(u8, o.arg.?, "always")) break :blk .ansi;
                    getopt.usageError(ctx, "invalid argument {f} for '--color' (auto, never or ansi)", .{cli.quoteC(o.arg.?)});
                    return 125;
                },
                o_setup => st.setup.append(arena, o.arg.?) catch return oom(ctx),
                o_prepare => st.prepare.append(arena, o.arg.?) catch return oom(ctx),
                o_conclude => st.conclude.append(arena, o.arg.?) catch return oom(ctx),
                o_cleanup => st.cleanup.append(arena, o.arg.?) catch return oom(ctx),
                o_export_json => st.export_json = o.arg.?,
                o_export_csv => st.export_csv = o.arg.?,
                o_param_list => {
                    const par = time.parseParameterList(arena, o.arg.?) catch {
                        getopt.usageError(ctx, "invalid --parameter-list {f}: expected NAME=V1,V2,...", .{cli.quoteC(o.arg.?)});
                        return 125;
                    };
                    st.params.append(arena, par) catch return oom(ctx);
                },
                o_param_scan => {
                    const par = time.parseParameterScan(arena, o.arg.?) catch {
                        getopt.usageError(ctx, "invalid --parameter-scan {f}: expected NAME:MIN:MAX[:STEP]", .{cli.quoteC(o.arg.?)});
                        return 125;
                    };
                    st.params.append(arena, par) catch return oom(ctx);
                },
                o_input => st.input = o.arg.?,
                o_output => st.output = o.arg.?,
                o_env => st.env = o.arg.?,
                o_metrics => st.metrics = time.parseMetrics(o.arg.?) orelse {
                    getopt.usageError(ctx, "invalid --metrics {f} (a preset: default, time, all; or row names, see --help)", .{cli.quoteC(o.arg.?)});
                    return 125;
                },
                else => unreachable,
            }
        },
    };
    const ops = p.operands.items;
    if (ops.len == 0) {
        getopt.usageError(ctx, "missing program to run", .{});
        return 125;
    }
    const env: time.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    if (bench) {
        if (format != null or out_path != null or append or quiet) {
            getopt.usageError(ctx, "--bench cannot be combined with -a, -f, -o, -p, -q or -v", .{});
            return 125;
        }
        return runBench(ctx, env, arena, ops, &st);
    }
    if (ext_used) {
        getopt.usageError(ctx, "this option only works with --bench", .{});
        return 125;
    }

    const fmt = format orelse cli.getenv(ctx, "TIME") orelse time.default_format;
    return runOne(ctx, env, ops, fmt, out_path, append, quiet);
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 125;
}

fn spawnText(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied, error.IsDir => "Permission denied",
        error.InvalidExe => "Exec format error",
        error.NotDir => "Not a directory",
        else => @errorName(e),
    };
}

fn runOne(ctx: cli.Context, env: time.Env, command: []const []const u8, fmt: []const u8, out_path: ?[]const u8, append: bool, quiet: bool) u8 {
    // As GNU, the report file is opened first: when it cannot be, the command
    // is not run.
    var file: ?Io.File = null;
    defer if (file) |f| f.close(ctx.io);
    if (out_path) |path| {
        file = (if (append)
            sys.openAppend(path)
        else
            Io.Dir.cwd().createFile(ctx.io, path, .{})) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            return 125;
        };
    }
    var m: time.Measurement = time.run(env, command, .{}) catch |e| blk: {
        cli.warn(ctx, "cannot run {s}: {s}", .{ command[0], spawnText(e) });
        // GNU still prints the summary, with the shell's 127 / 126 status.
        break :blk .{ .result = .{ .exited = if (e == error.FileNotFound) 127 else 126 } };
    };
    // A command that was not even started used no time at all.
    if (m.result == .none) m.result = .{ .exited = 1 };

    var buf: [4096]u8 = undefined;
    var fw = (file orelse Io.File.stderr()).writerStreaming(ctx.io, &buf);
    const w = &fw.interface;
    const info: time.Info = .{ .argv = command, .m = m, .page_size = std.heap.pageSize() };
    const ok = blk: {
        if (!quiet) time.writeAbnormal(w, m) catch break :blk false;
        const newline = time.writeFormat(w, fmt, info) catch break :blk false;
        if (newline) w.writeByte('\n') catch break :blk false;
        w.flush() catch break :blk false;
        break :blk true;
    };
    if (!ok) {
        cli.warn(ctx, "cannot write the report: {s}", .{cli.errText(fw.err orelse error.WriteFailed)});
        return 125;
    }
    return m.exitStatus();
}

/// `shell -c CMD` (`/C` on Windows); `sh` / `cmd` when no --shell was given.
fn shellArgv(arena: std.mem.Allocator, shell: ?[]const u8, line: []const u8) error{OutOfMemory}![]const []const u8 {
    const sh = shell orelse if (builtin.os.tag == .windows) "cmd" else "sh";
    const a = try arena.alloc([]const u8, 3);
    a[0] = sh;
    a[1] = if (builtin.os.tag == .windows) "/C" else "-c";
    a[2] = line;
    return a;
}

/// The hook for command `i`: one value serves all commands, otherwise one each.
fn pickHook(arena: std.mem.Allocator, shell: ?[]const u8, values: []const []const u8, pairs: []const time.Pair, i: usize) error{OutOfMemory}!?time.Hook {
    if (values.len == 0) return null;
    const line = if (values.len == 1) values[0] else values[i];
    return try shellArgv(arena, shell, try time.substitute(arena, line, pairs));
}

fn runBench(ctx: cli.Context, env: time.Env, arena: std.mem.Allocator, operands: []const []const u8, st: *BenchSettings) u8 {
    const tty = Io.File.stdout().isTty(ctx.io) catch false;
    const ansi = switch (st.color) {
        .never => false,
        .ansi => true,
        .auto => cli.colorEnabled(ctx, .auto, tty),
    } and sys.enableAnsiOutput();

    const expanded = time.expand(arena, operands, st.params.items) catch return oom(ctx);
    if (expanded.len == 0) {
        cli.warn(ctx, "a parameter has no values", .{});
        return 125;
    }
    const hook_lists = [_]struct { []const u8, []const []const u8 }{
        .{ "--setup", st.setup.items },
        .{ "--prepare", st.prepare.items },
        .{ "--conclude", st.conclude.items },
        .{ "--cleanup", st.cleanup.items },
    };
    for (hook_lists) |h| {
        if (h[1].len > 1 and h[1].len != expanded.len) {
            cli.warn(ctx, "{s} was given {d} times but there are {d} commands to run (give it once, or once per command)", .{ h[0], h[1].len, expanded.len });
            return 125;
        }
    }

    // Environment: ours plus the --env assignments.
    var env_map: ?std.process.Environ.Map = null;
    defer if (env_map) |*m| m.deinit();
    if (st.env) |assignments| {
        env_map = (if (ctx.environ) |e| e.clone(ctx.gpa) else std.process.Environ.Map.init(ctx.gpa)) catch return oom(ctx);
        const words = time.splitCommand(arena, assignments) catch {
            cli.warn(ctx, "--env: unterminated quote", .{});
            return 125;
        };
        for (words) |wd| {
            const eq = std.mem.indexOfScalar(u8, wd, '=') orelse {
                cli.warn(ctx, "--env: expected NAME=VALUE, got {f}", .{cli.quoteC(wd)});
                return 125;
            };
            env_map.?.put(wd[0..eq], wd[eq + 1 ..]) catch return oom(ctx);
        }
    }

    // Standard output of the benchmarked commands.
    var out_file: ?Io.File = null;
    defer if (out_file) |f| f.close(ctx.io);
    var run_stdout: time.StdIo = .ignore;
    if (st.output) |o| {
        if (std.mem.eql(u8, o, "null")) {
            run_stdout = .ignore;
        } else if (std.mem.eql(u8, o, "inherit")) {
            run_stdout = .inherit;
        } else {
            out_file = Io.Dir.cwd().createFile(ctx.io, o, .{}) catch |e| {
                cli.warn(ctx, "{s}: {s}", .{ o, cli.errText(e) });
                return 125;
            };
            run_stdout = .{ .file = out_file.? };
        }
    }

    const perf = sys.Perf.probe();
    if (builtin.os.tag == .linux and !perf) {
        cli.warn(ctx, "note: hardware counters are not available here (perf_event_paranoid, a virtual machine, or no permission); showing the other measurements only", .{});
    }

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const w = &stdout.interface;

    var entries: std.ArrayList(time.ExportEntry) = .empty;
    var first: ?time.BenchResult = null;
    for (expanded, 0..) |ex, idx| {
        const number = idx + 1;
        const argv: []const []const u8 = if (st.shell) |sh|
            shellArgv(arena, sh, ex.line) catch return oom(ctx)
        else
            time.splitCommand(arena, ex.line) catch |e| {
                cli.warn(ctx, "{f}: {s}", .{ cli.quoteC(ex.line), if (e == error.UnterminatedQuote) "unterminated quote" else "out of memory" });
                return 125;
            };
        if (argv.len == 0) {
            cli.warn(ctx, "empty command", .{});
            return 125;
        }
        const hooks: time.Hooks = .{
            .setup = pickHook(arena, st.shell, st.setup.items, ex.pairs, idx) catch return oom(ctx),
            .prepare = pickHook(arena, st.shell, st.prepare.items, ex.pairs, idx) catch return oom(ctx),
            .conclude = pickHook(arena, st.shell, st.conclude.items, ex.pairs, idx) catch return oom(ctx),
            .cleanup = pickHook(arena, st.shell, st.cleanup.items, ex.pairs, idx) catch return oom(ctx),
        };
        var fail: time.Failure = .{};
        const res = time.bench(env, arena, argv, .{
            .duration_ns = st.duration_ns,
            .min_runs = st.min_runs,
            .max_runs = st.max_runs,
            .runs = st.runs,
            .warmup = st.warmup,
            .allow_failures = st.allow_failures,
            .perf = perf,
            .hooks = hooks,
            .input_path = st.input,
            .stdout = run_stdout,
            .environ_map = if (env_map) |*m| m else null,
        }, &fail) catch |e| switch (e) {
            error.CommandFailed => {
                const cap = fail.capture.text();
                const head = if (fail.capture.truncated)
                    "────────────── truncated stderr ──────────────"
                else
                    "─────────────────── stderr ───────────────────";
                cli.writeStderr(ctx, "\nerror: Benchmark {d} command '{s}' failed with exit code {d}:\n{s}\n{s}\n──────────────────────────────────────────────", .{ number, ex.line, fail.code, head, cap });
                return 1;
            },
            error.HookFailed => {
                cli.warn(ctx, "the {s} command of benchmark {d} failed with exit code {d}", .{ fail.hook, number, fail.code });
                return 1;
            },
            error.Terminated => {
                cli.warn(ctx, "terminated unexpectedly: {s}", .{ex.line});
                return 1;
            },
            error.OutOfMemory => return oom(ctx),
            else => {
                cli.warn(ctx, "cannot run {s}: {s}", .{ argv[0], spawnText(e) });
                return if (e == error.FileNotFound) 127 else 126;
            },
        };
        time.writeBenchmark(w, ansi, number, argv, res, first, expanded.len, st.metrics) catch return writeFailed(&stdout);
        w.flush() catch return writeFailed(&stdout);
        if (first == null) first = res;
        entries.append(arena, .{ .command = ex.line, .pairs = ex.pairs, .result = res }) catch return oom(ctx);
    }

    if (st.export_json) |path| if (!exportTo(ctx, path, entries.items, .json)) return 1;
    if (st.export_csv) |path| if (!exportTo(ctx, path, entries.items, .csv)) return 1;
    return 0;
}

const ExportKind = enum { json, csv };

fn exportTo(ctx: cli.Context, path: []const u8, entries: []const time.ExportEntry, kind: ExportKind) bool {
    const f = Io.Dir.cwd().createFile(ctx.io, path, .{}) catch |e| {
        cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
        return false;
    };
    defer f.close(ctx.io);
    var buf: [4096]u8 = undefined;
    var fw = f.writerStreaming(ctx.io, &buf);
    const w = &fw.interface;
    (switch (kind) {
        .json => time.writeJson(w, entries),
        .csv => time.writeCsv(w, entries),
    }) catch {
        cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(fw.err orelse error.WriteFailed) });
        return false;
    };
    w.flush() catch {
        cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(fw.err orelse error.WriteFailed) });
        return false;
    };
    return true;
}

fn writeFailed(fw: *Io.File.Writer) u8 {
    cli.noteStdoutFailure(cli.errText(fw.err orelse error.WriteFailed));
    return 125;
}
