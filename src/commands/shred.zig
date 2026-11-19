// SPDX-License-Identifier: GPL-2.0-or-later
//! shred: thin wrapper over `util_core.shred` (decision 0004). Parses
//! arguments the way GNU shred does, opens the --random-source file and
//! routes the library's diagnostics; the passes and the file-name wiping are
//! in src/lib/shred.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const shred = @import("../lib/shred.zig");
const human = @import("../human.zig");
const argmatch = @import("../argmatch.zig");
const Io = std.Io;
const E = std.os.linux.E;

const help_text = @embedFile("../help/shred.txt");

const Remove = shred.Remove;
const remove_table = [_]argmatch.Entry{ .{ .name = "unlink", .value = 1 }, .{ .name = "wipe", .value = 2 }, .{ .name = "wipesync", .value = 3 } };

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

pub fn main(ctx: cli.Context) u8 {
    var o: shred.Options = .{};
    var random_source: ?[]const u8 = null;
    var p = getopt.Parser.init(ctx, "fn:s:uvxz", &.{
        .{ .name = "exact", .id = 'x' },
        .{ .name = "force", .id = 'f' },
        .{ .name = "iterations", .arg = .required, .id = 'n' },
        .{ .name = "size", .arg = .required, .id = 's' },
        .{ .name = "random-source", .arg = .required, .id = 1100 },
        .{ .name = "remove", .arg = .optional, .id = 'u' },
        .{ .name = "verbose", .id = 'v' },
        .{ .name = "zero", .id = 'z' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |opt| switch (opt.id) {
            'f' => o.force = true,
            'n' => {
                const r = human.strtoumaxBase(opt.arg.?, "", true);
                if (r.err != .ok or r.value > std.math.maxInt(usize) / 4) {
                    if (r.err == .overflow)
                        cli.warn(ctx, "invalid number of passes: {f}: Value too large for defined data type", .{cli.quoteC(opt.arg.?)})
                    else
                        cli.warn(ctx, "invalid number of passes: {f}", .{cli.quoteC(opt.arg.?)});
                    return 1;
                }
                o.n_iterations = r.value;
            },
            1100 => {
                if (random_source != null and !std.mem.eql(u8, random_source.?, opt.arg.?)) {
                    cli.warn(ctx, "multiple random sources specified", .{});
                    return 1;
                }
                random_source = opt.arg.?;
            },
            'u' => {
                if (opt.arg) |a| {
                    const r = argmatch.match(a, &remove_table);
                    switch (r) {
                        .ok => |v| o.remove = @enumFromInt(v),
                        else => {
                            argmatch.die(ctx, a, "--remove", &remove_table, r);
                            return 1;
                        },
                    }
                } else o.remove = .wipesync;
            },
            's' => {
                const r = human.strtoumaxBase(opt.arg.?, "cbBkKMGTPEZYRQ0", true);
                if (r.err != .ok or r.value > std.math.maxInt(i64)) {
                    cli.warn(ctx, "invalid file size: {f}", .{cli.quoteC(opt.arg.?)});
                    return 1;
                }
                o.size = @intCast(r.value);
            },
            'v' => o.verbose = true,
            'x' => o.exact = true,
            'z' => o.zero_fill = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const files = p.operands.items;
    if (files.len == 0) {
        cli.warn(ctx, "missing file operand", .{});
        return usageFail(ctx);
    }
    var random_file: ?Io.File = null;
    if (random_source) |rs| {
        random_file = Io.Dir.cwd().openFile(ctx.io, rs, .{}) catch |err| {
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(rs), cli.errText(err) });
            return 1;
        };
    }
    defer if (random_file) |f| f.close(ctx.io);
    o.random_source = random_file;

    const env: shred.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const ok = shred.run(env, o, files, .{ .context = @constCast(&ctx), .func = report }) catch |err| switch (err) {
        error.OutOfMemory => return 1,
        error.RandomSourceExhausted => {
            cli.warn(ctx, "{f}: end of file", .{cli.quoteA(random_source orelse "getrandom")});
            return 1;
        },
    };
    return if (ok) 0 else 1;
}

fn report(context: ?*anyopaque, ev: shred.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .diag => |t| cli.warn(ctx.*, "{s}", .{t}),
    }
}
