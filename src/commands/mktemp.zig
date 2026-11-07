//! mktemp — create a temporary file or directory, safely, and print its name.
//! Reference: GNU coreutils manual "mktemp invocation" (9.7). POSIX does not
//! specify mktemp.
//!
//! Template rules (probed against GNU 9.7): the last run of X characters
//! (at least three) is replaced by random letters and digits; anything after
//! it is a fixed suffix; `--suffix` appends one and then the template must end
//! in X. The file is created with O_EXCL (mode 0600 minus umask) and the
//! directory with mode 0700 minus umask; on EEXIST another name is tried.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const Io = std.Io;

const help_text = @embedFile("../help/mktemp.txt");

const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

pub fn main(ctx: cli.Context) u8 {
    var make_dir = false;
    var dry_run = false;
    var quiet = false;
    var dir_opt: ?[]const u8 = null; // from -p DIR / --tmpdir=DIR
    var use_tmpdir = false; // -p, --tmpdir
    var tmpdir_t = false; // -t
    var suffix_opt: ?[]const u8 = null;
    var p = getopt.Parser.init(ctx, "dp:qtuV", &.{
        .{ .name = "directory", .id = 'd' },
        .{ .name = "dry-run", .id = 'u' },
        .{ .name = "quiet", .id = 'q' },
        .{ .name = "suffix", .arg = .required, .id = 1100 },
        .{ .name = "tmpdir", .arg = .optional, .id = 'p' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'd' => make_dir = true,
            'u' => dry_run = true,
            'q' => quiet = true,
            't' => {
                use_tmpdir = true;
                tmpdir_t = true;
            },
            'p' => {
                use_tmpdir = true;
                if (o.arg) |a| dir_opt = a;
            },
            1100 => suffix_opt = o.arg,
            'V' => return if (cli.printVersion(ctx)) 0 else 1,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const ops = p.operands.items;
    if (ops.len > 1) {
        getopt.usageError(ctx, "too many templates", .{});
        return 1;
    }
    var template: []const u8 = "tmp.XXXXXXXXXX";
    if (ops.len == 0) {
        use_tmpdir = true;
    } else template = ops[0];

    // Split into <prefix X-run> <suffix>.
    var suffix: []const u8 = undefined;
    var body: []const u8 = undefined; // template without the suffix
    if (suffix_opt) |s| {
        if (std.mem.indexOfScalar(u8, s, '/') != null) {
            cli.warn(ctx, "invalid suffix {f}, contains directory separator", .{cli.quoteC(s)});
            return 1;
        }
        if (template.len == 0 or template[template.len - 1] != 'X') {
            cli.warn(ctx, "with --suffix, template {f} must end in X", .{cli.quoteC(template)});
            return 1;
        }
        body = template;
        suffix = s;
    } else {
        const last_x = std.mem.lastIndexOfScalar(u8, template, 'X');
        const end = if (last_x) |i| i + 1 else template.len;
        body = template[0..end];
        suffix = template[end..];
        if (std.mem.indexOfScalar(u8, suffix, '/') != null) {
            cli.warn(ctx, "invalid suffix {f}, contains directory separator", .{cli.quoteC(suffix)});
            return 1;
        }
    }
    var xs: usize = 0;
    while (xs < body.len and body[body.len - 1 - xs] == 'X') xs += 1;
    if (xs < 3) {
        cli.warn(ctx, "too few X's in template {f}", .{cli.quoteC(template)});
        return 1;
    }

    // Directory handling.
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var full: []u8 = undefined;
    if (use_tmpdir) {
        var dir: []const u8 = undefined;
        if (tmpdir_t) {
            dir = cli.getenv(ctx, "TMPDIR") orelse (dir_opt orelse "/tmp");
            if (std.mem.indexOfScalar(u8, template, '/') != null) {
                cli.warn(ctx, "invalid template, {f}, contains directory separator", .{cli.quoteC(template)});
                return 1;
            }
        } else {
            dir = dir_opt orelse (cli.getenv(ctx, "TMPDIR") orelse "/tmp");
            if (template.len > 0 and template[0] == '/') {
                cli.warn(ctx, "invalid template, {f}; with --tmpdir, it may not be absolute", .{cli.quoteC(template)});
                return 1;
            }
        }
        const sep: []const u8 = if (dir.len > 0 and dir[dir.len - 1] == '/') "" else "/";
        full = std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ dir, sep, body, suffix }) catch return 1;
    } else {
        full = std.fmt.allocPrint(a, "{s}{s}", .{ body, suffix }) catch return 1;
    }
    const x_start = full.len - suffix.len - xs;

    const cwd = Io.Dir.cwd();
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        const work = a.dupe(u8, full) catch return 1;
        fillRandom(ctx.io, work[x_start .. x_start + xs]);
        if (dry_run) {
            return if (cli.writeStdout(ctx.io, std.fmt.allocPrint(a, "{s}\n", .{work}) catch return 1)) 0 else 1;
        }
        var err_text: ?[]const u8 = null;
        var exists = false;
        if (make_dir) {
            cwd.createDir(ctx.io, work, .fromMode(0o700)) catch |e| {
                if (e == error.PathAlreadyExists) exists = true else err_text = cli.errText(e);
            };
        } else {
            if (cwd.createFile(ctx.io, work, .{ .exclusive = true, .permissions = .fromMode(0o600) })) |f| {
                f.close(ctx.io);
            } else |e| {
                if (e == error.PathAlreadyExists) exists = true else err_text = cli.errText(e);
            }
        }
        if (exists and attempts < 238328) continue;
        if (exists) err_text = "File exists";
        if (err_text) |t| {
            if (!quiet) cli.warn(ctx, "failed to create {s} via template {f}: {s}", .{ if (make_dir) "directory" else "file", cli.quoteA(full), t });
            return 1;
        }
        return if (cli.writeStdout(ctx.io, std.fmt.allocPrint(a, "{s}\n", .{work}) catch return 1)) 0 else 1;
    }
}

/// Fill `out` with letters and digits, uniformly (bytes >= 248 are rejected
/// so that 256 mod 62 does not bias the choice).
fn fillRandom(io: Io, out: []u8) void {
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (i < out.len) {
        io.random(&buf);
        for (buf) |b| {
            if (b >= 248) continue;
            out[i] = alphabet[b % 62];
            i += 1;
            if (i == out.len) break;
        }
    }
}
