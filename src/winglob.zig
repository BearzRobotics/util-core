// SPDX-License-Identifier: GPL-2.0-or-later
//! Wildcards in the arguments of a program started by cmd.exe.
//!
//! A Unix shell turns `*.txt` into the matching names before the program runs.
//! cmd.exe passes it on, and each Windows program does the work itself, so the
//! entry points call `argv` here. It follows the Unix shell: `*` and `?` count
//! only outside quotes, a name starting with "." needs a pattern starting with
//! ".", a pattern that matches nothing stays as it is, and the matches are
//! sorted. As Windows file names, they match whatever their case (ASCII only).
//! "[" is an ordinary character.
//!
//! Only cmd.exe is answered this way, because only its command line still shows
//! what was quoted, and because arguments that another program passes (xargs,
//! find -exec, env) are never patterns.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// The arguments to give the command: `args`, with the wildcard patterns among
/// them replaced when cmd.exe started this program. `cmd_line` is the command
/// line `args` were parsed from. Elsewhere than on Windows, and when anything
/// goes wrong, `args` unchanged. Allocates in `arena`.
pub fn argv(io: Io, arena: std.mem.Allocator, cmd_line: if (builtin.os.tag == .windows) []const u16 else void, args: []const [:0]const u8) []const [:0]const u8 {
    if (builtin.os.tag != .windows) return args;
    const line = std.unicode.wtf16LeToWtf8Alloc(arena, cmd_line) catch return args;
    if (std.mem.indexOfAny(u8, line, "*?") == null) return args;
    if (!@import("sys/windows.zig").startedByCmd()) return args;
    return expandLine(arena, line, args, Directory{ .io = io }) catch args;
}

/// One argument as the command line wrote it.
const Token = struct {
    text: []const u8,
    /// For each byte of `text`: it was inside quotes, or is otherwise not to
    /// be read as a wildcard.
    quoted: []const bool,

    fn hasWildcard(t: Token, from: usize, to: usize) bool {
        for (t.text[from..to], t.quoted[from..to]) |c, q| {
            if (!q and (c == '*' or c == '?')) return true;
        }
        return false;
    }
};

/// Split a command line by the rules of the C runtime, as
/// std.process.Args.Iterator.Windows does, keeping what was quoted.
fn tokenize(arena: std.mem.Allocator, line: []const u8) error{OutOfMemory}![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var quoted: std.ArrayList(bool) = .empty;
    var i: usize = 0;

    if (line.len == 0) return &.{};
    // The program name knows no backslash rules.
    var inside = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '"') {
            inside = !inside;
        } else if ((c == ' ' or c == '\t') and !inside) {
            i += 1;
            break;
        } else {
            try text.append(arena, c);
            try quoted.append(arena, true);
        }
    }
    try tokens.append(arena, .{ .text = try text.toOwnedSlice(arena), .quoted = try quoted.toOwnedSlice(arena) });

    while (true) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        inside = false;
        var backslashes: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (c == '\\') {
                backslashes += 1;
                continue;
            }
            const escaped = c == '"' and backslashes % 2 != 0;
            const keep = if (c == '"') backslashes / 2 else backslashes;
            for (0..keep) |_| {
                try text.append(arena, '\\');
                try quoted.append(arena, inside);
            }
            backslashes = 0;
            if (c == '"' and !escaped) {
                if (inside and i + 1 < line.len and line[i + 1] == '"') {
                    try text.append(arena, '"');
                    try quoted.append(arena, true);
                    i += 1;
                } else inside = !inside;
                continue;
            }
            if ((c == ' ' or c == '\t') and !inside) break;
            try text.append(arena, c);
            try quoted.append(arena, inside);
        }
        for (0..backslashes) |_| {
            try text.append(arena, '\\');
            try quoted.append(arena, inside);
        }
        try tokens.append(arena, .{ .text = try text.toOwnedSlice(arena), .quoted = try quoted.toOwnedSlice(arena) });
    }
    return tokens.items;
}

fn expandLine(arena: std.mem.Allocator, line: []const u8, args: []const [:0]const u8, files: anytype) ![]const [:0]const u8 {
    const tokens = try tokenize(arena, line);
    // Not the line these arguments came from: leave them alone.
    if (tokens.len != args.len) return args;
    var out: std.ArrayList([:0]const u8) = .empty;
    var changed = false;
    for (args, tokens, 0..) |arg, token, n| {
        if (n > 0 and std.mem.eql(u8, arg, token.text) and token.hasWildcard(0, token.text.len)) {
            const found = try matches(arena, token, files);
            if (found.len > 0) {
                try out.appendSlice(arena, found);
                changed = true;
                continue;
            }
        }
        try out.append(arena, arg);
    }
    return if (changed) out.items else args;
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

/// The length of the part of a path that names no directory entry and may hold
/// a "?" of its own: `C:`, `\\server\share\`, `\\?\C:\`.
fn rootLength(path: []const u8) usize {
    if (path.len >= 2 and isSeparator(path[0]) and isSeparator(path[1])) {
        var i: usize = 2;
        var parts: usize = 0;
        // Server and share, or "?" (or ".") and the drive.
        while (i < path.len and parts < 2) : (i += 1) {
            if (isSeparator(path[i])) parts += 1;
        }
        return i;
    }
    if (path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0])) return 2;
    return 0;
}

/// The names `token` matches, sorted; none when it matches nothing.
/// `files.list(arena, dir)` gives the entries of a directory ("" is the current
/// one) and `files.kind(path)` what a path names, or null.
fn matches(arena: std.mem.Allocator, token: Token, files: anytype) error{OutOfMemory}![]const [:0]const u8 {
    const path = token.text;
    var paths: std.ArrayList([]const u8) = .empty;
    const root = rootLength(path);
    try paths.append(arena, path[0..root]);
    var start = root;
    var listed = false;
    while (start < path.len) {
        var end = start;
        while (end < path.len and !isSeparator(path[end])) end += 1;
        var next = end;
        while (next < path.len and isSeparator(path[next])) next += 1;
        const separators = path[end..next];
        var found: std.ArrayList([]const u8) = .empty;
        if (!token.hasWildcard(start, end)) {
            for (paths.items) |before| {
                const full = try std.mem.concat(arena, u8, &.{ before, path[start..next] });
                // A fixed name after a pattern has to be there.
                if (listed) {
                    const kind = files.kind(full) orelse continue;
                    if (separators.len > 0 and kind != .directory) continue;
                }
                try found.append(arena, full);
            }
        } else {
            listed = true;
            for (paths.items) |before| {
                for (try files.list(arena, before)) |name| {
                    if (!matchName(path[start..end], token.quoted[start..end], name)) continue;
                    const full = try std.mem.concat(arena, u8, &.{ before, name, separators });
                    // "dir*\" asks for directories.
                    if (separators.len > 0 and files.kind(full) != .directory) continue;
                    try found.append(arena, full);
                }
            }
        }
        paths = found;
        start = next;
    }
    if (!listed) return &.{};
    const out = try arena.alloc([:0]const u8, paths.items.len);
    for (paths.items, out) |from, *to| to.* = try arena.dupeSentinel(u8, from, 0);
    std.mem.sort([:0]const u8, out, {}, struct {
        fn before(_: void, a: [:0]const u8, b: [:0]const u8) bool {
            // "\\" sorts as "/" does: "dir\\" before "dir2\\".
            for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
                const c: u8 = if (x == '\\') '/' else x;
                const d: u8 = if (y == '\\') '/' else y;
                if (c != d) return c < d;
            }
            return a.len < b.len;
        }
    }.before);
    return out;
}

/// The bytes of the character at the start of `s`.
fn charLength(s: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 1;
    return @min(n, s.len);
}

fn matchName(pattern: []const u8, quoted: []const bool, name: []const u8) bool {
    if (name.len > 0 and name[0] == '.' and (pattern.len == 0 or pattern[0] != '.')) return false;
    var p: usize = 0;
    var n: usize = 0;
    // Where to go back to: after the last "*", one character further.
    var star: ?usize = null;
    var resume_at: usize = 0;
    while (n < name.len) {
        if (p < pattern.len) {
            if (!quoted[p] and pattern[p] == '*') {
                p += 1;
                star = p;
                resume_at = n;
                continue;
            }
            if (!quoted[p] and pattern[p] == '?') {
                p += 1;
                n += charLength(name[n..]);
                continue;
            }
            if (std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n])) {
                p += 1;
                n += 1;
                continue;
            }
        }
        const back = star orelse return false;
        p = back;
        resume_at += charLength(name[resume_at..]);
        n = resume_at;
    }
    while (p < pattern.len and !quoted[p] and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const Directory = struct {
    io: Io,

    /// A directory that cannot be read matches nothing.
    pub fn list(self: Directory, arena: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var dir = Io.Dir.cwd().openDir(self.io, if (path.len == 0) "." else path, .{ .iterate = true }) catch return &.{};
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| try names.append(arena, try arena.dupe(u8, entry.name));
        return names.items;
    }

    pub fn kind(self: Directory, path: []const u8) ?Io.File.Kind {
        const st = Io.Dir.cwd().statFile(self.io, path, .{}) catch return null;
        return st.kind;
    }
};

const testing = std.testing;

test "command lines split as std splits them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const check = struct {
        fn one(gpa: std.mem.Allocator, line: []const u8) !void {
            const wide = try std.unicode.wtf8ToWtf16LeAlloc(gpa, line);
            var it = try std.process.Args.Iterator.Windows.init(gpa, wide);
            const tokens = try tokenize(gpa, line);
            var n: usize = 0;
            while (it.next()) |want| : (n += 1) {
                try testing.expect(n < tokens.len);
                try testing.expectEqualStrings(want, tokens[n].text);
                try testing.expectEqual(tokens[n].text.len, tokens[n].quoted.len);
            }
            try testing.expectEqual(n, tokens.len);
        }
    }.one;
    for ([_][]const u8{ "", "a", "\"C:\\a b\\x.exe\" y", "x \"\"", "x a\\\\\\\"b", "x \"a\"\"b\" c", "x a\\", "x \"unterminated *", "x  \t y " }) |line| try check(a, line);
    // Every short line over the characters that matter.
    const alphabet = "a *\"\\\t";
    var prng = std.Random.DefaultPrng.init(1);
    var buf: [12]u8 = undefined;
    for (0..20000) |_| {
        const len = prng.random().uintLessThan(usize, buf.len);
        for (buf[0..len]) |*c| c.* = alphabet[prng.random().uintLessThan(usize, alphabet.len)];
        try check(a, try std.mem.concat(a, u8, &.{ "p ", buf[0..len] }));
        _ = arena.reset(.retain_capacity);
    }
}

test "wildcards expand as a Unix shell expands them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fake = struct {
        const all = [_][]const u8{ "b.txt", "A.TXT", ".hidden.txt", "note.md", "dir/", "dir/in.txt", "dir2/", "é.c", "[x].c" };

        pub fn list(_: @This(), gpa: std.mem.Allocator, path: []const u8) error{OutOfMemory}![]const []const u8 {
            var names: std.ArrayList([]const u8) = .empty;
            for (all) |entry| {
                const name = std.mem.trimEnd(u8, entry, "/");
                const slash = std.mem.lastIndexOfScalar(u8, name, '/');
                const parent = if (slash) |s| name[0 .. s + 1] else "";
                if (!sameDir(parent, path)) continue;
                try names.append(gpa, name[parent.len..]);
            }
            return names.items;
        }

        fn sameDir(x: []const u8, y: []const u8) bool {
            if (x.len != y.len) return false;
            for (x, y) |c, d| if (c != d and !(isSeparator(c) and isSeparator(d))) return false;
            return true;
        }

        pub fn kind(_: @This(), path: []const u8) ?Io.File.Kind {
            for (all) |entry| {
                const name = std.mem.trimEnd(u8, entry, "/");
                if (sameDir(name, std.mem.trimEnd(u8, path, "/\\"))) return if (name.len < entry.len) .directory else .file;
            }
            return null;
        }
    };
    const expect = struct {
        fn run(gpa: std.mem.Allocator, written: []const u8, want: []const []const u8) !void {
            const line = try std.mem.concat(gpa, u8, &.{ "p ", written });
            const wide = try std.unicode.wtf8ToWtf16LeAlloc(gpa, line);
            var it = try std.process.Args.Iterator.Windows.init(gpa, wide);
            var args: std.ArrayList([:0]const u8) = .empty;
            while (it.next()) |arg| try args.append(gpa, try gpa.dupeSentinel(u8, arg, 0));
            const got = try expandLine(gpa, line, args.items, Fake{});
            try testing.expectEqual(want.len + 1, got.len);
            for (want, got[1..]) |w, g| try testing.expectEqualStrings(w, g);
        }
    }.run;
    try expect(a, "*.txt", &.{ "A.TXT", "b.txt" });
    try expect(a, ".*.txt", &.{".hidden.txt"});
    try expect(a, "\"*.txt\"", &.{"*.txt"});
    try expect(a, "-name=\"*\".txt", &.{"-name=*.txt"});
    try expect(a, "\"*\"*.md", &.{"**.md"});
    try expect(a, "*.zip x", &.{ "*.zip", "x" });
    try expect(a, "?.c", &.{"é.c"});
    try expect(a, "[x].?", &.{"[x].c"});
    try expect(a, "[b]*", &.{"[b]*"});
    try expect(a, "d*", &.{ "dir", "dir2" });
    try expect(a, "d*\\", &.{ "dir\\", "dir2\\" });
    try expect(a, "n*\\", &.{"n*\\"});
    try expect(a, "dir\\*.txt", &.{"dir\\in.txt"});
    try expect(a, "d*/in.txt", &.{"dir/in.txt"});
    try expect(a, "d*/*", &.{"dir/in.txt"});
    try expect(a, "\\\\?\\C:\\x", &.{"\\\\?\\C:\\x"});
    try testing.expectEqual(2, rootLength("C:*.txt"));
    try testing.expectEqual(7, rootLength("\\\\?\\C:\\*"));
    try testing.expectEqual(0, rootLength("\\*"));
}
