//! Shared copy engine of cp, mv and install: a port of the control flow of
//! GNU coreutils 9.6 src/copy.c (copy_internal, copy_reg, copy_dir,
//! same_file_ok, overwrite_ok and friends), consulted 2026-11-07, checked
//! against the 9.7 binary. SELinux contexts, ACLs, extended attributes,
//! reflink and the exchange mode of mv are not implemented.

const std = @import("std");
const cli = @import("cli.zig");
const sys = @import("sys.zig");
const backup = @import("backup.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const E = std.os.linux.E;

pub const Interactive = enum { unspecified, always_yes, always_skip, ask_user };
pub const Update = enum { all, none, none_fail, older };
pub const Sparse = enum { never, auto, always };
pub const Reflink = enum { auto, always, never };
pub const Deref = enum { undefined, never, command_line, always };

pub const Opts = struct {
    // Behaviour switches (copy.h cp_options).
    backup_type: backup.Type = .none,
    dereference: Deref = .undefined,
    interactive: Interactive = .unspecified,
    update: Update = .all,
    sparse: Sparse = .auto,
    reflink: Reflink = .auto,
    move_mode: bool = false,
    install_mode: bool = false,
    no_copy: bool = false,
    recursive: bool = false,
    copy_as_regular: bool = true,
    hard_link: bool = false,
    symbolic_link: bool = false,
    one_file_system: bool = false,
    unlink_dest_before_opening: bool = false,
    unlink_dest_after_failed_open: bool = false,
    preserve_ownership: bool = false,
    preserve_links: bool = false,
    preserve_mode: bool = false,
    preserve_timestamps: bool = false,
    explicit_no_preserve_mode: bool = false,
    require_preserve: bool = false,
    data_copy_required: bool = true,
    set_mode: bool = false,
    mode: u32 = 0,
    verbose: bool = false,
    debug: bool = false,
    keep_directory_symlink: bool = false,
    stdin_tty: bool = false,
    open_dangling_dest_symlink: bool = false,
    last_file: bool = false,
    /// Set by `mv`: the rename(2) errno already known (-1 = not tried).
    rename_errno: i32 = -1,
    chown_privileges: bool = false,
    owner_privileges: bool = false,
    // Per-run tables (null = off).
    track_dest: bool = false,
    track_src: bool = false,
};

const DevIno = struct { dev: u64, ino: u64 };

fn devOf(st: sys.FileStat) u64 {
    return (@as(u64, st.dev_major) << 32) | st.dev_minor;
}

fn key(st: sys.FileStat) DevIno {
    return .{ .dev = devOf(st), .ino = st.ino };
}

pub const Copier = struct {
    ctx: cli.Context,
    out: *cli.Out,
    x: Opts,
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    top_src: []const u8 = "",
    top_dst: []const u8 = "",
    umask: u32 = 0,
    /// src dev/ino -> destination name (remember_copied).
    copied: std.AutoHashMap(DevIno, []const u8),
    dest_info: std.AutoHashMap(DevIno, std.ArrayList([]const u8)),
    src_info: std.AutoHashMap(DevIno, std.ArrayList([]const u8)),

    pub fn init(ctx: cli.Context, out: *cli.Out, x: Opts) Copier {
        return .{
            .ctx = ctx,
            .out = out,
            .x = x,
            .arena = std.heap.ArenaAllocator.init(ctx.gpa),
            .gpa = ctx.gpa,
            .umask = sys.currentUmask(),
            .copied = std.AutoHashMap(DevIno, []const u8).init(ctx.gpa),
            .dest_info = std.AutoHashMap(DevIno, std.ArrayList([]const u8)).init(ctx.gpa),
            .src_info = std.AutoHashMap(DevIno, std.ArrayList([]const u8)).init(ctx.gpa),
        };
    }

    pub fn deinit(c: *Copier) void {
        c.copied.deinit();
        var it = c.dest_info.valueIterator();
        while (it.next()) |l| l.deinit(c.gpa);
        c.dest_info.deinit();
        var it2 = c.src_info.valueIterator();
        while (it2.next()) |l| l.deinit(c.gpa);
        c.src_info.deinit();
        c.arena.deinit();
    }

    fn a(c: *Copier) Allocator {
        return c.arena.allocator();
    }

    // -------------------------------------------------------------- helpers

    fn errPrint(c: *Copier, comptime fmt: []const u8, args: anytype) void {
        c.out.flush();
        cli.warn(c.ctx, fmt, args);
    }

    fn errno(c: *Copier, comptime fmt: []const u8, args: anytype, e: E) void {
        c.out.flush();
        cli.warn(c.ctx, fmt ++ ": {s}", args ++ .{sys.errnoText(e)});
    }

    fn say(c: *Copier, comptime fmt: []const u8, args: anytype) void {
        var buf: [8192]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, fmt, args) catch return;
        c.out.write(t);
    }

    fn emitVerbose(c: *Copier, comptime fmt: []const u8, src: []const u8, dst: []const u8, backup_name: ?[]const u8) void {
        c.say(fmt, .{ cli.quoteA(src), cli.quoteA(dst) });
        if (backup_name) |b| c.say(" (backup: {f})", .{cli.quoteA(b)});
        c.out.writeByte('\n');
    }

    fn yesno(c: *Copier) bool {
        // Read one line from stdin; "y" or "Y" first byte means yes.
        const stdin = Io.File.stdin();
        var first: ?u8 = null;
        var buf: [1]u8 = undefined;
        while (true) {
            const n = cli.readChunk(c.ctx.io, stdin, &buf) catch return false;
            if (n == 0) break;
            if (first == null) first = buf[0];
            if (buf[0] == '\n') break;
        }
        return first != null and (first.? == 'y' or first.? == 'Y');
    }

    fn canWriteAnyFile(c: *Copier) bool {
        _ = c;
        return sys.identity().euid == 0;
    }

    fn writableDestination(c: *Copier, name: []const u8, mode: u32) bool {
        return (mode & 0o170000) == 0o120000 or c.canWriteAnyFile() or sys.accessPath(name, 2) == null;
    }

    fn overwriteOk(c: *Copier, dst_name: []const u8, dst_sb: sys.FileStat) bool {
        c.out.flush();
        var perms: [10]u8 = undefined;
        modeChars(dst_sb.mode, &perms);
        if (!c.writableDestination(dst_name, dst_sb.mode)) {
            if (c.x.move_mode or c.x.unlink_dest_before_opening or c.x.unlink_dest_after_failed_open) {
                cli.writeStderrNoNl(c.ctx, "{s}: replace {f}, overriding mode {o:0>4} ({s})? ", .{ c.ctx.name, cli.quoteA(dst_name), dst_sb.mode & 0o7777, perms[1..] });
            } else {
                cli.writeStderrNoNl(c.ctx, "{s}: unwritable {f} (mode {o:0>4}, {s}); try anyway? ", .{ c.ctx.name, cli.quoteA(dst_name), dst_sb.mode & 0o7777, perms[1..] });
            }
        } else {
            cli.writeStderrNoNl(c.ctx, "{s}: overwrite {f}? ", .{ c.ctx.name, cli.quoteA(dst_name) });
        }
        return c.yesno();
    }

    fn abandonMove(c: *Copier, dst_name: []const u8, dst_sb: sys.FileStat) bool {
        return c.x.update == .none or c.x.update == .none_fail or
            ((c.x.interactive == .ask_user or (c.x.interactive == .unspecified and c.x.stdin_tty and !c.writableDestination(dst_name, dst_sb.mode))) and
                !c.overwriteOk(dst_name, dst_sb));
    }

    fn chownFailureOk(c: *Copier, e: E) bool {
        return (e == .PERM or e == .INVAL or e == .ACCES) and !c.x.chown_privileges;
    }

    fn ownerFailureOk(c: *Copier, e: E) bool {
        return (e == .PERM or e == .INVAL or e == .ACCES) and !c.x.owner_privileges;
    }

    fn lstat(path: []const u8, e: *E) ?sys.FileStat {
        return sys.fileStat(path, false, e);
    }

    fn stat(path: []const u8, e: *E) ?sys.FileStat {
        return sys.fileStat(path, true, e);
    }

    fn sameInode(x: sys.FileStat, y: sys.FileStat) bool {
        return x.ino == y.ino and devOf(x) == devOf(y);
    }

    fn lastComponent(path: []const u8) []const u8 {
        var end = path.len;
        while (end > 0 and path[end - 1] == '/') end -= 1;
        const trimmed = path[0..end];
        const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
        return if (slash) |s| trimmed[s + 1 ..] else trimmed;
    }

    fn dotOrDotdot(name: []const u8) bool {
        return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
    }

    /// True when both names denote the same directory entry (same name in
    /// the same directory).
    fn sameName(a1: []const u8, a2: []const u8) bool {
        const b1 = lastComponent(a1);
        const b2 = lastComponent(a2);
        if (!std.mem.eql(u8, b1, b2)) return false;
        const d1 = dirOf(a1);
        const d2 = dirOf(a2);
        var e: E = .SUCCESS;
        const s1 = sys.fileStat(d1, true, &e) orelse return false;
        const s2 = sys.fileStat(d2, true, &e) orelse return false;
        return sameInode(s1, s2);
    }

    fn dirOf(path: []const u8) []const u8 {
        var end = path.len;
        while (end > 0 and path[end - 1] == '/') end -= 1;
        const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse return ".";
        var d = slash;
        while (d > 0 and path[d - 1] == '/') d -= 1;
        return if (d == 0) "/" else path[0..d];
    }

    fn recordFile(c: *Copier, map: *std.AutoHashMap(DevIno, std.ArrayList([]const u8)), name: []const u8, st: sys.FileStat) void {
        const r = map.getOrPut(key(st)) catch return;
        if (!r.found_existing) r.value_ptr.* = .empty;
        const base = lastComponent(name);
        for (r.value_ptr.items) |n| if (std.mem.eql(u8, n, base)) return;
        const d = c.a().dupe(u8, base) catch return;
        r.value_ptr.append(c.gpa, d) catch {};
    }

    fn seenFile(c: *Copier, map: *std.AutoHashMap(DevIno, std.ArrayList([]const u8)), name: []const u8, st: sys.FileStat) bool {
        _ = c;
        const l = map.get(key(st)) orelse return false;
        const base = lastComponent(name);
        for (l.items) |n| if (std.mem.eql(u8, n, base)) return true;
        return false;
    }

    fn rememberCopied(c: *Copier, name: []const u8, st: sys.FileStat) ?[]const u8 {
        const r = c.copied.getOrPut(key(st)) catch return null;
        if (r.found_existing) return r.value_ptr.*;
        r.value_ptr.* = c.a().dupe(u8, name) catch name;
        return null;
    }

    fn srcToDestLookup(c: *Copier, st: sys.FileStat) ?[]const u8 {
        return c.copied.get(key(st));
    }

    fn forgetCreated(c: *Copier, st: sys.FileStat) void {
        _ = c.copied.remove(key(st));
    }

    // ------------------------------------------------------------- creation

    /// force_linkat: returns null on success, a negative marker via `removed`.
    fn forceLink(c: *Copier, src: []const u8, dst: []const u8, follow: bool, force: bool, removed: *bool) ?E {
        removed.* = false;
        const e1 = sys.linkPath(src, dst, follow) orelse return null;
        if (e1 != .EXIST or !force) return e1;
        // Replace the destination; keep it if source and destination are
        // the same file.
        var e: E = .SUCCESS;
        const s = if (follow) stat(src, &e) else lstat(src, &e);
        const d = lstat(dst, &e);
        if (s != null and d != null and sameInode(s.?, d.?)) return null;
        if (sys.unlinkPath(dst, false)) |ue| {
            if (ue != .NOENT) return ue;
        }
        _ = c;
        if (sys.linkPath(src, dst, follow)) |e2| return e2;
        removed.* = true;
        return null;
    }

    fn forceSymlink(c: *Copier, target: []const u8, dst: []const u8, force: bool, removed: *bool) ?E {
        _ = c;
        removed.* = false;
        const e1 = sys.symlinkPath(target, dst) orelse return null;
        if (e1 != .EXIST or !force) return e1;
        if (sys.unlinkPath(dst, false)) |ue| {
            if (ue != .NOENT) return ue;
        }
        if (sys.symlinkPath(target, dst)) |e2| return e2;
        removed.* = true;
        return null;
    }

    fn createHardLink(c: *Copier, src_name: []const u8, dst_name: []const u8, replace: bool, verbose: bool, dereference: bool) bool {
        var removed = false;
        if (c.forceLink(src_name, dst_name, dereference, replace, &removed)) |e| {
            c.errno("cannot create hard link {f} to {f}", .{ cli.quoteA(dst_name), cli.quoteA(src_name) }, e);
            return false;
        }
        if (removed and verbose) c.say("removed {f}\n", .{cli.quoteA(dst_name)});
        return true;
    }

    fn shouldDereference(c: *Copier, command_line_arg: bool) bool {
        return c.x.dereference == .always or (c.x.dereference == .command_line and command_line_arg);
    }

    fn isAncestor(sb: sys.FileStat, ancestors: []const DevIno) bool {
        for (ancestors) |an| if (an.ino == sb.ino and an.dev == devOf(sb)) return true;
        return false;
    }

    // ---------------------------------------------------------- same_file_ok

    fn sameFileOk(c: *Copier, src_name: []const u8, src_sb: sys.FileStat, dst_name: []const u8, dst_sb: sys.FileStat, return_now: *bool) bool {
        const x = &c.x;
        const same = sameInode(src_sb, dst_sb);
        return_now.* = false;
        if (same and x.hard_link) {
            return_now.* = true;
            return true;
        }
        var src_link = src_sb;
        var dst_link = dst_sb;
        var same_link: bool = undefined;
        var e: E = .SUCCESS;
        if (x.dereference == .never) {
            same_link = same;
            if (src_sb.isLink() and dst_sb.isLink()) {
                const sn = sameName(src_name, dst_name);
                if (!sn) {
                    if (x.backup_type != .none) return true;
                    if (same_link) {
                        return_now.* = true;
                        return !x.move_mode;
                    }
                }
                return !sn;
            }
        } else {
            if (!same) return true;
            const d = lstat(dst_name, &e) orelse return true;
            const s = lstat(src_name, &e) orelse return true;
            src_link = s;
            dst_link = d;
            same_link = sameInode(s, d);
            if (s.isLink() and d.isLink() and x.unlink_dest_before_opening) return true;
        }
        if (x.backup_type != .none) {
            if (!same_link) {
                if (!x.move_mode and x.dereference != .never and src_link.isLink() and !dst_link.isLink()) return false;
                return true;
            }
            return !sameName(src_name, dst_name);
        }
        if (x.move_mode or x.unlink_dest_before_opening) {
            if (dst_link.isLink()) return true;
            if (same_link and dst_link.nlink > 1 and !sameName(src_name, dst_name)) return !x.move_mode;
        }
        if (!src_link.isLink() and !dst_link.isLink()) {
            if (!sameInode(src_link, dst_link)) return true;
            if (x.hard_link) {
                return_now.* = true;
                return true;
            }
        }
        if (x.move_mode and src_sb.isLink() and dst_link.nlink > 1) {
            var rb: [4096]u8 = undefined;
            if (Io.Dir.cwd().realPathFile(c.ctx.io, src_name, &rb)) |n| {
                return !sameName(rb[0..n], dst_name);
            } else |_| {}
        }
        if (x.symbolic_link and dst_link.isLink()) return true;
        if (x.dereference == .never) {
            var ts = src_link;
            var td = dst_link;
            if (src_link.isLink()) ts = stat(src_name, &e) orelse return true;
            if (dst_link.isLink()) td = stat(dst_name, &e) orelse return true;
            if (!sameInode(ts, td)) return true;
            if (x.hard_link) {
                return_now.* = !dst_link.isLink();
                return true;
            }
        }
        return false;
    }

    fn sourceIsDstBackup(c: *Copier, srcbase: []const u8, src_st: sys.FileStat, dst_name: []const u8) bool {
        const suffix = backup.simpleSuffix(c.ctx);
        const dstbase = lastComponent(dst_name);
        if (!(srcbase.len == dstbase.len + suffix.len and std.mem.eql(u8, srcbase[0..dstbase.len], dstbase) and std.mem.eql(u8, srcbase[dstbase.len..], suffix))) return false;
        const back = std.fmt.allocPrint(c.gpa, "{s}{s}", .{ dst_name, suffix }) catch return false;
        defer c.gpa.free(back);
        var e: E = .SUCCESS;
        const bs = stat(back, &e) orelse return false;
        return sameInode(src_st, bs);
    }

    // ---------------------------------------------------------- entry points

    /// copy(): one command-line source.
    pub fn copy(c: *Copier, src_name: []const u8, dst_name: []const u8, nonexistent_dst: i32, copy_into_self: *bool, rename_succeeded: *?bool) bool {
        c.top_src = src_name;
        c.top_dst = dst_name;
        var first_dir = false;
        return c.copyInternal(src_name, dst_name, nonexistent_dst, null, &.{}, true, &first_dir, copy_into_self, rename_succeeded);
    }

    fn debugLine(c: *Copier, offload: []const u8, reflink: []const u8, sparse: []const u8) void {
        c.say("copy offload: {s}, reflink: {s}, sparse detection: {s}\n", .{ offload, reflink, sparse });
    }

    fn copyInternal(c: *Copier, src_name: []const u8, dst_name: []const u8, nonexistent_dst_in: i32, parent: ?sys.FileStat, ancestors: []const DevIno, command_line_arg: bool, first_dir_created: *bool, copy_into_self: *bool, rename_succeeded: *?bool) bool {
        const x = &c.x;
        var nonexistent_dst = nonexistent_dst_in;
        copy_into_self.* = false;
        var src_sb: sys.FileStat = undefined;
        var dst_sb: sys.FileStat = undefined;
        var src_mode: u32 = 0;
        var dst_backup: ?[]const u8 = null;
        var earlier_file: ?[]const u8 = null;
        var restore_dst_mode = false;
        var dst_mode: u32 = 0;
        var have_dst_lstat = false;
        var copied_as_regular = false;
        var dest_is_symlink = false;
        var e: E = .SUCCESS;
        var rename_errno: i32 = x.rename_errno;
        const drelname = if (dst_name.len > 0) dst_name else ".";

        if (x.move_mode) {
            if (rename_errno < 0) {
                rename_errno = if (sys.renamePath(src_name, drelname, sys.RENAME_NOREPLACE)) |re| @intFromEnum(re) else 0;
            }
            nonexistent_dst = @intFromBool(rename_errno == 0);
            rename_succeeded.* = rename_errno == 0;
        }
        const eexist: i32 = @intFromEnum(E.EXIST);

        if (if (rename_errno == 0) !x.last_file else (rename_errno != eexist or (x.update != .none and x.update != .none_fail))) {
            const name = if (rename_errno == 0) dst_name else src_name;
            const relname = if (rename_errno == 0) drelname else src_name;
            const follow = x.dereference != .never;
            const st = sys.fileStat(relname, follow, &e) orelse {
                c.errno("cannot stat {f}", .{cli.quoteA(name)}, e);
                return false;
            };
            src_sb = st;
            src_mode = st.mode;
            if (st.isDir() and !x.recursive) {
                if (!x.install_mode) {
                    c.errPrint("-r not specified; omitting directory {f}", .{cli.quoteA(src_name)});
                } else c.errPrint("omitting directory {f}", .{cli.quoteA(src_name)});
                return false;
            }
        }

        if (command_line_arg and x.track_src) {
            if ((src_mode & 0o170000) != 0o040000 and x.backup_type == .none and c.seenFile(&c.src_info, src_name, src_sb)) {
                c.errPrint("warning: source file {f} specified more than once", .{cli.quoteA(src_name)});
                return true;
            }
            c.recordFile(&c.src_info, src_name, src_sb);
        }

        const dereference = c.shouldDereference(command_line_arg);
        var new_dst = nonexistent_dst > 0;
        if (!new_dst) {
            if (!(rename_errno == eexist and (x.update == .none or x.update == .none_fail))) {
                const src_is_reg = (src_mode & 0o170000) == 0o100000;
                const src_is_dir = (src_mode & 0o170000) == 0o040000;
                const src_is_lnk = (src_mode & 0o170000) == 0o120000;
                const use_lstat = (!src_is_reg and (!x.copy_as_regular or (src_is_dir and !x.keep_directory_symlink) or src_is_lnk)) or
                    x.move_mode or x.symbolic_link or x.hard_link or x.backup_type != .none or x.unlink_dest_before_opening;
                if (!use_lstat and nonexistent_dst < 0) {
                    new_dst = true;
                } else if (sys.fileStat(drelname, !use_lstat, &e)) |ds| {
                    dst_sb = ds;
                    have_dst_lstat = use_lstat;
                    rename_errno = eexist;
                } else if (e == .NOENT) {
                    new_dst = true;
                } else if (e == .LOOP and !use_lstat and x.unlink_dest_after_failed_open) {
                    // cp -f's destination might be a symlink loop.
                } else {
                    c.errno("cannot stat {f}", .{cli.quoteA(dst_name)}, e);
                    return false;
                }
            }
            if (rename_errno == eexist) {
                var return_now = false;
                var return_val = true;
                var skipped = false;
                var go_skip = false;
                if (new_dst) {
                    // The destination vanished; fall through as a new file.
                } else {
                    if ((x.update != .none and x.update != .none_fail) and !c.sameFileOk(src_name, src_sb, dst_name, dst_sb, &return_now)) {
                        c.errPrint("{f} and {f} are the same file", .{ cli.quoteA(src_name), cli.quoteA(dst_name) });
                        return false;
                    }
                    if (return_now) return true;
                    if (x.update == .older and !src_sb.isDir()) {
                        // Older destination: copy; otherwise skip.
                        if (!destOlder(dst_sb, src_sb, x.preserve_timestamps and !(x.move_mode and devOf(dst_sb) == devOf(src_sb)))) {
                            rename_succeeded.* = true;
                            earlier_file = c.rememberCopied(dst_name, src_sb);
                            if (earlier_file) |ef| {
                                if (!c.createHardLink(ef, dst_name, true, x.verbose, dereference)) {
                                    return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                                }
                            }
                            skipped = true;
                            go_skip = true;
                        }
                    }
                    if (!go_skip) {
                        if (x.move_mode) {
                            if (c.abandonMove(dst_name, dst_sb)) {
                                rename_succeeded.* = true;
                                skipped = true;
                                return_val = x.update == .none;
                            }
                        } else {
                            if (!src_sb.isDir() and (x.update == .none or x.update == .none_fail or
                                (x.interactive == .ask_user and !c.overwriteOk(dst_name, dst_sb))))
                            {
                                skipped = true;
                                return_val = x.update == .none;
                                if (x.interactive == .ask_user and x.update == .all) return_val = false;
                            }
                        }
                    }
                    if (skipped) {
                        if (x.update == .none_fail) {
                            c.errPrint("not replacing {f}", .{cli.quoteA(dst_name)});
                        } else if (x.debug) c.say("skipped {f}\n", .{cli.quoteA(dst_name)});
                        return_now = true;
                    }
                    if (return_now) return return_val;

                    if (src_sb.isDir() != dst_sb.isDir() and x.backup_type == .none) {
                        if (src_sb.isDir()) {
                            c.errPrint("cannot overwrite non-directory {f} with directory {f}", .{ cli.quoteA(dst_name), cli.quoteA(src_name) });
                        } else c.errPrint("cannot overwrite directory {f} with non-directory {f}", .{ cli.quoteA(dst_name), cli.quoteA(src_name) });
                        return false;
                    }
                    if (!dst_sb.isDir() and command_line_arg and x.backup_type != .numbered and c.seenFile(&c.dest_info, dst_name, dst_sb)) {
                        c.errPrint("will not overwrite just-created {f} with {f}", .{ cli.quoteA(dst_name), cli.quoteA(src_name) });
                        return false;
                    }
                    const srcbase = lastComponent(src_name);
                    if (x.backup_type != .none and !dotOrDotdot(srcbase) and (x.move_mode or !dst_sb.isDir())) {
                        if (x.backup_type != .numbered and c.sourceIsDstBackup(srcbase, src_sb, dst_name)) {
                            if (x.move_mode) {
                                c.errPrint("backing up {f} might destroy source;  {f} not moved", .{ cli.quoteA(dst_name), cli.quoteA(src_name) });
                            } else c.errPrint("backing up {f} might destroy source;  {f} not copied", .{ cli.quoteA(dst_name), cli.quoteA(src_name) });
                            return false;
                        }
                        var berr: E = .SUCCESS;
                        if (backup.backupRename(c.ctx, c.a(), dst_name, x.backup_type, &berr)) |b| {
                            dst_backup = b;
                        } else if (berr != .NOENT) {
                            c.errno("cannot backup {f}", .{cli.quoteA(dst_name)}, berr);
                            return false;
                        }
                        new_dst = true;
                    } else if (!dst_sb.isDir() and !x.move_mode and (x.unlink_dest_before_opening or
                        (x.data_copy_required and ((x.preserve_links and dst_sb.nlink > 1) or (x.dereference == .never and !src_sb.isReg())))))
                    {
                        if (sys.unlinkPath(dst_name, false)) |ue| {
                            if (ue != .NOENT) {
                                c.errno("cannot remove {f}", .{cli.quoteA(dst_name)}, ue);
                                return false;
                            }
                        }
                        new_dst = true;
                        if (x.verbose) c.say("removed {f}\n", .{cli.quoteA(dst_name)});
                    }
                }
            }
        }

        // Do not copy through a symlink created by an earlier argument.
        if (command_line_arg and x.track_dest and !x.move_mode and x.backup_type == .none) {
            const lsb: ?sys.FileStat = if (have_dst_lstat) dst_sb else lstat(drelname, &e);
            if (lsb) |l| {
                if (l.isLink() and c.seenFile(&c.dest_info, dst_name, l)) {
                    c.errPrint("will not copy {f} through just-created symlink {f}", .{ cli.quoteA(src_name), cli.quoteA(dst_name) });
                    return false;
                }
            }
        }

        if (x.verbose and !x.move_mode and (src_mode & 0o170000) != 0o040000) {
            c.emitVerbose("{f} -> {f}", src_name, dst_name, dst_backup);
        }

        // Hard link preservation.
        const src_is_dir = (src_mode & 0o170000) == 0o040000;
        if (rename_errno == 0) {
            earlier_file = null;
        } else if (x.recursive and src_is_dir) {
            earlier_file = if (command_line_arg) c.rememberCopied(dst_name, src_sb) else c.srcToDestLookup(src_sb);
        } else if (x.move_mode and src_sb.nlink == 1) {
            earlier_file = c.srcToDestLookup(src_sb);
        } else if (x.preserve_links and !x.hard_link and (src_sb.nlink > 1 or (command_line_arg and x.dereference == .command_line) or x.dereference == .always)) {
            earlier_file = c.rememberCopied(dst_name, src_sb);
        }

        if (earlier_file) |ef| {
            if (src_is_dir) {
                if (sameName(src_name, ef)) {
                    c.errPrint("cannot copy a directory, {f}, into itself, {f}", .{ cli.quoteA(c.top_src), cli.quoteA(c.top_dst) });
                    copy_into_self.* = true;
                    return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                } else if (sameName(dst_name, ef)) {
                    c.errPrint("warning: source directory {f} specified more than once", .{cli.quoteA(c.top_src)});
                    if (x.move_mode) rename_succeeded.* = true;
                    return true;
                } else if (x.dereference == .always or (command_line_arg and x.dereference == .command_line)) {
                    // Reached again through symbolic links: copy it.
                } else {
                    c.errPrint("will not create hard link {f} to directory {f}", .{ cli.quoteA(dst_name), cli.quoteA(ef) });
                    return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                }
            } else {
                if (!c.createHardLink(ef, dst_name, true, x.verbose, dereference)) {
                    return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                }
                return true;
            }
        }

        if (x.move_mode) {
            if (rename_errno == eexist) {
                rename_errno = if (sys.renamePath(src_name, drelname, 0)) |re| @intFromEnum(re) else 0;
            }
            if (rename_errno == 0) {
                if (x.verbose) c.emitVerbose("renamed {f} -> {f}", src_name, dst_name, dst_backup);
                rename_succeeded.* = true;
                if (command_line_arg and !x.last_file) c.recordFile(&c.dest_info, dst_name, src_sb);
                return true;
            }
            const re: E = @enumFromInt(rename_errno);
            if (re == .INVAL) {
                c.errPrint("cannot move {f} to a subdirectory of itself, {f}", .{ cli.quoteA(c.top_src), cli.quoteA(c.top_dst) });
                copy_into_self.* = true;
                return true;
            }
            if (re != .XDEV or x.no_copy) {
                switch (re) {
                    .DQUOT, .EXIST, .ISDIR, .MLINK, .NOSPC, .TXTBSY, .NOTEMPTY => c.errno("cannot overwrite {f}", .{cli.quoteA(dst_name)}, re),
                    else => c.errno("cannot move {f} to {f}", .{ cli.quoteA(src_name), cli.quoteA(dst_name) }, re),
                }
                c.forgetCreated(src_sb);
                return false;
            }
            if (sys.unlinkPath(drelname, src_sb.isDir())) |ue| {
                if (ue != .NOENT) {
                    c.errno("inter-device move failed: {f} to {f}; unable to remove target", .{ cli.quoteA(src_name), cli.quoteA(dst_name) }, ue);
                    c.forgetCreated(src_sb);
                    return false;
                }
            }
            if (x.verbose and !src_sb.isDir()) c.emitVerbose("copied {f} -> {f}", src_name, dst_name, dst_backup);
            new_dst = true;
        }

        var dst_mode_bits = (if (x.set_mode) x.mode else src_mode) & 0o7777;
        var omitted: u32 = dst_mode_bits & (if (x.preserve_ownership) @as(u32, 0o077) else if (src_is_dir) @as(u32, 0o022) else @as(u32, 0));
        var delayed_ok = true;

        if (src_is_dir) {
            if (isAncestor(src_sb, ancestors)) {
                c.errPrint("cannot copy cyclic symbolic link {f}", .{cli.quoteA(src_name)});
                return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
            }
            if (new_dst or !dst_sb.isDir()) {
                const mode = dst_mode_bits & ~omitted;
                if (sys.mkdirPath(drelname, mode)) |me| {
                    c.errno("cannot create directory {f}", .{cli.quoteA(dst_name)}, me);
                    return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                }
                dst_sb = lstat(drelname, &e) orelse {
                    c.errno("cannot stat {f}", .{cli.quoteA(dst_name)}, e);
                    return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                };
                if ((dst_sb.mode & 0o700) != 0o700) {
                    dst_mode = dst_sb.mode;
                    restore_dst_mode = true;
                    if (sys.chmodPath(drelname, dst_mode | 0o700, true)) |ce| {
                        c.errno("setting permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                        return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                    }
                }
                if (!first_dir_created.*) {
                    _ = c.rememberCopied(dst_name, dst_sb);
                    first_dir_created.* = true;
                }
                if (x.verbose) {
                    if (x.move_mode) {
                        c.say("created directory {f}\n", .{cli.quoteA(dst_name)});
                    } else c.emitVerbose("{f} -> {f}", src_name, dst_name, null);
                }
            } else {
                omitted = 0;
            }
            if (x.one_file_system and parent != null and devOf(parent.?) != devOf(src_sb)) {
                // Crossing a file system boundary: do not copy the contents.
            } else {
                delayed_ok = c.copyDir(src_name, dst_name, new_dst, src_sb, ancestors, first_dir_created, copy_into_self);
            }
        } else if (x.symbolic_link) {
            dest_is_symlink = true;
            if (src_name.len == 0 or src_name[0] != '/') {
                // A relative symbolic link only works in the current directory.
                const dparent = dirOf(drelname);
                var in_current = std.mem.eql(u8, dparent, ".");
                if (!in_current) {
                    const dot = stat(".", &e);
                    const dp = stat(dparent, &e);
                    in_current = dot == null or dp == null or sameInode(dot.?, dp.?);
                }
                if (!in_current) {
                    c.errPrint("{f}: can make relative symbolic links only in current directory", .{cli.quote(dst_name)});
                    return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                }
            }
            var removed = false;
            if (c.forceSymlink(src_name, drelname, x.unlink_dest_after_failed_open, &removed)) |se| {
                c.errno("cannot create symbolic link {f} to {f}", .{ cli.quoteA(dst_name), cli.quoteA(src_name) }, se);
                return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
            }
        } else if (x.hard_link) {
            const replace = x.unlink_dest_after_failed_open or x.interactive == .ask_user;
            if (!c.createHardLink(src_name, dst_name, replace, false, dereference)) {
                return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
            }
        } else if (src_sb.isReg() or (x.copy_as_regular and !src_sb.isLink())) {
            copied_as_regular = true;
            if (!c.copyReg(src_name, dst_name, dst_mode_bits & 0o777, omitted, &new_dst, &src_sb)) {
                return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
            }
        } else if ((src_mode & 0o170000) == 0o010000) {
            const mode = src_mode & ~omitted;
            const z = dupeZ(c.a(), drelname) orelse return false;
            if (sys.mknod(z, mode, 0)) |me| {
                c.errno("cannot create fifo {f}", .{cli.quoteA(dst_name)}, me);
                return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
            }
        } else if ((src_mode & 0o170000) == 0o060000 or (src_mode & 0o170000) == 0o020000 or (src_mode & 0o170000) == 0o140000) {
            const mode = src_mode & ~omitted;
            const z = dupeZ(c.a(), drelname) orelse return false;
            if (sys.mknod(z, mode, sys.makedev(src_sb.rdev_major, src_sb.rdev_minor))) |me| {
                c.errno("cannot create special file {f}", .{cli.quoteA(dst_name)}, me);
                return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
            }
        } else if (src_sb.isLink()) {
            var lbuf: [4096]u8 = undefined;
            var le: E = .SUCCESS;
            const n = sys.readlinkPath(src_name, &lbuf, &le) orelse {
                c.errno("cannot read symbolic link {f}", .{cli.quoteA(src_name)}, le);
                return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
            };
            const link_val = lbuf[0..n];
            dest_is_symlink = true;
            var removed = false;
            var symlink_err = c.forceSymlink(link_val, drelname, x.unlink_dest_after_failed_open, &removed);
            if (symlink_err != null and x.update == .older and !new_dst and dst_sb.isLink() and dst_sb.size == link_val.len) {
                var dbuf: [4096]u8 = undefined;
                if (sys.readlinkPath(drelname, &dbuf, &le)) |dn| {
                    if (std.mem.eql(u8, dbuf[0..dn], link_val)) symlink_err = null;
                }
            }
            if (symlink_err) |se| {
                c.errno("cannot create symbolic link {f}", .{cli.quoteA(dst_name)}, se);
                return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
            }
            if (x.preserve_ownership) {
                if (sys.chownAt(drelname, src_sb.uid, src_sb.gid, true)) |ce| {
                    if (!c.chownFailureOk(ce)) {
                        c.errno("failed to preserve ownership for {s}", .{dst_name}, ce);
                        if (x.require_preserve) return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
                    }
                }
            }
        } else {
            c.errPrint("{f} has unknown file type", .{cli.quoteA(src_name)});
            return c.unBackup(dst_backup, dst_name, earlier_file, src_sb, false);
        }

        if (command_line_arg and x.track_dest) {
            if (lstat(drelname, &e)) |sb| c.recordFile(&c.dest_info, dst_name, sb);
        }
        if (x.hard_link and !src_is_dir) return delayed_ok;
        if (copied_as_regular) return delayed_ok;

        if (x.preserve_timestamps) {
            const ts = [2]sys.TimeSpec{ .{ .sec = src_sb.atime_s, .nsec = src_sb.atime_ns }, .{ .sec = src_sb.mtime_s, .nsec = src_sb.mtime_ns } };
            if (sys.setTimes(drelname, -1, ts, dest_is_symlink)) |te| {
                c.errno("preserving times for {f}", .{cli.quoteA(dst_name)}, te);
                if (x.require_preserve) return false;
            }
        }
        if (!dest_is_symlink and x.preserve_ownership and (new_dst or src_sb.uid != dst_sb.uid or src_sb.gid != dst_sb.gid)) {
            switch (c.setOwner(dst_name, -1, src_sb, new_dst, dst_sb)) {
                -1 => return false,
                0 => src_mode &= ~@as(u32, 0o7000),
                else => {},
            }
        }
        if (dest_is_symlink) return delayed_ok;

        if (x.preserve_mode or x.move_mode) {
            if (sys.chmodPath(drelname, src_mode & 0o7777, false)) |ce| {
                if (!c.ownerFailureOk(ce)) {
                    c.errno("preserving permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                    if (x.require_preserve) return false;
                }
            }
        } else if (x.set_mode) {
            if (sys.chmodPath(drelname, x.mode, false)) |ce| {
                c.errno("setting permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                return false;
            }
        } else if (x.explicit_no_preserve_mode and new_dst) {
            var def: u32 = if (src_is_dir or (src_mode & 0o170000) == 0o140000) 0o777 else 0o666;
            if (src_is_dir) def |= dst_sb.mode & 0o2000;
            if (sys.chmodPath(drelname, def & ~c.umask, false)) |ce| {
                c.errno("setting permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                return false;
            }
        } else {
            if (omitted != 0) {
                omitted &= ~c.umask;
                if (omitted != 0 and !restore_dst_mode) {
                    if (new_dst) {
                        dst_sb = lstat(drelname, &e) orelse {
                            c.errno("cannot stat {f}", .{cli.quoteA(dst_name)}, e);
                            return false;
                        };
                    }
                    dst_mode = dst_sb.mode;
                    if (omitted & ~dst_mode != 0) restore_dst_mode = true;
                }
            }
            if (restore_dst_mode) {
                if (sys.chmodPath(drelname, dst_mode | omitted, true)) |ce| {
                    c.errno("preserving permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                    if (x.require_preserve) return false;
                }
            }
        }
        dst_mode_bits = 0;
        return delayed_ok;
    }

    fn destOlder(dst: sys.FileStat, src: sys.FileStat, truncate_source: bool) bool {
        // true when the destination is older than the source (so copy).
        var ss = src.mtime_s;
        var sn: i64 = src.mtime_ns;
        if (truncate_source) {
            // The destination file system may have coarser timestamps.
            if (dst.mtime_ns == 0) sn = 0;
        }
        _ = &ss;
        if (dst.mtime_s != ss) return dst.mtime_s < ss;
        return dst.mtime_ns < sn;
    }

    /// Roll back a failed copy (copy_internal's un_backup label).
    fn unBackup(c: *Copier, dst_backup: ?[]const u8, dst_name: []const u8, earlier_file: ?[]const u8, src_sb: sys.FileStat, ok: bool) bool {
        if (earlier_file == null) c.forgetCreated(src_sb);
        if (dst_backup) |b| {
            if (sys.renamePath(b, dst_name, 0)) |re| {
                c.errno("cannot un-backup {f}", .{cli.quoteA(dst_name)}, re);
            } else if (c.x.verbose) {
                c.say("{f} -> {f} (unbackup)\n", .{ cli.quoteA(b), cli.quoteA(dst_name) });
            }
        }
        return ok;
    }

    /// set_owner(); returns 1 on success, 0 when ignorable failure, -1 on error.
    fn setOwner(c: *Copier, dst_name: []const u8, dest_desc: i32, src_sb: sys.FileStat, new_dst: bool, dst_sb: sys.FileStat) i32 {
        const x = &c.x;
        if (!new_dst and (x.preserve_mode or x.move_mode or x.set_mode)) {
            const old_mode = dst_sb.mode;
            const new_mode = if (x.preserve_mode or x.move_mode) src_sb.mode else x.mode;
            const temp = old_mode & new_mode & 0o700;
            if ((old_mode & 0o7777 & (~new_mode | 0o7000)) != 0) {
                const err = if (dest_desc >= 0) sys.fchmodFd(dest_desc, temp) else sys.chmodPath(dst_name, temp, false);
                if (err) |ce| {
                    if (!c.ownerFailureOk(ce)) c.errno("clearing permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                    return -@as(i32, @intFromBool(x.require_preserve));
                }
            }
        }
        const err = if (dest_desc >= 0) sys.fchownFd(dest_desc, src_sb.uid, src_sb.gid) else sys.chownAt(dst_name, src_sb.uid, src_sb.gid, true);
        if (err == null) return 1;
        const ce = err.?;
        if (c.chownFailureOk(ce)) {
            _ = if (dest_desc >= 0) sys.fchownFd(dest_desc, std.math.maxInt(u32), src_sb.gid) else sys.chownAt(dst_name, std.math.maxInt(u32), src_sb.gid, true);
        } else {
            c.errno("failed to preserve ownership for {f}", .{cli.quoteA(dst_name)}, ce);
            if (x.require_preserve) return -1;
        }
        return 0;
    }

    // ------------------------------------------------------------ directories

    fn copyDir(c: *Copier, src_name: []const u8, dst_name: []const u8, new_dst: bool, src_sb: sys.FileStat, ancestors: []const DevIno, first_dir_created: *bool, copy_into_self: *bool) bool {
        const ctx = c.ctx;
        var dir = Io.Dir.cwd().openDir(ctx.io, src_name, .{ .iterate = true }) catch |e| {
            c.out.flush();
            cli.warn(ctx, "cannot access {f}: {s}", .{ cli.quoteA(src_name), cli.errText(e) });
            return false;
        };
        const Ent = struct { name: []u8, ino: u64 };
        var names: std.ArrayList(Ent) = .empty;
        defer {
            for (names.items) |n| ctx.gpa.free(n.name);
            names.deinit(ctx.gpa);
        }
        var it = dir.iterate();
        while (it.next(ctx.io) catch null) |entry| {
            const dup = ctx.gpa.dupe(u8, entry.name) catch break;
            names.append(ctx.gpa, .{ .name = dup, .ino = entry.inode }) catch {
                ctx.gpa.free(dup);
                break;
            };
        }
        dir.close(ctx.io);

        // savedir(SAVEDIR_SORT_FASTREAD) orders the entries by inode number.
        std.mem.sort(Ent, names.items, {}, struct {
            fn lt(_: void, p: Ent, q: Ent) bool {
                return p.ino < q.ino;
            }
        }.lt);

        const x_saved = c.x;
        defer c.x = x_saved;
        if (c.x.dereference == .command_line) c.x.dereference = .never;

        var anc: std.ArrayList(DevIno) = .empty;
        defer anc.deinit(ctx.gpa);
        anc.appendSlice(ctx.gpa, ancestors) catch {};
        anc.append(ctx.gpa, key(src_sb)) catch {};

        var ok = true;
        var new_first_dir = false;
        for (names.items) |n| {
            const sname = joinName(c.gpa, src_name, n.name) catch continue;
            defer c.gpa.free(sname);
            const dname = joinName(c.gpa, dst_name, n.name) catch continue;
            defer c.gpa.free(dname);
            var first_dir = first_dir_created.*;
            var local_self = false;
            var rs: ?bool = null;
            if (!c.copyInternal(sname, dname, @intFromBool(new_dst), src_sb, anc.items, false, &first_dir, &local_self, &rs)) ok = false;
            if (local_self) {
                copy_into_self.* = true;
                break;
            }
            new_first_dir = new_first_dir or first_dir;
        }
        first_dir_created.* = new_first_dir;
        return ok;
    }

    // ------------------------------------------------------------- regular files

    fn copyReg(c: *Copier, src_name: []const u8, dst_name: []const u8, dst_mode: u32, omitted_in: u32, new_dst: *bool, src_sb: *sys.FileStat) bool {
        const x = &c.x;
        var omitted = omitted_in;
        var extra: u32 = 0;
        var e: E = .SUCCESS;
        var data_copy_required = x.data_copy_required;
        const drelname = dst_name;

        const src_fd = sys.openFd(src_name, sys.O.RDONLY | (if (x.dereference == .never) sys.O.NOFOLLOW else 0), 0, &e) orelse {
            c.errno("cannot open {f} for reading", .{cli.quoteA(src_name)}, e);
            return false;
        };
        var ok = true;
        defer _ = sys.closeFd(src_fd);

        const open_sb = sys.fstatFd(src_fd, &e) orelse {
            c.errno("cannot fstat {f}", .{cli.quoteA(src_name)}, e);
            return false;
        };
        if (!sameInode(src_sb.*, open_sb)) {
            c.errPrint("skipping file {f}, as it was replaced while being copied", .{cli.quoteA(src_name)});
            return false;
        }
        src_sb.* = open_sb;
        const src_mode = open_sb.mode;

        var dest_fd: i32 = -1;
        var dest_errno: E = .SUCCESS;
        if (!new_dst.*) {
            const flags = sys.O.WRONLY | (if (data_copy_required) sys.O.TRUNC else 0);
            if (sys.openFd(drelname, flags, 0, &e)) |fd| {
                dest_fd = fd;
            } else dest_errno = e;
            if (dest_fd < 0 and dest_errno != .NOENT and x.unlink_dest_after_failed_open) {
                if (sys.unlinkPath(drelname, false)) |ue| {
                    if (ue != .NOENT) {
                        c.errno("cannot remove {f}", .{cli.quoteA(dst_name)}, ue);
                        return false;
                    }
                } else if (x.verbose) c.say("removed {f}\n", .{cli.quoteA(dst_name)});
                dest_errno = .NOENT;
            }
            if (dest_fd < 0 and dest_errno == .NOENT) new_dst.* = true;
        }
        if (new_dst.*) {
            const open_mode = dst_mode & ~omitted;
            extra = open_mode & ~dst_mode;
            if (sys.openFd(drelname, sys.O.WRONLY | sys.O.CREAT | sys.O.EXCL, open_mode, &e)) |fd| {
                dest_fd = fd;
                dest_errno = .SUCCESS;
            } else dest_errno = e;
            if (dest_fd < 0 and dest_errno == .EXIST and !x.move_mode) {
                var dummy: [1]u8 = undefined;
                var le: E = .SUCCESS;
                if (sys.readlinkPath(drelname, &dummy, &le) != null) {
                    if (x.open_dangling_dest_symlink) {
                        if (sys.openFd(drelname, sys.O.WRONLY | sys.O.CREAT, open_mode, &e)) |fd| {
                            dest_fd = fd;
                            dest_errno = .SUCCESS;
                        } else dest_errno = e;
                    } else {
                        c.errPrint("not writing through dangling symlink {f}", .{cli.quoteA(dst_name)});
                        return false;
                    }
                }
            }
            if (dest_fd < 0 and dest_errno == .ISDIR and dst_name.len > 0 and dst_name[dst_name.len - 1] == '/') dest_errno = .NOTDIR;
        } else {
            omitted = 0;
            extra = 0;
        }
        if (dest_fd < 0) {
            c.errno("cannot create regular file {f}", .{cli.quoteA(dst_name)}, dest_errno);
            return false;
        }
        defer {
            if (sys.closeFd(dest_fd)) |ce| {
                c.errno("failed to close {f}", .{cli.quoteA(dst_name)}, ce);
                ok = false;
            }
        }

        if (x.reflink == .always) {
            if (data_copy_required) {
                c.errno("failed to clone {f} from {f}", .{ cli.quoteA(dst_name), cli.quoteA(src_name) }, .OPNOTSUPP);
                if (new_dst.*) _ = sys.unlinkPath(drelname, false);
                return false;
            }
        }

        var sb: sys.FileStat = undefined;
        if (!(data_copy_required or x.preserve_ownership or extra != 0)) {
            sb = std.mem.zeroes(sys.FileStat);
        } else if (sys.fstatFd(dest_fd, &e)) |fs| {
            sb = fs;
        } else {
            c.errno("cannot fstat {f}", .{cli.quoteA(dst_name)}, e);
            return false;
        }
        const temporary_mode = sb.mode | extra;
        if (temporary_mode != sb.mode and sys.fchmodFd(dest_fd, temporary_mode) != null) extra = 0;

        var used_holes: []const u8 = "no";
        if (data_copy_required) {
            const make_holes_cfg = sb.isReg() and (x.sparse == .always or x.sparse == .auto);
            const src_looks_sparse = open_sb.isReg() and open_sb.blocks * 512 < open_sb.size;
            used_holes = if (x.sparse == .always) "zeros" else if (src_looks_sparse and x.sparse == .auto) "SEEK_HOLE" else "no";
            if (!c.copyData(src_fd, dest_fd, open_sb, src_name, dst_name, make_holes_cfg, x.sparse == .always, src_looks_sparse)) {
                return false;
            }
        }
        if (x.debug) {
            c.debugLine(if (x.sparse == .always or x.reflink == .never) "avoided" else "yes", if (x.reflink == .never) "no" else "unsupported", used_holes);
        }
        data_copy_required = false;

        if (x.preserve_timestamps) {
            const ts = [2]sys.TimeSpec{ .{ .sec = src_sb.atime_s, .nsec = src_sb.atime_ns }, .{ .sec = src_sb.mtime_s, .nsec = src_sb.mtime_ns } };
            if (sys.setTimes(null, dest_fd, ts, false)) |te| {
                c.errno("preserving times for {f}", .{cli.quoteA(dst_name)}, te);
                if (x.require_preserve) return false;
            }
        }
        var smode = src_mode;
        if (x.preserve_ownership and (src_sb.uid != sb.uid or src_sb.gid != sb.gid)) {
            switch (c.setOwner(dst_name, dest_fd, src_sb.*, new_dst.*, sb)) {
                -1 => return false,
                0 => smode &= ~@as(u32, 0o7000),
                else => {},
            }
        }
        if (x.preserve_mode or x.move_mode) {
            if (sys.fchmodFd(dest_fd, smode & 0o7777)) |ce| {
                if (!c.ownerFailureOk(ce)) {
                    c.errno("preserving permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                    if (x.require_preserve) ok = false;
                }
            }
        } else if (x.set_mode) {
            if (sys.fchmodFd(dest_fd, x.mode)) |ce| {
                c.errno("setting permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                ok = false;
            }
        } else if (x.explicit_no_preserve_mode and new_dst.*) {
            if (sys.fchmodFd(dest_fd, 0o666 & ~c.umask)) |ce| {
                c.errno("setting permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                ok = false;
            }
        } else if (omitted != 0 or extra != 0) {
            omitted &= ~c.umask;
            if (omitted != 0 or extra != 0) {
                if (sys.fchmodFd(dest_fd, dst_mode & ~c.umask)) |ce| {
                    c.errno("preserving permissions for {f}", .{cli.quoteA(dst_name)}, ce);
                    if (x.require_preserve) ok = false;
                }
            }
        }
        return ok;
    }

    fn copyData(c: *Copier, src_fd: i32, dest_fd: i32, src_sb: sys.FileStat, src_name: []const u8, dst_name: []const u8, dest_is_reg: bool, force_zero_holes: bool, src_sparse: bool) bool {
        const buf = c.gpa.alloc(u8, 128 * 1024) catch {
            c.errPrint("memory exhausted", .{});
            return false;
        };
        defer c.gpa.free(buf);
        var e: E = .SUCCESS;
        const make_holes = dest_is_reg and c.x.sparse != .never and (force_zero_holes or src_sparse);
        const hole_size: usize = if (src_sb.blksize != 0) src_sb.blksize else 4096;
        var wrote_hole_at_eof = false;
        var total: u64 = 0;
        var pending_hole: u64 = 0;

        if (make_holes and src_sparse and !force_zero_holes) {
            // Walk data extents with SEEK_DATA / SEEK_HOLE.
            var pos: i64 = 0;
            const size: i64 = @intCast(src_sb.size);
            while (pos < size) {
                var se: E = .SUCCESS;
                const data = sys.seekFd(src_fd, pos, 3, &se) orelse {
                    if (se == .NXIO) break;
                    // Unsupported: fall back to plain copying below.
                    return c.plainCopy(src_fd, dest_fd, buf, src_name, dst_name);
                };
                const hole = sys.seekFd(src_fd, data, 4, &se) orelse size;
                if (data > pos) {
                    // leave a hole
                }
                _ = sys.seekFd(src_fd, data, 0, &se);
                if (sys.seekFd(dest_fd, data, 0, &se) == null) {
                    c.errno("cannot lseek {f}", .{cli.quoteA(dst_name)}, se);
                    return false;
                }
                var remaining: i64 = hole - data;
                while (remaining > 0) {
                    const want: usize = @intCast(@min(@as(i64, @intCast(buf.len)), remaining));
                    const n = sys.readFd(src_fd, buf[0..want], &e) orelse {
                        c.errno("error reading {f}", .{cli.quoteA(src_name)}, e);
                        return false;
                    };
                    if (n == 0) break;
                    if (sys.writeAllFd(dest_fd, buf[0..n])) |we| {
                        c.errno("error writing {f}", .{cli.quoteA(dst_name)}, we);
                        return false;
                    }
                    remaining -= @intCast(n);
                }
                pos = hole;
            }
            if (sys.ftruncateFd(dest_fd, src_sb.size)) |te| {
                c.errno("failed to extend {f}", .{cli.quoteA(dst_name)}, te);
                return false;
            }
            return true;
        }

        while (true) {
            const n = sys.readFd(src_fd, buf, &e) orelse {
                c.errno("error reading {f}", .{cli.quoteA(src_name)}, e);
                return false;
            };
            if (n == 0) break;
            total += n;
            if (make_holes and force_zero_holes) {
                var off: usize = 0;
                while (off < n) {
                    const chunk = @min(hole_size, n - off);
                    const blk = buf[off .. off + chunk];
                    const zero = std.mem.allEqual(u8, blk, 0);
                    if (zero) {
                        pending_hole += chunk;
                        wrote_hole_at_eof = true;
                    } else {
                        if (pending_hole > 0) {
                            var se: E = .SUCCESS;
                            if (sys.seekFd(dest_fd, @intCast(pending_hole), 1, &se) == null) {
                                c.errno("cannot lseek {f}", .{cli.quoteA(dst_name)}, se);
                                return false;
                            }
                            pending_hole = 0;
                        }
                        wrote_hole_at_eof = false;
                        if (sys.writeAllFd(dest_fd, blk)) |we| {
                            c.errno("error writing {f}", .{cli.quoteA(dst_name)}, we);
                            return false;
                        }
                    }
                    off += chunk;
                }
            } else if (sys.writeAllFd(dest_fd, buf[0..n])) |we| {
                c.errno("error writing {f}", .{cli.quoteA(dst_name)}, we);
                return false;
            }
        }
        if (wrote_hole_at_eof) {
            if (sys.ftruncateFd(dest_fd, total)) |te| {
                c.errno("failed to extend {f}", .{cli.quoteA(dst_name)}, te);
                return false;
            }
        }
        return true;
    }

    fn plainCopy(c: *Copier, src_fd: i32, dest_fd: i32, buf: []u8, src_name: []const u8, dst_name: []const u8) bool {
        var e: E = .SUCCESS;
        var se: E = .SUCCESS;
        _ = sys.seekFd(src_fd, 0, 0, &se);
        _ = sys.seekFd(dest_fd, 0, 0, &se);
        while (true) {
            const n = sys.readFd(src_fd, buf, &e) orelse {
                c.errno("error reading {f}", .{cli.quoteA(src_name)}, e);
                return false;
            };
            if (n == 0) break;
            if (sys.writeAllFd(dest_fd, buf[0..n])) |we| {
                c.errno("error writing {f}", .{cli.quoteA(dst_name)}, we);
                return false;
            }
        }
        return true;
    }
};

/// "rw-r--r--" style permission text (strmode without the type letter).
pub fn modeChars(mode: u32, out: *[10]u8) void {
    const rwx = "rwxrwxrwx";
    out[0] = '-';
    for (0..9) |k| out[k + 1] = if (mode & (@as(u32, 1) << @intCast(8 - k)) != 0) rwx[k] else '-';
    if (mode & 0o4000 != 0) out[3] = if (out[3] == 'x') 's' else 'S';
    if (mode & 0o2000 != 0) out[6] = if (out[6] == 'x') 's' else 'S';
    if (mode & 0o1000 != 0) out[9] = if (out[9] == 'x') 't' else 'T';
}

/// file_name_concat(dir, name): one slash between, none doubled.
fn dupeZ(a: Allocator, s: []const u8) ?[:0]u8 {
    const buf = a.alloc(u8, s.len + 1) catch return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

pub fn joinName(gpa: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    var end = dir.len;
    while (end > 0 and dir[end - 1] == '/') end -= 1;
    if (end == 0 and dir.len > 0) return std.fmt.allocPrint(gpa, "/{s}", .{name});
    if (dir.len == 0) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir[0..end], name });
}
