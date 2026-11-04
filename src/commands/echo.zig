//! echo — write arguments separated by spaces. Reference: GNU coreutils echo(1).
//!
//! Options -n, -e, -E are recognised only as leading arguments made solely of
//! those letters (e.g. "-neE"); anything else is printed literally. --help and
//! --version are recognised only as the sole argument. Backslash escapes are
//! interpreted only with -e. POSIXLY_CORRECT/XSI behaviour is not implemented.

const std = @import("std");
const cli = @import("../cli.zig");

pub fn main(ctx: cli.Context) u8 {
    var args = ctx.args;
    if (cli.soleArg(args, "--help")) {
        return if (cli.writeStdout(ctx.io, "Usage: echo [SHORT-OPTION]... [STRING]...\n" ++
            "Echo the STRING(s) to standard output.\n\n" ++
            "  -n     do not output the trailing newline\n" ++
            "  -e     enable interpretation of backslash escapes\n" ++
            "  -E     disable interpretation of backslash escapes (default)\n")) 0 else 1;
    }
    if (cli.soleArg(args, "--version")) return if (cli.printVersion(ctx)) 0 else 1;

    var newline = true;
    var escapes = false;
    while (args.len > 0 and isOptionGroup(args[0])) : (args = args[1..]) {
        for (args[0][1..]) |c| switch (c) {
            'n' => newline = false,
            'e' => escapes = true,
            'E' => escapes = false,
            else => unreachable,
        };
    }

    var out = cli.Out.init(ctx.io);
    for (args, 0..) |a, i| {
        if (i > 0) out.writeByte(' ');
        if (escapes) {
            if (writeEscaped(&out, a)) {
                // \c: stop all output, including the newline.
                out.flush();
                return if (out.failed) 1 else 0;
            }
        } else out.write(a);
    }
    if (newline) out.writeByte('\n');
    out.flush();
    return if (out.failed) 1 else 0;
}

/// "-" followed by one or more of n/e/E and nothing else.
fn isOptionGroup(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-') return false;
    for (a[1..]) |c| if (c != 'n' and c != 'e' and c != 'E') return false;
    return true;
}

/// Writes `s` with escapes interpreted. Returns true if \c was seen.
fn writeEscaped(out: *cli.Out, s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 == s.len) {
            out.writeByte(s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'a' => out.writeByte(7),
            'b' => out.writeByte(8),
            'c' => return true,
            'e' => out.writeByte(27),
            'f' => out.writeByte(12),
            'n' => out.writeByte('\n'),
            'r' => out.writeByte('\r'),
            't' => out.writeByte('\t'),
            'v' => out.writeByte(11),
            '\\' => out.writeByte('\\'),
            '0' => { // \0NNN: up to three octal digits after the 0
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i + 1 < s.len and isOct(s[i + 1])) : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                out.writeByte(@truncate(v));
            },
            'x' => { // \xHH: one or two hex digits; none -> literal "\x"
                var v: u8 = 0;
                var n: usize = 0;
                while (n < 2 and i + 1 < s.len) : (n += 1) {
                    const d = std.fmt.charToDigit(s[i + 1], 16) catch break;
                    i += 1;
                    v = v * 16 + d;
                }
                if (n == 0) out.write("\\x") else out.writeByte(v);
            },
            else => {
                out.writeByte('\\');
                out.writeByte(s[i]);
            },
        }
    }
    return false;
}

fn isOct(c: u8) bool {
    return c >= '0' and c <= '7';
}
