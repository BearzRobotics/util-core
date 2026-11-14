// SPDX-License-Identifier: GPL-2.0-or-later
//! printenv — print environment variables.
//! Reference: GNU coreutils manual "printenv invocation" (9.7). POSIX does not
//! specify printenv.
//!
//! No operands: print every NAME=value. With operands: print the value of each
//! variable that is set (a name containing '=' is never found). Exit status:
//! 0 all found, 1 some not found, 2 usage or write error (as the GNU manual).

const std = @import("std");
const cli = @import("../cli.zig");
const json = @import("../json.zig");

const long_names = [_][]const u8{ "null", "help", "version", "json" };

pub fn main(ctx: cli.Context) u8 {
    var term: u8 = '\n';
    var as_json = false;
    var i: usize = 0;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => term = 0,
                    1 => return if (cli.writeStdout(ctx.io, "Usage: printenv [OPTION]... [VARIABLE]...\n" ++
                        "Print the values of the specified environment VARIABLE(s).\n" ++
                        "If no VARIABLE is specified, print name and value pairs for them all.\n\n" ++
                        "  -0, --null     end each output line with NUL, not newline\n" ++
                        "      --help     display this help and exit\n" ++
                        "      --version  output version information and exit\n")) 0 else 2,
                    3 => as_json = true,
                    else => return if (cli.printVersion(ctx)) 0 else 2,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 2;
                },
            }
        } else for (a[1..]) |c| switch (c) {
            '0' => term = 0,
            else => {
                cli.invalidShort(ctx, c);
                return 2;
            },
        };
    }
    const names = ctx.args[i..];
    if (as_json and term == 0) {
        cli.warn(ctx, "--json cannot be combined with -0", .{});
        return 2;
    }
    const env = ctx.environ orelse return if (names.len == 0) 0 else 1;

    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    if (as_json) {
        // One object of NAME: value; a requested name that is not set is
        // left out and makes the status 1, as in the text form.
        var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        var first = true;
        w.writeByte('{') catch return 2;
        if (names.len == 0) {
            var it = env.iterator();
            while (it.next()) |e| {
                if (!first) w.writeByte(',') catch return 2;
                first = false;
                json.writeString(w, e.key_ptr.*) catch return 2;
                w.writeByte(':') catch return 2;
                json.writeString(w, e.value_ptr.*) catch return 2;
            }
        } else for (names) |n| {
            const v = if (std.mem.indexOfScalar(u8, n, '=') == null) env.get(n) else null;
            if (v) |value| {
                if (!first) w.writeByte(',') catch return 2;
                first = false;
                json.writeString(w, n) catch return 2;
                w.writeByte(':') catch return 2;
                json.writeString(w, value) catch return 2;
            } else status = 1;
        }
        w.writeAll("}\n") catch return 2;
        out.write(aw.written());
        out.flush();
        return if (out.failed) 2 else status;
    }
    if (names.len == 0) {
        var it = env.iterator();
        while (it.next()) |e| {
            out.write(e.key_ptr.*);
            out.writeByte('=');
            out.write(e.value_ptr.*);
            out.writeByte(term);
        }
    } else for (names) |n| {
        if (std.mem.indexOfScalar(u8, n, '=') == null) if (env.get(n)) |v| {
            out.write(v);
            out.writeByte(term);
            continue;
        };
        status = 1;
    }
    out.flush();
    return if (out.failed) 2 else status;
}
