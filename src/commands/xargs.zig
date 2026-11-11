// SPDX-License-Identifier: GPL-2.0-or-later
//! xargs — build and execute command lines from standard input.
//!
//! References, consulted 2026-11-07: POSIX.1-2024 xargs and the GNU findutils
//! 4.10 manual (xargs invocation), checked against the installed
//! `xargs (GNU findutils) 4.10.0`. Parallel runs (-P) wait for children in
//! the order they were started.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const quotearg = @import("../quotearg.zig");
const Io = std.Io;
const E = std.os.linux.E;

const help_text = @embedFile("../help/xargs.txt");

const X = struct {
    ctx: cli.Context,
    out: cli.Out,
    initial: std.ArrayList([]const u8) = .empty,
    items: std.ArrayList([]u8) = .empty,
    arena: std.heap.ArenaAllocator,
    max_args: u64 = 0,
    max_lines: u64 = 0,
    max_chars: usize = 0,
    arg_max: usize = 131072,
    posix_limit: usize = 0,
    env_bytes: usize = 0,
    replace: ?[]const u8 = null,
    eof_str: ?[]const u8 = null,
    null_input: bool = false,
    delimiter: ?u8 = null,
    no_run_if_empty: bool = false,
    verbose: bool = false,
    interactive: bool = false,
    open_tty: bool = false,
    exit_if_too_long: bool = false,
    procs: u64 = 1,
    slot_var: ?[]const u8 = null,
    lines_in_cmd: u64 = 0,
    bytes_in_cmd: usize = 0,
    exit_status: u8 = 0,
    running: std.ArrayList(Running) = .empty,
    next_slot: usize = 0,
    ran_any: bool = false,
    nul_warned: bool = false,
};

const Running = struct { child: std.process.Child, slot: usize };

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
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

fn envBytes(ctx: cli.Context) usize {
    var n: usize = 0;
    if (ctx.environ) |m| {
        var it = m.iterator();
        while (it.next()) |e| n += e.key_ptr.len + e.value_ptr.len + 2;
    }
    return n;
}

fn readStackLimit(ctx: cli.Context) usize {
    // The Zig runtime may raise this process's own stack limit, so look at the
    // parent's, which is what this process inherited.
    var pb: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/proc/{d}/limits", .{sys.parentPid()}) catch "/proc/self/limits";
    const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return 2097152;
    defer f.close(ctx.io);
    var buf: [4096]u8 = undefined;
    const n = cli.readChunk(ctx.io, f, &buf) catch return 2097152;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "Max stack size")) {
            var it = std.mem.tokenizeScalar(u8, l["Max stack size".len..], ' ');
            const soft = it.next() orelse return 2097152;
            if (std.mem.eql(u8, soft, "unlimited")) return 6 * 1024 * 1024;
            const v = std.fmt.parseInt(usize, soft, 10) catch return 2097152;
            return @max(v / 4, 131072);
        }
    }
    return 2097152;
}

fn waitOne(x: *X) void {
    if (x.running.items.len == 0) return;
    var r = x.running.orderedRemove(0);
    const name = x.initial.items[0];
    const term = r.child.wait(x.ctx.io) catch {
        cli.warn(x.ctx, "{s}: wait failed", .{name});
        x.exit_status = 124;
        return;
    };
    switch (term) {
        .exited => |c| {
            if (c == 255) {
                x.out.flush();
                cli.warn(x.ctx, "{s}: exited with status 255; aborting", .{name});
                finishAll(x);
                std.process.exit(124);
            }
            if (c != 0 and x.exit_status == 0) x.exit_status = 123;
            if (c != 0) x.exit_status = if (x.exit_status == 124 or x.exit_status == 125) x.exit_status else 123;
        },
        .signal => |s| {
            x.out.flush();
            cli.warn(x.ctx, "{s}: terminated by signal {d}", .{ name, @intFromEnum(s) });
            finishAll(x);
            std.process.exit(125);
        },
        else => {
            x.exit_status = 123;
        },
    }
}

fn finishAll(x: *X) void {
    while (x.running.items.len > 0) waitOne(x);
}

fn runCommand(x: *X) void {
    const ctx = x.ctx;
    if (x.items.items.len == 0 and x.replace != null) return;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |o| ctx.gpa.free(o);
        owned.deinit(ctx.gpa);
    }
    if (x.replace) |repl| {
        // Each initial argument has REPL replaced by the (single) item.
        const item: []const u8 = if (x.items.items.len > 0) x.items.items[0] else "";
        for (x.initial.items, 0..) |a, ai| {
            if (ai == 0 or std.mem.indexOf(u8, a, repl) == null) {
                argv.append(ctx.gpa, a) catch return;
                continue;
            }
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < a.len) {
                if (std.mem.startsWith(u8, a[i..], repl)) {
                    out.appendSlice(ctx.gpa, item) catch {};
                    i += repl.len;
                } else {
                    out.append(ctx.gpa, a[i]) catch {};
                    i += 1;
                }
            }
            const s = out.toOwnedSlice(ctx.gpa) catch return;
            owned.append(ctx.gpa, s) catch return;
            argv.append(ctx.gpa, cutNul(s)) catch return;
        }
    } else {
        argv.appendSlice(ctx.gpa, x.initial.items) catch return;
        for (x.items.items) |it| argv.append(ctx.gpa, cutNul(it)) catch return;
    }
    x.out.flush();
    if (x.verbose or x.interactive) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(ctx.gpa);
        for (argv.items, 0..) |a, i| {
            if (i > 0) line.append(ctx.gpa, ' ') catch {};
            quotearg.quote(&line, ctx.gpa, a, .shell_escape, null) catch {};
        }
        if (x.interactive) {
            const tty = Io.Dir.cwd().openFile(ctx.io, "/dev/tty", .{ .mode = .read_write }) catch {
                line.append(ctx.gpa, ' ') catch {};
                Io.File.stderr().writeStreamingAll(ctx.io, line.items) catch {};
                cli.warn(ctx, "failed to open /dev/tty for reading: No such device or address", .{});
                std.process.exit(1);
            };
            defer tty.close(ctx.io);
            line.appendSlice(ctx.gpa, " ?...") catch {};
            tty.writeStreamingAll(ctx.io, line.items) catch {};
            var ans: [64]u8 = undefined;
            const n = cli.readChunk(ctx.io, tty, &ans) catch 0;
            if (!(n > 0 and (ans[0] == 'y' or ans[0] == 'Y'))) {
                clearItems(x);
                return;
            }
        } else {
            line.append(ctx.gpa, '\n') catch {};
            Io.File.stderr().writeStreamingAll(ctx.io, line.items) catch {};
        }
    }
    // Keep at most `procs` children running.
    if (x.procs != 0) while (x.running.items.len >= x.procs) waitOne(x);

    var env_copy: ?std.process.Environ.Map = null;
    defer if (env_copy) |*m| m.deinit();
    var slot: usize = 0;
    if (x.slot_var) |sv| {
        if (ctx.environ) |m| {
            env_copy = m.clone(ctx.gpa) catch null;
            if (env_copy) |*ec| {
                slot = x.next_slot % @max(@as(usize, @intCast(@min(x.procs, 1 << 20))), 1);
                if (x.procs == 0) slot = x.next_slot;
                x.next_slot += 1;
                var nb: [24]u8 = undefined;
                ec.put(sv, std.fmt.bufPrint(&nb, "{d}", .{slot}) catch "0") catch {};
            }
        }
    }
    x.ran_any = true;
    var stdin_opt: std.process.SpawnOptions.StdIo = .ignore;
    var tty_file: ?Io.File = null;
    defer if (tty_file) |f| f.close(ctx.io);
    if (x.open_tty) {
        tty_file = Io.Dir.cwd().openFile(ctx.io, "/dev/tty", .{}) catch null;
        if (tty_file) |f| stdin_opt = .{ .file = f };
    }
    var child = std.process.spawn(ctx.io, .{
        .argv = argv.items,
        .stdin = stdin_opt,
        .environ_map = if (env_copy) |*m| m else null,
    }) catch |e| {
        const text: []const u8 = switch (e) {
            error.FileNotFound => "No such file or directory",
            error.AccessDenied, error.PermissionDenied => "Permission denied",
            error.InvalidExe => "Exec format error",
            error.IsDir => "Is a directory",
            error.NotDir => "Not a directory",
            else => @errorName(e),
        };
        cli.warn(ctx, "{s}: {s}", .{ argv.items[0], text });
        finishAll(x);
        std.process.exit(if (e == error.FileNotFound) 127 else 126);
    };
    x.running.append(ctx.gpa, .{ .child = child, .slot = slot }) catch {
        child.kill(ctx.io);
    };
    if (x.procs == 1) waitOne(x);
    clearItems(x);
}

fn cutNul(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, 0)) |i| s[0..i] else s;
}

fn clearItems(x: *X) void {
    for (x.items.items) |it| x.ctx.gpa.free(it);
    x.items.clearRetainingCapacity();
    x.lines_in_cmd = 0;
    x.bytes_in_cmd = 0;
}

fn initialBytes(x: *const X) usize {
    var n: usize = 0;
    for (x.initial.items) |a| n += a.len + 1;
    return n;
}

fn tooLong(x: *X) noreturn {
    x.out.flush();
    cli.warn(x.ctx, "cannot fit single argument within argument list size limit", .{});
    finishAll(x);
    std.process.exit(1);
}

/// Add one item (taking ownership); runs the command when a limit is hit.
fn addItem(x: *X, item: []u8) void {
    const ctx = x.ctx;
    const len = item.len + 1;
    const max_chars = x.max_chars;
    if (x.replace == null) {
        const base = initialBytes(x);
        if (base + x.bytes_in_cmd + len > max_chars) {
            if (x.items.items.len == 0) {
                if (base > max_chars) tooLong(x);
                x.out.flush();
                cli.warn(ctx, "argument line too long", .{});
                std.process.exit(1);
            }
            if (x.exit_if_too_long and (x.max_args != 0 or x.max_lines != 0)) {
                x.out.flush();
                cli.warn(ctx, "argument list too long", .{});
                finishAll(x);
                std.process.exit(1);
            }
            runCommand(x);
        }
    }
    x.items.append(ctx.gpa, item) catch return;
    x.bytes_in_cmd += len;
    if (x.replace != null) {
        runCommand(x);
    } else if (x.max_args != 0 and x.items.items.len >= x.max_args) {
        runCommand(x);
    }
}

fn endOfLine(x: *X) void {
    if (x.max_lines == 0 or x.replace != null) return;
    x.lines_in_cmd += 1;
    if (x.lines_in_cmd >= x.max_lines and x.items.items.len > 0) runCommand(x);
}

const Reader = struct {
    ctx: cli.Context,
    file: Io.File,
    buf: [8192]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    eof: bool = false,

    fn next(r: *Reader) ?u8 {
        if (r.pos >= r.len) {
            if (r.eof) return null;
            r.len = cli.readChunk(r.ctx.io, r.file, &r.buf) catch 0;
            r.pos = 0;
            if (r.len == 0) {
                r.eof = true;
                return null;
            }
        }
        const c = r.buf[r.pos];
        r.pos += 1;
        return c;
    }
};

fn processInput(x: *X, file: Io.File) void {
    const ctx = x.ctx;
    var rd: Reader = .{ .ctx = ctx, .file = file };
    var tok: std.ArrayList(u8) = .empty;
    defer tok.deinit(ctx.gpa);

    if (x.null_input or x.delimiter != null) {
        const d: u8 = x.delimiter orelse 0;
        var have = false;
        while (true) {
            const c = rd.next() orelse break;
            if (c == d) {
                have = false;
                finishToken(x, &tok, true);
            } else {
                have = true;
                tok.append(ctx.gpa, c) catch {};
            }
        }
        if (have) finishToken(x, &tok, true);
        return;
    }

    // Default mode: blanks and newlines separate items; quotes and
    // backslashes are special.
    const replace_mode = x.replace != null;
    var in_token = false;
    var line_has_item = false;
    var pending_continue = false;
    var quote: u8 = 0;
    var escaped = false;
    var stop = false;
    while (!stop) {
        const c_opt = rd.next();
        if (c_opt == null) {
            if (quote != 0) {
                if (x.items.items.len > 0 and x.max_lines == 0) runCommand(x);
                x.out.flush();
                cli.warn(ctx, "unmatched {s} quote; by default quotes are special to xargs unless you use the -0 option", .{if (quote == '\'') "single" else "double"});
                finishAll(x);
                std.process.exit(1);
            }
            if (in_token) {
                if (!finishDefault(x, &tok, &stop)) {}
                in_token = false;
                line_has_item = true;
            }
            if (line_has_item) endOfLine(x);
            break;
        }
        const c = c_opt.?;
        if (c == 0 and !x.nul_warned) {
            x.nul_warned = true;
            cli.warn(ctx, "WARNING: a NUL character occurred in the input.  It cannot be passed through in the argument list.  Did you mean to use the --null option?", .{});
        }
        if (escaped) {
            tok.append(ctx.gpa, c) catch {};
            in_token = true;
            escaped = false;
            continue;
        }
        if (quote != 0) {
            if (c == '\n') {
                if (x.items.items.len > 0 and x.max_lines == 0) runCommand(x);
                x.out.flush();
                cli.warn(ctx, "unmatched {s} quote; by default quotes are special to xargs unless you use the -0 option", .{if (quote == '\'') "single" else "double"});
                finishAll(x);
                std.process.exit(1);
            }
            if (c == quote) quote = 0 else tok.append(ctx.gpa, c) catch {};
            continue;
        }
        if (c == '\\') {
            escaped = true;
            in_token = true;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            in_token = true;
            continue;
        }
        if (c == '\n') {
            if (in_token) {
                if (finishDefault(x, &tok, &stop)) line_has_item = true;
                in_token = false;
            }
            if (stop) break;
            if (!pending_continue and line_has_item) {
                endOfLine(x);
                line_has_item = false;
            }
            pending_continue = false;
            continue;
        }
        if (isBlank(c) and !replace_mode) {
            if (in_token) {
                if (finishDefault(x, &tok, &stop)) line_has_item = true;
                in_token = false;
                if (stop) break;
            }
            pending_continue = true;
            continue;
        }
        if (isBlank(c) and replace_mode and !in_token) continue;
        pending_continue = false;
        tok.append(ctx.gpa, c) catch {};
        in_token = true;
    }
}

/// End of a token in default mode; handles the EOF string. Returns true when
/// an item was added.
fn finishDefault(x: *X, tok: *std.ArrayList(u8), stop: *bool) bool {
    if (x.eof_str) |e| {
        if (std.mem.eql(u8, tok.items, e)) {
            stop.* = true;
            tok.clearRetainingCapacity();
            return false;
        }
    }
    const item = x.ctx.gpa.dupe(u8, tok.items) catch return false;
    tok.clearRetainingCapacity();
    addItem(x, item);
    return true;
}

fn finishToken(x: *X, tok: *std.ArrayList(u8), count_line: bool) void {
    const item = x.ctx.gpa.dupe(u8, tok.items) catch return;
    tok.clearRetainingCapacity();
    addItem(x, item);
    if (count_line) endOfLine(x);
}

fn parseDelimiter(ctx: cli.Context, s: []const u8) ?u8 {
    if (s.len == 1) return s[0];
    if (s.len >= 2 and s[0] == '\\') {
        if (s.len == 2) switch (s[1]) {
            'a' => return 7,
            'b' => return 8,
            'f' => return 12,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'v' => return 11,
            '\\' => return '\\',
            '0' => return 0,
            else => {},
        };
        if (s[1] == 'x' and s.len > 2) {
            if (std.fmt.parseInt(u8, s[2..], 16)) |v| return v else |_| {}
        }
        if (std.fmt.parseInt(u8, s[1..], 8)) |v| return v else |_| {}
    }
    cli.warn(ctx, "Invalid input delimiter specification {s}: the delimiter must be either a single character or an escape sequence starting with \\.", .{s});
    return null;
}

pub fn main(ctx: cli.Context) u8 {
    var x: X = .{ .ctx = ctx, .out = cli.Out.init(ctx.io), .arena = std.heap.ArenaAllocator.init(ctx.gpa) };
    defer {
        x.arena.deinit();
        x.initial.deinit(ctx.gpa);
        for (x.items.items) |it| ctx.gpa.free(it);
        x.items.deinit(ctx.gpa);
        x.running.deinit(ctx.gpa);
    }
    x.env_bytes = envBytes(ctx);
    const sys_max = readStackLimit(ctx);
    x.posix_limit = if (sys_max > 2048 + x.env_bytes) sys_max - 2048 - x.env_bytes else 0;
    const usable = if (x.posix_limit > x.env_bytes) x.posix_limit - x.env_bytes else 0;
    x.arg_max = @min(usable, 131072);
    x.max_chars = x.arg_max;

    var arg_file: ?[]const u8 = null;
    var show_limits = false;
    var max_chars_set = false;
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
        .opt => |o| switch (o.id) {
            '0' => {
                x.null_input = true;
                x.delimiter = null;
            },
            'a' => arg_file = o.arg.?,
            'd' => {
                x.delimiter = parseDelimiter(ctx, o.arg.?) orelse return 1;
                x.null_input = false;
            },
            'E' => x.eof_str = if (o.arg.?.len == 0) null else o.arg.?,
            'e' => x.eof_str = if (o.arg) |a| (if (a.len == 0) null else a) else null,
            'I', 'i' => {
                const r: []const u8 = if (o.id == 'I') o.arg.? else (o.arg orelse "{}");
                if (x.max_args != 0) {
                    cli.warn(ctx, "warning: options --max-args and --replace/-I/-i are mutually exclusive, ignoring previous --max-args value", .{});
                    x.max_args = 0;
                }
                if (x.max_lines != 0) {
                    cli.warn(ctx, "warning: options --max-lines and --replace/-I/-i are mutually exclusive, ignoring previous --max-lines value", .{});
                    x.max_lines = 0;
                }
                x.replace = r;
            },
            'L', 'l' => {
                var n: u64 = 1;
                if (o.id == 'L') {
                    n = parseNum(ctx, o.arg.?, "-L", 1, null) orelse return usageFail(ctx);
                } else if (o.arg) |a| n = parseNum(ctx, a, "-l", 1, null) orelse return usageFail(ctx);
                if (x.replace != null) {
                    cli.warn(ctx, "warning: options --replace and -L are mutually exclusive, ignoring previous --replace value", .{});
                    x.replace = null;
                }
                if (x.max_args != 0) {
                    cli.warn(ctx, "warning: options --max-args and -L are mutually exclusive, ignoring previous --max-args value", .{});
                    x.max_args = 0;
                }
                x.max_lines = n;
            },
            'n' => {
                const n = parseNum(ctx, o.arg.?, "-n", 1, null) orelse return usageFail(ctx);
                if (x.replace != null) {
                    cli.warn(ctx, "warning: options --replace and --max-args/-n are mutually exclusive, ignoring previous --replace value", .{});
                    x.replace = null;
                }
                if (x.max_lines != 0) {
                    cli.warn(ctx, "warning: options --max-lines and --max-args/-n are mutually exclusive, ignoring previous --max-lines value", .{});
                    x.max_lines = 0;
                }
                x.max_args = n;
            },
            'P' => x.procs = parseNum(ctx, o.arg.?, "-P", 0, null) orelse return usageFail(ctx),
            'p' => {
                x.interactive = true;
                x.verbose = true;
            },
            'o' => x.open_tty = true,
            'r' => x.no_run_if_empty = true,
            's' => {
                const v = std.fmt.parseInt(i64, o.arg.?, 10) catch {
                    cli.warn(ctx, "invalid number \"{s}\" for -s option", .{o.arg.?});
                    return usageFail(ctx);
                };
                var n: usize = if (v < 0) 0 else @intCast(v);
                if (v < 1) {
                    cli.warn(ctx, "value {d} for -s option should be >= 1", .{v});
                    n = 1;
                } else if (n > x.posix_limit) {
                    cli.warn(ctx, "value {d} for -s option should be <= {d}", .{ v, x.posix_limit });
                    n = x.posix_limit;
                }
                x.max_chars = n;
                max_chars_set = true;
            },
            't' => x.verbose = true,
            'x' => x.exit_if_too_long = true,
            1100 => show_limits = true,
            1101 => x.slot_var = o.arg.?,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => {
                return if (cli.writeStdout(ctx.io, "xargs (GNU findutils) 4.10.0\n")) 0 else 1;
            },
            else => unreachable,
        },
    };
    // The command and its initial arguments.
    const cmd = p.operands.items;
    if (cmd.len == 0) {
        x.initial.append(ctx.gpa, "echo") catch return 1;
    } else for (cmd) |a| x.initial.append(ctx.gpa, a) catch return 1;

    if (show_limits) {
        var b: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&b, "Your environment variables take up {d} bytes\nPOSIX upper limit on argument length (this system): {d}\nPOSIX smallest allowable upper limit on argument length (all systems): 4096\nMaximum length of command we could actually use: {d}\nSize of command buffer we are actually using: {d}\nMaximum parallelism (--max-procs must be no greater): 2147483647\n", .{ x.env_bytes, x.posix_limit, usable, x.max_chars }) catch "";
        Io.File.stderr().writeStreamingAll(ctx.io, text) catch {};
    }

    var input: Io.File = Io.File.stdin();
    var close_input = false;
    if (arg_file) |af| {
        input = Io.Dir.cwd().openFile(ctx.io, af, .{}) catch |e| {
            cli.warn(ctx, "Cannot open input file {f}: {s}", .{ cli.quoteA(af), cli.errText(e) });
            return 1;
        };
        close_input = true;
    }
    defer if (close_input) input.close(ctx.io);

    processInput(&x, input);
    if (x.items.items.len > 0 or (!x.no_run_if_empty and !x.ran_any and x.replace == null)) {
        runCommand(&x);
    }
    finishAll(&x);
    x.out.flush();
    return x.exit_status;
}
