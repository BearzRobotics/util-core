// SPDX-License-Identifier: GPL-2.0-or-later
//! Helpers for grep's ripgrep-derived extensions (decision 0006): gitignore-style
//! pattern matching (`--glob`, `--ignore-vcs`), the built-in file type table
//! (`--type`), and JSON string escaping (`--json`).

const std = @import("std");
const fnmatch = @import("../fnmatch.zig");

// ------------------------------------------------------------------ globs

/// One gitignore-style pattern. A pattern without a slash (other than a
/// trailing one) matches a file name at any depth; with a slash it is
/// anchored to the base directory. `**` spans directories.
pub const Pattern = struct {
    text: []const u8,
    negate: bool = false,
    dir_only: bool = false,
    anchored: bool = false,

    /// Parse one pattern line of a gitignore file or a `--glob` argument.
    /// Returns null for blank lines and comments when `comments` is set.
    pub fn parse(line_in: []const u8, comments: bool) ?Pattern {
        var line = line_in;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        // trailing spaces are ignored unless escaped
        while (line.len > 0 and line[line.len - 1] == ' ' and !(line.len > 1 and line[line.len - 2] == '\\')) line = line[0 .. line.len - 1];
        if (line.len == 0) return null;
        if (comments and line[0] == '#') return null;
        var p: Pattern = .{ .text = line };
        if (line[0] == '!') {
            p.negate = true;
            line = line[1..];
        } else if (comments and line[0] == '\\' and line.len > 1 and (line[1] == '!' or line[1] == '#')) {
            line = line[1..];
        }
        if (line.len > 1 and line[line.len - 1] == '/') {
            p.dir_only = true;
            line = line[0 .. line.len - 1];
        }
        if (std.mem.indexOfScalar(u8, line, '/') != null) {
            p.anchored = true;
            if (line[0] == '/') line = line[1..];
        }
        if (line.len == 0) return null;
        p.text = line;
        return p;
    }

    /// Does the pattern match `rel`, a '/'-separated path relative to the
    /// base directory?
    pub fn matches(p: Pattern, rel: []const u8, is_dir: bool) bool {
        if (p.dir_only and !is_dir) return false;
        if (!p.anchored) {
            const base = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |k| rel[k + 1 ..] else rel;
            return fnmatch.match(p.text, base, .{});
        }
        return matchPath(p.text, rel);
    }
};

fn nextSeg(s: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* > s.len) return null;
    const start = pos.*;
    const end = std.mem.indexOfScalarPos(u8, s, start, '/') orelse s.len;
    pos.* = end + 1;
    return s[start..end];
}

/// Match `pat` against `path`, both split at '/', with `**` matching any
/// number of path components. As in fnmatch.zig only the last `**` is ever
/// gone back to: what an earlier one could take in addition, the last one can
/// take too. So the time is at most the product of the two lengths, however
/// many `**` an ignore file of the searched tree holds.
pub fn matchPath(pat: []const u8, path: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    // The pattern after the last `**`, and where in the path it was last tried.
    var star: ?struct { pi: usize, ti: usize } = null;
    while (true) {
        var next_p = pi;
        if (nextSeg(pat, &next_p)) |seg| {
            if (std.mem.eql(u8, seg, "**")) {
                if (next_p > pat.len) return true; // trailing "/**" matches everything below
                pi = next_p;
                star = .{ .pi = next_p, .ti = ti };
                continue;
            }
            var next_t = ti;
            if (nextSeg(path, &next_t)) |tseg| {
                if (fnmatch.match(seg, tseg, .{})) {
                    pi = next_p;
                    ti = next_t;
                    continue;
                }
            }
        } else if (ti > path.len) return true;
        // Let the last `**` take one more component.
        const back = if (star) |*s| s else return false;
        if (nextSeg(path, &back.ti) == null) return false;
        pi = back.pi;
        ti = back.ti;
    }
}

/// An ordered list of patterns from one file or from the command line.
pub const PatternList = struct {
    items: []const Pattern,

    /// Result of looking `rel` up: null = no pattern matched.
    /// true = ignored (last matching pattern is not negated).
    pub fn verdict(l: PatternList, rel: []const u8, is_dir: bool) ?bool {
        var i = l.items.len;
        while (i > 0) {
            i -= 1;
            const p = l.items[i];
            if (p.matches(rel, is_dir)) return !p.negate;
        }
        return null;
    }
};

// ------------------------------------------------------------- file types

pub const FileType = struct { name: []const u8, globs: []const []const u8 };

/// Built-in file types. Names and globs are copied from ripgrep's table; only
/// the common types are present (`--type-list` prints exactly these).
pub const types = [_]FileType{
    .{ .name = "asm", .globs = &.{ "*.S", "*.asm", "*.s" } },
    .{ .name = "c", .globs = &.{ "*.[chH]", "*.[chH].in", "*.cats" } },
    .{ .name = "cmake", .globs = &.{ "*.cmake", "CMakeLists.txt" } },
    .{ .name = "cpp", .globs = &.{ "*.[ChH]", "*.[ChH].in", "*.[ch]pp", "*.[ch]pp.in", "*.[ch]xx", "*.[ch]xx.in", "*.cc", "*.cc.in", "*.hh", "*.hh.in", "*.inl" } },
    .{ .name = "cs", .globs = &.{"*.cs"} },
    .{ .name = "csharp", .globs = &.{"*.cs"} },
    .{ .name = "css", .globs = &.{ "*.css", "*.scss" } },
    .{ .name = "docker", .globs = &.{"*Dockerfile*"} },
    .{ .name = "go", .globs = &.{"*.go"} },
    .{ .name = "html", .globs = &.{ "*.ejs", "*.htm", "*.html" } },
    .{ .name = "java", .globs = &.{ "*.java", "*.jsp", "*.jspx", "*.properties" } },
    .{ .name = "js", .globs = &.{ "*.cjs", "*.js", "*.jsx", "*.mjs", "*.vue" } },
    .{ .name = "json", .globs = &.{ "*.json", "*.sarif", "composer.lock" } },
    .{ .name = "lisp", .globs = &.{ "*.el", "*.jl", "*.lisp", "*.lsp", "*.sc", "*.scm" } },
    .{ .name = "lua", .globs = &.{"*.lua"} },
    .{ .name = "make", .globs = &.{ "*.mak", "*.mk", "Makefile.*", "[Gg][Nn][Uu]makefile", "[Gg][Nn][Uu]makefile.am", "[Gg][Nn][Uu]makefile.in", "[Mm]akefile", "[Mm]akefile.am", "[Mm]akefile.in" } },
    .{ .name = "md", .globs = &.{ "*.markdown", "*.md", "*.mdown", "*.mdwn", "*.mdx", "*.mkd", "*.mkdn" } },
    .{ .name = "perl", .globs = &.{ "*.PL", "*.perl", "*.pl", "*.plh", "*.plx", "*.pm", "*.t" } },
    .{ .name = "php", .globs = &.{ "*.php", "*.php3", "*.php4", "*.php5", "*.php7", "*.php8", "*.pht", "*.phtml" } },
    .{ .name = "py", .globs = &.{ "*.py", "*.pyi" } },
    .{ .name = "ruby", .globs = &.{ "*.gemspec", "*.rake", "*.rb", "*.rbw", ".irbrc", "Gemfile", "Rakefile", "config.ru" } },
    .{ .name = "rust", .globs = &.{"*.rs"} },
    .{ .name = "sh", .globs = &.{ "*.bash", "*.bashrc", "*.csh", "*.cshrc", "*.env", "*.ksh", "*.kshrc", "*.sh", "*.tcsh", "*.zsh", ".bash_login", ".bash_logout", ".bash_profile", ".bashrc", ".cshrc", ".env", ".kshrc", ".login", ".logout", ".profile", ".tcshrc", ".zlogin", ".zlogout", ".zprofile", ".zshenv", ".zshrc", "bash_login", "bash_logout", "bash_profile", "bashrc", "profile", "zlogin", "zlogout", "zprofile", "zshenv", "zshrc" } },
    .{ .name = "sql", .globs = &.{ "*.psql", "*.sql" } },
    .{ .name = "swift", .globs = &.{"*.swift"} },
    .{ .name = "toml", .globs = &.{ "*.toml", "Cargo.lock" } },
    .{ .name = "ts", .globs = &.{ "*.cts", "*.mts", "*.ts", "*.tsx" } },
    .{ .name = "txt", .globs = &.{"*.txt"} },
    .{ .name = "xml", .globs = &.{ "*.dtd", "*.rng", "*.sch", "*.xhtml", "*.xjb", "*.xml", "*.xml.dist", "*.xsd", "*.xsl", "*.xslt" } },
    .{ .name = "yaml", .globs = &.{ "*.yaml", "*.yml" } },
    .{ .name = "zig", .globs = &.{"*.zig"} },
};

pub fn findType(name: []const u8) ?FileType {
    for (types) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

pub fn nameHasGlob(name: []const u8, globs: []const []const u8) bool {
    for (globs) |g| if (fnmatch.match(g, name, .{})) return true;
    return false;
}

// ------------------------------------------------------------------- JSON

/// Write `s` as a JSON string body the way serde_json does: escapes for the
/// quote, the backslash and control characters; everything else raw.
pub fn jsonEscape(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        8 => try w.writeAll("\\b"),
        12 => try w.writeAll("\\f"),
        0...7, 11, 14...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
}

/// `{"text":"..."}` for valid UTF-8, else `{"bytes":"<base64>"}`.
pub fn jsonData(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(s)) {
        try w.writeAll("{\"text\":\"");
        try jsonEscape(w, s);
        try w.writeAll("\"}");
    } else {
        try w.writeAll("{\"bytes\":\"");
        try std.base64.standard.Encoder.encodeWriter(w, s);
        try w.writeAll("\"}");
    }
}

test "gitignore patterns" {
    const a = Pattern.parse("*.o", true).?;
    try std.testing.expect(a.matches("src/x.o", false));
    const b = Pattern.parse("build/", true).?;
    try std.testing.expect(b.matches("build", true));
    try std.testing.expect(!b.matches("build", false));
    const c = Pattern.parse("/src/*.c", true).?;
    try std.testing.expect(c.matches("src/a.c", false));
    try std.testing.expect(!c.matches("x/src/a.c", false));
    const d = Pattern.parse("a/**/b", true).?;
    try std.testing.expect(d.matches("a/b", false));
    try std.testing.expect(d.matches("a/x/y/b", false));
}

test "gitignore patterns with several double stars" {
    const t = std.testing;
    try t.expect(matchPath("**/a/**/b", "a/b"));
    try t.expect(matchPath("**/a/**/b", "x/a/y/a/z/b"));
    try t.expect(matchPath("a/**/**/b", "a/b"));
    try t.expect(matchPath("**/x/y", "x/x/y"));
    try t.expect(matchPath("a/**", "a/b/c"));
    try t.expect(matchPath("**/b/**", "a/b/c"));
    try t.expect(!matchPath("**/a/**/b", "b/a"));
    try t.expect(!matchPath("**/x/y", "x/y/z"));
    try t.expect(!matchPath("a/b", "a"));
    try t.expect(!matchPath("a", "a/b"));
    // Trying every position for every "**" would never end here.
    const deep = comptime repeated("x/", 200) ++ "f";
    try t.expect(!matchPath(comptime repeated("**/x/", 20) ++ "nomatch", deep));
    try t.expect(matchPath(comptime repeated("**/x/", 20) ++ "f", deep));
}

fn repeated(comptime text: []const u8, comptime times: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..times) |_| out = out ++ text;
    return out;
}
