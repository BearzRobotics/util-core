// SPDX-License-Identifier: GPL-2.0-or-later
//! install: thin wrapper over `util_core.install` (decision 0004). Parses
//! arguments the way GNU install does, resolves modes, owners and the
//! destination, sets umask 0 (install needs exact modes) and words the usage
//! diagnostics; the work is in src/lib/install.zig. SELinux options are
//! accepted and ignored.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const copy = @import("../copy.zig");
const backup_args = @import("../backup_args.zig");
const install = @import("../lib/install.zig");
const copy_cli = @import("../copy_cli.zig");
const mode_mod = @import("../mode.zig");
const userdb = @import("../userdb.zig");
const Io = std.Io;
const E = std.os.linux.E;

const help_text = @embedFile("../help/install.txt");

const unset = install.unset;

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

fn extraMode(m: u32) bool {
    return (m & ~@as(u32, 0o777 | 0o170000)) != 0;
}

fn run(ctx: cli.Context, out: *cli.Out) u8 {
    var x: copy.Opts = .{};
    x.copy_as_regular = true;
    x.dereference = .always;
    x.unlink_dest_before_opening = true;
    x.install_mode = true;
    x.set_mode = true;
    x.mode = 0o600;
    x.chown_privileges = sys.identity().euid == 0;
    x.owner_privileges = x.chown_privileges;
    var s: install.Options = .{ .x = x, .name = ctx.name };
    var specified_mode: ?[]const u8 = null;
    var make_backups = false;
    var backup_suffix: ?[]const u8 = null;
    var version_control: ?[]const u8 = null;
    var mkdir_and_install = false;
    var dir_arg = false;
    var target_directory: ?[]const u8 = null;
    var no_target_directory = false;
    var owner_name: ?[]const u8 = null;
    var group_name: ?[]const u8 = null;
    var strip_program_specified = false;

    var p = getopt.Parser.init(ctx, "bcCsDdg:m:o:pt:TvS:Z", &.{
        .{ .name = "backup", .arg = .optional, .id = 'b' },
        .{ .name = "compare", .id = 'C' },
        .{ .name = "debug", .id = 1100 },
        .{ .name = "directory", .id = 'd' },
        .{ .name = "group", .arg = .required, .id = 'g' },
        .{ .name = "mode", .arg = .required, .id = 'm' },
        .{ .name = "owner", .arg = .required, .id = 'o' },
        .{ .name = "preserve-timestamps", .id = 'p' },
        .{ .name = "strip", .id = 's' },
        .{ .name = "strip-program", .arg = .required, .id = 1101 },
        .{ .name = "suffix", .arg = .required, .id = 'S' },
        .{ .name = "target-directory", .arg = .required, .id = 't' },
        .{ .name = "no-target-directory", .id = 'T' },
        .{ .name = "verbose", .id = 'v' },
        .{ .name = "preserve-context", .id = 1102 },
        .{ .name = "context", .arg = .optional, .id = 1103 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'b' => {
                make_backups = true;
                if (o.arg) |a| version_control = a;
            },
            'c' => {},
            'C' => s.copy_only_if_needed = true,
            's' => s.strip_files = true,
            1100 => {
                s.x.debug = true;
                s.x.verbose = true;
            },
            1101 => {
                s.strip_program = o.arg.?;
                strip_program_specified = true;
            },
            'd' => dir_arg = true,
            'D' => mkdir_and_install = true,
            'v' => s.x.verbose = true,
            'g' => group_name = o.arg.?,
            'm' => specified_mode = o.arg.?,
            'o' => owner_name = o.arg.?,
            'p' => s.x.preserve_timestamps = true,
            'S' => {
                make_backups = true;
                backup_suffix = o.arg.?;
            },
            't' => {
                if (target_directory != null) {
                    cli.warn(ctx, "multiple target directories specified", .{});
                    return 1;
                }
                target_directory = o.arg.?;
            },
            'T' => no_target_directory = true,
            1102 => cli.warn(ctx, "WARNING: ignoring --preserve-context; this kernel is not SELinux-enabled", .{}),
            'Z', 1103 => if (o.arg != null) cli.warn(ctx, "warning: ignoring --context; it requires an SELinux-enabled kernel", .{}),
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (dir_arg and s.strip_files) {
        cli.warn(ctx, "the strip option may not be used when installing a directory", .{});
        return 1;
    }
    if (dir_arg and target_directory != null) {
        cli.warn(ctx, "target directory not allowed when installing a directory", .{});
        return 1;
    }
    s.x.backup_type = if (make_backups) (backup_args.parseVersion(ctx, "backup type", version_control) orelse return 1) else .none;
    s.x.backup_suffix = backup_args.simpleSuffix(ctx, backup_suffix);

    const operands = p.operands.items;
    var n_files = operands.len;
    if (n_files <= @intFromBool(!(dir_arg or target_directory != null))) {
        if (n_files == 0) {
            cli.warn(ctx, "missing file operand", .{});
        } else cli.warn(ctx, "missing destination file operand after {f}", .{cli.quoteA(operands[0])});
        return usageFail(ctx);
    }
    var e: E = .SUCCESS;
    var target_ok = true;
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
        target_ok = st != null and st.?.isDir();
        if (!target_ok) {
            const err: E = if (st == null) e else .NOTDIR;
            if (!(mkdir_and_install and err == .NOENT)) {
                cli.warn(ctx, "failed to access {f}: {s}", .{ cli.quoteA(t), sys.errnoText(err) });
                return 1;
            }
        }
    } else if (!dir_arg) {
        const last = operands[n_files - 1];
        const st = sys.fileStat(last, true, &e);
        if (st != null and st.?.isDir()) {
            target_directory = last;
            n_files -= 1;
        } else if (n_files > 2) {
            cli.warn(ctx, "target {f}: {s}", .{ cli.quoteA(last), sys.errnoText(if (st == null) e else .NOTDIR) });
            return 1;
        }
    }
    if (specified_mode) |m| {
        const mm = mode_mod.apply(m, 0, false, 0) orelse {
            cli.warn(ctx, "invalid mode {f}", .{cli.quoteC(m)});
            return 1;
        };
        s.mode = mm;
        var decided: u16 = 0;
        s.dir_mode = mode_mod.applyTracked(m, 0, true, 0, &decided).?;
        s.dir_mode_decided = decided;
    }
    if (strip_program_specified and !s.strip_files) {
        cli.warn(ctx, "WARNING: ignoring --strip-program option as -s option was not specified", .{});
    }
    if (s.copy_only_if_needed and s.x.preserve_timestamps) {
        cli.warn(ctx, "options --compare (-C) and --preserve-timestamps are mutually exclusive", .{});
        return usageFail(ctx);
    }
    if (s.copy_only_if_needed and s.strip_files) {
        cli.warn(ctx, "options --compare (-C) and --strip are mutually exclusive", .{});
        return usageFail(ctx);
    }
    if (s.copy_only_if_needed and extraMode(s.mode)) {
        cli.warn(ctx, "the --compare (-C) option is ignored when you specify a mode with non-permission bits", .{});
    }

    var db = userdb.Db.load(ctx.gpa, ctx.io);
    defer db.deinit();
    if (owner_name) |on| {
        if (db.userByName(on)) |u| {
            s.owner_id = u.uid;
        } else {
            const v = std.fmt.parseInt(u32, on, 0) catch {
                cli.warn(ctx, "invalid user {f}", .{cli.quoteA(on)});
                return 1;
            };
            s.owner_id = v;
        }
    }
    if (group_name) |gn| {
        if (db.groupByName(gn)) |g| {
            s.group_id = g.gid;
        } else {
            const v = std.fmt.parseInt(u32, gn, 0) catch {
                cli.warn(ctx, "invalid group {f}", .{cli.quoteA(gn)});
                return 1;
            };
            s.group_id = v;
        }
    }

    // install runs with umask 0 so that modes are exact.
    _ = sys.setUmask(0);

    s.x.umask = 0;
    var routing: copy_cli.Routing = .{ .ctx = ctx, .out = out };
    const env: install.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const plan: install.Plan = if (dir_arg)
        .directories
    else if (target_directory) |td|
        .{ .into_directory = .{ .target = td, .target_exists = target_ok, .make_ancestors = mkdir_and_install } }
    else
        .{ .file = .{ .make_ancestors = mkdir_and_install } };
    const operand_list: []const []const u8 = if (dir_arg) operands else if (target_directory != null) operands[0..n_files] else operands[0..2];
    const ok = install.run(env, s, operand_list, plan, routing.sink()) catch |err| switch (err) {
        // GNU exits at once, leaving buffered standard output unwritten.
        error.Fatal => std.process.exit(1),
        error.OutOfMemory => return 1,
    };
    return if (ok) 0 else 1;
}
