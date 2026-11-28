// SPDX-License-Identifier: GPL-2.0-or-later
//! du — estimate file space usage.
//! Thin wrapper over `util_core.du` (decision 0004): GNU's option parsing and
//! validation, the --files0-from / --exclude-from readers and the wording of
//! diagnostics are here; the walk, the accounting and the report (text and
//! --json) are in src/lib/du.zig.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "du invocation"
//! (9.7), POSIX.1-2024 du, and GNU coreutils 9.6 src/du.c and lib/exclude.c.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const human = @import("../human.zig");
const argmatch = @import("../argmatch.zig");
const du = @import("../lib/du.zig");
const Io = std.Io;

const help_text = @embedFile("../help/du.txt");

/// Words the library's events as GNU does.
const Report = struct {
    ctx: cli.Context,

    fn report(context: ?*anyopaque, ev: du.Event) void {
        const self: *Report = @ptrCast(@alignCast(context.?));
        const ctx = self.ctx;
        switch (ev) {
            .cannot_access => |e| if (e.errno) |errno|
                cli.warn(ctx, "cannot access {f}: {s}", .{ cli.quoteA(e.path), sys.errnoText(errno) })
            else
                cli.warn(ctx, "cannot access {f}", .{cli.quoteA(e.path)}),
            .circular => |path| cli.warn(ctx, "WARNING: Circular directory structure.\nThis almost certainly means that you have a corrupted file system.\nNOTIFY YOUR SYSTEM MANAGER.\nThe following directory is part of the cycle:\n  {f}", .{cli.quoteA(path)}),
            .cannot_read_dir => |e| cli.warn(ctx, "cannot read directory {f}: {s}", .{ cli.quoteA(e.path), sys.errnoText(e.errno) }),
        }
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn parseThreshold(arg: []const u8) struct { err: human.StrtolError, value: i64 } {
    var i: usize = 0;
    while (i < arg.len and isSpace(arg[i])) i += 1;
    var neg = false;
    var rest = arg;
    if (i < arg.len and arg[i] == '-') {
        neg = true;
        rest = arg[i + 1 ..];
    } else if (i < arg.len and arg[i] == '+') {
        rest = arg[i + 1 ..];
    }
    // A second sign is not a number.
    if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) return .{ .err = .invalid, .value = 0 };
    const r = human.strtoumax(rest, "kKmMGTPEZYRQ0");
    if (r.err == .invalid) return .{ .err = .invalid, .value = 0 };
    var err = r.err;
    var v: i64 = undefined;
    if (neg) {
        if (r.value > @as(u64, 1) << 63) {
            v = std.math.minInt(i64);
            err = if (err == .ok) .overflow else err;
        } else v = if (r.value == @as(u64, 1) << 63) std.math.minInt(i64) else -@as(i64, @intCast(r.value));
    } else {
        if (r.value > std.math.maxInt(i64)) {
            v = std.math.maxInt(i64);
            err = if (err == .ok) .overflow else err;
        } else v = @intCast(r.value);
    }
    return .{ .err = err, .value = v };
}

fn xstrtolFatal(ctx: cli.Context, e: human.StrtolError, o: getopt.Opt, long: []const u8, short: u8, arg: []const u8) void {
    var nb: [48]u8 = undefined;
    const name = if (o.is_long) (std.fmt.bufPrint(&nb, "--{s}", .{long}) catch long) else (std.fmt.bufPrint(&nb, "-{c}", .{short}) catch "-?");
    switch (e) {
        .invalid => cli.warn(ctx, "invalid {s} argument {f}", .{ name, cli.quoteC(arg) }),
        .invalid_suffix_char, .invalid_suffix_char_with_overflow => cli.warn(ctx, "invalid suffix in {s} argument {f}", .{ name, cli.quoteC(arg) }),
        .overflow => cli.warn(ctx, "{s} argument {f} too large", .{ name, cli.quoteC(arg) }),
        .ok => {},
    }
}

const time_args = [_]argmatch.Entry{
    .{ .name = "atime", .value = 2 }, .{ .name = "access", .value = 2 }, .{ .name = "use", .value = 2 },
    .{ .name = "ctime", .value = 1 }, .{ .name = "status", .value = 1 },
};
const time_style_args = [_]argmatch.Entry{
    .{ .name = "full-iso", .value = 0 }, .{ .name = "long-iso", .value = 1 }, .{ .name = "iso", .value = 2 },
};

/// The option state the parser fills in; becomes a `du.Options`.
const S = struct {
    ctx: cli.Context,
    opt_all: bool = false,
    apparent_size: bool = false,
    count_all: bool = false,
    hash_all: bool = false,
    nul_terminate: bool = false,
    print_grand_total: bool = false,
    separate_dirs: bool = false,
    max_depth: u64 = std.math.maxInt(u64),
    threshold: i64 = 0,
    human_opts: u32 = 0,
    block_size: u64 = 1024,
    inodes: bool = false,
    show_time: bool = false,
    time_type: du.TimeType = .mtime,
    time_format: []const u8 = "",
    deref: du.Deref = .physical,
    xdev: bool = false,
    json: bool = false,
    patterns: std.ArrayList([]const u8) = .empty,

    fn addPattern(s: *S, text: []const u8) void {
        const copy = s.ctx.gpa.dupe(u8, text) catch return;
        s.patterns.append(s.ctx.gpa, copy) catch s.ctx.gpa.free(copy);
    }

    fn options(s: *const S) du.Options {
        return .{
            .all = s.opt_all,
            .apparent_size = s.apparent_size,
            .count_links = s.count_all,
            .separate_dirs = s.separate_dirs,
            .max_depth = s.max_depth,
            .threshold = s.threshold,
            .human_opts = s.human_opts,
            .block_size = s.block_size,
            .inodes = s.inodes,
            .show_time = s.show_time,
            .time_type = s.time_type,
            .time_format = s.time_format,
            .deref = s.deref,
            .one_file_system = s.xdev,
            .grand_total = s.print_grand_total,
            .nul_terminate = s.nul_terminate,
            .hash_all = s.hash_all,
            .excludes = s.patterns.items,
            .json = s.json,
        };
    }
};

pub fn main(ctx: cli.Context) u8 {
    var s: S = .{ .ctx = ctx };
    defer {
        for (s.patterns.items) |p| ctx.gpa.free(p);
        s.patterns.deinit(ctx.gpa);
    }
    return realMain(&s);
}

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

fn realMain(s: *S) u8 {
    const ctx = s.ctx;
    var ok = true;
    var max_depth_specified = false;
    var unit_opt = false;
    var as_json = false;
    var depth_negative = false;
    var depth_text: u64 = 0;
    var summarize_only = false;
    var files_from: ?[]const u8 = null;
    var time_style: ?[]const u8 = null;
    var scratch: std.ArrayList([]u8) = .empty;
    defer {
        for (scratch.items) |x| ctx.gpa.free(x);
        scratch.deinit(ctx.gpa);
    }

    const env_bs = cli.getenv(ctx, "BLOCK_SIZE") orelse cli.getenv(ctx, "BLOCKSIZE");
    {
        const bs = human.options(cli.getenv(ctx, "DU_BLOCK_SIZE"), env_bs, cli.getenv(ctx, "POSIXLY_CORRECT") != null);
        s.human_opts = bs.opts;
        s.block_size = bs.size;
    }

    var p = getopt.Parser.init(ctx, "0abd:chHklmst:xB:DLPSX:", &.{
        .{ .name = "all", .id = 'a' },
        .{ .name = "apparent-size", .id = 1100 },
        .{ .name = "block-size", .arg = .required, .id = 'B' },
        .{ .name = "bytes", .id = 'b' },
        .{ .name = "count-links", .id = 'l' },
        .{ .name = "dereference", .id = 'L' },
        .{ .name = "dereference-args", .id = 'D' },
        .{ .name = "exclude", .arg = .required, .id = 1101 },
        .{ .name = "exclude-from", .arg = .required, .id = 'X' },
        .{ .name = "files0-from", .arg = .required, .id = 1102 },
        .{ .name = "human-readable", .id = 'h' },
        .{ .name = "inodes", .id = 1105 },
        .{ .name = "si", .id = 1103 },
        .{ .name = "max-depth", .arg = .required, .id = 'd' },
        .{ .name = "null", .id = '0' },
        .{ .name = "no-dereference", .id = 'P' },
        .{ .name = "one-file-system", .id = 'x' },
        .{ .name = "separate-dirs", .id = 'S' },
        .{ .name = "summarize", .id = 's' },
        .{ .name = "total", .id = 'c' },
        .{ .name = "threshold", .arg = .required, .id = 't' },
        .{ .name = "time", .arg = .optional, .id = 1104 },
        .{ .name = "time-style", .arg = .required, .id = 1106 },
        .{ .name = "json", .id = 1107 },
    });
    defer p.deinit();

    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            '0' => {
                s.nul_terminate = true;
                unit_opt = true;
            },
            'a' => s.opt_all = true,
            1100 => s.apparent_size = true,
            'b' => {
                s.apparent_size = true;
                s.human_opts = 0;
                s.block_size = 1;
            },
            'c' => s.print_grand_total = true,
            'h' => {
                unit_opt = true;
                s.human_opts = human.autoscale | human.si | human.base_1024;
                s.block_size = 1;
            },
            1103 => {
                unit_opt = true;
                s.human_opts = human.autoscale | human.si;
                s.block_size = 1;
            },
            'k' => {
                unit_opt = true;
                s.human_opts = 0;
                s.block_size = 1024;
            },
            'd' => {
                // xstrtoimax accepts negative numbers; such a depth shows
                // only the root (the root is always listed).
                const arg = o.arg.?;
                const trimmed = std.mem.trimStart(u8, arg, " \t\n\r\x0b\x0c");
                const neg = trimmed.len > 0 and trimmed[0] == '-';
                const r = human.strtoumax(if (neg) trimmed[1..] else arg, "");
                if (r.err == .ok and r.value <= std.math.maxInt(i64) and !(neg and trimmed.len > 1 and (trimmed[1] == '-' or trimmed[1] == '+'))) {
                    max_depth_specified = true;
                    depth_negative = neg and r.value != 0;
                    s.max_depth = if (neg) 0 else r.value;
                    depth_text = r.value;
                } else {
                    cli.warn(ctx, "invalid maximum depth {f}", .{cli.quoteC(arg)});
                    ok = false;
                }
            },
            'm' => {
                unit_opt = true;
                s.human_opts = 0;
                s.block_size = 1024 * 1024;
            },
            'l' => s.count_all = true,
            's' => summarize_only = true,
            't' => {
                const r = parseThreshold(o.arg.?);
                if (r.err != .ok) {
                    xstrtolFatal(ctx, r.err, o, "threshold", 't', o.arg.?);
                    return 1;
                }
                s.threshold = r.value;
                if (r.value == 0 and o.arg.?.len > 0 and o.arg.?[0] == '-') {
                    cli.warn(ctx, "invalid --threshold argument '-0'", .{});
                    return 1;
                }
            },
            'x' => s.xdev = true,
            'B' => {
                unit_opt = true;
                const bs = human.options(o.arg.?, null, false);
                if (bs.err != .ok) {
                    xstrtolFatal(ctx, bs.err, o, "block-size", 'B', o.arg.?);
                    return 1;
                }
                s.human_opts = bs.opts;
                s.block_size = bs.size;
            },
            'H', 'D' => s.deref = .comfollow,
            'L' => s.deref = .logical,
            'P' => s.deref = .physical,
            'S' => s.separate_dirs = true,
            'X' => {
                const from_stdin = std.mem.eql(u8, o.arg.?, "-");
                const f = if (from_stdin) Io.File.stdin() else Io.Dir.cwd().openFile(ctx.io, o.arg.?, .{}) catch |e| {
                    cli.warn(ctx, "{f}: {s}", .{ cli.quote(o.arg.?), cli.errText(e) });
                    ok = false;
                    continue;
                };
                defer if (!from_stdin) f.close(ctx.io);
                var data: std.ArrayList(u8) = .empty;
                defer data.deinit(ctx.gpa);
                // Patterns that were not read would silently count files they
                // exclude, so a failure here ends du.
                while (true) {
                    data.ensureUnusedCapacity(ctx.gpa, 8192) catch {
                        cli.warn(ctx, "memory exhausted", .{});
                        return 1;
                    };
                    const n = cli.readChunk(ctx.io, f, data.unusedCapacitySlice()) catch |e| {
                        cli.warn(ctx, "{f}: {s}\nTry '{s} --help' for more information.", .{ cli.quote(o.arg.?), cli.errText(e), ctx.name });
                        return 1;
                    };
                    if (n == 0) break;
                    data.items.len += n;
                }
                var start: usize = 0;
                var i: usize = 0;
                while (i < data.items.len) : (i += 1) {
                    if (data.items[i] == '\n') {
                        var end = i;
                        while (end > start and isSpace(data.items[end - 1])) end -= 1;
                        if (end > start) s.addPattern(data.items[start..end]);
                        start = i + 1;
                    }
                }
                if (start < data.items.len) {
                    var end = data.items.len;
                    while (end > start and isSpace(data.items[end - 1])) end -= 1;
                    if (end > start) s.addPattern(data.items[start..end]);
                }
            },
            1102 => files_from = o.arg.?,
            1101 => s.addPattern(o.arg.?),
            1105 => s.inodes = true,
            1104 => {
                s.show_time = true;
                s.time_type = .mtime;
                if (o.arg) |a| {
                    const v = argmatch.match(a, &time_args);
                    switch (v) {
                        .ok => |x| s.time_type = if (x == 2) .atime else .ctime,
                        else => {
                            argmatch.die(ctx, a, "--time", &time_args, v);
                            return 1;
                        },
                    }
                }
            },
            1106 => {
                time_style = o.arg.?;
                unit_opt = true;
            },
            1107 => as_json = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (!ok) return usageFail(ctx);
    if (as_json and unit_opt) {
        cli.warn(ctx, "--json cannot be combined with -h, --si, -k, -m, -B, -0 or --time-style", .{});
        return usageFail(ctx);
    }
    s.json = as_json;

    if (s.opt_all and summarize_only) {
        cli.warn(ctx, "cannot both summarize and show all entries", .{});
        return usageFail(ctx);
    }
    if (summarize_only and max_depth_specified and s.max_depth == 0 and !depth_negative) {
        cli.warn(ctx, "warning: summarizing is the same as using --max-depth=0", .{});
    }
    if (summarize_only and max_depth_specified and (s.max_depth != 0 or depth_negative)) {
        if (depth_negative) {
            cli.warn(ctx, "warning: summarizing conflicts with --max-depth=-{d}", .{depth_text});
        } else cli.warn(ctx, "warning: summarizing conflicts with --max-depth={d}", .{s.max_depth});
        return usageFail(ctx);
    }
    if (summarize_only) s.max_depth = 0;
    if (s.inodes) {
        if (s.apparent_size) cli.warn(ctx, "warning: options --apparent-size and -b are ineffective with --inodes", .{});
        s.block_size = 1;
    }

    if (s.show_time) {
        var style: []const u8 = undefined;
        if (time_style) |t| {
            style = t;
        } else {
            const env = cli.getenv(ctx, "TIME_STYLE");
            if (env == null or std.mem.eql(u8, env.?, "locale")) {
                style = "long-iso";
            } else if (env.?.len > 0 and env.?[0] == '+') {
                style = if (std.mem.indexOfScalar(u8, env.?, '\n')) |nl| env.?[0..nl] else env.?;
            } else {
                var t = env.?;
                while (std.mem.startsWith(u8, t, "posix-")) t = t["posix-".len..];
                style = t;
            }
        }
        if (style.len > 0 and style[0] == '+') {
            s.time_format = style[1..];
        } else {
            const v = argmatch.match(style, &time_style_args);
            switch (v) {
                .ok => |x| s.time_format = switch (x) {
                    0 => "%Y-%m-%d %H:%M:%S.%N %z",
                    1 => "%Y-%m-%d %H:%M",
                    else => "%Y-%m-%d",
                },
                else => {
                    argmatch.die(ctx, style, "time style", &time_style_args, v);
                    return 1;
                },
            }
        }
    }

    const operands = p.operands.items;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    var files0_data: ?[]u8 = null;
    defer if (files0_data) |d| ctx.gpa.free(d);
    if (files_from) |ff| {
        if (operands.len > 0) {
            cli.warn(ctx, "extra operand {f}", .{cli.quoteC(operands[0])});
            cli.writeStderr(ctx, "file operands cannot be combined with --files0-from", .{});
            return usageFail(ctx);
        }
        const f: Io.File = if (std.mem.eql(u8, ff, "-")) Io.File.stdin() else Io.Dir.cwd().openFile(ctx.io, ff, .{}) catch |e| {
            cli.warn(ctx, "cannot open {f} for reading: {s}", .{ cli.quoteA(ff), cli.errText(e) });
            return 1;
        };
        var data: std.ArrayList(u8) = .empty;
        while (true) {
            data.ensureUnusedCapacity(ctx.gpa, 8192) catch break;
            const n = cli.readChunk(ctx.io, f, data.unusedCapacitySlice()) catch {
                cli.warn(ctx, "{f}: read error", .{cli.quote(ff)});
                ok = false;
                break;
            };
            if (n == 0) break;
            data.items.len += n;
        }
        if (!std.mem.eql(u8, ff, "-")) f.close(ctx.io);
        files0_data = data.toOwnedSlice(ctx.gpa) catch null;
        s.hash_all = true;
    } else {
        s.hash_all = operands.len > 1 or s.deref == .logical;
    }

    var n_args: usize = 0;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(ctx.gpa);
    if (files0_data) |d| {
        var start: usize = 0;
        var i: usize = 0;
        while (i < d.len) : (i += 1) {
            if (d[i] == 0) {
                queue.append(ctx.gpa, d[start..i]) catch {};
                start = i + 1;
            }
        }
        if (start < d.len) queue.append(ctx.gpa, d[start..]) catch {};
    } else if (files_from == null) {
        if (operands.len == 0) {
            queue.append(ctx.gpa, ".") catch {};
        } else queue.appendSlice(ctx.gpa, operands) catch {};
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    var rep: Report = .{ .ctx = ctx };
    const env: du.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    var d = du.Du.init(env, s.options(), &stdout.interface, .{ .context = &rep, .func = Report.report });
    defer d.deinit();

    for (queue.items) |name| {
        n_args += 1;
        var skip = false;
        if (files_from != null and std.mem.eql(u8, files_from.?, "-") and std.mem.eql(u8, name, "-")) {
            cli.warn(ctx, "when reading file names from stdin, no file name of {f} allowed", .{cli.quoteA(name)});
            skip = true;
        }
        if (name.len == 0) {
            if (files_from == null) {
                cli.warn(ctx, "invalid zero-length file name", .{});
            } else cli.warn(ctx, "{f}:{d}: invalid zero-length file name", .{ cli.quote(files_from.?), n_args });
            skip = true;
        }
        if (skip) {
            ok = false;
            continue;
        }
        if (!d.walk(name)) ok = false;
    }

    d.finish() catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        return 1;
    };
    return if (ok) 0 else 1;
}
