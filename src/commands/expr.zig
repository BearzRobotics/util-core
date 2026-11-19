// SPDX-License-Identifier: GPL-2.0-or-later
//! expr: thin wrapper over `util_core.expr` (decision 0004). Handles --help,
//! --version and `--`, words the diagnostics and maps results to GNU's exit
//! status (0 result is neither null nor 0, 1 null or 0, 2 syntax error,
//! 3 other errors; GNU 9.7 reports a division by zero with status 2 here).

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const expr = @import("../lib/expr.zig");

pub fn main(ctx: cli.Context) u8 {
    var args: []const [:0]const u8 = ctx.args;
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return help(ctx);
    if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) return if (cli.printVersion(ctx)) 0 else 1;
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args = args[1..];
    if (args.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 2;
    }
    // A slice of sentinel-terminated slices has the layout of a slice of slices.
    const tokens: []const []const u8 = @ptrCast(args);

    var buf: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: expr.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const is_null = expr.run(env, tokens, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.Syntax, error.Fatal => return 2,
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 3;
        },
    };
    return if (is_null) 1 else 0;
}

fn report(context: ?*anyopaque, ev: expr.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .missing_argument_after => |t| cli.warn(ctx.*, "syntax error: missing argument after {f}", .{cli.quoteC(t)}),
        .expecting_close_after => |t| cli.warn(ctx.*, "syntax error: expecting {f} after {f}", .{ cli.quoteC(")"), cli.quoteC(t) }),
        .expecting_close_instead => |t| cli.warn(ctx.*, "syntax error: expecting {f} instead of {f}", .{ cli.quoteC(")"), cli.quoteC(t) }),
        .unexpected_argument => |t| cli.warn(ctx.*, "syntax error: unexpected argument {f}", .{cli.quoteC(t)}),
        .non_integer_argument => cli.warn(ctx.*, "non-integer argument", .{}),
        .division_by_zero => cli.warn(ctx.*, "division by zero", .{}),
        .regex_error => |m| cli.warn(ctx.*, "{s}", .{m}),
        .regex_too_big => cli.warn(ctx.*, "Regular expression too big", .{}),
    }
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: expr EXPRESSION\n  or:  expr OPTION\n\n      --help        display this help and exit\n      --version     output version information and exit\n\nPrint the value of EXPRESSION to standard output.  A blank line below\nseparates increasing precedence groups.  EXPRESSION may be:\n\n  ARG1 | ARG2       ARG1 if it is neither null nor 0, otherwise ARG2\n\n  ARG1 & ARG2       ARG1 if neither argument is null or 0, otherwise 0\n\n  ARG1 < ARG2       ARG1 is less than ARG2\n  ARG1 <= ARG2      ARG1 is less than or equal to ARG2\n  ARG1 = ARG2       ARG1 is equal to ARG2\n  ARG1 != ARG2      ARG1 is unequal to ARG2\n  ARG1 >= ARG2      ARG1 is greater than or equal to ARG2\n  ARG1 > ARG2       ARG1 is greater than ARG2\n\n  ARG1 + ARG2       arithmetic sum of ARG1 and ARG2\n  ARG1 - ARG2       arithmetic difference of ARG1 and ARG2\n\n  ARG1 * ARG2       arithmetic product of ARG1 and ARG2\n  ARG1 / ARG2       arithmetic quotient of ARG1 divided by ARG2\n  ARG1 % ARG2       arithmetic remainder of ARG1 divided by ARG2\n\n  STRING : REGEXP   anchored pattern match of REGEXP in STRING\n\n  match STRING REGEXP        same as STRING : REGEXP\n  substr STRING POS LENGTH   substring of STRING, POS counted from 1\n  index STRING CHARS         index in STRING where any CHARS is found, or 0\n  length STRING              length of STRING\n  + TOKEN                    interpret TOKEN as a string, even if it is a\n                               keyword like 'match' or an operator like '/'\n\n  ( EXPRESSION )             value of EXPRESSION\n")) 0 else 1;
}
