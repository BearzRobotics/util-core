// SPDX-License-Identifier: GPL-2.0-or-later
//! xargs: thin wrapper over `util_core.xargs` (decision 0004). Parses the
//! arguments as GNU xargs does, words the diagnostics and the -t trace, asks
//! the -p question on /dev/tty, and exits with the library's status. The item
//! splitting, limits and process management are in src/lib/xargs.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const xargs = @import("../lib/xargs.zig");
const Io = std.Io;

const help_text = @embedFile("../help/xargs.txt");

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

fn parseNum(ctx: cli.Context, text: []const u8, opt: []const u8, min: i64, max: ?u64) ?u64 {
    const v = std.fmt.parseInt(i64, text, 10) catch |e| {
        if (e == error.Overflow and text.len > 0 and text[0] != '-') return std.math.maxInt(i64);
        cli.warn(ctx, "invalid number \"{s}\" for {s} option", .{ text, opt });
        return null;
    };
    if (v < min) {
        cli.warn(ctx, "value {d} for {s} option should be >= {d}", .{ v, opt, min });
        return null;
    }
    if (max) |m| if (@as(u64, @intCast(v)) > m) {
        cli.warn(ctx, "value {d} for {s} option should be <= {d}", .{ v, opt, m });
        return null;
    };
    return @intCast(v);
}

fn report(context: ?*anyopaque, ev: xargs.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .nul_in_input => cli.warn(ctx.*, "WARNING: a NUL character occurred in the input.  It cannot be passed through in the argument list.  Did you mean to use the --null option?", .{}),
        .unmatched_quote => |q| cli.warn(ctx.*, "unmatched {s} quote; by default quotes are special to xargs unless you use the -0 option", .{if (q.single) "single" else "double"}),
        .argument_line_too_long => cli.warn(ctx.*, "argument line too long", .{}),
        .cannot_fit_single_argument => cli.warn(ctx.*, "cannot fit single argument within argument list size limit", .{}),
        .argument_list_too_long => cli.warn(ctx.*, "argument list too long", .{}),
        .child_exited_255 => |name| cli.warn(ctx.*, "{s}: exited with status 255; aborting", .{name}),
        .child_signaled => |s| cli.warn(ctx.*, "{s}: terminated by signal {d}", .{ s.name, s.signal }),
        .wait_failed => |name| cli.warn(ctx.*, "{s}: wait failed", .{name}),
        .spawn_failed => |s| {
            const text: []const u8 = switch (s.err) {
                error.FileNotFound => "No such file or directory",
                error.AccessDenied, error.PermissionDenied => "Permission denied",
                error.InvalidExe => "Exec format error",
                error.IsDir => "Is a directory",
                error.NotDir => "Not a directory",
                else => @errorName(s.err),
            };
            cli.warn(ctx.*, "{s}: {s}", .{ s.name, text });
        },
        .trace => |line| {
            const gpa = ctx.gpa;
            const text = std.fmt.allocPrint(gpa, "{s}\n", .{line}) catch return;
            defer gpa.free(text);
            Io.File.stderr().writeStreamingAll(ctx.io, text) catch {};
        },
    }
}

/// -p: show the command and read y/Y from /dev/tty.
fn confirm(context: ?*anyopaque, line: []const u8) xargs.Answer {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    const gpa = ctx.gpa;
    const tty = Io.Dir.cwd().openFile(ctx.io, "/dev/tty", .{ .mode = .read_write }) catch {
        const text = std.fmt.allocPrint(gpa, "{s} ", .{line}) catch return .abort;
        defer gpa.free(text);
        Io.File.stderr().writeStreamingAll(ctx.io, text) catch {};
        cli.warn(ctx.*, "failed to open /dev/tty for reading: No such device or address", .{});
        return .abort;
    };
    defer tty.close(ctx.io);
    const text = std.fmt.allocPrint(gpa, "{s} ?...", .{line}) catch return .abort;
    defer gpa.free(text);
    tty.writeStreamingAll(ctx.io, text) catch {};
    var ans: [64]u8 = undefined;
    const n = cli.readChunk(ctx.io, tty, &ans) catch 0;
    return if (n > 0 and (ans[0] == 'y' or ans[0] == 'Y')) .yes else .no;
}

pub fn main(ctx: cli.Context) u8 {
    const env: xargs.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    var o: xargs.Options = .{};
    const limits = xargs.systemLimits(env);
    o.max_chars = limits.arg_max;

    var arg_file: ?[]const u8 = null;
    var show_limits = false;
    var p = getopt.Parser.init(ctx, "+0a:E:e::I:i::L:l::n:oprs:txP:d:", &.{
        .{ .name = "null", .id = '0' },
        .{ .name = "arg-file", .arg = .required, .id = 'a' },
        .{ .name = "delimiter", .arg = .required, .id = 'd' },
        .{ .name = "eof", .arg = .optional, .id = 'e' },
        .{ .name = "replace", .arg = .optional, .id = 'i' },
        .{ .name = "max-lines", .arg = .optional, .id = 'l' },
        .{ .name = "max-args", .arg = .required, .id = 'n' },
        .{ .name = "max-chars", .arg = .required, .id = 's' },
        .{ .name = "max-procs", .arg = .required, .id = 'P' },
        .{ .name = "interactive", .id = 'p' },
        .{ .name = "open-tty", .id = 'o' },
        .{ .name = "no-run-if-empty", .id = 'r' },
        .{ .name = "verbose", .id = 't' },
        .{ .name = "exit", .id = 'x' },
        .{ .name = "show-limits", .id = 1100 },
        .{ .name = "process-slot-var", .arg = .required, .id = 1101 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |opt| switch (opt.id) {
            '0' => {
                o.null_input = true;
                o.delimiter = null;
            },
            'a' => arg_file = opt.arg.?,
            'd' => {
                o.delimiter = xargs.parseDelimiter(opt.arg.?) orelse {
                    cli.warn(ctx, "Invalid input delimiter specification {s}: the delimiter must be either a single character or an escape sequence starting with \\.", .{opt.arg.?});
                    return 1;
                };
                o.null_input = false;
            },
            'E' => o.eof_str = if (opt.arg.?.len == 0) null else opt.arg.?,
            'e' => o.eof_str = if (opt.arg) |a| (if (a.len == 0) null else a) else null,
            'I', 'i' => {
                const r: []const u8 = if (opt.id == 'I') opt.arg.? else (opt.arg orelse "{}");
                if (o.max_args != 0) {
                    cli.warn(ctx, "warning: options --max-args and --replace/-I/-i are mutually exclusive, ignoring previous --max-args value", .{});
                    o.max_args = 0;
                }
                if (o.max_lines != 0) {
                    cli.warn(ctx, "warning: options --max-lines and --replace/-I/-i are mutually exclusive, ignoring previous --max-lines value", .{});
                    o.max_lines = 0;
                }
                o.replace = r;
            },
            'L', 'l' => {
                var n: u64 = 1;
                if (opt.id == 'L') {
                    n = parseNum(ctx, opt.arg.?, "-L", 1, null) orelse return usageFail(ctx);
                } else if (opt.arg) |a| n = parseNum(ctx, a, "-l", 1, null) orelse return usageFail(ctx);
                if (o.replace != null) {
                    cli.warn(ctx, "warning: options --replace and -L are mutually exclusive, ignoring previous --replace value", .{});
                    o.replace = null;
                }
                if (o.max_args != 0) {
                    cli.warn(ctx, "warning: options --max-args and -L are mutually exclusive, ignoring previous --max-args value", .{});
                    o.max_args = 0;
                }
                o.max_lines = n;
            },
            'n' => {
                const n = parseNum(ctx, opt.arg.?, "-n", 1, null) orelse return usageFail(ctx);
                if (o.replace != null) {
                    cli.warn(ctx, "warning: options --replace and --max-args/-n are mutually exclusive, ignoring previous --replace value", .{});
                    o.replace = null;
                }
                if (o.max_lines != 0) {
                    cli.warn(ctx, "warning: options --max-lines and --max-args/-n are mutually exclusive, ignoring previous --max-lines value", .{});
                    o.max_lines = 0;
                }
                o.max_args = n;
            },
            'P' => o.procs = parseNum(ctx, opt.arg.?, "-P", 0, null) orelse return usageFail(ctx),
            'p' => {
                o.confirm = .{ .context = @constCast(&ctx), .func = confirm };
                o.verbose = true;
            },
            'o' => o.open_tty = true,
            'r' => o.no_run_if_empty = true,
            's' => {
                const v = std.fmt.parseInt(i64, opt.arg.?, 10) catch {
                    cli.warn(ctx, "invalid number \"{s}\" for -s option", .{opt.arg.?});
                    return usageFail(ctx);
                };
                var n: usize = if (v < 0) 0 else @intCast(v);
                if (v < 1) {
                    cli.warn(ctx, "value {d} for -s option should be >= 1", .{v});
                    n = 1;
                } else if (n > limits.posix_limit) {
                    cli.warn(ctx, "value {d} for -s option should be <= {d}", .{ v, limits.posix_limit });
                    n = limits.posix_limit;
                }
                o.max_chars = n;
            },
            't' => o.verbose = true,
            'x' => o.exit_if_too_long = true,
            1100 => show_limits = true,
            1101 => o.slot_var = opt.arg.?,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => {
                return if (cli.writeStdout(ctx.io, "xargs (GNU findutils) 4.10.0\n")) 0 else 1;
            },
            else => unreachable,
        },
    };
    // The command and its initial arguments (the library defaults to echo).
    o.command = p.operands.items;

    if (show_limits) {
        var b: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&b, "Your environment variables take up {d} bytes\nPOSIX upper limit on argument length (this system): {d}\nPOSIX smallest allowable upper limit on argument length (all systems): 4096\nMaximum length of command we could actually use: {d}\nSize of command buffer we are actually using: {d}\nMaximum parallelism (--max-procs must be no greater): 2147483647\n", .{ limits.env_bytes, limits.posix_limit, limits.usable, o.max_chars.? }) catch "";
        Io.File.stderr().writeStreamingAll(ctx.io, text) catch {};
    }

    var input: Io.File = Io.File.stdin();
    var close_input = false;
    o.inherit_stdin = arg_file != null;
    // As in GNU, "-" names standard input.
    if (arg_file) |af| if (!std.mem.eql(u8, af, "-")) {
        input = Io.Dir.cwd().openFile(ctx.io, af, .{}) catch |e| {
            cli.warn(ctx, "Cannot open input file {f}: {s}", .{ cli.quoteA(af), cli.errText(e) });
            return 1;
        };
        close_input = true;
    };
    defer if (close_input) input.close(ctx.io);

    var rbuf: [8192]u8 = undefined;
    var reader = input.readerStreaming(ctx.io, &rbuf);
    const result = xargs.run(env, o, &reader.interface, .{ .context = @constCast(&ctx), .func = report }) catch {
        cli.warn(ctx, "out of memory", .{});
        return 1;
    };
    return result.status;
}
