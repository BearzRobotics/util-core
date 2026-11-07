//! mkfifo — make named pipes.
//! Reference: GNU coreutils manual "mkfifo invocation" (9.7); POSIX.1-2024 mkfifo.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const mode_mod = @import("../mode.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const help_text = @embedFile("../help/mkfifo.txt");

pub fn main(ctx: cli.Context) u8 {
    var mode_text: ?[]const u8 = null;
    var p = getopt.Parser.init(ctx, "m:Z", &.{
        .{ .name = "mode", .arg = .required, .id = 'm' },
        .{ .name = "context", .arg = .optional, .id = 'Z' },
    });
    defer p.deinit();
    var context_warned = false;
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'm' => mode_text = o.arg,
            'Z' => if (o.arg != null and !context_warned) {
                context_warned = true;
                cli.warn(ctx, "warning: ignoring --context; it requires an SELinux/SMACK-enabled kernel", .{});
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const names = p.operands.items;
    if (names.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 1;
    }
    const umask = sys.umask();
    var final: ?u16 = null;
    if (mode_text) |t| {
        final = mode_mod.apply(t, 0o666, false, umask) orelse {
            cli.warn(ctx, "invalid mode", .{});
            return 1;
        };
        if (final.? > 0o777) {
            cli.warn(ctx, "mode must specify only file permission bits", .{});
            return 1;
        }
    }
    var status: u8 = 0;
    for (names) |name| {
        const z = ctx.gpa.dupeSentinel(u8, name, 0) catch return 1;
        defer ctx.gpa.free(z);
        // With -m the exact mode is set afterwards, so the umask cannot take bits away.
        if (sys.mknod(z, 0o010000 | (final orelse 0o666), 0)) |e| {
            cli.warn(ctx, "cannot create fifo {f}: {s}", .{ cli.quoteA(name), sys.errnoText(e) });
            status = 1;
            continue;
        }
        if (final) |m| Io.Dir.cwd().setFilePermissions(ctx.io, name, .fromMode(m), .{}) catch |e| {
            cli.warn(ctx, "cannot set permissions of {f}: {s}", .{ cli.quoteA(name), cli.errText(e) });
            status = 1;
        };
    }
    return status;
}
