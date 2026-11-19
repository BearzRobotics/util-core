// SPDX-License-Identifier: GPL-2.0-or-later
//! Pieces shared by the findutils-family libraries (find, locate, updatedb):
//! the GNU `quote()` formatting, the --regextype names and their translation
//! onto the regex package, and the mount table (`/proc/self/mountinfo`).

const std = @import("std");
const Io = std.Io;
const regex = @import("regex");
const posixre = @import("../posixre.zig");
const sys = @import("../sys.zig");

/// A string as GNU `quote()` prints it in messages: single-quoted with C
/// escapes (\\ for a backslash, \' for a quote, \a \b \t \n \v \f \r, and
/// three-digit octal for other control and non-ASCII bytes). Use with `{f}`.
pub const QuotedC = struct {
    text: []const u8,

    pub fn format(q: QuotedC, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeByte('\'');
        for (q.text) |c| switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '\'' => try w.writeAll("\\'"),
            7 => try w.writeAll("\\a"),
            8 => try w.writeAll("\\b"),
            9 => try w.writeAll("\\t"),
            10 => try w.writeAll("\\n"),
            11 => try w.writeAll("\\v"),
            12 => try w.writeAll("\\f"),
            13 => try w.writeAll("\\r"),
            else => if (c < 0x20 or c >= 0x7f) try w.print("\\{o:0>3}", .{c}) else try w.writeByte(c),
        };
        try w.writeByte('\'');
    }
};

pub fn quoteC(text: []const u8) QuotedC {
    return .{ .text = text };
}

/// Does the locale in the environment name a UTF-8 charset?
pub fn localeIsUtf8(env: anytype) bool {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |k| {
        const v = env.getenv(k) orelse continue;
        if (v.len == 0) continue;
        return std.ascii.findIgnoreCase(v, "utf-8") != null or std.ascii.findIgnoreCase(v, "utf8") != null;
    }
    return false;
}

/// The regular-expression dialects of --regextype.
pub const RegexSyntax = enum {
    emacs,
    findutils_default,
    posix_basic,
    grep,
    posix_minimal_basic,
    posix_extended,
    posix_egrep,
    awk,
    gnu_awk,

    /// The dialect named by a --regextype argument (GNU's spellings).
    pub fn parse(name: []const u8) ?RegexSyntax {
        const eq = std.mem.eql;
        if (eq(u8, name, "posix-basic") or eq(u8, name, "ed") or eq(u8, name, "sed")) return .posix_basic;
        if (eq(u8, name, "grep")) return .grep;
        if (eq(u8, name, "posix-minimal-basic")) return .posix_minimal_basic;
        if (eq(u8, name, "posix-extended")) return .posix_extended;
        if (eq(u8, name, "posix-egrep") or eq(u8, name, "egrep")) return .posix_egrep;
        if (eq(u8, name, "awk")) return .awk;
        if (eq(u8, name, "gnu-awk")) return .gnu_awk;
        if (eq(u8, name, "posix-awk")) return .posix_extended;
        if (eq(u8, name, "emacs")) return .emacs;
        if (eq(u8, name, "findutils-default")) return .findutils_default;
        return null;
    }
};

pub const RegexFailure = struct {
    /// The POSIX diagnostic for the pattern (regerror-style wording).
    text: []const u8,
};

/// Compile `pat` in `syntax` onto the regex package. With `anchored` the
/// whole subject must match (find -regex); otherwise it is a search (locate).
/// On a bad pattern returns error.BadRegex and sets `failure`.
pub fn compileRegex(
    gpa: std.mem.Allocator,
    pat: []const u8,
    syntax: RegexSyntax,
    icase: bool,
    anchored: bool,
    failure: *RegexFailure,
) error{ OutOfMemory, BadRegex }!*regex.Regex {
    var conv: []const u8 = pat;
    var ere = false;
    var lenient = false;
    switch (syntax) {
        .posix_basic => ere = false,
        .grep => {
            ere = false;
            lenient = true;
        },
        .posix_minimal_basic => {
            ere = false;
            lenient = true;
            conv = posixre.minimalBasic(gpa, pat);
        },
        .posix_extended => ere = true,
        .posix_egrep => {
            ere = true;
            lenient = true;
        },
        .awk, .gnu_awk => {
            ere = true;
            conv = posixre.awkEre(gpa, pat, syntax == .awk);
        },
        .emacs, .findutils_default => {
            conv = posixre.emacsToEre(gpa, pat, syntax == .emacs);
            ere = true;
        },
    }
    const body = posixre.translateOpts(gpa, conv, ere, .{ .icase = icase, .lenient_brace = lenient }) catch {
        failure.text = posixre.diagnoseMode(conv, ere);
        return error.BadRegex;
    };
    const src = if (anchored) try std.fmt.allocPrint(gpa, "(?s)\\A(?:{s})\\z", .{body}) else try std.fmt.allocPrint(gpa, "(?s){s}", .{body});
    const re = try gpa.create(regex.Regex);
    re.* = regex.Regex.compile(gpa, src, .{ .dialect = .perl, .ignore_case = icase, .limits = posixre.big_limits }, null) catch {
        failure.text = posixre.diagnoseMode(conv, ere);
        return error.BadRegex;
    };
    return re;
}

pub const Mount = struct { dev: u64, fstype: []const u8 };

/// The mounted file systems by device number `(major << 32) | minor`.
pub const Mounts = struct {
    list: []Mount,

    /// Reads /proc/self/mountinfo; an unreadable file gives an empty table.
    /// Strings are allocated from `gpa` (use an arena).
    pub fn load(gpa: std.mem.Allocator) error{OutOfMemory}!Mounts {
        var list: std.ArrayList(Mount) = .empty;
        var err: std.os.linux.E = .SUCCESS;
        if (sys.openFd("/proc/self/mountinfo", sys.O.RDONLY, 0, &err)) |fd| {
            var data: std.ArrayList(u8) = .empty;
            var buf: [8192]u8 = undefined;
            while (true) {
                const k = sys.readFd(fd, &buf, &err) orelse break;
                if (k == 0) break;
                try data.appendSlice(gpa, buf[0..k]);
            }
            _ = sys.closeFd(fd);
            var lines = std.mem.splitScalar(u8, data.items, '\n');
            while (lines.next()) |ln| {
                var f = std.mem.tokenizeScalar(u8, ln, ' ');
                _ = f.next();
                _ = f.next();
                const mm = f.next() orelse continue;
                var seen_dash = false;
                var typ: []const u8 = "";
                while (f.next()) |tok| {
                    if (seen_dash) {
                        typ = tok;
                        break;
                    }
                    if (std.mem.eql(u8, tok, "-")) seen_dash = true;
                }
                const colon = std.mem.indexOfScalar(u8, mm, ':') orelse continue;
                const maj = std.fmt.parseInt(u32, mm[0..colon], 10) catch continue;
                const min = std.fmt.parseInt(u32, mm[colon + 1 ..], 10) catch continue;
                try list.append(gpa, .{ .dev = (@as(u64, maj) << 32) | min, .fstype = try gpa.dupe(u8, typ) });
            }
        }
        return .{ .list = list.items };
    }

    pub fn fsType(m: Mounts, dev: u64) []const u8 {
        for (m.list) |e| {
            if (e.dev == dev) return e.fstype;
        }
        return "unknown";
    }
};

test "quoteC escapes like GNU quote()" {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{quoteC("a b\n\x01'")});
    try std.testing.expectEqualStrings("'a b\\n\\001\\''", s);
}

test "RegexSyntax names" {
    try std.testing.expectEqual(RegexSyntax.posix_extended, RegexSyntax.parse("posix-awk").?);
    try std.testing.expectEqual(@as(?RegexSyntax, null), RegexSyntax.parse("perl"));
}
