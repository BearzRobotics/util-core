// SPDX-License-Identifier: GPL-2.0-or-later
//! Line-by-line git change marks for `cat`'s bat-style view (like bat's
//! gutter): which lines of a file were added, modified, or have lines
//! removed next to them, comparing the working tree with the index.
//!
//! The directory of a displayed file is untrusted: its repository may be an
//! unpacked archive whose `.git/config` names programs. `git diff` runs some
//! of them (core.fsmonitor, filter.*.clean and filter.*.process, hooks, and
//! the transport helpers of a partial clone), so it is not used. Only the
//! index blob is fetched, with `git cat-file blob`, which applies no filters,
//! and it is compared with the file here (diffcore). When the two differ,
//! `git check-attr` and `git config --get` say how git would have converted
//! the file; neither runs anything. A file that needs a repository program to
//! be converted (a `filter` attribute) gets no marks.
//!
//! When git is not installed, the file is not in a repository, it is
//! untracked, or nothing differs, `load` returns null and the view has no
//! marker column (bat does the same).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const common = @import("common.zig");
const diffcore = @import("diffcore.zig");

pub const Mark = enum {
    added,
    modified,
    /// Lines were removed directly above this (the first) line.
    removed_above,
    /// Lines were removed directly below this line.
    removed_below,

    pub fn char(m: Mark) []const u8 {
        return switch (m) {
            .added => "+",
            .modified => "~",
            .removed_above => "‾",
            .removed_below => "_",
        };
    }
};

pub const Changes = struct {
    marks: std.AutoHashMapUnmanaged(u64, Mark) = .empty,

    pub fn deinit(c: *Changes, gpa: std.mem.Allocator) void {
        c.marks.deinit(gpa);
    }

    /// Mark of a 1-based line, if it has one.
    pub fn at(c: *const Changes, line: u64) ?Mark {
        return c.marks.get(line);
    }

    pub fn isEmpty(c: *const Changes) bool {
        return c.marks.count() == 0;
    }

    /// The marks for `new`, compared line by line with `old`.
    pub fn compute(gpa: std.mem.Allocator, old: []const u8, new: []const u8) !Changes {
        var c: Changes = .{};
        errdefer c.deinit(gpa);
        const a = try diffcore.splitLines(gpa, old);
        defer a.deinit(gpa);
        const b = try diffcore.splitLines(gpa, new);
        defer b.deinit(gpa);
        const edits = try diffcore.compare(gpa, a, b, .{});
        defer gpa.free(edits);
        for (edits) |e| {
            if (e.inserted == 0) {
                // Pure removal: `line1` is the number of the line before it.
                if (e.line1 == 0) {
                    try c.marks.put(gpa, 1, .removed_above);
                } else try c.marks.put(gpa, e.line1, .removed_below);
            } else {
                const mark: Mark = if (e.deleted == 0) .added else .modified;
                for (0..e.inserted) |n| try c.marks.put(gpa, e.line1 + n + 1, mark);
            }
        }
        return c;
    }
};

/// Neither side of a comparison may be larger than this; a huge file is not
/// worth the memory, and gets no marks.
const size_limit = 64 * 1024 * 1024;

/// The git program: the first one in an absolute PATH directory. A relative
/// or empty entry (and, on Windows, the implicit current directory) could
/// name a program that came with the files being viewed.
fn findGit(env: common.Env, buf: []u8) ?[]const u8 {
    const name = if (builtin.os.tag == .windows) "git.exe" else "git";
    var it = std.mem.tokenizeScalar(u8, env.getenv("PATH") orelse return null, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const full = std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, name }) catch continue;
        Io.Dir.cwd().access(env.io, full, .{ .execute = true }) catch continue;
        return full;
    }
    return null;
}

const Git = struct {
    env: common.Env,
    program: []const u8,
    dir: []const u8,
    environ: *const std.process.Environ.Map,

    /// Standard output of one plumbing command, owned by the caller, or null
    /// when it failed. Every call goes through here so that none can miss the
    /// settings that keep the repository from running a program.
    fn run(g: Git, args: []const []const u8) ?[]u8 {
        const gpa = g.env.gpa;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        // An empty core.fsmonitor turns it off in old and new git alike.
        argv.appendSlice(gpa, &.{ g.program, "-C", g.dir, "--no-pager", "-c", "core.fsmonitor=", "-c", "core.hooksPath=/dev/null" }) catch return null;
        argv.appendSlice(gpa, args) catch return null;
        var child = std.process.spawn(g.env.io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .environ_map = g.environ,
        }) catch return null;
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        var chunk: [16384]u8 = undefined;
        const out = child.stdout.?;
        var failed = false;
        while (true) {
            const n = out.readStreaming(g.env.io, &.{&chunk}) catch break;
            if (n == 0) break;
            // Keep draining so that the child can exit.
            if (failed or list.items.len + n > size_limit) {
                failed = true;
                continue;
            }
            list.appendSlice(gpa, chunk[0..n]) catch {
                failed = true;
            };
        }
        const term = child.wait(g.env.io) catch return null;
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok or failed) return null;
        return list.toOwnedSlice(gpa) catch null;
    }
};

/// What git's attributes say about the comparison.
const Attributes = struct {
    /// `filter` or `working-tree-encoding`: only git, running the programs
    /// the repository names, knows what the stored form would be.
    converted: bool = false,
    /// `ident` expands `$Id$` on checkout.
    ident: bool = false,
    /// null: not said; false: `-diff`, the file counts as binary.
    diff: ?bool = null,
    /// null: not said, core.autocrlf decides line endings.
    crlf: ?bool = null,

    /// Parse `git check-attr -z` output: path, name and value, each
    /// NUL-terminated.
    fn parse(out: []const u8) Attributes {
        var a: Attributes = .{};
        var eol = false;
        var it = std.mem.splitScalar(u8, out, 0);
        while (it.next()) |_| {
            const name = it.next() orelse break;
            const value = it.next() orelse break;
            if (std.mem.eql(u8, value, "unspecified")) continue;
            const off = std.mem.eql(u8, value, "unset");
            if (std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "working-tree-encoding")) {
                if (!off) a.converted = true;
            } else if (std.mem.eql(u8, name, "ident")) {
                a.ident = !off;
            } else if (std.mem.eql(u8, name, "diff")) {
                a.diff = !off;
            } else if (std.mem.eql(u8, name, "text")) {
                a.crlf = !off;
            } else if (std.mem.eql(u8, name, "eol")) {
                eol = !off;
            }
        }
        // `eol` implies `text`, unless `-text` says the file is binary.
        if (eol and a.crlf == null) a.crlf = true;
        return a;
    }
};

fn isBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data[0..@min(data.len, 8000)], 0) != null;
}

fn autoCrlf(git: Git) bool {
    const out = git.run(&.{ "config", "--get", "core.autocrlf" }) orelse return false;
    defer git.env.gpa.free(out);
    const value = std.mem.trim(u8, out, " \r\n");
    for ([_][]const u8{ "true", "input", "yes", "on", "1" }) |t| {
        if (std.ascii.eqlIgnoreCase(value, t)) return true;
    }
    return false;
}

/// The change marks of `path` (relative to the current directory), or null
/// when there is nothing to show. Runs `git` (see the top of this file for
/// what it may and may not run); never reports an error.
pub fn load(env: common.Env, path: []const u8) ?Changes {
    // The child's environment is a copy with additions, so a host that gives
    // none cannot get marks.
    const host_environ = env.environ orelse return null;
    // git compares a symbolic link's target string, not the text shown, and
    // anything else that is not a regular file must not be read twice.
    const st = Io.Dir.cwd().statFile(env.io, path, .{ .follow_symlinks = false }) catch return null;
    if (st.kind != .file or st.size > size_limit) return null;
    var program_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const program = findGit(env, &program_buf) orelse return null;
    return compareWithIndex(env, host_environ, program, path) catch null;
}

fn compareWithIndex(env: common.Env, host_environ: *const std.process.Environ.Map, program: []const u8, path: []const u8) !?Changes {
    const gpa = env.gpa;
    var environ = try host_environ.clone(gpa);
    defer environ.deinit();
    // A partial clone must not fetch a missing blob: the repository chooses
    // the transport program. The first setting is for git 2.45 and later (and
    // its security backports); the second forbids every transport in any git,
    // and overrides the repository's protocol.*.allow.
    try environ.put("GIT_NO_LAZY_FETCH", "1");
    try environ.put("GIT_ALLOW_PROTOCOL", ":");
    try environ.put("GIT_OPTIONAL_LOCKS", "0");
    const git: Git = .{ .env = env, .program = program, .dir = std.fs.path.dirname(path) orelse ".", .environ = &environ };

    const base = std.fs.path.basename(path);
    const object = try std.fmt.allocPrint(gpa, ":./{s}", .{base});
    defer gpa.free(object);
    const old = git.run(&.{ "cat-file", "blob", object }) orelse return null;
    defer gpa.free(old);
    var new: []u8 = try Io.Dir.cwd().readFileAlloc(env.io, path, gpa, .limited(size_limit));
    defer gpa.free(new);
    if (std.mem.eql(u8, old, new)) return null;

    const relative = try std.fmt.allocPrint(gpa, "./{s}", .{base});
    defer gpa.free(relative);
    const listed = git.run(&.{ "check-attr", "-z", "filter", "working-tree-encoding", "ident", "diff", "text", "eol", "--", relative }) orelse return null;
    defer gpa.free(listed);
    const attr = Attributes.parse(listed);
    if (attr.converted or attr.ident) return null;
    if (!(attr.diff orelse !(isBinary(old) or isBinary(new)))) return null;
    // A CRLF checkout of a file stored with LF is not a change.
    if (std.mem.indexOfScalar(u8, old, '\r') == null and std.mem.indexOf(u8, new, "\r\n") != null and
        (attr.crlf orelse autoCrlf(git)))
    {
        const stripped = try diffcore.stripCr(gpa, new);
        gpa.free(new);
        new = stripped;
    }

    var c = try Changes.compute(gpa, old, new);
    if (c.isEmpty()) {
        c.deinit(gpa);
        return null;
    }
    return c;
}

test "marks follow bat" {
    const gpa = std.testing.allocator;
    var c = try Changes.compute(gpa, "gone\na\nb\nc\nd\ne\nf\n", "a\nB\nc\nd\nnew\nmore\ne\n");
    defer c.deinit(gpa);
    try std.testing.expectEqual(Mark.removed_above, c.at(1).?);
    try std.testing.expectEqual(Mark.modified, c.at(2).?);
    try std.testing.expect(c.at(3) == null);
    try std.testing.expectEqual(Mark.added, c.at(5).?);
    try std.testing.expectEqual(Mark.added, c.at(6).?);
    try std.testing.expectEqual(Mark.removed_below, c.at(7).?);
}

test "git attributes" {
    const a = Attributes.parse("./f\x00filter\x00unspecified\x00./f\x00diff\x00unset\x00./f\x00eol\x00crlf\x00");
    try std.testing.expect(!a.converted);
    try std.testing.expectEqual(false, a.diff.?);
    try std.testing.expectEqual(true, a.crlf.?);
    try std.testing.expect(Attributes.parse("./f\x00filter\x00lfs\x00").converted);
    try std.testing.expectEqual(false, Attributes.parse("./f\x00text\x00unset\x00./f\x00eol\x00lf\x00").crlf.?);
}
