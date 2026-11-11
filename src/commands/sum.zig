// SPDX-License-Identifier: GPL-2.0-or-later
//! sum — checksum and block count (BSD or System V algorithm).
//! Reference: GNU coreutils manual "sum invocation" (9.7).
//!
//! Output: "SUM BLOCKS [NAME]". The BSD form (default, -r) writes the 16-bit
//! checksum with five digits and the block count (1024-byte blocks) right
//! aligned in five columns; the System V form (-s) uses plain numbers and
//! 512-byte blocks. A name is printed when at least one file operand is given.

const std = @import("std");
const cli = @import("../cli.zig");
const hash = @import("../hash.zig");

const long_names = [_][]const u8{ "sysv", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var sysv = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
        } else if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
        } else if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            switch (m) {
                .found => |k| {
                    if (eq != null) {
                        cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                        return 1;
                    }
                    switch (k) {
                        0 => sysv = true,
                        1 => return help(ctx),
                        else => return if (cli.printVersion(ctx)) 0 else 1,
                    }
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        } else for (a[1..]) |c| switch (c) {
            'r' => sysv = false,
            's' => sysv = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    var out = cli.Out.init(ctx.io);
    var buf: [64 * 1024]u8 = undefined;
    var status: u8 = 0;
    for (inputs) |name| {
        const file = cli.openInput(ctx.io, name) catch |e| {
            out.flush();
            cli.warn(ctx, "{s}: {s}", .{ name, cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        var bsd: hash.BsdSum = .{};
        var sys5: hash.SysvSum = .{};
        var failed = false;
        while (true) {
            const n = cli.readChunk(ctx.io, file, &buf) catch |e| {
                out.flush();
                cli.warn(ctx, "{s}: {s}", .{ name, cli.errText(e) });
                failed = true;
                break;
            };
            if (n == 0) break;
            if (sysv) sys5.update(buf[0..n]) else bsd.update(buf[0..n]);
        }
        if (failed) {
            status = 1;
            continue;
        }
        if (sysv) {
            out.print("{d} {d}", .{ sys5.final(), (sys5.len + 511) / 512 });
        } else {
            out.print("{d:0>5} {d: >5}", .{ bsd.sum, (bsd.len + 1023) / 1024 });
        }
        if (files.items.len > 0) {
            out.writeByte(' ');
            out.write(name);
        }
        out.writeByte('\n');
        if (out.failed) break;
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return status;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: sum [OPTION]... [FILE]...\n" ++
        "Print or check BSD (16-bit) checksums.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "  -r              use BSD sum algorithm (the default), use 1K blocks\n" ++
        "  -s, --sysv      use System V sum algorithm, use 512 bytes blocks\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
