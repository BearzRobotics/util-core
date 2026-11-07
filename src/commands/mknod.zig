//! mknod — make block or character special files, or named pipes.
//! Reference: GNU coreutils manual "mknod invocation" (9.7); POSIX.1-2024
//! does not specify mknod. Block and character devices need privilege.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const mode_mod = @import("../mode.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const help_text = @embedFile("../help/mknod.txt");

fn parseNum(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(u64, text, 0) catch null;
}

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
    const ops = p.operands.items;
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
    if (ops.len == 0) {
        getopt.usageError(ctx, "missing operand", .{});
        return 1;
    }
    if (ops.len == 1) {
        getopt.usageError(ctx, "missing operand after {f}", .{cli.quoteC(ops[0])});
        return 1;
    }
    const name = ops[0];
    const type_text = ops[1];
    // GNU looks only at the first character of TYPE, and checks the operand
    // count before it complains about an unknown type.
    const kind: u8 = if (type_text.len > 0) type_text[0] else 0;
    const is_fifo = kind == 'p';
    var rest = ops[2..];
    var dev: u64 = 0;
    if (is_fifo and rest.len > 0) {
        // GNU adds the explanation only when exactly MAJOR and MINOR were given.
        if (rest.len == 2)
            getopt.usageError(ctx, "extra operand {f}\nFifos do not have major and minor device numbers.", .{cli.quoteC(rest[0])})
        else
            getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(rest[0])});
        return 1;
    }
    if (!is_fifo) {
        if (rest.len == 0) {
            getopt.usageError(ctx, "missing operand after {f}\nSpecial files require major and minor device numbers.", .{cli.quoteC(type_text)});
            return 1;
        }
        if (rest.len == 1) {
            getopt.usageError(ctx, "missing operand after {f}", .{cli.quoteC(rest[0])});
            return 1;
        }
        if (rest.len > 2) {
            getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(rest[2])});
            return 1;
        }
    }
    const file_type: u32 = switch (kind) {
        'b' => 0o060000,
        'c', 'u' => 0o020000,
        'p' => 0o010000,
        else => {
            getopt.usageError(ctx, "invalid device type {f}", .{cli.quoteC(type_text)});
            return 1;
        },
    };
    if (!is_fifo) {
        const major = parseNum(rest[0]) orelse {
            cli.warn(ctx, "invalid major device number {f}", .{cli.quoteC(rest[0])});
            return 1;
        };
        const minor = parseNum(rest[1]) orelse {
            cli.warn(ctx, "invalid minor device number {f}", .{cli.quoteC(rest[1])});
            return 1;
        };
        // glibc makedev(): split the numbers into the kernel's dev_t layout.
        dev = ((major & 0xfffff000) << 32) | ((major & 0xfff) << 8) | ((minor & 0xffffff00) << 12) | (minor & 0xff);
        rest = rest[2..];
    }
    const z = ctx.gpa.dupeSentinel(u8, name, 0) catch return 1;
    defer ctx.gpa.free(z);
    if (sys.mknod(z, file_type | (final orelse 0o666), dev)) |e| {
        cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), sys.errnoText(e) });
        return 1;
    }
    if (final) |m| Io.Dir.cwd().setFilePermissions(ctx.io, name, .fromMode(m), .{}) catch |e| {
        cli.warn(ctx, "cannot set permissions of {f}: {s}", .{ cli.quoteA(name), cli.errText(e) });
        return 1;
    };
    return 0;
}
