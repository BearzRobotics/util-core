// SPDX-License-Identifier: GPL-2.0-or-later
//! mktemp library: create a temporary file or directory, safely.
//! Reference: GNU coreutils manual "mktemp invocation" (9.7). POSIX does not
//! specify mktemp.
//!
//! Template rules (probed against GNU 9.7): the last run of X characters
//! (at least three) is replaced by random letters and digits; anything after
//! it is a fixed suffix; `--suffix` appends one and then the template must end
//! in X. The file is created with O_EXCL (mode 0600 minus umask) and the
//! directory with mode 0700 minus umask; on EEXIST another name is tried.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

pub const default_template = "tmp.XXXXXXXXXX";

pub const Options = struct {
    /// -d: make a directory instead of a file.
    directory: bool = false,
    /// -u: only print a name, create nothing.
    dry_run: bool = false,
    /// The TEMPLATE operand; null means `default_template` (and --tmpdir).
    template: ?[]const u8 = null,
    /// --suffix=SUFF.
    suffix: ?[]const u8 = null,
    /// -p / --tmpdir (also implied when there is no template).
    use_tmpdir: bool = false,
    /// -t.
    tmpdir_t: bool = false,
    /// DIR of -p DIR / --tmpdir=DIR.
    dir: ?[]const u8 = null,
};

/// A template the library refuses; the slices point into the options.
pub const Problem = union(enum) {
    /// Suffix (given or derived from the template) contains a '/'.
    suffix_has_slash: []const u8,
    /// --suffix given and the template does not end in X.
    suffix_needs_x: []const u8,
    /// Fewer than three X's at the end of the template.
    too_few_x: []const u8,
    /// -t and the template contains a '/'.
    template_has_slash: []const u8,
    /// --tmpdir and the template is absolute.
    template_absolute: []const u8,
};

/// The validated template: where the random characters go.
pub const Plan = struct {
    /// Full path with the X run still in place.
    full: []u8,
    x_start: usize,
    x_len: usize,
    directory: bool,
    dry_run: bool,
};

pub const Prepared = union(enum) { ok: Plan, bad: Problem };

/// Validate the options and build the path template. `tmpdir_env` is the value
/// of $TMPDIR (the caller reads it). `arena` owns the result.
pub fn prepare(arena: std.mem.Allocator, opts: Options, tmpdir_env: ?[]const u8) error{OutOfMemory}!Prepared {
    var use_tmpdir = opts.use_tmpdir;
    var template: []const u8 = default_template;
    if (opts.template) |t| template = t else use_tmpdir = true;

    var suffix: []const u8 = undefined;
    var body: []const u8 = undefined; // template without the suffix
    if (opts.suffix) |s| {
        if (std.mem.indexOfScalar(u8, s, '/') != null) return .{ .bad = .{ .suffix_has_slash = s } };
        if (template.len == 0 or template[template.len - 1] != 'X') return .{ .bad = .{ .suffix_needs_x = template } };
        body = template;
        suffix = s;
    } else {
        const last_x = std.mem.lastIndexOfScalar(u8, template, 'X');
        const end = if (last_x) |i| i + 1 else template.len;
        body = template[0..end];
        suffix = template[end..];
        if (std.mem.indexOfScalar(u8, suffix, '/') != null) return .{ .bad = .{ .suffix_has_slash = suffix } };
    }
    var xs: usize = 0;
    while (xs < body.len and body[body.len - 1 - xs] == 'X') xs += 1;
    if (xs < 3) return .{ .bad = .{ .too_few_x = template } };

    var full: []u8 = undefined;
    if (use_tmpdir) {
        var dir: []const u8 = undefined;
        if (opts.tmpdir_t) {
            dir = tmpdir_env orelse (opts.dir orelse "/tmp");
            if (std.mem.indexOfScalar(u8, template, '/') != null) return .{ .bad = .{ .template_has_slash = template } };
        } else {
            dir = opts.dir orelse (tmpdir_env orelse "/tmp");
            if (template.len > 0 and template[0] == '/') return .{ .bad = .{ .template_absolute = template } };
        }
        const sep: []const u8 = if (dir.len > 0 and dir[dir.len - 1] == '/') "" else "/";
        full = try std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ dir, sep, body, suffix });
    } else {
        full = try std.fmt.allocPrint(arena, "{s}{s}", .{ body, suffix });
    }
    return .{ .ok = .{
        .full = full,
        .x_start = full.len - suffix.len - xs,
        .x_len = xs,
        .directory = opts.directory,
        .dry_run = opts.dry_run,
    } };
}

pub const Created = union(enum) {
    /// The name that was created (or, with dry_run, would be); owned by `arena`.
    name: []u8,
    /// Creation failed with this error (EEXIST: every candidate was taken).
    failed: anyerror,
};

/// Pick random names until one can be created. `arena` owns the result.
pub fn create(env: Env, arena: std.mem.Allocator, plan: Plan) error{OutOfMemory}!Created {
    const cwd = Io.Dir.cwd();
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        const work = try arena.dupe(u8, plan.full);
        fillRandom(env.io, work[plan.x_start .. plan.x_start + plan.x_len]);
        if (plan.dry_run) return .{ .name = work };
        var failure: ?anyerror = null;
        var exists = false;
        if (plan.directory) {
            cwd.createDir(env.io, work, .fromMode(0o700)) catch |e| {
                if (e == error.PathAlreadyExists) exists = true else failure = e;
            };
        } else {
            if (cwd.createFile(env.io, work, .{ .exclusive = true, .permissions = .fromMode(0o600) })) |f| {
                f.close(env.io);
            } else |e| {
                if (e == error.PathAlreadyExists) exists = true else failure = e;
            }
        }
        if (exists and attempts < 238328) continue;
        if (exists) failure = error.PathAlreadyExists;
        if (failure) |e| return .{ .failed = e };
        return .{ .name = work };
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

test "prepare splits template and suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try prepare(arena.allocator(), .{ .template = "fooXXXXbar" }, null);
    try std.testing.expectEqual(@as(usize, 4), r.ok.x_len);
    try std.testing.expectEqualStrings("fooXXXXbar", r.ok.full);
    try std.testing.expectEqual(@as(usize, 3), r.ok.x_start);
    const bad = try prepare(arena.allocator(), .{ .template = "fooXX" }, null);
    try std.testing.expect(bad.bad == .too_few_x);
}
