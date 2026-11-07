//! sync — flush file system buffers.
//! Reference: GNU coreutils manual "sync invocation" (9.7); POSIX.1-2024 sync.
//!
//! No operands: sync(2). With files: fsync, or fdatasync with -d, or syncfs
//! with -f, on each named file.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const help_text = @embedFile("../help/sync.txt");

pub fn main(ctx: cli.Context) u8 {
    var data = false;
    var fs = false;
    var p = getopt.Parser.init(ctx, "df", &.{
        .{ .name = "data", .id = 'd' },
        .{ .name = "file-system", .id = 'f' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'd' => data = true,
            'f' => fs = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const files = p.operands.items;
    if (data and fs) {
        cli.warn(ctx, "cannot specify both --data and --file-system", .{});
        return 1;
    }
    if (data and files.len == 0) {
        cli.warn(ctx, "--data needs at least one argument", .{});
        return 1;
    }
    if (files.len == 0) {
        _ = sys.syncFile(-1, .all);
        return 0;
    }
    var status: u8 = 0;
    for (files) |name| {
        const f = Io.Dir.cwd().openFile(ctx.io, name, .{ .mode = .read_only, .allow_directory = true }) catch |e| {
            cli.warn(ctx, "error opening {f}: {s}", .{ cli.quoteA(name), cli.errText(e) });
            status = 1;
            continue;
        };
        defer f.close(ctx.io);
        const kind: sys.SyncKind = if (data) .data else if (fs) .fs else .file;
        if (sys.syncFile(f.handle, kind)) |e| {
            cli.warn(ctx, "error syncing {f}: {s}", .{ cli.quoteA(name), sys.errnoText(e) });
            status = 1;
        }
    }
    return status;
}
