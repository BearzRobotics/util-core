// SPDX-License-Identifier: GPL-2.0-or-later
//! test (and `[`): thin wrapper over `util_core.test_cmd` / `util_core.bracket`
//! (decision 0004). Handles `[`'s closing bracket and --help/--version and
//! words the diagnostics; the evaluation is in src/lib/test.zig.
//!
//! Exit status: 0 true, 1 false, 2 for a syntax error.

const std = @import("std");
const cli = @import("../cli.zig");
const test_lib = @import("../lib/test.zig");
const bracket_lib = @import("../lib/bracket.zig");

pub fn main(ctx: cli.Context) u8 {
    return run(ctx, false);
}

pub fn run(ctx: cli.Context, bracket: bool) u8 {
    const args: []const [:0]const u8 = ctx.args;
    if (bracket) {
        // "[ expr ]": --help and --version work only as the sole argument,
        // without the closing bracket.
        if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) return help(ctx);
        if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) return if (cli.printVersion(ctx)) 0 else 1;
    }
    // A slice of sentinel-terminated slices has the layout of a slice of slices.
    const tokens: []const []const u8 = @ptrCast(args);
    const env: test_lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const observer: test_lib.Observer = .{ .context = @constCast(&ctx), .func = report };
    const result = (if (bracket)
        bracket_lib.evaluate(env, tokens, observer)
    else
        test_lib.evaluate(env, tokens, .{}, observer)) catch |e| switch (e) {
        error.MissingBracket => {
            cli.warn(ctx, "missing ']'", .{});
            return 2;
        },
        error.Syntax => return 2,
    };
    return if (result) 0 else 1;
}

fn report(context: ?*anyopaque, ev: test_lib.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .extra_argument => |t| cli.warn(ctx.*, "extra argument {f}", .{cli.quoteC(t)}),
        .missing_argument_after => |t| cli.warn(ctx.*, "missing argument after {f}", .{cli.quoteC(t)}),
        .binary_operator_expected => |t| cli.warn(ctx.*, "{f}: binary operator expected", .{cli.quoteC(t)}),
        .unary_operator_expected => |t| cli.warn(ctx.*, "{f}: unary operator expected", .{cli.quoteC(t)}),
        .invalid_integer => |t| cli.warn(ctx.*, "invalid integer {f}", .{cli.quoteC(t)}),
        .close_paren_expected => |found| if (found) |f|
            cli.warn(ctx.*, "{f} expected, found {f}", .{ cli.quoteC(")"), cli.quoteC(f) })
        else
            cli.warn(ctx.*, "{f} expected", .{cli.quoteC(")")}),
    }
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: test EXPRESSION\n" ++
        "  or:  test\n" ++
        "  or:  [ EXPRESSION ]\n" ++
        "  or:  [ ]\n" ++
        "  or:  [ OPTION\n" ++
        "Exit with the status determined by EXPRESSION.\n" ++
        "\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n" ++
        "\n" ++
        "An omitted EXPRESSION defaults to false.  Otherwise,\n" ++
        "EXPRESSION is true or false and sets exit status.  It is one of:\n" ++
        "\n" ++
        "  ( EXPRESSION )               EXPRESSION is true\n" ++
        "  ! EXPRESSION                 EXPRESSION is false\n" ++
        "  EXPRESSION1 -a EXPRESSION2   both EXPRESSION1 and EXPRESSION2 are true\n" ++
        "  EXPRESSION1 -o EXPRESSION2   either EXPRESSION1 or EXPRESSION2 is true\n" ++
        "\n" ++
        "  -n STRING            the length of STRING is nonzero\n" ++
        "  STRING               equivalent to -n STRING\n" ++
        "  -z STRING            the length of STRING is zero\n" ++
        "  STRING1 = STRING2    the strings are equal\n" ++
        "  STRING1 != STRING2   the strings are not equal\n" ++
        "  STRING1 > STRING2    STRING1 is greater than STRING2 in the current locale\n" ++
        "  STRING1 < STRING2    STRING1 is less than STRING2 in the current locale\n" ++
        "\n" ++
        "  INTEGER1 -eq INTEGER2   INTEGER1 is equal to INTEGER2\n" ++
        "  INTEGER1 -ge INTEGER2   INTEGER1 is greater than or equal to INTEGER2\n" ++
        "  INTEGER1 -gt INTEGER2   INTEGER1 is greater than INTEGER2\n" ++
        "  INTEGER1 -le INTEGER2   INTEGER1 is less than or equal to INTEGER2\n" ++
        "  INTEGER1 -lt INTEGER2   INTEGER1 is less than INTEGER2\n" ++
        "  INTEGER1 -ne INTEGER2   INTEGER1 is not equal to INTEGER2\n" ++
        "\n" ++
        "  FILE1 -ef FILE2   FILE1 and FILE2 have the same device and inode numbers\n" ++
        "  FILE1 -nt FILE2   FILE1 is newer (modification date) than FILE2\n" ++
        "  FILE1 -ot FILE2   FILE1 is older than FILE2\n" ++
        "\n" ++
        "  -b FILE     FILE exists and is block special\n" ++
        "  -c FILE     FILE exists and is character special\n" ++
        "  -d FILE     FILE exists and is a directory\n" ++
        "  -e FILE     FILE exists\n" ++
        "  -f FILE     FILE exists and is a regular file\n" ++
        "  -g FILE     FILE exists and is set-group-ID\n" ++
        "  -G FILE     FILE exists and is owned by the effective group ID\n" ++
        "  -h FILE     FILE exists and is a symbolic link (same as -L)\n" ++
        "  -k FILE     FILE exists and has its sticky bit set\n" ++
        "  -L FILE     FILE exists and is a symbolic link (same as -h)\n" ++
        "  -N FILE     FILE exists and has been modified since it was last read\n" ++
        "  -O FILE     FILE exists and is owned by the effective user ID\n" ++
        "  -p FILE     FILE exists and is a named pipe\n" ++
        "  -r FILE     FILE exists and the user has read access\n" ++
        "  -s FILE     FILE exists and has a size greater than zero\n" ++
        "  -S FILE     FILE exists and is a socket\n" ++
        "  -t FD       file descriptor FD is opened on a terminal\n" ++
        "  -u FILE     FILE exists and its set-user-ID bit is set\n" ++
        "  -w FILE     FILE exists and the user has write access\n" ++
        "  -x FILE     FILE exists and the user has execute (or search) access\n" ++
        "\n" ++
        "Except for -h and -L, all FILE-related tests dereference symbolic links.\n" ++
        "Beware that parentheses need to be escaped (e.g., by backslashes) for shells.\n" ++
        "INTEGER may also be -l STRING, which evaluates to the length of STRING.\n" ++
        "\n" ++
        "Binary -a and -o are ambiguous.  Use 'test EXPR1 && test EXPR2'\n" ++
        "or 'test EXPR1 || test EXPR2' instead.\n" ++
        "\n" ++
        "'[' honors --help and --version, but 'test' treats them as STRINGs.\n" ++
        "\n" ++
        "Your shell may have its own version of test and/or [, which usually supersedes\n" ++
        "the version described here.  Please refer to your shell's documentation\n" ++
        "for details about the options it supports.\n" ++
        "\n" ++
        "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>\n" ++
        "Report any translation bugs to <https://translationproject.org/team/>\n" ++
        "Full documentation <https://www.gnu.org/software/coreutils/test>\n" ++
        "or available locally via: info '(coreutils) test invocation'\n")) 0 else 1;
}
