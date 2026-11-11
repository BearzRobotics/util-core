// SPDX-License-Identifier: GPL-2.0-or-later
//! env — run a program in a modified environment, or print the environment.
//! Reference: GNU coreutils manual "env invocation" (9.7); POSIX.1-2024 env.
//!
//! Options are processed in order, each acting on the environment as it stands.
//! `-S` splits its argument like a shebang line and re-parses the result.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const exec = @import("../exec.zig");
const sys = @import("../sys.zig");
const Io = std.Io;
const Map = std.process.Environ.Map;

const opt_block: u32 = 2000;
const opt_default: u32 = 2001;
const opt_ignore: u32 = 2002;
const opt_list: u32 = 2003;

const longs = [_]getopt.Long{
    .{ .name = "ignore-environment", .id = 'i' },
    .{ .name = "null", .id = '0' },
    .{ .name = "unset", .arg = .required, .id = 'u' },
    .{ .name = "chdir", .arg = .required, .id = 'C' },
    .{ .name = "argv0", .arg = .required, .id = 'a' },
    .{ .name = "split-string", .arg = .required, .id = 'S' },
    .{ .name = "debug", .id = 'v' },
    .{ .name = "block-signal", .arg = .optional, .id = opt_block },
    .{ .name = "default-signal", .arg = .optional, .id = opt_default },
    .{ .name = "ignore-signal", .arg = .optional, .id = opt_ignore },
    .{ .name = "list-signal-handling", .id = opt_list },
};

const bad_status: u8 = 125;

pub fn main(ctx: cli.Context) u8 {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var env = Map.init(a);
    if (ctx.environ) |src| {
        var it = src.iterator();
        while (it.next()) |e| env.put(e.key_ptr.*, e.value_ptr.*) catch return bad_status;
    }

    var debug = false;
    var nul = false;
    var list_signals = false;
    var argv0: ?[]const u8 = null;
    var chdir: ?[]const u8 = null;
    var ignore_env = false;
    var cur = ctx;
    var parser = getopt.Parser.init(cur, "+iv0u:C:a:S:", &longs);
    while (true) {
        const item = parser.next();
        const o = switch (item) {
            .done => break,
            .bad => return bad_status,
            .opt => |o| o,
        };
        switch (o.id) {
            'i' => ignore_env = true,
            '0' => nul = true,
            'v' => debug = true,
            'u' => {
                const name = o.arg.?;
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) {
                    cli.warn(ctx, "cannot unset {f}: Invalid argument", .{cli.quoteC(name)});
                    return bad_status;
                }
                if (debug) say(ctx, "unset:    {s}", .{name});
                _ = env.orderedRemove(name);
            },
            'C' => {
                chdir = o.arg.?; // only the last -C counts, applied after the loop
            },
            'a' => argv0 = o.arg.?,
            'S' => {
                const text = o.arg.?;
                var pieces: std.ArrayList([:0]const u8) = .empty;
                if (!split(ctx, a, &env, text, &pieces)) return bad_status;
                if (debug) {
                    say(ctx, "split -S:  {f}", .{cli.quoteC(text)});
                    for (pieces.items, 0..) |pc, i| say(ctx, "{s}{f}", .{ if (i == 0) " into:    " else "     &    ", cli.quoteC(pc) });
                }
                const rest = cur.args[parser.index..];
                const joined = a.alloc([:0]const u8, pieces.items.len + rest.len) catch return bad_status;
                @memcpy(joined[0..pieces.items.len], pieces.items);
                @memcpy(joined[pieces.items.len..], rest);
                cur.args = joined;
                parser.deinit();
                parser = getopt.Parser.init(cur, "+iv0u:C:a:S:", &longs);
            },
            opt_block, opt_default, opt_ignore => {
                const d: sys.Disposition = if (o.id == opt_block) .block else if (o.id == opt_default) .default else .ignore;
                if (!signalOption(ctx, o.arg, d, &list_signals, debug)) return bad_status;
            },
            opt_list => list_signals = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text)) 0 else bad_status,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else bad_status,
            else => unreachable,
        }
    }
    defer parser.deinit();

    var operands = parser.operands.items;
    if (operands.len > 0 and std.mem.eql(u8, operands[0], "-")) {
        ignore_env = true;
        operands = operands[1..];
    }
    if (ignore_env) {
        if (debug) say(ctx, "cleaning environ", .{});
        env.deinit();
        env = Map.init(a);
    }
    var k: usize = 0;
    while (k < operands.len) : (k += 1) {
        const eq = std.mem.indexOfScalar(u8, operands[k], '=') orelse break;
        if (eq == 0) continue; // an empty name cannot be stored; GNU sets it
        if (debug) say(ctx, "setenv:   {s}", .{operands[k]});
        env.put(operands[k][0..eq], operands[k][eq + 1 ..]) catch return bad_status;
    }
    const command = operands[k..];

    if (nul and command.len > 0) {
        cli.warn(ctx, "cannot specify --null (-0) with command\nTry '{s} --help' for more information.", .{ctx.name});
        return bad_status;
    }
    if (command.len == 0 and chdir != null) {
        cli.warn(ctx, "must specify command with --chdir (-C)\nTry '{s} --help' for more information.", .{ctx.name});
        return bad_status;
    }
    if (command.len == 0 and argv0 != null) {
        cli.warn(ctx, "must specify command with --argv0 (-a)\nTry '{s} --help' for more information.", .{ctx.name});
        return bad_status;
    }
    if (chdir) |dir| {
        if (debug) say(ctx, "chdir:    {f}", .{cli.quoteC(dir)});
        std.process.setCurrentPath(ctx.io, dir) catch |e| {
            cli.warn(ctx, "cannot change directory to {f}: {s}", .{ cli.quoteC(dir), cli.errText(e) });
            return bad_status;
        };
    }
    if (list_signals) listSignals(ctx);

    if (command.len == 0) {
        var out = cli.Out.init(ctx.io);
        var it = env.iterator();
        while (it.next()) |e| {
            out.write(e.key_ptr.*);
            out.writeByte('=');
            out.write(e.value_ptr.*);
            out.writeByte(if (nul) 0 else '\n');
        }
        out.flush();
        return if (out.failed) bad_status else 0;
    }

    if (argv0) |z| if (debug) say(ctx, "argv0:     {f}", .{cli.quoteC(z)});
    const argv = a.alloc([]const u8, command.len) catch return bad_status;
    for (command, 0..) |c, i| argv[i] = c;
    if (argv0) |z| argv[0] = z;
    if (debug) {
        say(ctx, "executing: {s}", .{command[0]});
        for (argv, 0..) |c, i| say(ctx, "   arg[{d}]= {f}", .{ i, cli.quoteC(c) });
    }
    const rc = exec.exec(ctx, command[0], argv, &env);
    // GNU hints at -S when a name with blanks was not found.
    if (rc == 127 and std.mem.indexOfAny(u8, command[0], " \t\n\x0b\x0c\r") != null)
        cli.warn(ctx, "use -[v]S to pass options in shebang lines", .{});
    return rc;
}

/// Debug and signal-list lines: standard error without the command prefix.
fn say(ctx: cli.Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    Io.File.stderr().writeStreamingAll(ctx.io, msg) catch {};
}

fn signalOption(ctx: cli.Context, arg: ?[]const u8, d: sys.Disposition, list: *bool, debug: bool) bool {
    _ = debug;
    _ = list;
    const text = arg orelse {
        var n: u8 = 1;
        while (n <= 64) : (n += 1) {
            if (n == 9 or n == 19 or n == 32 or n == 33) continue; // unchangeable or reserved by libc
            _ = sys.setSignal(n, d);
        }
        return true;
    };
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        const n = sys.signalNumber(tok) orelse {
            cli.warn(ctx, "{f}: invalid signal\nTry '{s} --help' for more information.", .{ cli.quoteC(tok), ctx.name });
            return false;
        };
        if (!sys.setSignal(n, d)) {
            cli.warn(ctx, "failed to set signal action for signal {d}: Invalid argument", .{n});
            return false;
        }
    }
    return true;
}

fn listSignals(ctx: cli.Context) void {
    var n: u8 = 1;
    while (n <= 64) : (n += 1) {
        var nb: [16]u8 = undefined;
        const name = sys.signalName(n, &nb) orelse continue;
        const st = sys.signalState(n);
        if (st.blocked and st.disp == .ignore) {
            say(ctx, "{s: <10} ({d: >2}): BLOCK,IGNORE", .{ name, n });
        } else if (st.blocked) {
            say(ctx, "{s: <10} ({d: >2}): BLOCK", .{ name, n });
        } else if (st.disp == .ignore) {
            say(ctx, "{s: <10} ({d: >2}): IGNORE", .{ name, n });
        }
    }
}

/// Split a `-S` string into arguments. Rules (GNU manual, "-S/--split-string
/// usage in scripts"): blanks separate words; '...' is literal except \\ and
/// \'; "..." allows escapes and ${VAR}; unquoted \_ is a separator; \c ends
/// the string; # at the start of a word starts a comment.
fn split(ctx: cli.Context, a: std.mem.Allocator, env: *const Map, text: []const u8, out: *std.ArrayList([:0]const u8)) bool {
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    const blanks = " \t\n\x0b\x0c\r";
    while (i < text.len) {
        const c = text[i];
        if (std.mem.indexOfScalar(u8, blanks, c) != null) {
            if (in_word) flush(a, out, &word, &in_word);
            i += 1;
            continue;
        }
        if (c == '#' and !in_word) break;
        in_word = true;
        switch (c) {
            '\'' => {
                i += 1;
                while (true) {
                    if (i >= text.len) {
                        cli.warn(ctx, "no terminating quote in -S string", .{});
                        return false;
                    }
                    const d = text[i];
                    if (d == '\'') break;
                    if (d == '\\' and i + 1 < text.len and (text[i + 1] == '\'' or text[i + 1] == '\\')) {
                        word.append(a, text[i + 1]) catch return false;
                        i += 2;
                        continue;
                    }
                    word.append(a, d) catch return false;
                    i += 1;
                }
                i += 1;
            },
            '"' => {
                i += 1;
                while (true) {
                    if (i >= text.len) {
                        cli.warn(ctx, "no terminating quote in -S string", .{});
                        return false;
                    }
                    const d = text[i];
                    if (d == '"') break;
                    if (d == '\\') {
                        i += 1;
                        if (i >= text.len) {
                            cli.warn(ctx, "invalid backslash at end of string in -S", .{});
                            return false;
                        }
                        const e = text[i];
                        switch (e) {
                            '"', '\\', '$' => word.append(a, e) catch return false,
                            '_' => word.append(a, ' ') catch return false,
                            'c' => {
                                flush(a, out, &word, &in_word);
                                return true;
                            },
                            'f' => word.append(a, 12) catch return false,
                            'n' => word.append(a, 10) catch return false,
                            'r' => word.append(a, 13) catch return false,
                            't' => word.append(a, 9) catch return false,
                            'v' => word.append(a, 11) catch return false,
                            else => {
                                cli.warn(ctx, "invalid sequence '\\{c}' in -S", .{e});
                                return false;
                            },
                        }
                        i += 1;
                        continue;
                    }
                    if (d == '$') {
                        i = expand(ctx, a, env, text, i, &word) orelse return false;
                        continue;
                    }
                    word.append(a, d) catch return false;
                    i += 1;
                }
                i += 1;
            },
            '$' => i = expand(ctx, a, env, text, i, &word) orelse return false,
            '\\' => {
                i += 1;
                if (i >= text.len) {
                    cli.warn(ctx, "invalid backslash at end of string in -S", .{});
                    return false;
                }
                const e = text[i];
                switch (e) {
                    '_' => flush(a, out, &word, &in_word),
                    'c' => {
                        if (in_word and word.items.len > 0) flush(a, out, &word, &in_word);
                        return true;
                    },
                    '#', '$', '"', '\'', '\\' => word.append(a, e) catch return false,
                    'f' => word.append(a, 12) catch return false,
                    'n' => word.append(a, 10) catch return false,
                    'r' => word.append(a, 13) catch return false,
                    't' => word.append(a, 9) catch return false,
                    'v' => word.append(a, 11) catch return false,
                    else => {
                        cli.warn(ctx, "invalid sequence '\\{c}' in -S", .{e});
                        return false;
                    },
                }
                i += 1;
            },
            else => {
                word.append(a, c) catch return false;
                i += 1;
            },
        }
    }
    if (in_word) flush(a, out, &word, &in_word);
    return true;
}

fn flush(a: std.mem.Allocator, out: *std.ArrayList([:0]const u8), word: *std.ArrayList(u8), in_word: *bool) void {
    const z = a.dupeSentinel(u8, word.items, 0) catch return;
    out.append(a, z) catch {};
    word.clearRetainingCapacity();
    in_word.* = false;
}

/// `${NAME}` at text[i]; returns the index after it.
fn expand(ctx: cli.Context, a: std.mem.Allocator, env: *const Map, text: []const u8, i: usize, word: *std.ArrayList(u8)) ?usize {
    const bad = struct {
        fn f(c: cli.Context, t: []const u8, at: usize) ?usize {
            cli.warn(c, "only ${{VARNAME}} expansion is supported, error at: {s}", .{t[at..]});
            return null;
        }
    }.f;
    if (i + 1 >= text.len or text[i + 1] != '{') return bad(ctx, text, i);
    var j = i + 2;
    if (j >= text.len or !(std.ascii.isAlphabetic(text[j]) or text[j] == '_')) return bad(ctx, text, i);
    while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
    if (j >= text.len or text[j] != '}') return bad(ctx, text, i);
    if (env.get(text[i + 2 .. j])) |v| word.appendSlice(a, v) catch return null;
    return j + 1;
}

const help_text =
    "Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]\n" ++
    "Set each NAME to VALUE in the environment and run COMMAND.\n\n" ++
    "Mandatory arguments to long options are mandatory for short options too.\n" ++
    "  -a, --argv0=ARG      pass ARG as the zeroth argument of COMMAND\n" ++
    "  -i, --ignore-environment  start with an empty environment\n" ++
    "  -0, --null           end each output line with NUL, not newline\n" ++
    "  -u, --unset=NAME     remove variable from the environment\n" ++
    "  -C, --chdir=DIR      change working directory to DIR\n" ++
    "  -S, --split-string=S  process and split S into separate arguments;\n" ++
    "                        used to pass multiple arguments on shebang lines\n" ++
    "      --block-signal[=SIG]    block delivery of SIG signal(s) to COMMAND\n" ++
    "      --default-signal[=SIG]  reset handling of SIG signal(s) to the default\n" ++
    "      --ignore-signal[=SIG]   set handling of SIG signal(s) to do nothing\n" ++
    "      --list-signal-handling  list non default signal handling to stderr\n" ++
    "  -v, --debug          print verbose information for each processing step\n" ++
    "      --help        display this help and exit\n" ++
    "      --version     output version information and exit\n\n" ++
    "A mere - implies -i.  If no COMMAND, print the resulting environment.\n\n" ++
    "SIG may be a signal name like 'PIPE', or a signal number like '13'.\n" ++
    "Without SIG, all known signals are included.  Multiple signals can be\n" ++
    "comma-separated.  An empty SIG argument is a no-op.\n\n" ++
    "Exit status:\n" ++
    "  125  if the env command itself fails\n" ++
    "  126  if COMMAND is found but cannot be invoked\n" ++
    "  127  if COMMAND cannot be found\n" ++
    "  -    the exit status of COMMAND otherwise\n";
