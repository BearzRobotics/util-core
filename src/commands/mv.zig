// SPDX-License-Identifier: GPL-2.0-or-later
//! mv — move (rename) files.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "mv invocation"
//! (9.7), POSIX.1-2024 mv, and GNU coreutils 9.6 src/mv.c; the rename and
//! cross-device copy logic is in src/copy.zig. `--exchange` is not
//! implemented.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const copy = @import("../copy.zig");
const backup = @import("../backup.zig");
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

fn stripSlashes(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and s[end - 1] == '/') end -= 1;
    return s[0..end];
}

fn lastComponent(path: []const u8) []const u8 {
    // GNU last_component keeps trailing slashes (they are stripped later).
    var i = path.len;
    var trailing: usize = 0;
    while (i > 0 and path[i - 1] == '/') {
        i -= 1;
        trailing += 1;
    }
    const start = if (std.mem.lastIndexOfScalar(u8, path[0..i], '/')) |s| s + 1 else 0;
    return path[start..path.len];
}

/// rm -r on the source after an inter-device copy.
fn removeTree(ctx: cli.Context, out: *cli.Out, path: []const u8, verbose: bool) bool {
    var e: E = .SUCCESS;
    const st = sys.fileStat(path, false, &e) orelse {
        out.flush();
        cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(path), sys.errnoText(e) });
        return false;
    };
    var ok = true;
    if (st.isDir()) {
        var dir = Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch |err| {
            out.flush();
            cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(path), cli.errText(err) });
            return false;
        };
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| ctx.gpa.free(n);
            names.deinit(ctx.gpa);
        }
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            const dup = ctx.gpa.dupe(u8, entry.name) catch break;
            names.append(ctx.gpa, dup) catch {
                ctx.gpa.free(dup);
                break;
            };
        }
        dir.close(ctx.io);
        for (names.items) |n| {
            const child = copy.joinName(ctx.gpa, path, n) catch continue;
            defer ctx.gpa.free(child);
            if (!removeTree(ctx, out, child, verbose)) ok = false;
        }
        if (ok) {
            if (sys.unlinkPath(path, true)) |ue| {
                out.flush();
                cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(path), sys.errnoText(ue) });
                return false;
            }
            if (verbose) {
                var b: [8200]u8 = undefined;
                out.write(std.fmt.bufPrint(&b, "removed directory {f}\n", .{cli.quoteA(path)}) catch "");
            }
        }
        return ok;
    }
    if (sys.unlinkPath(path, false)) |ue| {
        out.flush();
        cli.warn(ctx, "cannot remove {f}: {s}", .{ cli.quoteA(path), sys.errnoText(ue) });
        return false;
    }
    if (verbose) {
        var b: [8200]u8 = undefined;
        out.write(std.fmt.bufPrint(&b, "removed {f}\n", .{cli.quoteA(path)}) catch "");
    }
    return true;
}

fn doMove(ctx: cli.Context, c: *copy.Copier, out: *cli.Out, source: []const u8, dest: []const u8) bool {
    var into_self = false;
    var rs: ?bool = false;
    var ok = c.copy(source, dest, 0, &into_self, &rs);
    if (ok) {
        var remove = false;
        if (into_self) {
            ok = false;
        } else if (rs.?) {
            // renamed, or the user declined
        } else remove = true;
        if (remove) {
            if (!removeTree(ctx, out, source, c.x.verbose)) ok = false;
        }
    }
    return ok;
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
            x.rename_errno = if (sys.renamePath(operands[0], last, sys.RENAME_NOREPLACE)) |re| @intFromEnum(re) else 0;
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
    x.backup_type = if (make_backups) (backup.parseVersion(ctx, "backup type", version_control) orelse return 1) else .none;
    backup.setSimpleSuffix(ctx, backup_suffix);

    var c = copy.Copier.init(ctx, out, x);
    defer c.deinit();
    var ok = true;
    if (target_directory) |td| {
        if (n_files >= 2) c.x.track_dest = true;
        for (operands[0..n_files], 0..) |src_in, i| {
            c.x.last_file = i + 1 == n_files;
            const source = if (remove_trailing_slashes) stripSlashes(src_in) else src_in;
            const base = lastComponent(source);
            const joined = copy.joinName(ctx.gpa, td, base) catch return 1;
            defer ctx.gpa.free(joined);
            const dest = stripSlashes(joined);
            if (!doMove(ctx, &c, out, source, dest)) ok = false;
        }
    } else {
        c.x.last_file = true;
        const s0 = if (remove_trailing_slashes) stripSlashes(operands[0]) else operands[0];
        const s1 = if (remove_trailing_slashes) stripSlashes(operands[1]) else operands[1];
        ok = doMove(ctx, &c, out, s0, s1);
    }
    operands = &.{};
    return if (ok) 0 else 1;
}
