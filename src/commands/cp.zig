//! cp — copy files and directories.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "cp invocation"
//! (9.7), POSIX.1-2024 cp, GNU coreutils 9.6 src/cp.c (argument handling,
//! --parents, target-directory logic) and src/copy.c (see src/copy.zig).

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const copy = @import("../copy.zig");
const backup = @import("../backup.zig");
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
                std.process.exit(1);
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

fn stripTrailingSlashes(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 1 and s[end - 1] == '/') end -= 1;
    return s[0..end];
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
    x.backup_type = if (make_backups) (backup.parseVersion(ctx, "backup type", version_control) orelse return 1) else .none;
    backup.setSimpleSuffix(ctx, backup_suffix);
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

    var c = copy.Copier.init(ctx, out, x);
    defer c.deinit();
    var ok = true;

    if (tgt) |target| {
        if (n_files >= 2) {
            c.x.track_dest = true;
            c.x.track_src = true;
        }
        for (operands[0..n_files]) |arg_in| {
            const arg = if (remove_trailing_slashes) stripTrailingSlashes(arg_in) else arg_in;
            var dst_name: []u8 = undefined;
            var parent_exists = true;
            var attr_list: std.ArrayList(DirAttr) = .empty;
            defer attr_list.deinit(ctx.gpa);
            if (parents_option) {
                const a2 = stripTrailingSlashes(arg);
                dst_name = copy.joinName(ctx.gpa, target, a2) catch return 1;
                parent_exists = makeDirParents(ctx, &c, target, dst_name, a2, &attr_list, &new_dst, x, out);
            } else {
                var base = lastComponent(arg);
                base = stripTrailingSlashes(base);
                if (std.mem.eql(u8, base, "..")) base = base[0..0];
                dst_name = copy.joinName(ctx.gpa, target, base) catch return 1;
            }
            defer ctx.gpa.free(dst_name);
            if (!parent_exists) {
                ok = false;
            } else {
                var into_self = false;
                var rs: ?bool = null;
                if (!c.copy(arg, dst_name, @intFromBool(new_dst), &into_self, &rs)) ok = false;
                if (parents_option) {
                    if (!reProtect(ctx, &c, dst_name, target, attr_list.items, x)) ok = false;
                }
            }
        }
    } else {
        const source = operands[0];
        var dest = operands[1];
        if (parents_option) {
            cli.warn(ctx, "with --parents, the destination must be a directory", .{});
            return usageFail(ctx);
        }
        if (c.x.unlink_dest_after_failed_open and c.x.backup_type != .none and std.mem.eql(u8, source, dest) and !new_dst) {
            const st2 = sys.fileStat(dest, true, &e);
            if (st2 != null and st2.?.isReg()) {
                if (backup.findBackupName(ctx, c.arena.allocator(), dest, c.x.backup_type)) |nb| {
                    dest = nb;
                    c.x.backup_type = .none;
                }
            }
        }
        var into_self = false;
        var rs: ?bool = null;
        ok = c.copy(source, dest, -@as(i32, @intFromBool(new_dst)), &into_self, &rs);
    }
    return if (ok) 0 else 1;
}

fn lastComponent(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const t = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, t, '/');
    return if (slash) |s| t[s + 1 ..] else t;
}

const DirAttr = struct {
    st: sys.FileStat,
    slash_offset: usize,
    restore_mode: bool,
};

fn umaskNow() u32 {
    return sys.currentUmask();
}

/// make_dir_parents_private: create the leading directories of `dst_name`
/// below `target`; `src` is the source name appended to the target.
fn makeDirParents(ctx: cli.Context, c: *copy.Copier, target: []const u8, dst_name: []const u8, src: []const u8, attr_list: *std.ArrayList(DirAttr), new_dst: *bool, x: copy.Opts, out: *cli.Out) bool {
    _ = c;
    var e: E = .SUCCESS;
    // Offset of the source name inside dst_name.
    const src_offset = dst_name.len - src.len;
    const dirlen = dirLen(dst_name);
    if (dirlen <= src_offset) return true;
    const dst_dir = dst_name[0..dirlen];
    _ = target;
    var rel_start: usize = src_offset;
    while (rel_start < dst_name.len and dst_name[rel_start] == '/') rel_start += 1;
    const have = sys.fileStat(dst_dir, true, &e);
    if (have == null) {
        var slash = rel_start;
        const srcpart = dst_name[rel_start..];
        _ = srcpart;
        while (std.mem.indexOfScalarPos(u8, dst_name, slash, '/')) |sl| {
            const dir_part = dst_name[0..sl];
            const src_part = dst_name[src_offset..sl];
            const dstat = sys.fileStat(dir_part, true, &e);
            const missing = dstat == null;
            if (missing or x.preserve_ownership or x.preserve_mode or x.preserve_timestamps) {
                var se: E = .SUCCESS;
                const sst = sys.fileStat(src_part, true, &se);
                const src_errno: E = if (sst == null) se else if (sst.?.isDir()) .SUCCESS else .NOTDIR;
                if (src_errno != .SUCCESS) {
                    cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteA(src_part), sys.errnoText(src_errno) });
                    return false;
                }
                attr_list.insert(ctx.gpa, 0, .{ .st = sst.?, .slash_offset = sl, .restore_mode = false }) catch {};
            }
            if (missing) {
                new_dst.* = true;
                const src_mode = attr_list.items[0].st.mode;
                const omitted: u32 = src_mode & (if (x.preserve_ownership) @as(u32, 0o077) else if (x.preserve_mode) @as(u32, 0o022) else 0);
                var mkdir_mode: u32 = if (x.explicit_no_preserve_mode) 0o777 else src_mode;
                mkdir_mode &= 0o7777 & ~omitted;
                if (sys.mkdirPath(dir_part, mkdir_mode)) |me| {
                    cli.warn(ctx, "cannot make directory {f}: {s}", .{ cli.quoteA(dir_part), sys.errnoText(me) });
                    return false;
                }
                if (x.verbose) {
                    var buf: [8192]u8 = undefined;
                    const t = std.fmt.bufPrint(&buf, "{s} -> {s}\n", .{ src_part, dir_part }) catch "";
                    out.write(t);
                }
                const stats = sys.fileStat(dir_part, false, &e) orelse {
                    cli.warn(ctx, "failed to get attributes of {f}: {s}", .{ cli.quoteA(dir_part), sys.errnoText(e) });
                    return false;
                };
                var om = omitted;
                if (!x.preserve_mode) {
                    if (om & ~stats.mode != 0) om &= ~umaskNow();
                    if (om & ~stats.mode != 0 or (stats.mode & 0o700) != 0o700) {
                        attr_list.items[0].st.mode = stats.mode | om;
                        attr_list.items[0].restore_mode = true;
                    }
                }
                const accessible = stats.mode | 0o700;
                if (stats.mode != accessible) {
                    if (sys.chmodPath(dir_part, accessible, false)) |ce| {
                        cli.warn(ctx, "setting permissions for {f}: {s}", .{ cli.quoteA(dir_part), sys.errnoText(ce) });
                        return false;
                    }
                }
            } else if (!dstat.?.isDir()) {
                cli.warn(ctx, "{f} exists but is not a directory", .{cli.quoteA(dir_part)});
                return false;
            } else new_dst.* = false;
            slash = sl + 1;
            while (slash < dst_name.len and dst_name[slash] == '/') slash += 1;
        }
    } else if (!have.?.isDir()) {
        cli.warn(ctx, "{f} exists but is not a directory", .{cli.quoteA(dst_dir)});
        return false;
    } else new_dst.* = false;
    return true;
}

fn dirLen(path: []const u8) usize {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return 0;
    var d = slash;
    while (d > 1 and path[d - 1] == '/') d -= 1;
    return if (d == 0) 1 else d;
}

fn reProtect(ctx: cli.Context, c: *copy.Copier, dst_name: []const u8, target: []const u8, attrs: []const DirAttr, x: copy.Opts) bool {
    _ = c;
    _ = target;
    for (attrs) |at| {
        const name = dst_name[0..at.slash_offset];
        if (x.preserve_timestamps) {
            const ts = [2]sys.TimeSpec{ .{ .sec = at.st.atime_s, .nsec = at.st.atime_ns }, .{ .sec = at.st.mtime_s, .nsec = at.st.mtime_ns } };
            if (sys.setTimes(name, -1, ts, false)) |te| {
                cli.warn(ctx, "failed to preserve times for {f}: {s}", .{ cli.quoteA(name), sys.errnoText(te) });
                return false;
            }
        }
        if (x.preserve_ownership) {
            if (sys.chownAt(name, at.st.uid, at.st.gid, true)) |ce| {
                if (!((ce == .PERM or ce == .INVAL or ce == .ACCES) and !x.chown_privileges)) {
                    cli.warn(ctx, "failed to preserve ownership for {f}: {s}", .{ cli.quoteA(name), sys.errnoText(ce) });
                    return false;
                }
                _ = sys.chownAt(name, std.math.maxInt(u32), at.st.gid, true);
            }
        }
        if (x.preserve_mode) {
            if (sys.chmodPath(name, at.st.mode & 0o7777, false)) |ce| {
                _ = ce;
                return false;
            }
        } else if (at.restore_mode) {
            if (sys.chmodPath(name, at.st.mode & 0o7777, true)) |ce| {
                cli.warn(ctx, "failed to preserve permissions for {f}: {s}", .{ cli.quoteA(name), sys.errnoText(ce) });
                return false;
            }
        }
    }
    return true;
}
