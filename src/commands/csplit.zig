// SPDX-License-Identifier: GPL-2.0-or-later
//! csplit: thin wrapper over `util_core.csplit` (decision 0004). Parses
//! arguments and the pattern operands the way GNU csplit does and words the
//! diagnostics; the splitting is in src/lib/csplit.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const posixre = @import("../posixre.zig");
const csplit = @import("../lib/csplit.zig");
const Io = std.Io;

const help_text = @embedFile("../help/csplit.txt");

const Control = csplit.Control;

/// Validate a --suffix-format (max_out in GNU). Returns false after printing.
fn checkSuffixFormat(ctx: cli.Context, fmt: []const u8) bool {
    var percent = false;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%') continue;
        i += 1;
        if (i < fmt.len and fmt[i] == '%') continue;
        if (percent) {
            cli.warn(ctx, "too many % conversion specifications in suffix", .{});
            return false;
        }
        percent = true;
        var alt = false;
        var thousands = false;
        while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '0' or fmt[i] == '\'' or fmt[i] == '#')) : (i += 1) {
            if (fmt[i] == '#') alt = true;
            if (fmt[i] == '\'') thousands = true;
        }
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
        }
        if (i >= fmt.len) {
            cli.warn(ctx, "missing conversion specifier in suffix", .{});
            return false;
        }
        const ch = fmt[i];
        var compatible_thousands = true;
        switch (ch) {
            'd', 'i', 'u' => {},
            'o', 'x', 'X' => compatible_thousands = false,
            else => {
                if (std.ascii.isPrint(ch))
                    cli.warn(ctx, "invalid conversion specifier in suffix: {c}", .{ch})
                else
                    cli.warn(ctx, "invalid conversion specifier in suffix: \\{o:0>3}", .{ch});
                return false;
            },
        }
        if ((alt and compatible_thousands) or (thousands and !compatible_thousands)) {
            cli.warn(ctx, "invalid flags in conversion specification: %{c}{c}", .{ @as(u8, if (alt and compatible_thousands) '#' else '\''), ch });
            return false;
        }
    }
    if (!percent) {
        cli.warn(ctx, "missing % conversion specification in suffix", .{});
        return false;
    }
    return true;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var opts: csplit.Options = .{ .args = &.{}, .controls = &.{} };
    var controls: std.ArrayList(Control) = .empty;

    var parser = getopt.Parser.init(ctx, "f:b:kn:sqz", &.{
        .{ .name = "digits", .arg = .required, .id = 'n' },
        .{ .name = "quiet", .id = 'q' },
        .{ .name = "silent", .id = 's' },
        .{ .name = "keep-files", .id = 'k' },
        .{ .name = "elide-empty-files", .id = 'z' },
        .{ .name = "prefix", .arg = .required, .id = 'f' },
        .{ .name = "suffix-format", .arg = .required, .id = 'b' },
        .{ .name = "suppress-matched", .id = 1100 },
    });
    defer parser.deinit();
    while (true) switch (parser.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'f' => opts.prefix = o.arg.?,
            'b' => opts.suffix_format = o.arg.?,
            'k' => opts.keep_files = true,
            'n' => {
                const v = std.fmt.parseInt(i64, o.arg.?, 10) catch -1;
                if (v < 0 or v > std.math.maxInt(i32)) {
                    const bad_syntax = std.fmt.parseInt(i64, o.arg.?, 10) catch null == null;
                    cli.warn(ctx, "invalid number: {f}{s}", .{ cli.quoteC(o.arg.?), if (bad_syntax) "" else ": Value too large for defined data type" });
                    return 1;
                }
                opts.digits = @intCast(v);
            },
            's', 'q' => opts.suppress_count = true,
            'z' => opts.elide_empty_files = true,
            1100 => opts.suppress_matched = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const ops = parser.operands.items;
    if (ops.len < 2) {
        if (ops.len == 0)
            getopt.usageError(ctx, "missing operand", .{})
        else
            getopt.usageError(ctx, "missing operand after {f}", .{cli.quoteC(ops[ops.len - 1])});
        return 1;
    }
    if (opts.suffix_format) |sf| if (!checkSuffixFormat(ctx, sf)) return 1;

    // Open the input.
    var file_opt: ?Io.File = null;
    if (cli.openInput(ctx.io, ops[0])) |f| {
        file_opt = f;
    } else |e| {
        // GNU opens a directory fine and fails on the first read.
        if (e == error.IsDir) {
        } else {
            cli.warn(ctx, "cannot open {f} for reading: {s}", .{ cli.quoteA(ops[0]), cli.errText(e) });
            return 1;
        }
    }
    defer if (file_opt) |f| cli.closeInput(ctx.io, f);

    // Parse the patterns (before reading input, like GNU).
    var last_val: i64 = 0;
    var i: usize = 1;
    while (i < ops.len) : (i += 1) {
        const a = ops[i];
        var c: Control = .{ .argnum = i };
        if (a.len > 0 and (a[0] == '/' or a[0] == '%')) {
            const delim = a[0];
            const close = std.mem.lastIndexOfScalar(u8, a[1..], delim) orelse {
                cli.warn(ctx, "{s}: closing delimiter '{c}' missing", .{ a, delim });
                return 1;
            };
            const pat = a[1 .. 1 + close];
            c.regexpr = true;
            c.ignore = delim == '%';
            c.re = posixre.compile(arena, pat, false, false) catch {
                cli.warn(ctx, "{f}: invalid regular expression: {s}", .{ cli.quoteC(a), posixre.diagnose(pat) });
                return 1;
            };
            const rest = a[1 + close + 1 ..];
            if (rest.len > 0) {
                c.offset = parseSigned(rest) orelse {
                    cli.warn(ctx, "{f}: integer expected after delimiter", .{cli.quoteC(a)});
                    return 1;
                };
            }
        } else {
            const v = std.fmt.parseInt(i64, a, 10) catch {
                cli.warn(ctx, "{f}: invalid pattern", .{cli.quoteC(a)});
                return 1;
            };
            if (v < 0 or (a.len > 0 and a[0] == '-')) {
                cli.warn(ctx, "{f}: invalid pattern", .{cli.quoteC(a)});
                return 1;
            }
            if (v == 0) {
                cli.warn(ctx, "{s}: line number must be greater than zero", .{a});
                return 1;
            }
            if (v < last_val) {
                cli.warn(ctx, "line number {f} is smaller than preceding line number, {d}", .{ cli.quoteC(a), last_val });
                return 1;
            }
            if (v == last_val) cli.warn(ctx, "warning: line number {f} is the same as preceding line number", .{cli.quoteC(a)});
            last_val = v;
            c.lines_required = v;
        }
        if (i + 1 < ops.len and ops[i + 1].len > 0 and ops[i + 1][0] == '{') {
            i += 1;
            const r = ops[i];
            if (r[r.len - 1] != '}') {
                cli.warn(ctx, "{f}: '}}' is required in repeat count", .{cli.quoteC(r)});
                return 1;
            }
            const inner = r[1 .. r.len - 1];
            if (std.mem.eql(u8, inner, "*")) {
                c.repeat_forever = true;
            } else {
                const v = std.fmt.parseInt(i64, inner, 10) catch -1;
                if (v < 0 or inner.len == 0 or inner[0] == '-' or inner[0] == '+') {
                    cli.warn(ctx, "{f}}}: integer required between '{{' and '}}'", .{cli.quoteC(r)});
                    return 1;
                }
                c.repeat = v;
            }
        }
        controls.append(arena, c) catch return 1;
    }

    opts.args = ops;
    opts.controls = controls.items;
    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: csplit.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    const result = csplit.run(env, opts, file_opt, &stdout.interface, .{ .context = @constCast(&ctx), .func = report });
    if (result.stdout_failed) cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
    return result.status;
}

fn report(context: ?*anyopaque, ev: csplit.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .read_error_directory => cli.warn(ctx.*, "read error: Is a directory", .{}),
        .read_error => cli.warn(ctx.*, "read error", .{}),
        .create_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .write_error => |name| cli.warn(ctx.*, "write error for {f}", .{cli.quoteA(name)}),
        .delete_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .line_out_of_range => |e| if (e.repetition != 0)
            cli.warn(ctx.*, "{f}: line number out of range on repetition {d}", .{ cli.quoteC(e.text), e.repetition })
        else
            cli.warn(ctx.*, "{f}: line number out of range", .{cli.quoteC(e.text)}),
        .match_not_found => |e| if (e.repetition != 0)
            cli.warn(ctx.*, "{f}: match not found on repetition {d}", .{ cli.quoteC(e.text), e.repetition })
        else
            cli.warn(ctx.*, "{f}: match not found", .{cli.quoteC(e.text)}),
        .memory_exhausted => cli.warn(ctx.*, "memory exhausted", .{}),
    }
}

fn parseSigned(text: []const u8) ?i64 {
    var t = text;
    var neg = false;
    if (t.len > 0 and (t[0] == '+' or t[0] == '-')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    if (t.len == 0) return null;
    const v = std.fmt.parseInt(i64, t, 10) catch return null;
    return if (neg) -v else v;
}
