// SPDX-License-Identifier: GPL-2.0-or-later
//! ptx: thin wrapper over `util_core.ptx` (decision 0004). Parses arguments
//! and operands the way GNU ptx does and words the diagnostics; the index
//! generation is in src/lib/ptx.zig.

const std = @import("std");
const numparse = @import("../numparse.zig");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const ptx = @import("../lib/ptx.zig");
const Io = std.Io;

const help_text = @embedFile("../help/ptx.txt");

fn parseBase0(text: []const u8) isize {
    // xstrtoimax base 0: 0x hex, leading 0 octal, otherwise decimal.
    var t = text;
    var neg = false;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    const v: isize = if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X'))
        numparse.parseInt(isize, t[2..], 16) catch 0
    else if (t.len > 1 and t[0] == '0')
        numparse.parseInt(isize, t[1..], 8) catch 0
    else
        numparse.parseInt(isize, t, 10) catch 0;
    return if (neg) -v else v;
}

fn unescapeString(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) break;
        switch (s[i]) {
            'x' => {
                i += 1;
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i < s.len and std.ascii.isHex(s[i])) : (n += 1) {
                    v = v * 16 + (std.fmt.charToDigit(s[i], 16) catch 0);
                    i += 1;
                }
                if (n == 0) {
                    try out.appendSlice(gpa, "\\x");
                } else try out.append(gpa, @truncate(v));
            },
            '0' => {
                i += 1;
                var v: u32 = 0;
                var n: usize = 0;
                while (n < 3 and i < s.len and s[i] >= '0' and s[i] <= '7') : (n += 1) {
                    v = v * 8 + (s[i] - '0');
                    i += 1;
                }
                try out.append(gpa, @truncate(v));
            },
            'a' => {
                try out.append(gpa, 7);
                i += 1;
            },
            'b' => {
                try out.append(gpa, 8);
                i += 1;
            },
            'c' => i = s.len,
            'f' => {
                try out.append(gpa, 12);
                i += 1;
            },
            'n' => {
                try out.append(gpa, 10);
                i += 1;
            },
            'r' => {
                try out.append(gpa, 13);
                i += 1;
            },
            't' => {
                try out.append(gpa, 9);
                i += 1;
            },
            'v' => {
                try out.append(gpa, 11);
                i += 1;
            },
            else => {
                try out.append(gpa, '\\');
                try out.append(gpa, s[i]);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var opts: ptx.Options = .{ .inputs = &.{} };

    var fmt_arg: ?[]const u8 = null;
    var parser = getopt.Parser.init(ctx, "AF:GM:ORS:TW:b:i:fg:o:trw:", &.{
        .{ .name = "auto-reference", .id = 'A' },
        .{ .name = "break-file", .arg = .required, .id = 'b' },
        .{ .name = "flag-truncation", .arg = .required, .id = 'F' },
        .{ .name = "ignore-case", .id = 'f' },
        .{ .name = "gap-size", .arg = .required, .id = 'g' },
        .{ .name = "ignore-file", .arg = .required, .id = 'i' },
        .{ .name = "macro-name", .arg = .required, .id = 'M' },
        .{ .name = "only-file", .arg = .required, .id = 'o' },
        .{ .name = "references", .id = 'r' },
        .{ .name = "right-side-refs", .id = 'R' },
        .{ .name = "format", .arg = .required, .id = 1100 },
        .{ .name = "sentence-regexp", .arg = .required, .id = 'S' },
        .{ .name = "traditional", .id = 'G' },
        .{ .name = "typeset-mode", .id = 't' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "word-regexp", .arg = .required, .id = 'W' },
    });
    defer parser.deinit();
    while (true) switch (parser.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'G' => opts.gnu_extensions = false,
            'b' => opts.break_file = o.arg,
            'f' => opts.ignore_case = true,
            'g' => {
                const v = parseBase0(o.arg.?);
                if (v <= 0) {
                    cli.warn(ctx, "invalid gap width: {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                }
                opts.gap_size = v;
            },
            'i' => opts.ignore_file = o.arg,
            'o' => opts.only_file = o.arg,
            'r' => opts.input_reference = true,
            't' => {},
            'w' => {
                const v = parseBase0(o.arg.?);
                if (v <= 0) {
                    cli.warn(ctx, "invalid line width: {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                }
                opts.line_width = v;
            },
            'A' => opts.auto_reference = true,
            'F' => opts.truncation_string = unescapeString(arena, o.arg.?) catch return 1,
            'M' => opts.macro_name = o.arg.?,
            'O' => opts.output_format = .roff,
            'R' => opts.right_reference = true,
            'S' => opts.context_regex = unescapeString(arena, o.arg.?) catch return 1,
            'T' => opts.output_format = .tex,
            'W' => {
                const w = unescapeString(arena, o.arg.?) catch return 1;
                opts.word_regex = if (w.len == 0) null else w;
            },
            1100 => fmt_arg = o.arg,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (fmt_arg) |fa| {
        const names = [_][]const u8{ "roff", "tex" };
        var found: ?usize = null;
        var amb = false;
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, n, fa)) {
                found = i;
                amb = false;
                break;
            }
            if (std.mem.startsWith(u8, n, fa)) {
                if (found != null) amb = true;
                found = i;
            }
        }
        if (found == null or amb) {
            cli.warn(ctx, "{s} argument {f} for '--format'\nValid arguments are:\n  - 'roff'\n  - 'tex'\nTry '{s} --help' for more information.", .{ if (amb) "ambiguous" else "invalid", cli.quoteC(fa), ctx.name });
            return 1;
        }
        opts.output_format = if (found.? == 0) .roff else .tex;
    }

    const operands = parser.operands.items;
    var names_list: std.ArrayList([]const u8) = .empty;
    var fnames: std.ArrayList(?[]const u8) = .empty;
    var out_redirect: ?[]const u8 = null;
    if (operands.len == 0) {
        fnames.append(arena, null) catch return 1;
    } else if (opts.gnu_extensions) {
        for (operands) |o| fnames.append(arena, if (o.len == 0 or std.mem.eql(u8, o, "-")) null else o) catch return 1;
    } else {
        fnames.append(arena, if (operands[0].len == 0 or std.mem.eql(u8, operands[0], "-")) null else operands[0]) catch return 1;
        if (operands.len > 1) out_redirect = operands[1];
        if (operands.len > 2) {
            getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(operands[2])});
            return 1;
        }
    }
    _ = &names_list;
    opts.inputs = fnames.items;
    opts.output_path = out_redirect;

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: ptx.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    ptx.run(env, opts, &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
        error.Failed => return 1,
        error.WriteFailed => {
            if (out_redirect == null) cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    return 0;
}

fn report(context: ?*anyopaque, ev: ptx.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .file_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .invalid_regex => |text| cli.warn(ctx.*, "Invalid regular expression (for regexp {f})", .{cli.quoteC(text)}),
        .context_zero => |text| cli.warn(ctx.*, "error: regular expression has a match of length zero: {f}", .{cli.quoteC(text)}),
        .output_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
    }
}
