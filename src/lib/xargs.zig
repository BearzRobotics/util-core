// SPDX-License-Identifier: GPL-2.0-or-later
//! xargs library: build and execute command lines from a stream of items.
//! Reference: POSIX.1-2024 xargs and the GNU findutils 4.10 manual (xargs
//! invocation), checked against `xargs (GNU findutils) 4.10.0`. Parallel runs
//! (-P) wait for children in the order they were started.
//!
//! The library reads items from a caller-supplied `*Io.Reader`, spawns the
//! commands through `Env.io`, and reports every diagnostic and the `-t` trace
//! through the `Observer`. The conditions GNU xargs exits on (a child that
//! exited 255, was killed by a signal, a command that could not be started,
//! an argument that does not fit, an unmatched quote) end the run and come
//! back as `Result.status` (124, 125, 126/127, 1) after the running children
//! have been waited for, exactly as the executable exits.

const std = @import("std");
const programpath = @import("../programpath.zig");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");
const quotearg = @import("../quotearg.zig");

pub const Env = common.Env;

pub const Event = union(enum) {
    /// A NUL byte in the input in the default (non -0) mode; reported once.
    nul_in_input,
    unmatched_quote: struct { single: bool },
    /// "argument line too long".
    argument_line_too_long,
    /// "cannot fit single argument within argument list size limit".
    cannot_fit_single_argument,
    /// "argument list too long" (-x).
    argument_list_too_long,
    /// A child exited with status 255; the run aborts with status 124.
    child_exited_255: []const u8,
    /// A child was killed by a signal; the run aborts with status 125.
    child_signaled: struct { name: []const u8, signal: u32 },
    wait_failed: []const u8,
    /// The command could not be started; the run aborts with 127 (not found)
    /// or 126.
    spawn_failed: struct { name: []const u8, err: anyerror },
    /// -I with an empty replacement string and an argument that is not empty:
    /// the string is found at the same place forever, so the command grows
    /// without end. GNU's "command too long".
    command_too_long,
    /// -t: the command line about to run, shell-quoted, without newline.
    trace: []const u8,
};
pub const Observer = common.Observer(Event);

/// Answer to the -p confirmation.
pub const Answer = enum { yes, no, abort };

/// -p: asked with the quoted command line before each run. `abort` ends the
/// run at once with status 1 (children are not waited for).
pub const Confirm = struct {
    context: ?*anyopaque = null,
    func: *const fn (context: ?*anyopaque, line: []const u8) Answer,
};

pub const Options = struct {
    /// The command and its initial arguments (`echo` when empty).
    command: []const []const u8 = &.{},
    max_args: u64 = 0,
    max_lines: u64 = 0,
    /// Null: the system default (`systemLimits(env).arg_max`).
    max_chars: ?usize = null,
    replace: ?[]const u8 = null,
    eof_str: ?[]const u8 = null,
    null_input: bool = false,
    delimiter: ?u8 = null,
    no_run_if_empty: bool = false,
    /// -t: emit a `trace` event per command (not when `confirm` is set).
    verbose: bool = false,
    confirm: ?Confirm = null,
    /// -o: children read from /dev/tty.
    open_tty: bool = false,
    /// The items do not come from standard input (-a), so the commands get
    /// it; otherwise their standard input is /dev/null.
    inherit_stdin: bool = false,
    exit_if_too_long: bool = false,
    /// -P; 0 is unlimited.
    procs: u64 = 1,
    slot_var: ?[]const u8 = null,
};

pub const Result = struct {
    /// What the executable exits with.
    status: u8 = 0,
};

/// What GNU xargs derives from the environment and the stack limit.
pub const Limits = struct {
    env_bytes: usize,
    /// POSIX upper limit on argument length.
    posix_limit: usize,
    usable: usize,
    /// Default command-line size (capped at 128 KiB as GNU does).
    arg_max: usize,
};

pub fn systemLimits(env: Env) Limits {
    const env_bytes = envBytes(env);
    const sys_max = readStackLimit(env);
    const posix_limit = if (sys_max > 2048 + env_bytes) sys_max - 2048 - env_bytes else 0;
    const usable = if (posix_limit > env_bytes) posix_limit - env_bytes else 0;
    return .{ .env_bytes = env_bytes, .posix_limit = posix_limit, .usable = usable, .arg_max = @min(usable, 131072) };
}

pub fn envBytes(env: Env) usize {
    var n: usize = 0;
    if (env.environ) |m| {
        var it = m.iterator();
        while (it.next()) |e| n += e.key_ptr.len + e.value_ptr.len + 2;
    }
    return n;
}

fn readStackLimit(env: Env) usize {
    // The Zig runtime may raise this process's own stack limit, so look at the
    // parent's, which is what this process inherited.
    var pb: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "/proc/{d}/limits", .{sys.parentPid()}) catch "/proc/self/limits";
    const f = Io.Dir.cwd().openFile(env.io, path, .{}) catch return 2097152;
    defer f.close(env.io);
    var buf: [4096]u8 = undefined;
    const n = common.readChunk(env.io, f, &buf) catch return 2097152;
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

/// The byte for a `-d` argument: one character or an escape sequence starting
/// with a backslash; null when it is neither.
pub fn parseDelimiter(s: []const u8) ?u8 {
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
    return null;
}

const Running = struct { child: std.process.Child, slot: usize };

/// Internal control flow: `Abort` ends the run with `X.abort_status`.
const Stop = error{ OutOfMemory, Abort };

const X = struct {
    env: Env,
    opt: Options,
    observer: Observer,
    initial: []const []const u8,
    items: std.ArrayList([]u8) = .empty,
    max_chars: usize,
    lines_in_cmd: u64 = 0,
    bytes_in_cmd: usize = 0,
    exit_status: u8 = 0,
    abort_status: u8 = 0,
    running: std.ArrayList(Running) = .empty,
    next_slot: usize = 0,
    ran_any: bool = false,
    nul_warned: bool = false,

    fn abort(x: *X, status: u8) Stop {
        x.abort_status = status;
        return error.Abort;
    }
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn waitOne(x: *X) Stop!void {
    if (x.running.items.len == 0) return;
    var r = x.running.orderedRemove(0);
    const name = x.initial[0];
    const term = r.child.wait(x.env.io) catch {
        x.observer.emit(.{ .wait_failed = name });
        x.exit_status = 124;
        return;
    };
    switch (term) {
        .exited => |c| {
            if (c == 255) {
                x.observer.emit(.{ .child_exited_255 = name });
                try finishAll(x);
                return x.abort(124);
            }
            if (c != 0 and x.exit_status == 0) x.exit_status = 123;
            if (c != 0) x.exit_status = if (x.exit_status == 124 or x.exit_status == 125) x.exit_status else 123;
        },
        .signal => |s| {
            x.observer.emit(.{ .child_signaled = .{ .name = name, .signal = @intFromEnum(s) } });
            try finishAll(x);
            return x.abort(125);
        },
        else => {
            x.exit_status = 123;
        },
    }
}

fn finishAll(x: *X) Stop!void {
    while (x.running.items.len > 0) try waitOne(x);
}

fn runCommand(x: *X) Stop!void {
    const gpa = x.env.gpa;
    if (x.items.items.len == 0 and x.opt.replace != null) return;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |o| gpa.free(o);
        owned.deinit(gpa);
    }
    if (x.opt.replace) |repl| {
        // Each initial argument has REPL replaced by the (single) item.
        const item: []const u8 = if (x.items.items.len > 0) x.items.items[0] else "";
        for (x.initial, 0..) |a, ai| {
            if (ai > 0 and repl.len == 0) {
                // As in GNU, an empty argument becomes the item.
                if (a.len != 0) {
                    x.observer.emit(.command_too_long);
                    try finishAll(x);
                    return x.abort(1);
                }
                try argv.append(gpa, cutNul(item));
                continue;
            }
            if (ai == 0 or std.mem.indexOf(u8, a, repl) == null) {
                try argv.append(gpa, a);
                continue;
            }
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            var i: usize = 0;
            while (i < a.len) {
                if (std.mem.startsWith(u8, a[i..], repl)) {
                    try out.appendSlice(gpa, item);
                    i += repl.len;
                } else {
                    try out.append(gpa, a[i]);
                    i += 1;
                }
            }
            const s = try out.toOwnedSlice(gpa);
            errdefer gpa.free(s);
            try owned.append(gpa, s);
            try argv.append(gpa, cutNul(s));
        }
    } else {
        try argv.appendSlice(gpa, x.initial);
        for (x.items.items) |it| try argv.append(gpa, cutNul(it));
    }
    if (x.opt.confirm != null or x.opt.verbose) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        for (argv.items, 0..) |a, i| {
            if (i > 0) try line.append(gpa, ' ');
            try quotearg.quote(&line, gpa, a, .shell_escape, null);
        }
        if (x.opt.confirm) |c| {
            switch (c.func(c.context, line.items)) {
                .yes => {},
                .no => {
                    clearItems(x);
                    return;
                },
                .abort => return x.abort(1),
            }
        } else {
            x.observer.emit(.{ .trace = line.items });
        }
    }
    // Keep at most `procs` children running.
    if (x.opt.procs != 0) while (x.running.items.len >= x.opt.procs) try waitOne(x);

    var env_copy: ?std.process.Environ.Map = null;
    defer if (env_copy) |*m| m.deinit();
    var slot: usize = 0;
    if (x.opt.slot_var) |sv| {
        if (x.env.environ) |m| {
            env_copy = m.clone(gpa) catch null;
            if (env_copy) |*ec| {
                slot = x.next_slot % @max(@as(usize, @intCast(@min(x.opt.procs, 1 << 20))), 1);
                if (x.opt.procs == 0) slot = x.next_slot;
                x.next_slot += 1;
                var nb: [24]u8 = undefined;
                ec.put(sv, std.fmt.bufPrint(&nb, "{d}", .{slot}) catch "0") catch {};
            }
        }
    }
    x.ran_any = true;
    var stdin_opt: std.process.SpawnOptions.StdIo = if (x.opt.inherit_stdin) .inherit else .ignore;
    var tty_file: ?Io.File = null;
    defer if (tty_file) |f| f.close(x.env.io);
    if (x.opt.open_tty) {
        tty_file = Io.Dir.cwd().openFile(x.env.io, "/dev/tty", .{}) catch null;
        if (tty_file) |f| stdin_opt = .{ .file = f };
    }
    // On Windows the program is found through PATH here, so that one in the
    // current directory is not run for a bare name.
    const name = argv.items[0];
    const program: ?[]const u8 = programpath.resolve(x.env, gpa, name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => null,
    };
    defer if (program) |found| if (found.ptr != name.ptr) gpa.free(found);
    if (program == null) {
        x.observer.emit(.{ .spawn_failed = .{ .name = name, .err = error.FileNotFound } });
        try finishAll(x);
        return x.abort(127);
    }
    argv.items[0] = program.?;
    var child = std.process.spawn(x.env.io, .{
        .argv = argv.items,
        .stdin = stdin_opt,
        .environ_map = if (env_copy) |*m| m else null,
    }) catch |e| {
        x.observer.emit(.{ .spawn_failed = .{ .name = argv.items[0], .err = e } });
        try finishAll(x);
        return x.abort(if (e == error.FileNotFound) 127 else 126);
    };
    x.running.append(gpa, .{ .child = child, .slot = slot }) catch {
        child.kill(x.env.io);
    };
    if (x.opt.procs == 1) try waitOne(x);
    clearItems(x);
}

fn cutNul(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, 0)) |i| s[0..i] else s;
}

fn clearItems(x: *X) void {
    for (x.items.items) |it| x.env.gpa.free(it);
    x.items.clearRetainingCapacity();
    x.lines_in_cmd = 0;
    x.bytes_in_cmd = 0;
}

fn initialBytes(x: *const X) usize {
    var n: usize = 0;
    for (x.initial) |a| n += a.len + 1;
    return n;
}

/// Add one item (taking ownership); runs the command when a limit is hit.
fn addItem(x: *X, item: []u8) Stop!void {
    const gpa = x.env.gpa;
    // `item` is freed here unless it reaches `x.items`, which owns it.
    var owned = false;
    errdefer if (!owned) gpa.free(item);
    const len = item.len + 1;
    const max_chars = x.max_chars;
    if (x.opt.replace == null) {
        const base = initialBytes(x);
        if (base + x.bytes_in_cmd + len > max_chars) {
            if (x.items.items.len == 0) {
                if (base > max_chars) {
                    x.observer.emit(.cannot_fit_single_argument);
                    try finishAll(x);
                    return x.abort(1);
                }
                x.observer.emit(.argument_line_too_long);
                return x.abort(1);
            }
            if (x.opt.exit_if_too_long and (x.opt.max_args != 0 or x.opt.max_lines != 0)) {
                x.observer.emit(.argument_list_too_long);
                try finishAll(x);
                return x.abort(1);
            }
            try runCommand(x);
            // The item may be too long even for a command line to itself.
            if (base + len > max_chars) {
                x.observer.emit(.argument_line_too_long);
                try finishAll(x);
                return x.abort(1);
            }
        }
    }
    try x.items.append(gpa, item);
    owned = true;
    x.bytes_in_cmd += len;
    if (x.opt.replace != null) {
        try runCommand(x);
    } else if (x.opt.max_args != 0 and x.items.items.len >= x.opt.max_args) {
        try runCommand(x);
    }
}

fn endOfLine(x: *X) Stop!void {
    if (x.opt.max_lines == 0 or x.opt.replace != null) return;
    x.lines_in_cmd += 1;
    if (x.lines_in_cmd >= x.opt.max_lines and x.items.items.len > 0) try runCommand(x);
}

fn nextByte(r: *Io.Reader) ?u8 {
    return r.takeByte() catch null;
}

/// Add a byte to the item being read. An item as long as a whole command line
/// can never be passed on, so reading stops there instead of collecting an
/// endless one. As GNU xargs, run the items already waiting first, except
/// where a command must be complete (-I, -L, -x).
fn appendByte(x: *X, tok: *std.ArrayList(u8), c: u8) Stop!void {
    if (tok.items.len + 1 >= x.max_chars) {
        const partial_ok = x.opt.replace == null and x.opt.max_lines == 0 and !x.opt.exit_if_too_long;
        if (partial_ok and x.items.items.len > 0) try runCommand(x);
        // When the command itself does not fit, that is what is wrong.
        const command_too_big = x.opt.replace == null and initialBytes(x) > x.max_chars;
        x.observer.emit(if (command_too_big) .cannot_fit_single_argument else .argument_line_too_long);
        try finishAll(x);
        return x.abort(1);
    }
    try tok.append(x.env.gpa, c);
}

fn unmatchedQuote(x: *X, quote: u8) Stop {
    x.observer.emit(.{ .unmatched_quote = .{ .single = quote == '\'' } });
    finishAll(x) catch |e| return e;
    return x.abort(1);
}

fn processInput(x: *X, rd: *Io.Reader) Stop!void {
    var tok: std.ArrayList(u8) = .empty;
    defer tok.deinit(x.env.gpa);

    if (x.opt.null_input or x.opt.delimiter != null) {
        const d: u8 = x.opt.delimiter orelse 0;
        var have = false;
        while (true) {
            const c = nextByte(rd) orelse break;
            if (c == d) {
                have = false;
                try finishToken(x, &tok, true);
            } else {
                have = true;
                try appendByte(x, &tok, c);
            }
        }
        if (have) try finishToken(x, &tok, true);
        return;
    }

    // Default mode: blanks and newlines separate items; quotes and
    // backslashes are special.
    const replace_mode = x.opt.replace != null;
    var in_token = false;
    var line_has_item = false;
    var pending_continue = false;
    var quote: u8 = 0;
    var escaped = false;
    var stop = false;
    while (!stop) {
        const c_opt = nextByte(rd);
        if (c_opt == null) {
            if (quote != 0) {
                if (x.items.items.len > 0 and x.opt.max_lines == 0) try runCommand(x);
                return unmatchedQuote(x, quote);
            }
            if (in_token) {
                _ = try finishDefault(x, &tok, &stop);
                in_token = false;
                line_has_item = true;
            }
            if (line_has_item) try endOfLine(x);
            break;
        }
        const c = c_opt.?;
        if (c == 0 and !x.nul_warned) {
            x.nul_warned = true;
            x.observer.emit(.nul_in_input);
        }
        if (escaped) {
            try appendByte(x, &tok, c);
            in_token = true;
            escaped = false;
            continue;
        }
        if (quote != 0) {
            if (c == '\n') {
                if (x.items.items.len > 0 and x.opt.max_lines == 0) try runCommand(x);
                return unmatchedQuote(x, quote);
            }
            if (c == quote) quote = 0 else try appendByte(x, &tok, c);
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
                if (try finishDefault(x, &tok, &stop)) line_has_item = true;
                in_token = false;
            }
            if (stop) break;
            if (!pending_continue and line_has_item) {
                try endOfLine(x);
                line_has_item = false;
            }
            pending_continue = false;
            continue;
        }
        if (isBlank(c) and !replace_mode) {
            if (in_token) {
                if (try finishDefault(x, &tok, &stop)) line_has_item = true;
                in_token = false;
                if (stop) break;
            }
            pending_continue = true;
            continue;
        }
        if (isBlank(c) and replace_mode and !in_token) continue;
        pending_continue = false;
        try appendByte(x, &tok, c);
        in_token = true;
    }
}

/// End of a token in default mode; handles the EOF string. Returns true when
/// an item was added.
fn finishDefault(x: *X, tok: *std.ArrayList(u8), stop: *bool) Stop!bool {
    if (x.opt.eof_str) |e| {
        if (std.mem.eql(u8, tok.items, e)) {
            stop.* = true;
            tok.clearRetainingCapacity();
            return false;
        }
    }
    const item = try x.env.gpa.dupe(u8, tok.items);
    tok.clearRetainingCapacity();
    try addItem(x, item);
    return true;
}

fn finishToken(x: *X, tok: *std.ArrayList(u8), count_line: bool) Stop!void {
    const item = try x.env.gpa.dupe(u8, tok.items);
    tok.clearRetainingCapacity();
    try addItem(x, item);
    if (count_line) try endOfLine(x);
}

fn runAll(x: *X, input: *Io.Reader) Stop!void {
    try processInput(x, input);
    if (x.items.items.len > 0 or (!x.opt.no_run_if_empty and !x.ran_any and x.opt.replace == null)) {
        try runCommand(x);
    }
    try finishAll(x);
}

/// Read items from `input` and run the command over them.
pub fn run(env: Env, options: Options, input: *Io.Reader, observer: Observer) error{OutOfMemory}!Result {
    const echo = [_][]const u8{"echo"};
    var x: X = .{
        .env = env,
        .opt = options,
        .observer = observer,
        .initial = if (options.command.len == 0) &echo else options.command,
        .max_chars = options.max_chars orelse systemLimits(env).arg_max,
    };
    defer {
        for (x.items.items) |it| env.gpa.free(it);
        x.items.deinit(env.gpa);
        x.running.deinit(env.gpa);
    }
    runAll(&x, input) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Abort => return .{ .status = x.abort_status },
    };
    return .{ .status = x.exit_status };
}

test "parseDelimiter" {
    try std.testing.expectEqual(@as(?u8, ','), parseDelimiter(","));
    try std.testing.expectEqual(@as(?u8, '\n'), parseDelimiter("\\n"));
    try std.testing.expectEqual(@as(?u8, 0x41), parseDelimiter("\\x41"));
    try std.testing.expectEqual(@as(?u8, 0o101), parseDelimiter("\\101"));
    try std.testing.expectEqual(@as(?u8, null), parseDelimiter("ab"));
}
