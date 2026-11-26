// SPDX-License-Identifier: GPL-2.0-or-later
//! tail — output the last part of files.
//! References: GNU coreutils manual "tail invocation" (9.7); POSIX.1-2024 tail.
//!
//! Implemented: -n/-c with [+]NUM[suffix], -q, -v, -z, long options, the
//! obsolete `-NUM[bcl][f]` first-argument form, and -f/--follow=descriptor|name,
//! -F, --retry, -s, --pid for regular files (by polling). Not implemented (rejected
//! with an error): --max-unchanged-stats.
//!
//! Strategy: a regular file named on the command line is read backwards from
//! its end; other inputs (stdin, pipes) are streamed while holding only the
//! last N items in memory.

const std = @import("std");
const cli = @import("../cli.zig");
const count_arg = @import("../count_arg.zig");
const tail = @import("../lib/tail.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "bytes", "lines", "follow", "quiet", "silent", "verbose", "zero-terminated", "sleep-interval", "pid", "retry", "max-unchanged-stats", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var cfg: tail.Options = .{};
    var header: tail.Header = .auto;
    const args = ctx.args;
    var i: usize = 0;

    if (args.len > 0 and isObsolete(args[0])) {
        if (!parseObsolete(ctx, args[0], &cfg)) return 1;
        i = 1;
    }

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
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
            switch (k) {
                0, 1, 7, 8, 10 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                            return 1;
                        }
                        val = args[i];
                    }
                    switch (k) {
                        0, 1 => if (!setCount(ctx, &cfg, k == 0, val)) return 1,
                        7 => if (!setSleep(ctx, &cfg, val)) return 1,
                        8 => if (!setPid(ctx, &cfg, val)) return 1,
                        else => return unsupported(ctx, "--max-unchanged-stats"),
                    }
                },
                2 => {
                    cfg.follow = true;
                    if (eq) |e| {
                        const how = a[e + 1 ..];
                        if (how.len == 0 or !(std.mem.startsWith(u8, "descriptor", how) or std.mem.startsWith(u8, "name", how))) {
                            cli.warn(ctx, "invalid argument '{s}' for '--follow'\nValid arguments are:\n  - 'descriptor'\n  - 'name'\nTry '{s} --help' for more information.", .{ how, ctx.name });
                            return 1;
                        }
                        cfg.follow_name = std.mem.startsWith(u8, "name", how);
                    } else cfg.follow_name = false;
                },
                3, 4 => header = .never,
                5 => header = .always,
                6 => cfg.delimiter = 0,
                9 => cfg.retry = true,
                11 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'q' => header = .never,
            'v' => header = .always,
            'z' => cfg.delimiter = 0,
            'f' => {
                cfg.follow = true;
                cfg.follow_name = false;
            },
            'F' => {
                cfg.follow = true;
                cfg.follow_name = true;
                cfg.retry = true;
            },
            '0'...'9' => {
                // GNU: digits are only valid in the obsolete first-argument form.
                cli.warn(ctx, "option used in invalid context -- {c}", .{a[j]});
                return 1;
            },
            'c', 'n', 's' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                const ok = if (a[j] == 's') setSleep(ctx, &cfg, val) else setCount(ctx, &cfg, a[j] == 'c', val);
                if (!ok) return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    if (!cfg.follow) {
        if (cfg.retry) cli.warn(ctx, "warning: --retry ignored; --retry is useful only when following", .{});
        if (cfg.pid != null) cli.warn(ctx, "warning: PID ignored; --pid=PID is useful only when following", .{});
    } else if (cfg.retry and !cfg.follow_name) {
        cli.warn(ctx, "warning: --retry only effective for the initial open", .{});
    }
    if (cfg.follow and cfg.follow_name) for (inputs) |nm| if (std.mem.eql(u8, nm, "-")) {
        cli.warn(ctx, "cannot follow '-' by name", .{});
        return 1;
    };
    var lib_inputs: std.ArrayList(tail.Input) = .empty;
    defer lib_inputs.deinit(ctx.gpa);
    for (inputs) |path| {
        const in: tail.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        lib_inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    cfg.header = header;
    if (cfg.follow and isPipeOrSocket(ctx, Io.File.stdout())) cfg.output = Io.File.stdout();
    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: tail.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = tail.run(env, cfg, lib_inputs.items, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    if (result.reader_gone) {
        // End as the next write would have: by SIGPIPE, or silently with
        // status 1 should the signal not end us.
        _ = sys.raiseSelf(sys.signo.PIPE);
    }
    return if (result.failed) 1 else 0;
}

fn isPipeOrSocket(ctx: cli.Context, file: Io.File) bool {
    const st = file.stat(ctx.io) catch return false;
    return st.kind == .named_pipe or st.kind == .unix_domain_socket;
}

fn report(context: ?*anyopaque, ev: tail.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    const err_text = if (ev.err) |e| cli.errText(e) else "";
    switch (ev.kind) {
        .is_dir => cli.warn(ctx.*, "error reading '{s}': Is a directory", .{ev.name}),
        .open_failed => cli.warn(ctx.*, "cannot open '{s}' for reading: {s}", .{ ev.name, err_text }),
        .read_failed => cli.warn(ctx.*, "error reading '{s}': {s}", .{ ev.name, err_text }),
        .no_files_remaining => cli.warn(ctx.*, "no files remaining", .{}),
        .inaccessible_retry => cli.warn(ctx.*, "'{s}' has become inaccessible: {s}", .{ ev.name, ev.detail }),
        .inaccessible => cli.warn(ctx.*, "{s}: {s}", .{ ev.name, ev.detail }),
        .appeared => cli.warn(ctx.*, "'{s}' has appeared;  following new file", .{ev.name}),
        .replaced => cli.warn(ctx.*, "'{s}' has been replaced;  following new file", .{ev.name}),
        .truncated => cli.warn(ctx.*, "{s}: file truncated", .{ev.name}),
    }
}

/// Obsolete `-NUM[bcl][f]` as the first argument (GNU rejects other letters,
/// unlike head). `b` means 512-byte blocks and implies bytes.
fn isObsolete(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-' or !std.ascii.isDigit(a[1])) return false;
    var i: usize = 1;
    while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
    if (i < a.len and std.mem.indexOfScalar(u8, "bcl", a[i]) != null) i += 1;
    if (i < a.len and a[i] == 'f') i += 1;
    return i == a.len;
}

fn parseObsolete(ctx: cli.Context, a: []const u8, cfg: *tail.Options) bool {
    var i: usize = 1;
    while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
    var num = count_arg.parse(a[1..i]) orelse {
        cli.warn(ctx, "invalid number of lines: '{s}'", .{a[1..i]});
        return false;
    };
    cfg.from_start = false;
    if (i < a.len and a[i] != 'f') {
        switch (a[i]) {
            'b' => {
                num.value *|= 512;
                cfg.bytes = true;
            },
            'c' => cfg.bytes = true,
            else => cfg.bytes = false,
        }
    }
    cfg.count = num.value;
    if (a[a.len - 1] == 'f') cfg.follow = true;
    return true;
}

fn setCount(ctx: cli.Context, cfg: *tail.Options, bytes: bool, text: []const u8) bool {
    const c = count_arg.parse(text) orelse {
        cli.warn(ctx, "invalid number of {s}: '{s}'", .{ if (bytes) "bytes" else "lines", text });
        return false;
    };
    cfg.bytes = bytes;
    cfg.count = c.value;
    cfg.from_start = c.sign == .plus;
    return true;
}

fn setSleep(ctx: cli.Context, cfg: *tail.Options, text: []const u8) bool {
    const v = std.fmt.parseFloat(f64, text) catch -1;
    if (!(v >= 0)) {
        cli.warn(ctx, "invalid number of seconds: '{s}'", .{text});
        return false;
    }
    cfg.sleep_seconds = v;
    return true;
}

fn setPid(ctx: cli.Context, cfg: *tail.Options, text: []const u8) bool {
    const v = std.fmt.parseInt(i32, text, 10) catch -1;
    if (v < 0) {
        cli.warn(ctx, "invalid PID: '{s}'", .{text});
        return false;
    }
    cfg.pid = v;
    return true;
}

fn unsupported(ctx: cli.Context, what: []const u8) u8 {
    cli.warn(ctx, "{s} is not supported yet", .{what});
    return 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tail [OPTION]... [FILE]...\n" ++
        "Print the last 10 lines of each FILE to standard output.\n" ++
        "With more than one FILE, precede each with a header giving the file name.\n\n" ++
        "  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to\n" ++
        "                             output starting with byte NUM of each file\n" ++
        "  -f, --follow[=descriptor]  output appended data as the file grows\n" ++
        "  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;\n" ++
        "                             or use -n +NUM to skip NUM-1 lines at the start\n" ++
        "      --pid=PID            with -f, terminate after process ID, PID dies\n" ++
        "  -q, --quiet, --silent    never output headers giving file names\n" ++
        "  -s, --sleep-interval=N   with -f, sleep for approximately N seconds\n" ++
        "                             (default 1.0) between iterations\n" ++
        "  -v, --verbose            always output headers giving file names\n" ++
        "  -z, --zero-terminated    line delimiter is NUL, not newline\n" ++
        "      --help               display this help and exit\n" ++
        "      --version            output version information and exit\n")) 0 else 1;
}

test "isObsolete" {
    try std.testing.expect(isObsolete("-5"));
    try std.testing.expect(isObsolete("-5f"));
    try std.testing.expect(isObsolete("-5cf"));
    try std.testing.expect(!isObsolete("-5q"));
    try std.testing.expect(!isObsolete("-5k"));
    try std.testing.expect(!isObsolete("-f"));
    try std.testing.expect(!isObsolete("-5x"));
}
