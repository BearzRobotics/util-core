//! dircolors — output commands to set the LS_COLORS environment variable.
//!
//! References, consulted 2026-11-04 (see docs/compatibility/dircolors.md):
//!   * GNU coreutils manual, "dircolors invocation" (documents 9.12);
//!   * GNU coreutils src/dircolors.c and src/dircolors.hin, master branch.
//! The source was read for behaviour only; this implementation and the
//! comments in dircolors.db are our own.
//!
//! Database format: lines of "KEYWORD VALUE"; '#' ends the value; TERM and
//! COLORTERM lines switch the entries after them on or off depending on
//! whether $TERM / $COLORTERM matches a glob pattern.

const std = @import("std");
const cli = @import("../cli.zig");

/// Built-in database, used when no FILE is given and printed by -p. It is
/// parsed at run time by the same code as user files.
pub const default_database = @embedFile("dircolors.db");

pub const Entry = struct {
    /// '*' for ".ext" keywords (so ".gz" is shown as "*.gz"), else 0.
    prefix: u8,
    /// Two-letter code ("di"), the extension (".gz"), or a pattern ("*~").
    key: []const u8,
    value: []const u8,
};

const Keyword = struct { name: []const u8, code: []const u8 };

/// Keywords, matched case-insensitively.
const keywords = [_]Keyword{
    .{ .name = "NORMAL", .code = "no" },
    .{ .name = "NORM", .code = "no" },
    .{ .name = "FILE", .code = "fi" },
    .{ .name = "RESET", .code = "rs" },
    .{ .name = "DIR", .code = "di" },
    .{ .name = "LNK", .code = "ln" },
    .{ .name = "LINK", .code = "ln" },
    .{ .name = "SYMLINK", .code = "ln" },
    .{ .name = "ORPHAN", .code = "or" },
    .{ .name = "MISSING", .code = "mi" },
    .{ .name = "FIFO", .code = "pi" },
    .{ .name = "PIPE", .code = "pi" },
    .{ .name = "SOCK", .code = "so" },
    .{ .name = "BLK", .code = "bd" },
    .{ .name = "BLOCK", .code = "bd" },
    .{ .name = "CHR", .code = "cd" },
    .{ .name = "CHAR", .code = "cd" },
    .{ .name = "DOOR", .code = "do" },
    .{ .name = "EXEC", .code = "ex" },
    .{ .name = "LEFT", .code = "lc" },
    .{ .name = "LEFTCODE", .code = "lc" },
    .{ .name = "RIGHT", .code = "rc" },
    .{ .name = "RIGHTCODE", .code = "rc" },
    .{ .name = "END", .code = "ec" },
    .{ .name = "ENDCODE", .code = "ec" },
    .{ .name = "SUID", .code = "su" },
    .{ .name = "SETUID", .code = "su" },
    .{ .name = "SGID", .code = "sg" },
    .{ .name = "SETGID", .code = "sg" },
    .{ .name = "STICKY", .code = "st" },
    .{ .name = "CAPABILITY", .code = "ca" },
    .{ .name = "MULTIHARDLINK", .code = "mh" },
    .{ .name = "CLRTOEOL", .code = "cl" },
    .{ .name = "OTHER_WRITABLE", .code = "ow" },
    .{ .name = "STICKY_OTHER_WRITABLE", .code = "tw" },
};

/// Accepted and ignored.
const ignored_keywords = [_][]const u8{ "OPTIONS", "COLOR", "EIGHTBIT" };

/// Shell-style glob match (fnmatch with no flags): `*`, `?`, `[...]` with
/// ranges and `!`/`^` negation, and backslash quoting.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star_p = p;
                    star_t = t;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    t += 1;
                    continue;
                },
                '[' => if (classEnd(pattern, p) != null) {
                    if (matchClass(pattern, p, text[t])) |next| {
                        p = next;
                        t += 1;
                        continue;
                    }
                } else if (text[t] == '[') {
                    // An unterminated class is an ordinary '['.
                    p += 1;
                    t += 1;
                    continue;
                },
                '\\' => if (p + 1 < pattern.len and pattern[p + 1] == text[t]) {
                    p += 2;
                    t += 1;
                    continue;
                },
                else => |c| if (c == text[t]) {
                    p += 1;
                    t += 1;
                    continue;
                },
            }
        }
        // Mismatch: retry after the last '*', consuming one more byte.
        const sp = star_p orelse return false;
        p = sp + 1;
        star_t += 1;
        t = star_t;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Index just past the closing ']' of the class starting at pattern[start],
/// or null when the class is not terminated.
fn classEnd(pattern: []const u8, start: usize) ?usize {
    var i = start + 1;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1; // a leading ']' is literal
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            i += 1;
        } else if (pattern[i] == ']') return i + 1;
    }
    return null;
}

/// If pattern[start..] is a bracket class containing `c`, return the index
/// after it; otherwise null.
fn matchClass(pattern: []const u8, start: usize, c: u8) ?usize {
    const end = classEnd(pattern, start) orelse return null;
    var i = start + 1;
    var negate = false;
    if (pattern[i] == '!' or pattern[i] == '^') {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < end - 1) {
        var lo = pattern[i];
        if (lo == '\\' and i + 1 < end - 1) {
            i += 1;
            lo = pattern[i];
        } else if (lo == ']' and !first) break;
        first = false;
        i += 1;
        if (i + 1 < end - 1 and pattern[i] == '-') {
            var hi = pattern[i + 1];
            i += 2;
            if (hi == '\\' and i < end - 1) {
                hi = pattern[i];
                i += 1;
            }
            if (lo <= c and c <= hi) matched = true;
        } else if (lo == c) matched = true;
    }
    return if (matched != negate) end else null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

pub const Problem = struct {
    pub const Kind = enum { missing_second_token, unrecognized_keyword };
    kind: Kind,
    line: usize,
    /// The keyword for unrecognized_keyword. Borrows from the parsed text.
    keyword: []const u8,
};

/// Parse a database. `term` is $TERM (or "none" when unset or empty) and
/// `colorterm` is $COLORTERM (or "" when unset). Entries are appended in file
/// order and borrow from `text`; problems are appended in file order and
/// parsing continues past them, as the output is withheld if there are any.
pub fn parseDatabase(
    gpa: std.mem.Allocator,
    text: []const u8,
    term: []const u8,
    colorterm: []const u8,
    entries: *std.ArrayList(Entry),
    problems: *std.ArrayList(Problem),
) std.mem.Allocator.Error!void {
    // global: no TERM line seen. no: the last TERM line did not match.
    // sure: the last TERM line matched and no entry has followed it yet.
    // yes: entries have followed a matching TERM line (a later TERM line
    // can still cancel them).
    const State = enum { no, yes, sure, global };
    var state: State = .global;

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        var p: usize = 0;
        while (p < raw.len and isSpace(raw[p])) p += 1;
        if (p == raw.len or raw[p] == '#') continue;

        const kw_start = p;
        while (p < raw.len and !isSpace(raw[p])) p += 1;
        const keyword = raw[kw_start..p];

        // The argument starts after the white space and runs to a '#' or the
        // end of the line, minus trailing white space.
        var arg: ?[]const u8 = null;
        if (p < raw.len) {
            while (p < raw.len and isSpace(raw[p])) p += 1;
            if (p < raw.len and raw[p] != '#') {
                const start = p;
                while (p < raw.len and raw[p] != '#') p += 1;
                var end = p;
                while (end > start and isSpace(raw[end - 1])) end -= 1;
                arg = raw[start..end];
            }
        }
        const value = arg orelse {
            try problems.append(gpa, .{ .kind = .missing_second_token, .line = line_no, .keyword = keyword });
            continue;
        };

        var unrecognized = false;
        if (std.ascii.eqlIgnoreCase(keyword, "TERM")) {
            if (state != .sure) state = if (globMatch(value, term)) .sure else .no;
        } else if (std.ascii.eqlIgnoreCase(keyword, "COLORTERM")) {
            if (state != .sure) state = if (globMatch(value, colorterm)) .sure else .no;
        } else {
            if (state == .sure) state = .yes; // another TERM line can cancel
            if (state != .no) {
                if (keyword[0] == '.') {
                    try entries.append(gpa, .{ .prefix = '*', .key = keyword, .value = value });
                } else if (keyword[0] == '*') {
                    try entries.append(gpa, .{ .prefix = 0, .key = keyword, .value = value });
                } else if (isIgnored(keyword)) {
                    // accepted and ignored
                } else if (codeFor(keyword)) |code| {
                    try entries.append(gpa, .{ .prefix = 0, .key = code, .value = value });
                } else unrecognized = true;
            } else unrecognized = true;
        }

        // Unknown keywords are reported only inside a TERM / COLORTERM block
        // that applies; elsewhere they are silently skipped.
        if (unrecognized and (state == .sure or state == .yes)) {
            try problems.append(gpa, .{ .kind = .unrecognized_keyword, .line = line_no, .keyword = keyword });
        }
    }
}

fn isIgnored(keyword: []const u8) bool {
    for (ignored_keywords) |k| if (std.ascii.eqlIgnoreCase(keyword, k)) return true;
    return false;
}

fn codeFor(keyword: []const u8) ?[]const u8 {
    for (keywords) |k| if (std.ascii.eqlIgnoreCase(keyword, k.name)) return k.code;
    return null;
}

const Shell = enum { unknown, bourne, c };

/// How a string is written for the shell. `raw` (used by --print-ls-colors)
/// writes it unchanged.
const Quoting = enum { raw, bourne, c };

/// Write `s` inside a single-quoted shell string. A ':' or '=' is preceded by
/// a backslash unless an odd run of backslashes or a '^' already protects it
/// (LS_COLORS has its own escape syntax); `'` becomes `'\''`; in C shell `!`
/// gets a backslash so history substitution does not fire.
fn writeQuoted(out: *cli.Out, s: []const u8, quoting: Quoting) void {
    if (quoting == .raw) return out.write(s);
    var need_backslash = true;
    for (s) |c| {
        switch (c) {
            '\'' => {
                out.write("'\\'");
                need_backslash = true;
            },
            '\\', '^' => need_backslash = !need_backslash,
            '!' => {
                if (quoting == .c) out.writeByte('\\');
                need_backslash = true;
            },
            ':', '=' => {
                if (need_backslash) out.writeByte('\\');
                need_backslash = true;
            },
            else => need_backslash = true,
        }
        out.writeByte(c);
    }
}

fn writeEntry(out: *cli.Out, e: Entry, quoting: Quoting, display: bool) void {
    if (display) {
        out.write("\x1b[");
        out.write(e.value);
        out.writeByte('m');
    }
    if (e.prefix != 0) out.writeByte(e.prefix);
    writeQuoted(out, e.key, quoting);
    out.writeByte(if (display) '\t' else '=');
    writeQuoted(out, e.value, quoting);
    if (display) out.write("\x1b[0m");
    out.writeByte(if (display) '\n' else ':');
}

/// Name as it appears in a diagnostic: quoted with single quotes only when it
/// contains characters a shell would interpret.
fn writeName(w: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8) !void {
    const plain = name.len > 0 and for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_-./+,:=@%", c) != null)) break false;
    } else true;
    if (plain) return w.appendSlice(gpa, name);
    try w.append(gpa, '\'');
    for (name) |c| {
        if (c == '\'') try w.appendSlice(gpa, "'\\''") else try w.append(gpa, c);
    }
    try w.append(gpa, '\'');
}

const Options = struct {
    shell: Shell = .unknown,
    print_database: bool = false,
    print_ls_colors: bool = false,
};

const long_options = [_]struct { name: []const u8, id: u8 }{
    .{ .name = "sh", .id = 'b' },
    .{ .name = "bourne-shell", .id = 'b' },
    .{ .name = "csh", .id = 'c' },
    .{ .name = "c-shell", .id = 'c' },
    .{ .name = "print-database", .id = 'p' },
    .{ .name = "print-ls-colors", .id = 'L' },
    .{ .name = "help", .id = 'h' },
    .{ .name = "version", .id = 'V' },
};

pub fn main(ctx: cli.Context) u8 {
    var opts: Options = .{};
    var operands: [2]?[]const u8 = .{ null, null };
    var n_operands: usize = 0;
    var only_operands = false;

    for (ctx.args) |a| {
        if (only_operands or a.len < 2 or a[0] != '-') {
            if (n_operands < 2) operands[n_operands] = a;
            n_operands += 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (std.mem.startsWith(u8, a, "--")) {
            const id = longOption(a[2..]) orelse return badOption(ctx, a);
            switch (id) {
                'h' => return help(ctx),
                'V' => return if (cli.printVersion(ctx)) 0 else 1,
                else => applyOption(&opts, id),
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'b', 'c', 'p' => applyOption(&opts, c),
            else => return badOption(ctx, a),
        };
    }

    // These checks and their order follow GNU.
    if ((opts.print_database or opts.print_ls_colors) and opts.shell != .unknown)
        return usageError(ctx, "the options to output non shell syntax,\nand to select a shell syntax are mutually exclusive");
    if (opts.print_database and opts.print_ls_colors)
        return usageError(ctx, "options --print-database and --print-ls-colors are mutually exclusive");
    const allowed: usize = if (opts.print_database) 0 else 1;
    if (n_operands > allowed) {
        const extra = operands[allowed].?;
        if (opts.print_database) {
            cli.warn(ctx, "extra operand '{s}'\nfile operands cannot be combined with --print-database (-p)\nTry '{s} --help' for more information.", .{ extra, ctx.name });
        } else {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ extra, ctx.name });
        }
        return 1;
    }

    if (opts.print_database) {
        return if (cli.writeStdout(ctx.io, default_database)) 0 else 1;
    }

    if (opts.shell == .unknown and !opts.print_ls_colors) {
        opts.shell = guessShell(ctx);
        if (opts.shell == .unknown) {
            cli.warn(ctx, "no SHELL environment variable, and no shell type option given", .{});
            return 1;
        }
    }

    // Read the database.
    const file = operands[0];
    var owned: ?[]u8 = null;
    defer if (owned) |o| ctx.gpa.free(o);
    const text: []const u8 = if (file) |path| blk: {
        const data = readAll(ctx, path) catch |e| {
            var name: std.ArrayList(u8) = .empty;
            defer name.deinit(ctx.gpa);
            writeName(&name, ctx.gpa, path) catch {};
            cli.warn(ctx, "{s}: {s}", .{ name.items, cli.errText(e) });
            return 1;
        };
        owned = data;
        break :blk data;
    } else default_database;

    const term_env = cli.getenv(ctx, "TERM");
    const term: []const u8 = if (term_env == null or term_env.?.len == 0) "none" else term_env.?;
    const colorterm = cli.getenv(ctx, "COLORTERM") orelse "";

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(ctx.gpa);
    var problems: std.ArrayList(Problem) = .empty;
    defer problems.deinit(ctx.gpa);
    parseDatabase(ctx.gpa, text, term, colorterm, &entries, &problems) catch return fail(ctx, "out of memory");

    if (problems.items.len > 0) {
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(ctx.gpa);
        if (file) |path| writeName(&name, ctx.gpa, path) catch {} else name.appendSlice(ctx.gpa, "<internal>") catch {};
        for (problems.items) |pr| switch (pr.kind) {
            .missing_second_token => cli.warn(ctx, "{s}:{d}: invalid line;  missing second token", .{ name.items, pr.line }),
            .unrecognized_keyword => cli.warn(ctx, "{s}:{d}: unrecognized keyword '{s}'", .{ name.items, pr.line, pr.keyword }),
        };
        return 1;
    }

    var out = cli.Out.init(ctx.io);
    if (opts.print_ls_colors) {
        for (entries.items) |e| writeEntry(&out, e, .raw, true);
    } else {
        const quoting: Quoting = if (opts.shell == .c) .c else .bourne;
        out.write(if (opts.shell == .c) "setenv LS_COLORS '" else "LS_COLORS='");
        for (entries.items) |e| writeEntry(&out, e, quoting, false);
        out.write(if (opts.shell == .c) "'\n" else "';\nexport LS_COLORS\n");
    }
    out.flush();
    return if (out.failed) 1 else 0;
}

fn applyOption(opts: *Options, id: u8) void {
    switch (id) {
        'b' => opts.shell = .bourne,
        'c' => opts.shell = .c,
        'p' => opts.print_database = true,
        'L' => opts.print_ls_colors = true,
        else => unreachable,
    }
}

/// Long option by exact name or unambiguous prefix (as getopt_long does).
fn longOption(name: []const u8) ?u8 {
    var found: ?u8 = null;
    for (long_options) |o| {
        if (std.mem.eql(u8, o.name, name)) return o.id;
        if (std.mem.startsWith(u8, o.name, name)) {
            if (found != null and found.? != o.id) return null; // ambiguous
            found = o.id;
        }
    }
    return found;
}

/// C shell when the basename of $SHELL is exactly csh or tcsh.
fn guessShell(ctx: cli.Context) Shell {
    const shell = cli.getenv(ctx, "SHELL") orelse return .unknown;
    if (shell.len == 0) return .unknown;
    const base = std.Io.Dir.path.basename(shell);
    if (std.mem.eql(u8, base, "csh") or std.mem.eql(u8, base, "tcsh")) return .c;
    return .bourne;
}

/// Read a whole file ("-" is standard input).
fn readAll(ctx: cli.Context, path: []const u8) ![]u8 {
    const file = try cli.openInput(ctx.io, path);
    defer cli.closeInput(ctx.io, file);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(ctx.gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try cli.readChunk(ctx.io, file, &buf);
        if (n == 0) break;
        try data.appendSlice(ctx.gpa, buf[0..n]);
    }
    return data.toOwnedSlice(ctx.gpa);
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: dircolors [OPTION]... [FILE]\n" ++
        "Output commands to set the LS_COLORS environment variable.\n\n" ++
        "Determine format of output:\n" ++
        "  -b, --sh, --bourne-shell    output Bourne shell code to set LS_COLORS\n" ++
        "  -c, --csh, --c-shell        output C shell code to set LS_COLORS\n" ++
        "  -p, --print-database        output defaults\n" ++
        "      --print-ls-colors       output fully escaped colors for display\n" ++
        "      --help     display this help and exit\n" ++
        "      --version  output version information and exit\n\n" ++
        "If FILE is specified, read it to determine which colors to use for which\n" ++
        "file types and extensions.  Otherwise, a precompiled database is used.\n" ++
        "For details on the format of these files, run 'dircolors --print-database'.\n")) 0 else 1;
}

fn fail(ctx: cli.Context, msg: []const u8) u8 {
    cli.warn(ctx, "{s}", .{msg});
    return 1;
}

fn usageError(ctx: cli.Context, msg: []const u8) u8 {
    cli.warn(ctx, "{s}\nTry '{s} --help' for more information.", .{ msg, ctx.name });
    return 1;
}

fn badOption(ctx: cli.Context, opt: []const u8) u8 {
    cli.warn(ctx, "invalid option '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}

// ---- tests ---------------------------------------------------------------

fn parseForTest(text: []const u8, term: []const u8, colorterm: []const u8, entries: *std.ArrayList(Entry), problems: *std.ArrayList(Problem)) !void {
    try parseDatabase(std.testing.allocator, text, term, colorterm, entries, problems);
}

test "globMatch" {
    const t = std.testing;
    try t.expect(globMatch("xterm*", "xterm-256color"));
    try t.expect(!globMatch("xterm*", "vt100"));
    try t.expect(globMatch("*color*", "xterm-256color"));
    try t.expect(globMatch("?*", "a"));
    try t.expect(!globMatch("?*", ""));
    try t.expect(globMatch("con[0-9]*x[0-9]*", "con80x25"));
    try t.expect(!globMatch("con[0-9]*x[0-9]*", "conx25"));
    try t.expect(globMatch("[!a]b", "cb"));
    try t.expect(!globMatch("[!a]b", "ab"));
    try t.expect(globMatch("a\\*b", "a*b"));
    try t.expect(!globMatch("a\\*b", "aXb"));
    try t.expect(globMatch("[", "["));
    try t.expect(globMatch("*", ""));
    try t.expect(globMatch("a*a*a", "aXaYa"));
}

test "parse: keywords, aliases, comments, white space" {
    var e: std.ArrayList(Entry) = .empty;
    defer e.deinit(std.testing.allocator);
    var pr: std.ArrayList(Problem) = .empty;
    defer pr.deinit(std.testing.allocator);
    try parseForTest("# c\r\ndir 01;34  # note\n.tar 1\n*~ 2\nLNK 3\nOPTIONS x\n  link\t4 \r\nDIR a#b\n", "none", "", &e, &pr);
    try std.testing.expectEqual(@as(usize, 0), pr.items.len);
    try std.testing.expectEqual(@as(usize, 6), e.items.len);
    try std.testing.expectEqualStrings("di", e.items[0].key);
    try std.testing.expectEqualStrings("01;34", e.items[0].value);
    try std.testing.expectEqual(@as(u8, '*'), e.items[1].prefix);
    try std.testing.expectEqualStrings(".tar", e.items[1].key);
    try std.testing.expectEqualStrings("*~", e.items[2].key);
    try std.testing.expectEqualStrings("ln", e.items[3].key);
    try std.testing.expectEqualStrings("4", e.items[4].value);
    try std.testing.expectEqualStrings("a", e.items[5].value); // '#' ends the value even inside a word
}

test "parse: TERM state machine (a later TERM line can cancel)" {
    var d: std.ArrayList(Problem) = .empty;
    defer d.deinit(std.testing.allocator);
    const Case = struct { text: []const u8, term: []const u8, colorterm: []const u8, want: usize };
    const cases = [_]Case{
        .{ .text = "TERM vt*\nDIR 1\nTERM xterm*\nFILE 2\n", .term = "xterm-256color", .colorterm = "", .want = 1 },
        .{ .text = "TERM xterm*\nDIR 1\nTERM vt*\nFILE 2\n", .term = "xterm", .colorterm = "", .want = 1 }, // cancelled
        .{ .text = "TERM xterm*\nTERM vt*\nDIR 1\n", .term = "xterm", .colorterm = "", .want = 1 }, // sure is sticky until an entry follows
        .{ .text = "COLORTERM ?*\nDIR 5\n", .term = "x", .colorterm = "", .want = 0 },
        .{ .text = "COLORTERM ?*\nDIR 5\n", .term = "x", .colorterm = "truecolor", .want = 1 },
        .{ .text = "TERM zzz\nCOLORTERM ?*\nDIR 5\n", .term = "zzz", .colorterm = "1", .want = 1 },
        .{ .text = "DIR 1\nTERM vt*\nFILE 2\n", .term = "xterm", .colorterm = "", .want = 1 }, // global entry kept
    };
    for (cases, 0..) |c, i| {
        var e: std.ArrayList(Entry) = .empty;
        defer e.deinit(std.testing.allocator);
        d.clearRetainingCapacity();
        try parseForTest(c.text, c.term, c.colorterm, &e, &d);
        std.testing.expectEqual(c.want, e.items.len) catch |err| {
            std.debug.print("case {d} failed\n", .{i});
            return err;
        };
    }
}

test "parse: unknown keywords are reported only inside a matching TERM block" {
    var e: std.ArrayList(Entry) = .empty;
    defer e.deinit(std.testing.allocator);
    var pr: std.ArrayList(Problem) = .empty;
    defer pr.deinit(std.testing.allocator);

    try parseForTest("FOO 1\n", "x", "", &e, &pr); // global: silent
    try std.testing.expectEqual(@as(usize, 0), pr.items.len);
    try parseForTest("TERM no*\nFOO 1\n", "x", "", &e, &pr); // not matching: silent
    try std.testing.expectEqual(@as(usize, 0), pr.items.len);
    try parseForTest("TERM x\nFOO 1\nDIR\n", "x", "", &e, &pr); // matching: reported
    try std.testing.expectEqual(@as(usize, 2), pr.items.len);
    try std.testing.expectEqual(Problem.Kind.unrecognized_keyword, pr.items[0].kind);
    try std.testing.expectEqual(@as(usize, 2), pr.items[0].line);
    try std.testing.expectEqualStrings("FOO", pr.items[0].keyword);
    try std.testing.expectEqual(Problem.Kind.missing_second_token, pr.items[1].kind);
    try std.testing.expectEqual(@as(usize, 3), pr.items[1].line);
}

test "parse: a keyword followed only by a comment has no value" {
    var e: std.ArrayList(Entry) = .empty;
    defer e.deinit(std.testing.allocator);
    var pr: std.ArrayList(Problem) = .empty;
    defer pr.deinit(std.testing.allocator);
    // "DIR#x" is a single (unknown, silently skipped) keyword with value "1".
    try parseForTest("DIR # nothing\nDIR#x 1\n", "none", "", &e, &pr);
    try std.testing.expectEqual(@as(usize, 1), pr.items.len);
    try std.testing.expectEqual(@as(usize, 1), pr.items[0].line);
    try std.testing.expectEqual(@as(usize, 0), e.items.len);
}

test "quoting follows GNU append_quoted" {
    var out = cli.Out.init(undefined);
    writeQuoted(&out, "a:b=c\\:d^:e'f!g", .bourne);
    try std.testing.expectEqualStrings("a\\:b\\=c\\:d^:e'\\''f!g", out.buf[0..out.len]);
    out.len = 0;
    writeQuoted(&out, "x!y", .c);
    try std.testing.expectEqualStrings("x\\!y", out.buf[0..out.len]);
    out.len = 0;
    writeQuoted(&out, "a:b", .raw);
    try std.testing.expectEqualStrings("a:b", out.buf[0..out.len]);
}

test "built-in database parses cleanly; unknown terminals get nothing" {
    var e: std.ArrayList(Entry) = .empty;
    defer e.deinit(std.testing.allocator);
    var pr: std.ArrayList(Problem) = .empty;
    defer pr.deinit(std.testing.allocator);
    try parseForTest(default_database, "xterm-256color", "", &e, &pr);
    try std.testing.expectEqual(@as(usize, 0), pr.items.len);
    try std.testing.expectEqualStrings("rs", e.items[0].key);
    try std.testing.expectEqualStrings("di", e.items[1].key);
    try std.testing.expect(e.items.len > 150);

    e.clearRetainingCapacity();
    try parseForTest(default_database, "none", "", &e, &pr);
    try std.testing.expectEqual(@as(usize, 0), e.items.len);
}

test "long option prefixes" {
    try std.testing.expectEqual(@as(?u8, 'b'), longOption("sh"));
    try std.testing.expectEqual(@as(?u8, 'p'), longOption("print-d"));
    try std.testing.expectEqual(@as(?u8, 'L'), longOption("print-l"));
    try std.testing.expectEqual(@as(?u8, null), longOption("print")); // ambiguous
    try std.testing.expectEqual(@as(?u8, 'c'), longOption("c-"));
    try std.testing.expectEqual(@as(?u8, null), longOption("x"));
}
