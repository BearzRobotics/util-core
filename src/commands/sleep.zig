// SPDX-License-Identifier: GPL-2.0-or-later
//! sleep — delay for a specified time.
//! References: GNU coreutils manual "sleep invocation" (9.7); POSIX.1-2024
//! sleep (a single non-negative decimal integer number of seconds).
//!
//! GNU extension followed here: one or more operands NUMBER[smhd], summed;
//! NUMBER may be fractional, have an exponent, be hexadecimal or "inf".
//! Not implemented: parsing in the current locale's decimal point.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn main(ctx: cli.Context) u8 {
    var i: usize = 0;
    var total: f64 = 0;
    var operands: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            // Everything after "--" is an operand.
            for (ctx.args[i + 1 ..]) |op| {
                total += parseInterval(op) orelse return invalid(ctx, op);
                operands += 1;
            }
            break;
        }
        if (std.mem.eql(u8, a, "--help")) return help(ctx);
        if (std.mem.eql(u8, a, "--version")) return if (cli.printVersion(ctx)) 0 else 1;
        if (a.len >= 2 and a[0] == '-' and !isNumberStart(a[1])) {
            if (a[1] == '-') {
                cli.badLong(ctx, a, .none);
            } else cli.invalidShort(ctx, a[1]);
            return 1;
        }
        total += parseInterval(a) orelse return invalid(ctx, a);
        operands += 1;
    }
    if (operands == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    const max_ns: f64 = @floatFromInt(std.math.maxInt(i96));
    const ns = total * std.time.ns_per_s;
    const forever = std.math.isInf(total) or ns >= max_ns;
    // A finite sleep is done in one call; "inf" sleeps in long slices forever.
    while (true) {
        const d: std.Io.Duration = if (forever)
            .fromSeconds(std.math.maxInt(i32))
        else
            .fromNanoseconds(@intFromFloat(ns));
        std.Io.sleep(ctx.io, d, .awake) catch return 1;
        if (!forever) return 0;
    }
}

fn isNumberStart(c: u8) bool {
    return std.ascii.isDigit(c) or c == '.';
}

fn invalid(ctx: cli.Context, text: []const u8) u8 {
    cli.warn(ctx, "invalid time interval '{s}'\nTry '{s} --help' for more information.", .{ text, ctx.name });
    return 1;
}

/// Seconds denoted by one operand, or null when it is invalid. Negative and
/// NaN values are invalid (GNU rejects anything not >= 0).
pub fn parseInterval(text: []const u8) ?f64 {
    if (text.len == 0) return null;
    var body = text;
    var mult: f64 = 1;
    switch (text[text.len - 1]) {
        's' => body = text[0 .. text.len - 1],
        'm' => {
            body = text[0 .. text.len - 1];
            mult = 60;
        },
        'h' => {
            body = text[0 .. text.len - 1];
            mult = 3600;
        },
        'd' => {
            body = text[0 .. text.len - 1];
            mult = 86400;
        },
        else => {},
    }
    if (body.len == 0 or body[0] == '+' and body.len == 1) return null;
    const v = std.fmt.parseFloat(f64, body) catch return null;
    if (std.math.isNan(v) or v < 0) return null;
    return v * mult;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: sleep NUMBER[SUFFIX]...\n" ++
        "  or:  sleep OPTION\n" ++
        "Pause for NUMBER seconds.  SUFFIX may be 's' for seconds (the default),\n" ++
        "'m' for minutes, 'h' for hours or 'd' for days.  NUMBER need not be an\n" ++
        "integer.  Given two or more arguments, pause for the amount of time\n" ++
        "specified by the sum of their values.\n\n" ++
        "      --help     display this help and exit\n" ++
        "      --version  output version information and exit\n")) 0 else 1;
}

test "parseInterval" {
    const t = std.testing;
    try t.expectEqual(@as(?f64, 5), parseInterval("5"));
    try t.expectEqual(@as(?f64, 0.5), parseInterval("0.5"));
    try t.expectEqual(@as(?f64, 120), parseInterval("2m"));
    try t.expectEqual(@as(?f64, 7200), parseInterval("2h"));
    try t.expectEqual(@as(?f64, 86400), parseInterval("1d"));
    try t.expectEqual(@as(?f64, 1.5), parseInterval("1.5s"));
    try t.expectEqual(@as(?f64, 1), parseInterval("1e0"));
    try t.expect(std.math.isInf(parseInterval("inf").?));
    try t.expect(parseInterval("") == null);
    try t.expect(parseInterval("-1") == null);
    try t.expect(parseInterval("abc") == null);
    try t.expect(parseInterval("s") == null);
    try t.expect(parseInterval("nan") == null);
}
