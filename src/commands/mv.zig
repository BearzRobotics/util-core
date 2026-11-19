// SPDX-License-Identifier: GPL-2.0-or-later
//! mv: thin wrapper over `util_core.mv` (decision 0004). Parses arguments the
//! way GNU mv does, decides what the destination is and words the usage
//! diagnostics; moving is done by src/lib/mv.zig over the shared engine in
//! src/copy.zig. `--exchange` is not implemented.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const copy = @import("../copy.zig");
const backup_args = @import("../backup_args.zig");
const mv = @import("../lib/mv.zig");
const copy_cli = @import("../copy_cli.zig");
const argmatch = @import("../argmatch.zig");
const Io = std.Io;
const E = std.os.linux.E;

const help_text = @embedFile("../help/mv.txt");

const update_table = [_]argmatch.Entry{ .{ .name = "all", .value = 0 }, .{ .name = "none", .value = 1 }, .{ .name = "none-fail", .value = 2 }, .{ .name = "older", .value = 3 } };

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

pub fn main(ctx: cli.Context) u8 {
    var out = cli.Out.init(ctx.io);
    const rc = run(ctx, &out);
    out.flush();
    return rc;
}

fn run(ctx: cli.Context, out: *cli.Out) u8 {
    var x: copy.Opts = .{};
    x.copy_as_regular = false;
    x.dereference = .never;
    x.move_mode = true;
    x.preserve_ownership = true;
    x.preserve_links = true;
    x.preserve_mode = true;
    x.preserve_timestamps = true;
    x.recursive = true;
    x.stdin_tty = Io.File.stdin().isTty(ctx.io) catch false;
    x.chown_privileges = sys.identity().euid == 0;
    x.owner_privileges = x.chown_privileges;
    var make_backups = false;
    var backup_suffix: ?[]const u8 = null;
    var version_control: ?[]const u8 = null;
    var remove_trailing_slashes = false;
    var target_directory: ?[]const u8 = null;
    var no_target_directory = false;

    var p = getopt.Parser.init(ctx, "bfint:uvS:TZ", &.{
        .{ .name = "backup", .arg = .optional, .id = 'b' },
        .{ .name = "context", .id = 'Z' },
        .{ .name = "debug", .id = 1100 },
        .{ .name = "exchange", .id = 1101 },
        .{ .name = "force", .id = 'f' },
        .{ .name = "interactive", .id = 'i' },
        .{ .name = "no-clobber", .id = 'n' },
        .{ .name = "no-copy", .id = 1102 },
        .{ .name = "no-target-directory", .id = 'T' },
        .{ .name = "strip-trailing-slashes", .id = 1103 },
        .{ .name = "suffix", .arg = .required, .id = 'S' },
        .{ .name = "target-directory", .arg = .required, .id = 't' },
        .{ .name = "update", .arg = .optional, .id = 'u' },
        .{ .name = "verbose", .id = 'v' },
    });
    defer p.deinit();
    var exchange = false;
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'b' => {
                make_backups = true;
                if (o.arg) |a| version_control = a;
            },
            'f' => x.interactive = .always_yes,
            'i' => x.interactive = .ask_user,
            'n' => x.interactive = .always_skip,
            1100 => {
                x.debug = true;
                x.verbose = true;
            },
            1101 => exchange = true,
            1102 => x.no_copy = true,
            1103 => remove_trailing_slashes = true,
            't' => {
                if (target_directory != null) {
                    cli.warn(ctx, "multiple target directories specified", .{});
                    return 1;
                }
                target_directory = o.arg.?;
            },
            'T' => no_target_directory = true,
            'u' => {
                x.update = .older;
                if (o.arg) |a| {
                    const r = argmatch.match(a, &update_table);
                    switch (r) {
                        .ok => |v| x.update = @enumFromInt(v),
                        else => {
                            argmatch.die(ctx, a, "--update", &update_table, r);
                            return 1;
                        },
                    }
                }
            },
            'v' => x.verbose = true,
            'S' => {
                make_backups = true;
                backup_suffix = o.arg.?;
            },
            'Z' => {},
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (exchange) {
        cli.warn(ctx, "--exchange is not supported", .{});
        return 1;
    }
    var operands = p.operands.items;
    var n_files = operands.len;
    if (n_files <= @intFromBool(target_directory == null)) {
        if (n_files == 0) {
            cli.warn(ctx, "missing file operand", .{});
        } else cli.warn(ctx, "missing destination file operand after {f}", .{cli.quoteA(operands[0])});
        return usageFail(ctx);
    }
    var e: E = .SUCCESS;
    if (no_target_directory) {
        if (target_directory != null) {
            cli.warn(ctx, "cannot combine --target-directory (-t) and --no-target-directory (-T)", .{});
            return 1;
        }
        if (n_files > 2) {
            cli.warn(ctx, "extra operand {f}", .{cli.quoteA(operands[2])});
            return usageFail(ctx);
        }
    } else if (target_directory) |t| {
        const st = sys.fileStat(t, true, &e);
        if (st == null or !st.?.isDir()) {
            cli.warn(ctx, "target directory {f}: {s}", .{ cli.quoteA(t), sys.errnoText(if (st == null) e else .NOTDIR) });
            return 1;
        }
    } else {
        const last = operands[n_files - 1];
        if (n_files == 2) {
            x.rename_errno = mv.probeRename(operands[0], last);
        }
        if (x.rename_errno != 0) {
            const st = sys.fileStat(last, true, &e);
            if (st != null and st.?.isDir()) {
                x.rename_errno = -1;
                target_directory = last;
                n_files -= 1;
            } else {
                const err: E = if (st == null) e else .NOTDIR;
                if (n_files > 2) {
                    cli.warn(ctx, "target {f}: {s}", .{ cli.quoteA(last), sys.errnoText(err) });
                    return 1;
                }
            }
        }
    }
    if (remove_trailing_slashes) {
        // Applied to a copy of the operand list below.
    }
    if (x.interactive == .always_skip) x.update = .none;
    if (make_backups and (x.update == .none or x.update == .none_fail)) {
        cli.warn(ctx, "cannot combine --backup with --exchange, -n, or --update=none-fail", .{});
        return usageFail(ctx);
    }
    x.backup_type = if (make_backups) (backup_args.parseVersion(ctx, "backup type", version_control) orelse return 1) else .none;
    x.backup_suffix = backup_args.simpleSuffix(ctx, backup_suffix);
    x.umask = sys.currentUmask();

    var routing: copy_cli.Routing = .{ .ctx = ctx, .out = out };
    const env: mv.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const ok = if (target_directory) |td|
        mv.run(env, x, operands[0..n_files], .{
            .destination = .{ .directory = td },
            .strip_trailing_slashes = remove_trailing_slashes,
        }, routing.sink()) catch return 1
    else
        mv.run(env, x, operands[0..2], .{
            .destination = .file,
            .strip_trailing_slashes = remove_trailing_slashes,
        }, routing.sink()) catch return 1;
    operands = &.{};
    return if (ok) 0 else 1;
}
