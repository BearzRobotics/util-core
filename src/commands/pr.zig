// SPDX-License-Identifier: GPL-2.0-or-later
//! pr: thin wrapper over `util_core.pr` (decision 0004). Parses arguments the
//! way GNU pr does (including the obsolete -w/-s handling and the +PAGE
//! operand) and words the diagnostics; the page and column layout is in
//! src/lib/pr.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const pr = @import("../lib/pr.zig");
const Io = std.Io;

const help_text = @embedFile("../help/pr.txt");

fn parseNum(ctx: cli.Context, text: []const u8, min: i64, err: []const u8) ?i32 {
    const v = std.fmt.parseInt(i64, text, 10) catch |e| {
        cli.warn(ctx, "{s}: {f}{s}", .{ err, cli.quoteC(text), if (e == error.Overflow) ": Value too large for defined data type" else "" });
        return null;
    };
    if (v < min or v > std.math.maxInt(i32)) {
        // xnumtoimax: below a positive minimum is ERANGE, anything else EOVERFLOW.
        const why: []const u8 = if (v < min and min > 0) ": Numerical result out of range" else ": Value too large for defined data type";
        cli.warn(ctx, "{s}: {f}{s}", .{ err, cli.quoteC(text), why });
        return null;
    }
    return @intCast(v);
}

fn getoptarg(ctx: cli.Context, arg: []const u8, sw: u8, character: *u8, number: *i32) bool {
    var a = arg;
    if (a.len == 0) {
        getopt.usageError(ctx, "'-{c}': Invalid argument: {f}", .{ sw, cli.quoteC(arg) });
        return false;
    }
    if (!std.ascii.isDigit(a[0])) {
        character.* = a[0];
        a = a[1..];
    }
    if (a.len > 0) {
        const v = std.fmt.parseInt(i64, a, 10) catch -1;
        if (v <= 0 or v > std.math.maxInt(i32)) {
            getopt.usageError(ctx, "'-{c}' extra characters or invalid number in the argument: {f}", .{ sw, cli.quoteC(a) });
            return false;
        }
        number.* = @intCast(v);
    }
    return true;
}

const PageParse = enum { ok, not_pages, fatal };

/// first_last_page: ok, "not a page spec" (treated as a file name), or a
/// fatal xstrtol-style diagnostic already printed.
fn firstLastPage(p: *pr.Options, ctx: cli.Context, pages: []const u8, option: []const u8) PageParse {
    var i: usize = 0;
    var first: u64 = 0;
    var overflow = false;
    while (i < pages.len and std.ascii.isDigit(pages[i])) : (i += 1) {
        const m = @mulWithOverflow(first, 10);
        const a = @addWithOverflow(m[0], pages[i] - '0');
        if (m[1] != 0 or a[1] != 0) overflow = true;
        first = a[0];
    }
    if (overflow) {
        cli.warn(ctx, "{s} argument {f} too large", .{ option, cli.quoteC(pages) });
        return .fatal;
    }
    if (i == 0) {
        // No digits: xstrtoumax reports an invalid number.
        cli.warn(ctx, "invalid {s} argument {f}", .{ option, cli.quoteC(pages) });
        return .fatal;
    }
    if (first == 0) return .not_pages;
    var last: u64 = std.math.maxInt(u64);
    if (i < pages.len and pages[i] == ':') {
        i += 1;
        const st = i;
        last = 0;
        while (i < pages.len and std.ascii.isDigit(pages[i])) : (i += 1) {
            const m = @mulWithOverflow(last, 10);
            const a = @addWithOverflow(m[0], pages[i] - '0');
            if (m[1] != 0 or a[1] != 0) overflow = true;
            last = a[0];
        }
        if (overflow) {
            cli.warn(ctx, "{s} argument {f} too large", .{ option, cli.quoteC(pages) });
            return .fatal;
        }
        if (i == st) {
            cli.warn(ctx, "invalid {s} argument {f}", .{ option, cli.quoteC(pages) });
            return .fatal;
        }
        if (last < first) return .not_pages;
        if (i < pages.len) {
            cli.warn(ctx, "invalid suffix in {s} argument {f}", .{ option, cli.quoteC(pages) });
            return .fatal;
        }
    } else if (i < pages.len) return .not_pages;
    p.first_page_number = first;
    p.last_page_number = last;
    return .ok;
}


pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var opts: pr.Options = .{};

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var old_w = false;
    var old_s = false;
    var old_options = false;
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(gpa);
    var digit_run = false;

    var parser = getopt.Parser.init(ctx, "-0123456789D:FJN:S::TW:abcde::fh:i::l:mn::o:rs::tvw:", &.{
        .{ .name = "pages", .arg = .required, .id = 1100 },
        .{ .name = "columns", .arg = .required, .id = 1101 },
        .{ .name = "across", .id = 'a' },
        .{ .name = "show-control-chars", .id = 'c' },
        .{ .name = "double-space", .id = 'd' },
        .{ .name = "date-format", .arg = .required, .id = 'D' },
        .{ .name = "expand-tabs", .arg = .optional, .id = 'e' },
        .{ .name = "form-feed", .id = 'f' },
        .{ .name = "header", .arg = .required, .id = 'h' },
        .{ .name = "output-tabs", .arg = .optional, .id = 'i' },
        .{ .name = "join-lines", .id = 'J' },
        .{ .name = "length", .arg = .required, .id = 'l' },
        .{ .name = "merge", .id = 'm' },
        .{ .name = "number-lines", .arg = .optional, .id = 'n' },
        .{ .name = "first-line-number", .arg = .required, .id = 'N' },
        .{ .name = "indent", .arg = .required, .id = 'o' },
        .{ .name = "no-file-warnings", .id = 'r' },
        .{ .name = "separator", .arg = .optional, .id = 's' },
        .{ .name = "sep-string", .arg = .optional, .id = 'S' },
        .{ .name = "omit-header", .id = 't' },
        .{ .name = "omit-pagination", .id = 'T' },
        .{ .name = "show-nonprinting", .id = 'v' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "page-width", .arg = .required, .id = 'W' },
    });
    defer parser.deinit();
    while (true) {
        const item = parser.next();
        const o = switch (item) {
            .done => break,
            .bad => return 1,
            .opt => |o| o,
        };
        if (o.id >= '0' and o.id <= '9') {
            if (!digit_run) digits.clearRetainingCapacity();
            digit_run = true;
            digits.append(gpa, @intCast(o.id)) catch return 1;
            continue;
        }
        digit_run = false;
        switch (o.id) {
            getopt.operand_id => {
                const a = o.arg.?;
                var consumed = false;
                if (opts.first_page_number == 0 and a.len > 0 and a[0] == '+') {
                    switch (firstLastPage(&opts, ctx, a[1..], "+")) {
                        .ok => consumed = true,
                        .fatal => return 1,
                        .not_pages => {},
                    }
                }
                if (!consumed) files.append(gpa, a) catch return 1;
            },
            1100 => {
                switch (firstLastPage(&opts, ctx, o.arg.?, "--pages")) {
                    .ok => {},
                    .fatal => return 1,
                    .not_pages => {
                        cli.warn(ctx, "invalid page range {f}", .{cli.quoteC(o.arg.?)});
                        return 1;
                    },
                }
            },
            1101 => {
                opts.columns = parseNum(ctx, o.arg.?, 1, "invalid number of columns") orelse return 1;
                opts.explicit_columns = true;
                digits.clearRetainingCapacity(); // --columns overrides -NUM
            },
            'a' => {
                opts.print_across_flag = true;
                opts.storing_columns = false;
            },
            'b' => opts.balance_columns = true,
            'c' => opts.use_cntrl_prefix = true,
            'd' => opts.double_space = true,
            'D' => opts.date_format = o.arg,
            'e' => {
                if (o.arg) |a| if (!getoptarg(ctx, a, 'e', &opts.input_tab_char, &opts.chars_per_input_tab)) return 1;
                opts.untabify_input = true;
            },
            'f', 'F' => opts.use_form_feed = true,
            'h' => opts.custom_header = o.arg,
            'i' => {
                if (o.arg) |a| if (!getoptarg(ctx, a, 'i', &opts.output_tab_char, &opts.chars_per_output_tab)) return 1;
                opts.tabify_output = true;
            },
            'J' => opts.join_lines = true,
            'l' => opts.lines_per_page = parseNum(ctx, o.arg.?, 1, "'-l PAGE_LENGTH' invalid number of lines") orelse return 1,
            'm' => {
                opts.parallel_files = true;
                opts.storing_columns = false;
            },
            'n' => {
                opts.numbered_lines = true;
                if (o.arg) |a| if (!getoptarg(ctx, a, 'n', &opts.number_separator, &opts.chars_per_number)) return 1;
            },
            'N' => {
                opts.skip_count = false;
                opts.start_line_num = parseNum(ctx, o.arg.?, std.math.minInt(i32), "'-N NUMBER' invalid starting line number") orelse return 1;
            },
            'o' => opts.chars_per_margin = parseNum(ctx, o.arg.?, 0, "'-o MARGIN' invalid line offset") orelse return 1,
            'r' => opts.ignore_failed_opens = true,
            's' => {
                old_options = true;
                old_s = true;
                if (!opts.use_col_separator) if (o.arg) |a| {
                    opts.col_sep_string = a;
                    opts.col_sep_length = @intCast(a.len);
                };
            },
            'S' => {
                old_s = false;
                opts.col_sep_string = "";
                opts.col_sep_length = 0;
                opts.use_col_separator = true;
                if (o.arg) |a| {
                    opts.col_sep_string = a;
                    opts.col_sep_length = @intCast(a.len);
                }
            },
            't' => {
                opts.extremities = false;
                opts.keep_ff = true;
            },
            'T' => {
                opts.extremities = false;
                opts.keep_ff = false;
            },
            'v' => opts.use_esc_sequence = true,
            'w' => {
                old_options = true;
                old_w = true;
                const tmp = parseNum(ctx, o.arg.?, 1, "'-w PAGE_WIDTH' invalid number of characters") orelse return 1;
                if (!opts.truncate_lines) opts.chars_per_line = tmp;
            },
            'W' => {
                old_w = false;
                opts.truncate_lines = true;
                opts.chars_per_line = parseNum(ctx, o.arg.?, 1, "'-W PAGE_WIDTH' invalid number of characters") orelse return 1;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        }
    }
    if (digits.items.len > 0) {
        opts.columns = parseNum(ctx, digits.items, 1, "invalid number of columns") orelse return 1;
        opts.explicit_columns = true;
    }

    if (opts.parallel_files and opts.explicit_columns) {
        cli.warn(ctx, "cannot specify number of columns when printing in parallel", .{});
        return 1;
    }
    if (opts.parallel_files and opts.print_across_flag) {
        cli.warn(ctx, "cannot specify both printing across and printing in parallel", .{});
        return 1;
    }
    if (old_options) {
        if (old_w) {
            if (opts.parallel_files or opts.explicit_columns) {
                opts.truncate_lines = true;
                if (old_s) opts.use_col_separator = true;
            } else opts.join_lines = true;
        } else if (!opts.use_col_separator) {
            if (old_s and (opts.parallel_files or opts.explicit_columns)) {
                if (!opts.truncate_lines) {
                    opts.join_lines = true;
                    if (opts.col_sep_length > 0) opts.use_col_separator = true;
                } else opts.use_col_separator = true;
            }
        }
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: pr.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    const result = pr.run(env, opts, files.items, &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
        error.OutOfMemory => {
            cli.warn(ctx, "memory exhausted", .{});
            return 1;
        },
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: pr.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .page_width_too_narrow => cli.warn(ctx.*, "page width too narrow", .{}),
        .open_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .read_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .start_page_exceeds => |e| cli.warn(ctx.*, "starting page number {d} exceeds page count {d}", .{ e.page, e.count }),
        .page_number_overflow => cli.warn(ctx.*, "page number overflow", .{}),
    }
}
