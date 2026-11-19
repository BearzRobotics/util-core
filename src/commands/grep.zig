// SPDX-License-Identifier: GPL-2.0-or-later
//! grep: thin wrapper over `util_core.grep` (decision 0004). Parses arguments
//! the way GNU grep does and words the diagnostics; matching, scanning and
//! output are in src/lib/grep.zig. Reference: GNU grep 3.12.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const posixre = @import("../posixre.zig");
const sys = @import("../sys.zig");
const argmatch = @import("../argmatch.zig");
const grep = @import("../lib/grep.zig");
const LX = std.os.linux;
const Io = std.Io;

const help_text = @embedFile("../help/grep.txt");

// -------------------------------------------------------------------- main

fn usage(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Usage: {s} [OPTION]... PATTERNS [FILE]...\nTry '{s} --help' for more information.", .{ ctx.name, ctx.name });
    return 2;
}

fn contextArg(ctx: cli.Context, arg: []const u8) ?i64 {
    var v: i64 = 0;
    if (arg.len == 0) {
        cli.warn(ctx, "{s}: invalid context length argument", .{arg});
        return null;
    }
    for (arg) |ch| {
        if (!std.ascii.isDigit(ch)) {
            cli.warn(ctx, "{s}: invalid context length argument", .{arg});
            return null;
        }
        v = v *| 10 +| (ch - '0');
    }
    return v;
}

pub fn main(ctx: cli.Context) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = std.heap.smp_allocator;
    const env: grep.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    var o: grep.Options = .{};
    var globs: std.ArrayList(grep.Glob) = .empty;
    var excl: std.ArrayList([]const u8) = .empty;
    var no_messages = false;
    o.utf8 = grep.localeIsUtf8(env);

    var p = getopt.Parser.init(ctx, "0123456789A:B:C:D:EFGHIPTUVX:abcd:e:f:hiLlm:noqRrsuvwxyZz", &.{
        .{ .name = "basic-regexp", .id = 'G' },
        .{ .name = "extended-regexp", .id = 'E' },
        .{ .name = "fixed-regexp", .id = 'F' },
        .{ .name = "fixed-strings", .id = 'F' },
        .{ .name = "perl-regexp", .id = 'P' },
        .{ .name = "after-context", .arg = .required, .id = 'A' },
        .{ .name = "before-context", .arg = .required, .id = 'B' },
        .{ .name = "binary-files", .arg = .required, .id = 1100 },
        .{ .name = "byte-offset", .id = 'b' },
        .{ .name = "context", .arg = .required, .id = 'C' },
        .{ .name = "color", .arg = .optional, .id = 1101 },
        .{ .name = "colour", .arg = .optional, .id = 1101 },
        .{ .name = "count", .id = 'c' },
        .{ .name = "dereference-recursive", .id = 'R' },
        .{ .name = "devices", .arg = .required, .id = 'D' },
        .{ .name = "directories", .arg = .required, .id = 'd' },
        .{ .name = "exclude", .arg = .required, .id = 1102 },
        .{ .name = "exclude-from", .arg = .required, .id = 1103 },
        .{ .name = "exclude-dir", .arg = .required, .id = 1104 },
        .{ .name = "file", .arg = .required, .id = 'f' },
        .{ .name = "files-with-matches", .id = 'l' },
        .{ .name = "files-without-match", .id = 'L' },
        .{ .name = "group-separator", .arg = .required, .id = 1105 },
        .{ .name = "include", .arg = .required, .id = 1106 },
        .{ .name = "ignore-case", .id = 'i' },
        .{ .name = "no-ignore-case", .id = 1107 },
        .{ .name = "initial-tab", .id = 'T' },
        .{ .name = "label", .arg = .required, .id = 1108 },
        .{ .name = "line-buffered", .id = 1109 },
        .{ .name = "line-number", .id = 'n' },
        .{ .name = "line-regexp", .id = 'x' },
        .{ .name = "max-count", .arg = .required, .id = 'm' },
        .{ .name = "no-filename", .id = 'h' },
        .{ .name = "no-group-separator", .id = 1110 },
        .{ .name = "no-messages", .id = 's' },
        .{ .name = "null", .id = 'Z' },
        .{ .name = "null-data", .id = 'z' },
        .{ .name = "only-matching", .id = 'o' },
        .{ .name = "quiet", .id = 'q' },
        .{ .name = "recursive", .id = 'r' },
        .{ .name = "regexp", .arg = .required, .id = 'e' },
        .{ .name = "invert-match", .id = 'v' },
        .{ .name = "silent", .id = 'q' },
        .{ .name = "text", .id = 'a' },
        .{ .name = "binary", .id = 'U' },
        .{ .name = "with-filename", .id = 'H' },
        .{ .name = "word-regexp", .id = 'w' },
    });
    defer p.deinit();
    p.no_try = true;

    var matcher_set = false;
    var keys: std.ArrayList(u8) = .empty;
    var have_keys = false;
    var digit_val: i64 = 0;
    var last_digit_idx: usize = std.math.maxInt(usize);
    var default_ctx: i64 = -1;
    while (true) {
        const idx_before = p.index;
        switch (p.next()) {
            .done => break,
            .bad => return usage(ctx),
            .opt => |opt| switch (opt.id) {
                '0'...'9' => {
                    if (last_digit_idx == idx_before and p.sub != 0 or last_digit_idx == idx_before) {
                        digit_val = digit_val *| 10 +| (opt.id - '0');
                    } else digit_val = opt.id - '0';
                    last_digit_idx = idx_before;
                    default_ctx = digit_val;
                },
                'A' => o.after = contextArg(ctx, opt.arg.?) orelse return 2,
                'B' => o.before = contextArg(ctx, opt.arg.?) orelse return 2,
                'C' => default_ctx = contextArg(ctx, opt.arg.?) orelse return 2,
                'D' => {
                    const t = [_]argmatch.Entry{};
                    _ = t;
                    if (std.mem.eql(u8, opt.arg.?, "read")) o.devices = .read else if (std.mem.eql(u8, opt.arg.?, "skip")) o.devices = .skip else {
                        cli.warn(ctx, "unknown devices method", .{});
                        return 2;
                    }
                },
                'E' => {
                    if (matcher_set and o.syntax != .extended) {
                        cli.warn(ctx, "conflicting matchers specified", .{});
                        return 2;
                    }
                    matcher_set = true;
                    o.syntax = .extended;
                },
                'F' => {
                    if (matcher_set and o.syntax != .fixed) {
                        cli.warn(ctx, "conflicting matchers specified", .{});
                        return 2;
                    }
                    matcher_set = true;
                    o.syntax = .fixed;
                },
                'G' => {
                    if (matcher_set and o.syntax != .basic) {
                        cli.warn(ctx, "conflicting matchers specified", .{});
                        return 2;
                    }
                    matcher_set = true;
                    o.syntax = .basic;
                },
                'P' => {
                    if (matcher_set and o.syntax != .perl) {
                        cli.warn(ctx, "conflicting matchers specified", .{});
                        return 2;
                    }
                    matcher_set = true;
                    o.syntax = .perl;
                },
                'X' => {
                    const a = opt.arg.?;
                    if (std.mem.eql(u8, a, "grep")) o.syntax = .basic else if (std.mem.eql(u8, a, "egrep")) o.syntax = .extended else if (std.mem.eql(u8, a, "fgrep")) o.syntax = .fixed else if (std.mem.eql(u8, a, "perl")) o.syntax = .perl else {
                        cli.warn(ctx, "invalid matcher {s}", .{a});
                        return 2;
                    }
                },
                'H' => o.with_filename = true,
                'I' => o.binary_files = .without_match,
                'T' => o.initial_tab = true,
                'U' => {},
                'u' => return usage(ctx),
                'V' => return version(ctx),
                'a' => o.binary_files = .text,
                'b' => o.byte_offset = true,
                'c' => o.count = true,
                'd' => {
                    const a = opt.arg.?;
                    const tbl = [_]argmatch.Entry{ .{ .name = "read", .value = 0 }, .{ .name = "recurse", .value = 1 }, .{ .name = "skip", .value = 2 } };
                    switch (argmatch.match(a, &tbl)) {
                        .ok => |v| o.directories = switch (v) {
                            0 => .read,
                            1 => .recurse,
                            else => .skip,
                        },
                        else => |r| {
                            argmatch.dieEx(ctx, a, "--directories", &tbl, r, "Usage: grep [OPTION]... PATTERNS [FILE]...");
                            return 1;
                        },
                    }
                },
                'e' => {
                    keys.appendSlice(gpa, opt.arg.?) catch return oom(ctx);
                    keys.append(gpa, '\n') catch return oom(ctx);
                    have_keys = true;
                },
                'f' => {
                    const name = opt.arg.?;
                    var err: LX.E = .SUCCESS;
                    const fd: i32 = if (std.mem.eql(u8, name, "-")) 0 else sys.openFd(name, sys.O.RDONLY, 0, &err) orelse {
                        cli.warn(ctx, "{s}: {s}", .{ name, sys.errnoText(err) });
                        return 2;
                    };
                    var data: std.ArrayList(u8) = .empty;
                    var buf: [65536]u8 = undefined;
                    while (true) {
                        const n = sys.readFd(fd, &buf, &err) orelse {
                            cli.warn(ctx, "{s}: {s}", .{ name, sys.errnoText(err) });
                            return 2;
                        };
                        if (n == 0) break;
                        data.appendSlice(gpa, buf[0..n]) catch return oom(ctx);
                    }
                    if (fd != 0) _ = sys.closeFd(fd);
                    have_keys = true;
                    if (data.items.len > 0) {
                        keys.appendSlice(gpa, data.items) catch return oom(ctx);
                        if (data.items[data.items.len - 1] != '\n') keys.append(gpa, '\n') catch return oom(ctx);
                    }
                },
                'h' => o.with_filename = false,
                'i', 'y' => o.icase = true,
                'L' => o.list = .nonmatching,
                'l' => o.list = .matching,
                'm' => {
                    const a = opt.arg.?;
                    var v: i64 = 0;
                    var neg = false;
                    var s = a;
                    if (s.len > 0 and s[0] == '-') {
                        neg = true;
                        s = s[1..];
                    }
                    if (s.len == 0) {
                        cli.warn(ctx, "invalid max count", .{});
                        return 2;
                    }
                    for (s) |ch| {
                        if (!std.ascii.isDigit(ch)) {
                            cli.warn(ctx, "invalid max count", .{});
                            return 2;
                        }
                        v = v *| 10 +| (ch - '0');
                    }
                    o.max_count = if (neg) std.math.maxInt(i64) else v;
                },
                'n' => o.line_number = true,
                'o' => o.only = true,
                'q' => o.quiet = true,
                'R' => {
                    o.deref_recursive = true;
                    o.directories = .recurse;
                },
                'r' => {
                    o.directories = .recurse;
                    o.deref_recursive = false;
                },
                's' => no_messages = true,
                'v' => o.invert = true,
                'w' => o.word = true,
                'x' => o.line = true,
                'Z' => o.null_after_name = true,
                'z' => {
                    o.null_data = true;
                },
                1100 => {
                    const a = opt.arg.?;
                    if (std.mem.eql(u8, a, "binary")) o.binary_files = .binary else if (std.mem.eql(u8, a, "text")) o.binary_files = .text else if (std.mem.eql(u8, a, "without-match")) o.binary_files = .without_match else {
                        cli.warn(ctx, "unknown binary-files type", .{});
                        return 2;
                    }
                },
                1101 => {
                    const a = opt.arg;
                    if (a == null) o.color = colorAuto(ctx) else if (std.mem.eql(u8, a.?, "always") or std.mem.eql(u8, a.?, "yes") or std.mem.eql(u8, a.?, "force")) o.color = true else if (std.mem.eql(u8, a.?, "never") or std.mem.eql(u8, a.?, "no") or std.mem.eql(u8, a.?, "none")) o.color = false else if (std.mem.eql(u8, a.?, "auto") or std.mem.eql(u8, a.?, "tty") or std.mem.eql(u8, a.?, "if-tty")) o.color = colorAuto(ctx) else {
                        return if (cli.writeStdout(ctx.io, help_text)) 0 else 2;
                    }
                },
                1102 => globs.append(gpa, .{ .pat = opt.arg.?, .include = false }) catch return oom(ctx),
                1103 => {
                    const name = opt.arg.?;
                    var err: LX.E = .SUCCESS;
                    const fd = sys.openFd(name, sys.O.RDONLY, 0, &err) orelse {
                        cli.warn(ctx, "{s}: {s}", .{ name, sys.errnoText(err) });
                        return 2;
                    };
                    var data: std.ArrayList(u8) = .empty;
                    var buf: [65536]u8 = undefined;
                    while (true) {
                        const n = sys.readFd(fd, &buf, &err) orelse break;
                        if (n == 0) break;
                        data.appendSlice(arena, buf[0..n]) catch return oom(ctx);
                    }
                    _ = sys.closeFd(fd);
                    var lines = std.mem.splitScalar(u8, data.items, '\n');
                    while (lines.next()) |ln| {
                        if (ln.len == 0) continue;
                        globs.append(gpa, .{ .pat = ln, .include = false }) catch return oom(ctx);
                    }
                },
                1104 => excl.append(gpa, opt.arg.?) catch return oom(ctx),
                1105 => o.group_sep = opt.arg.?,
                1106 => globs.append(gpa, .{ .pat = opt.arg.?, .include = true }) catch return oom(ctx),
                1107 => o.icase = false,
                1108 => o.label = opt.arg.?,
                1109 => o.line_buffered = true,
                1110 => o.group_sep = null,
                getopt.help_id => return if (cli.writeStdout(ctx.io, help_text)) 0 else 2,
                getopt.version_id => return version(ctx),
                else => return usage(ctx),
            },
        }
    }

    var operands = p.operands.items;
    if (!have_keys) {
        if (operands.len == 0) return usage(ctx);
        keys.appendSlice(gpa, operands[0]) catch return oom(ctx);
        keys.append(gpa, '\n') catch return oom(ctx);
        operands = operands[1..];
    }
    if (default_ctx >= 0) {
        if (o.after < 0) o.after = default_ctx;
        if (o.before < 0) o.before = default_ctx;
    }
    // patterns
    var keycc: usize = 0;
    if (!(have_keys and keys.items.len == 0)) {
        _ = keys.pop();
        keycc = keys.items.len;
    }
    if (o.prepare(keycc, have_keys)) return 1;

    var report_state = Report{ .ctx = ctx, .no_messages = no_messages };
    const observer: grep.Observer = .{ .context = &report_state, .func = report };
    var diag: grep.CompileError = .{};
    var matcher = grep.Matcher.compile(gpa, o, keys.items, observer, &diag) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.BadPattern => {
            cli.warn(ctx, "{s}", .{switch (diag.kind) {
                .syntax => posixre.diagnoseGrep(diag.pattern, diag.extended),
                .bare_class => "character class syntax is [[:space:]], not [:space:]",
                .invalid_perl => "invalid Perl regular expression",
            }});
            return 2;
        },
    };
    defer matcher.deinit();

    if (o.color) o.colors = grep.Colors.fromEnv(env, observer);
    o.globs = globs.items;
    o.exclude_dirs = excl.items;
    o.output_file = Io.File.stdout();

    var inputs: std.ArrayList(grep.Input) = .empty;
    defer inputs.deinit(gpa);
    if (operands.len == 0) {
        if (o.directories == .recurse) {
            o.implicit_dot = true;
            inputs.append(gpa, .{ .name = ".", .source = .{ .path = "." } }) catch return oom(ctx);
        } else inputs.append(gpa, .{ .name = null, .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (operands) |f| {
        const in: grep.Input = if (std.mem.eql(u8, f, "-"))
            .{ .name = f, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = f, .source = .{ .path = f } };
        inputs.append(gpa, in) catch return oom(ctx);
    }

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const result = grep.run(env, o, &matcher, inputs.items, &stdout.interface, observer) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 2;
        },
    };
    if (result.early_exit) return 0;
    if (result.errors) return 2;
    return if (result.matched) 0 else 1;
}

const Report = struct { ctx: cli.Context, no_messages: bool };

/// Word the library's events as GNU grep does.
fn report(context: ?*anyopaque, ev: grep.Event) void {
    const st: *const Report = @ptrCast(@alignCast(context.?));
    const ctx = st.ctx;
    switch (ev) {
        .read_error => |e| if (!st.no_messages) cli.warn(ctx, "{s}: {s}", .{ e.name, sys.errnoText(e.errno) }),
        .is_directory => |n| if (!st.no_messages) cli.warn(ctx, "{s}: Is a directory", .{n}),
        .input_is_output => |n| if (!st.no_messages) cli.warn(ctx, "{s}: input file is also the output", .{n}),
        .binary_matches => |n| cli.warn(ctx, "{s}: binary file matches", .{n}),
        .leading_operator => |ch| switch (ch) {
            '{' => cli.warn(ctx, "warning: {{...}} at start of expression", .{}),
            else => cli.warn(ctx, "warning: {c} at start of expression", .{ch}),
        },
        .deprecated_grep_color => |gc| cli.warn(ctx, "warning: GREP_COLOR='{s}' is deprecated; use GREP_COLORS='mt={s}'", .{ gc, gc }),
    }
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 2;
}

fn colorAuto(ctx: cli.Context) bool {
    const term = cli.getenv(ctx, "TERM") orelse return false;
    if (std.mem.eql(u8, term, "dumb")) return false;
    return Io.File.stdout().isTty(ctx.io) catch false;
}

fn version(ctx: cli.Context) u8 {
    const v =
        \\grep (GNU grep) 3.12
        \\Copyright (C) 2025 Free Software Foundation, Inc.
        \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
        \\This is free software: you are free to change and redistribute it.
        \\There is NO WARRANTY, to the extent permitted by law.
        \\
        \\Written by Mike Haertel and others; see
        \\<https://git.savannah.gnu.org/cgit/grep.git/tree/AUTHORS>.
        \\
    ;
    return if (cli.writeStdout(ctx.io, v)) 0 else 2;
}
