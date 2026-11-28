// SPDX-License-Identifier: GPL-2.0-or-later
//! env — run a program in a modified environment, or print the environment.
//! Reference: GNU coreutils manual "env invocation" (9.7); POSIX.1-2024 env.
//!
//! Options are processed in order, each acting on the environment as it stands.
//! `-S` splits its argument like a shebang line and re-parses the result.
//! The environment handling and the -S splitter are in src/lib/env.zig;
//! signal dispositions, --chdir and the exec, which are process-wide, stay here.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const exec = @import("../exec.zig");
const sys = @import("../sys.zig");
const envlib = @import("../lib/env.zig");
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

    var env = envlib.copyEnvironment(a, ctx.environ) catch return bad_status;

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
                if (!envlib.validUnsetName(name)) {
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
                const pieces = switch (envlib.splitString(a, &env, text) catch return bad_status) {
                    .ok => |p| p,
                    .bad => |problem| {
                        splitDiagnostic(ctx, problem);
                        return bad_status;
                    },
                };
                if (debug) {
                    say(ctx, "split -S:  {f}", .{cli.quoteC(text)});
                    for (pieces, 0..) |pc, i| say(ctx, "{s}{f}", .{ if (i == 0) " into:    " else "     &    ", cli.quoteC(pc) });
                }
                const rest = cur.args[parser.index..];
                const joined = a.alloc([:0]const u8, pieces.len + rest.len) catch return bad_status;
                @memcpy(joined[0..pieces.len], pieces);
                @memcpy(joined[pieces.len..], rest);
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
    const dbg: Debug = .{ .ctx = ctx, .on = debug };
    const command = envlib.applyAssignments(&env, operands, .{
        .context = @constCast(&dbg),
        .func = onAssign,
    }) catch return bad_status;

    if (envlib.check(command.len, nul, chdir, argv0)) |problem| {
        switch (problem) {
            .null_with_command => cli.warn(ctx, "cannot specify --null (-0) with command\nTry '{s} --help' for more information.", .{ctx.name}),
            .chdir_without_command => cli.warn(ctx, "must specify command with --chdir (-C)\nTry '{s} --help' for more information.", .{ctx.name}),
            .argv0_without_command => cli.warn(ctx, "must specify command with --argv0 (-a)\nTry '{s} --help' for more information.", .{ctx.name}),
        }
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
        var buf: [8192]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
        envlib.print(&env, nul, &stdout.interface) catch {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return bad_status;
        };
        return if (cli.flushWriter(&stdout)) 0 else bad_status;
    }

    if (argv0) |z| if (debug) say(ctx, "argv0:     {f}", .{cli.quoteC(z)});
    const argv = envlib.commandArgv(a, command, argv0) catch return bad_status;
    if (debug) {
        say(ctx, "executing: {s}", .{command[0]});
        for (argv, 0..) |c, i| say(ctx, "   arg[{d}]= {f}", .{ i, cli.quoteC(c) });
    }
    const rc = exec.exec(ctx, command[0], argv, &env);
    // GNU hints at -S when a name with blanks was not found.
    if (rc == 127 and envlib.wantsShebangHint(command[0]))
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
        // 0 names a signal to kill and timeout, but it has no action.
        const num = sys.signalNumber(tok);
        const n = if (num != null and num.? != 0) num.? else {
            cli.warn(ctx, "{f}: invalid signal\nTry '{s} --help' for more information.", .{ cli.quoteC(tok), ctx.name });
            return false;
        };
        // The C library keeps two for itself, and GNU env cannot touch them.
        if (builtin.os.tag == .linux and (n == 32 or n == 33)) {
            const what = if (d == .block) "block" else "get signal action for";
            cli.warn(ctx, "failed to {s} signal {d}: Invalid argument", .{ what, n });
            return false;
        }
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

const Debug = struct { ctx: cli.Context, on: bool };

fn onAssign(context: ?*anyopaque, ev: envlib.Event) void {
    const d: *const Debug = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .setenv => |text| if (d.on) say(d.ctx, "setenv:   {s}", .{text}),
    }
}

fn splitDiagnostic(ctx: cli.Context, problem: envlib.SplitProblem) void {
    switch (problem) {
        .no_terminating_quote => cli.warn(ctx, "no terminating quote in -S string", .{}),
        .backslash_at_end => cli.warn(ctx, "invalid backslash at end of string in -S", .{}),
        .invalid_sequence => |c| cli.warn(ctx, "invalid sequence '\\{c}' in -S", .{c}),
        .bad_expansion => |rest| cli.warn(ctx, "only ${{VARNAME}} expansion is supported, error at: {s}", .{rest}),
    }
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
