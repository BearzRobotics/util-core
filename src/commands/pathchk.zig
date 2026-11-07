//! pathchk — check whether file names are valid or portable.
//! Reference: GNU coreutils manual "pathchk invocation" (9.7); POSIX.1-2024 pathchk.
//!
//! -p checks the POSIX portable character set and the minimum limits (14
//! bytes per component, 255 per name); -P rejects empty names and components
//! starting with '-'. Without -p the name is looked at with lstat, and the
//! limits are the Linux ones (NAME_MAX 255, PATH_MAX 4096): the `pathconf`
//! values of unusual file systems are not consulted.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");

const help_text = @embedFile("../help/pathchk.txt");

pub fn main(ctx: cli.Context) u8 {
    var basic = false;
    var extra = false;
    var p = getopt.Parser.init(ctx, "pP", &.{
        .{ .name = "portability", .id = 1100 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'p' => basic = true,
            'P' => extra = true,
            1100 => {
                basic = true;
                extra = true;
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
    var status: u8 = 0;
    for (names) |n| if (!validate(ctx, n, basic, extra)) {
        status = 1;
    };
    return status;
}

fn portableChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '/';
}

fn validate(ctx: cli.Context, file: []const u8, basic: bool, extra: bool) bool {
    if (extra and !noLeadingHyphen(ctx, file)) return false;
    if ((basic or extra) and file.len == 0) {
        cli.warn(ctx, "empty file name", .{});
        return false;
    }
    if (basic) {
        for (file) |c| if (!portableChar(c)) {
            var buf: [8]u8 = undefined;
            const shown: []const u8 = switch (c) {
                '\'' => "\\'",
                '\\' => "\\\\",
                7 => "\\a",
                8 => "\\b",
                9 => "\\t",
                10 => "\\n",
                11 => "\\v",
                12 => "\\f",
                13 => "\\r",
                else => if (c < 0x20 or c >= 0x7f)
                    std.fmt.bufPrint(&buf, "\\{o:0>3}", .{c}) catch unreachable
                else
                    @as(*const [1]u8, &c),
            };
            cli.warn(ctx, "non-portable character '{s}' in file name {f}", .{ shown, cli.quoteA(file) });
            return false;
        };
    } else {
        var err: std.os.linux.E = .SUCCESS;
        if (sys.fileStat(file, false, &err) == null) {
            if (err != .NOENT or file.len == 0) {
                cli.warn(ctx, "{f}: {s}", .{ cli.quote(file), sys.errnoText(err) });
                return false;
            }
        }
    }
    const name_max: usize = if (basic) 14 else 255;
    const path_max: usize = if (basic) 256 else 4096;
    if (file.len >= path_max) {
        cli.warn(ctx, "limit {d} exceeded by length {d} of file name {f}", .{ path_max - 1, file.len, cli.quoteA(file) });
        return false;
    }
    var it = std.mem.splitScalar(u8, file, '/');
    while (it.next()) |comp| {
        if (comp.len > name_max) {
            cli.warn(ctx, "limit {d} exceeded by length {d} of file name component {f}", .{ name_max, comp.len, cli.quoteA(comp) });
            return false;
        }
    }
    return true;
}

fn noLeadingHyphen(ctx: cli.Context, file: []const u8) bool {
    var it = std.mem.splitScalar(u8, file, '/');
    while (it.next()) |comp| {
        if (comp.len > 0 and comp[0] == '-') {
            cli.warn(ctx, "leading '-' in a component of file name {f}", .{cli.quoteA(file)});
            return false;
        }
    }
    return true;
}
