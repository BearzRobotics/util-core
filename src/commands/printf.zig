// SPDX-License-Identifier: GPL-2.0-or-later
//! printf: thin wrapper over `util_core.printf` (decision 0004). Handles the
//! --help/--version/-- convention and words the diagnostics; formatting,
//! escapes and argument conversion are in src/lib/printf.zig.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const printf = @import("../lib/printf.zig");

pub fn main(ctx: cli.Context) u8 {
    var args: []const [:0]const u8 = ctx.args;
    if (args.len > 0 and std.mem.eql(u8, args[0], "--help")) return help(ctx);
    if (args.len > 0 and std.mem.eql(u8, args[0], "--version")) return if (cli.printVersion(ctx)) 0 else 1;
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args = args[1..];
    if (args.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    const format = args[0];
    // A slice of sentinel-terminated slices has the layout of a slice of slices.
    const operands: []const []const u8 = @ptrCast(args[1..]);

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: printf.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = printf.run(env, format, operands, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => {
            cli.warn(ctx, "memory exhausted", .{});
            return 1;
        },
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    if (result.excess_argument) |first| {
        var wb: [4400]u8 = undefined;
        const line = std.fmt.bufPrint(&wb, "{s}: warning: ignoring excess arguments, starting with {f}\n", .{ ctx.name, cli.quoteC(first) }) catch "";
        Io.File.stderr().writeStreamingAll(ctx.io, line) catch {};
    }
    return result.status;
}

fn report(context: ?*anyopaque, ev: printf.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .missing_hex_digits => cli.warn(ctx.*, "missing hexadecimal number in escape", .{}),
        .invalid_universal_name => |h| cli.warn(ctx.*, "invalid universal character name \\u{s}", .{h}),
        .invalid_spec => |t| cli.warn(ctx.*, "{s}: invalid conversion specification", .{t}),
        .not_numeric => |t| cli.warn(ctx.*, "{f}: expected a numeric value", .{cli.quoteC(t)}),
        .partial_number => |t| cli.warn(ctx.*, "{f}: value not completely converted", .{cli.quoteC(t)}),
        .number_out_of_range => |t| cli.warn(ctx.*, "{f}: Numerical result out of range", .{cli.quoteC(t)}),
        .invalid_width => |t| cli.warn(ctx.*, "invalid field width: {f}", .{cli.quoteC(t)}),
        .invalid_precision => |t| cli.warn(ctx.*, "invalid precision: {f}", .{cli.quoteC(t)}),
        .field_too_wide => cli.warn(ctx.*, "write error: field width or precision too large", .{}),
        .char_constant_extra => |rest| {
            var buf: [4400]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}: warning: {s}: character(s) following character constant have been ignored\n", .{ ctx.name, rest }) catch return;
            Io.File.stderr().writeStreamingAll(ctx.io, line) catch {};
        },
    }
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: printf FORMAT [ARGUMENT]...\n  or:  printf OPTION\nPrint ARGUMENT(s) according to FORMAT, or execute according to OPTION:\n\n      --help        display this help and exit\n      --version     output version information and exit\n\nFORMAT controls the output as in C printf.  Interpreted sequences are:\n\n  \\\"      double quote\n  \\\\      backslash\n  \\a      alert (BEL)\n  \\b      backspace\n  \\c      produce no further output\n  \\e      escape\n  \\f      form feed\n  \\n      new line\n  \\r      carriage return\n  \\t      horizontal tab\n  \\v      vertical tab\n  \\NNN    byte with octal value NNN (1 to 3 digits)\n  \\xHH    byte with hexadecimal value HH (1 to 2 digits)\n  \\uHHHH  Unicode (ISO/IEC 10646) character with hex value HHHH (4 digits)\n  \\UHHHHHHHH  Unicode character with hex value HHHHHHHH (8 digits)\n  %%      a single %\n  %b      ARGUMENT as a string with '\\' escapes interpreted,\n          except that octal escapes are of the form \\0 or \\0NNN\n  %q      ARGUMENT is printed in a format that can be reused as shell input,\n          escaping non-printable characters with the proposed POSIX $'' syntax.\n\nand all C format specifications ending with one of diouxXfeEgGcs, with\nARGUMENTs converted to proper type first.  Variable widths are handled.\n")) 0 else 1;
}
