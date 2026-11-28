// SPDX-License-Identifier: GPL-2.0-or-later
//! cp: thin wrapper over `util_core.cp` (decision 0004). Parses arguments the
//! way GNU cp does, decides what the destination is and words the usage
//! diagnostics; copying is done by src/lib/cp.zig over the shared engine in
//! src/copy.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const copy = @import("../copy.zig");
const backup_args = @import("../backup_args.zig");
const cp = @import("../lib/cp.zig");
const copy_cli = @import("../copy_cli.zig");
const argmatch = @import("../argmatch.zig");
const Io = std.Io;
const E = std.os.linux.E;

const help_text = @embedFile("../help/cp.txt");

const sparse_table = [_]argmatch.Entry{ .{ .name = "never", .value = 0 }, .{ .name = "auto", .value = 1 }, .{ .name = "always", .value = 2 } };
const reflink_table = [_]argmatch.Entry{ .{ .name = "auto", .value = 0 }, .{ .name = "always", .value = 1 }, .{ .name = "never", .value = 2 } };
const update_table = [_]argmatch.Entry{ .{ .name = "all", .value = 0 }, .{ .name = "none", .value = 1 }, .{ .name = "none-fail", .value = 2 }, .{ .name = "older", .value = 3 } };
const preserve_table = [_]argmatch.Entry{
    .{ .name = "mode", .value = 0 },    .{ .name = "timestamps", .value = 1 }, .{ .name = "ownership", .value = 2 },
    .{ .name = "links", .value = 3 },   .{ .name = "context", .value = 4 },    .{ .name = "xattr", .value = 5 },
    .{ .name = "all", .value = 6 },
};

fn decodePreserve(ctx: cli.Context, arg: []const u8, x: *copy.Opts, on: bool, opt: []const u8) bool {
    var it = std.mem.splitScalar(u8, arg, ',');
    while (it.next()) |tok| {
        const r = argmatch.match(tok, &preserve_table);
        const v: u32 = switch (r) {
            .ok => |n| n,
            else => {
                argmatch.die(ctx, tok, opt, &preserve_table, r);
                return false;
            },
        };
        switch (v) {
            0 => {
                x.preserve_mode = on;
                x.explicit_no_preserve_mode = !on;
            },
            1 => x.preserve_timestamps = on,
            2 => x.preserve_ownership = on,
            3 => x.preserve_links = on,
            4 => if (on) {
                cli.warn(ctx, "cannot preserve security context without an SELinux-enabled kernel", .{});
                return false;
            },
            5 => {},
            else => {
                x.preserve_mode = on;
                x.preserve_timestamps = on;
                x.preserve_ownership = on;
                x.preserve_links = on;
                x.explicit_no_preserve_mode = !on;
            },
        }
    }
    return true;
}

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
    x.copy_as_regular = true;
    x.open_dangling_dest_symlink = cli.getenv(ctx, "POSIXLY_CORRECT") != null;
    x.chown_privileges = sys.identity().euid == 0;
    x.owner_privileges = x.chown_privileges;
    var make_backups = false;
    var backup_suffix: ?[]const u8 = null;
    var version_control: ?[]const u8 = null;
    var copy_contents = false;
    var target_directory: ?[]const u8 = null;
    var no_target_directory = false;
    var parents_option = false;
    var remove_trailing_slashes = false;

    var p = getopt.Parser.init(ctx, "abdfHilLnprst:uvxPRS:TZ", &.{
        .{ .name = "archive", .id = 'a' },
        .{ .name = "attributes-only", .id = 1100 },
        .{ .name = "backup", .arg = .optional, .id = 1101 },
        .{ .name = "copy-contents", .id = 1102 },
        .{ .name = "debug", .id = 1103 },
        .{ .name = "dereference", .id = 'L' },
        .{ .name = "force", .id = 'f' },
        .{ .name = "interactive", .id = 'i' },
        .{ .name = "link", .id = 'l' },
        .{ .name = "no-clobber", .id = 'n' },
        .{ .name = "no-dereference", .id = 'P' },
        .{ .name = "no-preserve", .arg = .required, .id = 1104 },
        .{ .name = "no-target-directory", .id = 'T' },
        .{ .name = "one-file-system", .id = 'x' },
        .{ .name = "parents", .id = 1105 },
        .{ .name = "path", .id = 1105 },
        .{ .name = "preserve", .arg = .optional, .id = 1106 },
        .{ .name = "recursive", .id = 'R' },
        .{ .name = "remove-destination", .id = 1107 },
        .{ .name = "sparse", .arg = .required, .id = 1108 },
        .{ .name = "reflink", .arg = .optional, .id = 1109 },
        .{ .name = "strip-trailing-slashes", .id = 1110 },
        .{ .name = "suffix", .arg = .required, .id = 'S' },
        .{ .name = "symbolic-link", .id = 's' },
        .{ .name = "target-directory", .arg = .required, .id = 't' },
        .{ .name = "update", .arg = .optional, .id = 1111 },
        .{ .name = "verbose", .id = 'v' },
        .{ .name = "keep-directory-symlink", .id = 1112 },
        .{ .name = "context", .arg = .optional, .id = 1113 },
    });
    defer p.deinit();

    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            1108 => {
                const r = argmatch.match(o.arg.?, &sparse_table);
                switch (r) {
                    .ok => |v| x.sparse = @enumFromInt(v),
                    else => {
                        argmatch.die(ctx, o.arg.?, "--sparse", &sparse_table, r);
                        return 1;
                    },
                }
            },
            1109 => {
                if (o.arg) |a| {
                    const r = argmatch.match(a, &reflink_table);
                    switch (r) {
                        .ok => |v| x.reflink = @enumFromInt(v),
                        else => {
                            argmatch.die(ctx, a, "--reflink", &reflink_table, r);
                            return 1;
                        },
                    }
                } else x.reflink = .always;
            },
            'a' => {
                x.dereference = .never;
                x.preserve_links = true;
                x.preserve_ownership = true;
                x.preserve_mode = true;
                x.preserve_timestamps = true;
                x.require_preserve = true;
                x.recursive = true;
            },
            1101, 'b' => {
                make_backups = true;
                if (o.arg) |a| version_control = a;
            },
            1100 => x.data_copy_required = false,
            1103 => {
                x.debug = true;
                x.verbose = true;
            },
            1102 => copy_contents = true,
            'd' => {
                x.preserve_links = true;
                x.dereference = .never;
            },
            'f' => x.unlink_dest_after_failed_open = true,
            'H' => x.dereference = .command_line,
            'i' => x.interactive = .ask_user,
            'l' => x.hard_link = true,
            'L' => x.dereference = .always,
            'n' => {
                cli.warn(ctx, "warning: behavior of -n is non-portable and may change in future; use --update=none instead", .{});
                x.interactive = .always_skip;
            },
            'P' => x.dereference = .never,
            1104 => if (!decodePreserve(ctx, o.arg.?, &x, false, "--no-preserve")) return 1,
            1106 => {
                if (o.arg) |a| {
                    if (!decodePreserve(ctx, a, &x, true, "--preserve")) return 1;
                    x.require_preserve = true;
                } else {
                    x.preserve_ownership = true;
                    x.preserve_mode = true;
                    x.preserve_timestamps = true;
                    x.require_preserve = true;
                }
            },
            'p' => {
                x.preserve_ownership = true;
                x.preserve_mode = true;
                x.preserve_timestamps = true;
                x.require_preserve = true;
            },
            1105 => parents_option = true,
            'r', 'R' => x.recursive = true,
            1107 => x.unlink_dest_before_opening = true,
            1110 => remove_trailing_slashes = true,
            's' => x.symbolic_link = true,
            't' => {
                if (target_directory != null) {
                    cli.warn(ctx, "multiple target directories specified", .{});
                    return 1;
                }
                target_directory = o.arg.?;
            },
            'T' => no_target_directory = true,
            'u', 1111 => {
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
            1112 => x.keep_directory_symlink = true,
            'x' => x.one_file_system = true,
            'Z', 1113 => {
                if (o.arg != null) cli.warn(ctx, "warning: ignoring --context; it requires an SELinux-enabled kernel", .{});
            },
            'S' => {
                make_backups = true;
                backup_suffix = o.arg.?;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };

    if (x.reflink == .auto and x.sparse == .never) x.reflink = .never;
    if (x.hard_link and x.symbolic_link) {
        cli.warn(ctx, "cannot make both hard and symbolic links", .{});
        return usageFail(ctx);
    }
    if (x.interactive == .always_skip) x.update = .none;
    if (make_backups and (x.update == .none or x.update == .none_fail)) {
        cli.warn(ctx, "--backup is mutually exclusive with -n or --update=none-fail", .{});
        return usageFail(ctx);
    }
    if (x.reflink == .always and x.sparse != .auto) {
        cli.warn(ctx, "--reflink can be used only with --sparse=auto", .{});
        return usageFail(ctx);
    }
    x.backup_type = if (make_backups) (backup_args.parseVersion(ctx, "backup type", version_control) orelse return 1) else .none;
    x.backup_suffix = backup_args.simpleSuffix(ctx, backup_suffix);
    x.umask = sys.currentUmask();
    if (x.dereference == .undefined) {
        x.dereference = if (x.recursive and !x.hard_link) .never else .always;
    }
    if (x.recursive) x.copy_as_regular = copy_contents;

    const operands = p.operands.items;
    var n_files = operands.len;
    var new_dst = false;
    var tgt: ?[]const u8 = target_directory;
    var e: E = .SUCCESS;

    if (n_files <= @intFromBool(tgt == null)) {
        if (n_files == 0) {
            cli.warn(ctx, "missing file operand", .{});
        } else cli.warn(ctx, "missing destination file operand after {f}", .{cli.quoteA(operands[0])});
        return usageFail(ctx);
    }

    if (no_target_directory) {
        if (tgt != null) {
            cli.warn(ctx, "cannot combine --target-directory (-t) and --no-target-directory (-T)", .{});
            return 1;
        }
        if (n_files > 2) {
            cli.warn(ctx, "extra operand {f}", .{cli.quoteA(operands[2])});
            return usageFail(ctx);
        }
    } else if (tgt) |t| {
        const st = sys.fileStat(t, true, &e);
        if (st == null or !st.?.isDir()) {
            const ee: E = if (st == null) e else .NOTDIR;
            cli.warn(ctx, "target directory {f}: {s}", .{ cli.quoteA(t), sys.errnoText(ee) });
            return 1;
        }
    } else {
        const last = operands[n_files - 1];
        const st = sys.fileStat(last, true, &e);
        if (st != null and st.?.isDir()) {
            tgt = last;
            n_files -= 1;
        } else {
            const err: E = if (st == null) e else .NOTDIR;
            if (err == .NOENT) new_dst = true;
            if (n_files > 2) {
                cli.warn(ctx, "target {f}: {s}", .{ cli.quoteA(last), sys.errnoText(err) });
                return 1;
            }
        }
    }

    var routing: copy_cli.Routing = .{ .ctx = ctx, .out = out };
    const env: cp.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const ok = if (tgt) |target|
        cp.run(env, x, operands[0..n_files], .{
            .destination = .{ .directory = target },
            .parents = parents_option,
            .strip_trailing_slashes = remove_trailing_slashes,
        }, routing.sink()) catch return 1
    else blk: {
        if (parents_option) {
            cli.warn(ctx, "with --parents, the destination must be a directory", .{});
            return usageFail(ctx);
        }
        break :blk cp.run(env, x, operands[0..2], .{
            .destination = .{ .file = .{ .new_dst = new_dst } },
        }, routing.sink()) catch return 1;
    };
    return if (ok) 0 else 1;
}
