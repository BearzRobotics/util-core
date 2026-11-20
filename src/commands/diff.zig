// SPDX-License-Identifier: GPL-2.0-or-later
//! diff: thin wrapper over `util_core.diff` (decision 0004). Parses arguments
//! the way GNU diff does and words the diagnostics.
//! References: GNU diffutils manual "Comparing and Merging Files" (3.12);
//! POSIX.1-2024 diff.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const diff = @import("../lib/diff.zig");

const help_text = @embedFile("../help/diff.txt");

const O = struct {
    const normal = 1100;
    const brief = 'q';
    const context = 1101;
    const unified = 1102;
    const ed = 'e';
    const rcs = 'n';
    const side = 'y';
    const left_column = 1103;
    const suppress_common = 1104;
    const label = 1105;
    const tabsize = 1106;
    const suppress_blank_empty = 1107;
    const no_deref = 1108;
    const unidirectional = 1109;
    const ign_name_case = 1110;
    const no_ign_name_case = 1111;
    const from_file = 1112;
    const to_file = 1113;
    const strip_cr = 1114;
    const line_format = 1115;
    const horizon = 1116;
    const color = 1117;
    const palette = 1118;
    const old_group = 1120;
    const new_group = 1121;
    const unchanged_group = 1122;
    const changed_group = 1123;
    const old_line = 1124;
    const new_line = 1125;
    const unchanged_line = 1126;
    const speed = 'H';
    const json = 1200;
};

const Fail = error{Usage};

fn usage(ctx: cli.Context, comptime fmt: []const u8, args: anytype) u8 {
    cli.warn(ctx, fmt, args);
    cli.warn(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 2;
}

fn parseCount(text: []const u8) ?usize {
    if (text.len == 0) return null;
    var v: usize = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v *| 10 +| (c - '0');
    }
    return v;
}

fn shellWord(gpa: std.mem.Allocator, out: *std.ArrayList(u8), w: []const u8) !void {
    var safe = w.len > 0;
    for (w) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_+,./:@%^", c) != null)) safe = false;
    }
    try out.append(gpa, ' ');
    if (safe) return out.appendSlice(gpa, w);
    try out.append(gpa, '\'');
    for (w) |c| {
        if (c == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, c);
    }
    try out.append(gpa, '\'');
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var opts: diff.Options = .{};
    var style_set = false;
    var context_given: ?usize = null;
    var as_json = false;
    var digits: std.ArrayList(u8) = .empty;
    var excludes: std.ArrayList([]const u8) = .empty;
    var ignores: std.ArrayList([]const u8) = .empty;
    var nlabels: usize = 0;
    var from_file: ?[]const u8 = null;
    var to_file: ?[]const u8 = null;
    var function_default = false;

    const longs = [_]getopt.Long{
        .{ .name = "normal", .id = O.normal },
        .{ .name = "brief", .id = 'q' },
        .{ .name = "report-identical-files", .id = 's' },
        .{ .name = "context", .arg = .optional, .id = O.context },
        .{ .name = "unified", .arg = .optional, .id = O.unified },
        .{ .name = "ed", .id = 'e' },
        .{ .name = "rcs", .id = 'n' },
        .{ .name = "side-by-side", .id = 'y' },
        .{ .name = "width", .arg = .required, .id = 'W' },
        .{ .name = "left-column", .id = O.left_column },
        .{ .name = "suppress-common-lines", .id = O.suppress_common },
        .{ .name = "show-c-function", .id = 'p' },
        .{ .name = "show-function-line", .arg = .required, .id = 'F' },
        .{ .name = "label", .arg = .required, .id = O.label },
        .{ .name = "expand-tabs", .id = 't' },
        .{ .name = "initial-tab", .id = 'T' },
        .{ .name = "tabsize", .arg = .required, .id = O.tabsize },
        .{ .name = "suppress-blank-empty", .id = O.suppress_blank_empty },
        .{ .name = "paginate", .id = 'l' },
        .{ .name = "recursive", .id = 'r' },
        .{ .name = "no-dereference", .id = O.no_deref },
        .{ .name = "new-file", .id = 'N' },
        .{ .name = "unidirectional-new-file", .id = O.unidirectional },
        .{ .name = "ignore-file-name-case", .id = O.ign_name_case },
        .{ .name = "no-ignore-file-name-case", .id = O.no_ign_name_case },
        .{ .name = "exclude", .arg = .required, .id = 'x' },
        .{ .name = "exclude-from", .arg = .required, .id = 'X' },
        .{ .name = "starting-file", .arg = .required, .id = 'S' },
        .{ .name = "from-file", .arg = .required, .id = O.from_file },
        .{ .name = "to-file", .arg = .required, .id = O.to_file },
        .{ .name = "ignore-case", .id = 'i' },
        .{ .name = "ignore-tab-expansion", .id = 'E' },
        .{ .name = "ignore-trailing-space", .id = 'Z' },
        .{ .name = "ignore-space-change", .id = 'b' },
        .{ .name = "ignore-all-space", .id = 'w' },
        .{ .name = "ignore-blank-lines", .id = 'B' },
        .{ .name = "ignore-matching-lines", .arg = .required, .id = 'I' },
        .{ .name = "text", .id = 'a' },
        .{ .name = "strip-trailing-cr", .id = O.strip_cr },
        .{ .name = "ifdef", .arg = .required, .id = 'D' },
        .{ .name = "old-group-format", .arg = .required, .id = O.old_group },
        .{ .name = "new-group-format", .arg = .required, .id = O.new_group },
        .{ .name = "unchanged-group-format", .arg = .required, .id = O.unchanged_group },
        .{ .name = "changed-group-format", .arg = .required, .id = O.changed_group },
        .{ .name = "line-format", .arg = .required, .id = O.line_format },
        .{ .name = "old-line-format", .arg = .required, .id = O.old_line },
        .{ .name = "new-line-format", .arg = .required, .id = O.new_line },
        .{ .name = "unchanged-line-format", .arg = .required, .id = O.unchanged_line },
        .{ .name = "minimal", .id = 'd' },
        .{ .name = "horizon-lines", .arg = .required, .id = O.horizon },
        .{ .name = "speed-large-files", .id = 'H' },
        .{ .name = "color", .arg = .optional, .id = O.color },
        .{ .name = "palette", .arg = .required, .id = O.palette },
        .{ .name = "binary", .id = 'h' },
        .{ .name = "json", .id = O.json },
    };
    var parser = getopt.Parser.init(ctx, "0123456789abBcC:dD:eEfF:hHI:ilL:nNpPqrsS:tTuU:vwW:x:X:yZ", &longs);
    parser.ext_min = O.json;
    parser.try_prefix = true;
    defer parser.deinit();

    var fmt: diff.Formats = .{};
    var fmt_any = false;
    while (true) {
        const item = parser.next();
        switch (item) {
            .done => break,
            .bad => return 2,
            .opt => {},
        }
        const o = item.opt;
        const is_digit = o.id >= '0' and o.id <= '9' and !o.is_long;
        if (is_digit) {
            digits.append(arena, @intCast(o.id)) catch return oom(ctx);
            context_given = parseCount(digits.items);
            continue;
        } else digits.clearRetainingCapacity();
        switch (o.id) {
            'a' => opts.text = true,
            'b' => {
                if (!opts.flags.ignore_all_space) opts.flags.ignore_space_change = true;
            },
            'w' => {
                opts.flags.ignore_all_space = true;
                opts.flags.ignore_space_change = false;
            },
            'B' => opts.ignore_blank_lines = true,
            'E' => opts.flags.ignore_tab_expansion = true,
            'Z' => opts.flags.ignore_trailing_space = true,
            'i' => opts.flags.ignore_case = true,
            'c' => {
                if (!setStyle(ctx, &opts, &style_set, .context)) return 2;
            },
            'C', O.context => {
                if (!setStyle(ctx, &opts, &style_set, .context)) return 2;
                if (o.arg) |a| context_given = parseCount(a) orelse return usage(ctx, "invalid context length '{s}'", .{a});
            },
            'u' => {
                if (!setStyle(ctx, &opts, &style_set, .unified)) return 2;
            },
            'U', O.unified => {
                if (!setStyle(ctx, &opts, &style_set, .unified)) return 2;
                if (o.arg) |a| context_given = parseCount(a) orelse return usage(ctx, "invalid context length '{s}'", .{a});
            },
            'e' => {
                if (!setStyle(ctx, &opts, &style_set, .ed)) return 2;
            },
            'f' => {
                if (!setStyle(ctx, &opts, &style_set, .forward_ed)) return 2;
            },
            'n' => {
                if (!setStyle(ctx, &opts, &style_set, .rcs)) return 2;
            },
            O.normal => {
                if (!setStyle(ctx, &opts, &style_set, .normal)) return 2;
            },
            'y' => {
                if (!setStyle(ctx, &opts, &style_set, .side_by_side)) return 2;
            },
            'D' => {
                if (!setStyle(ctx, &opts, &style_set, .ifdef)) return 2;
                opts.ifdef_name = o.arg.?;
            },
            O.old_group, O.new_group, O.unchanged_group, O.changed_group, O.line_format, O.old_line, O.new_line, O.unchanged_line => {
                if (!setStyle(ctx, &opts, &style_set, .ifdef)) return 2;
                fmt_any = true;
                const a = o.arg.?;
                switch (o.id) {
                    O.old_group => fmt.old_group = a,
                    O.new_group => fmt.new_group = a,
                    O.unchanged_group => fmt.unchanged_group = a,
                    O.changed_group => fmt.changed_group = a,
                    O.line_format => {
                        fmt.old_line = a;
                        fmt.new_line = a;
                        fmt.unchanged_line = a;
                    },
                    O.old_line => fmt.old_line = a,
                    O.new_line => fmt.new_line = a,
                    else => fmt.unchanged_line = a,
                }
            },
            'W' => {
                const v = parseCount(o.arg.?) orelse 0;
                if (v == 0) return usage(ctx, "invalid width '{s}'", .{o.arg.?});
                opts.width = v;
            },
            O.tabsize => {
                const v = parseCount(o.arg.?) orelse 0;
                if (v == 0) return usage(ctx, "invalid tabsize '{s}'", .{o.arg.?});
                opts.tab_size = v;
            },
            O.horizon => {
                opts.flags.horizon_lines = parseCount(o.arg.?) orelse return usage(ctx, "invalid horizon length '{s}'", .{o.arg.?});
            },
            O.left_column => opts.left_column = true,
            O.suppress_common => opts.suppress_common_lines = true,
            'p' => function_default = true,
            'F' => opts.function_regexp = o.arg.?,
            O.label => {
                if (nlabels >= 2) {
                    cli.warn(ctx, "too many file label options", .{});
                    return 2;
                }
                opts.labels[nlabels] = o.arg.?;
                nlabels += 1;
            },
            't' => opts.expand_tabs = true,
            'T' => opts.initial_tab = true,
            O.suppress_blank_empty => opts.suppress_blank_empty = true,
            'l' => {},
            'r' => opts.recursive = true,
            O.no_deref => opts.no_dereference = true,
            'N' => opts.new_file = true,
            'P', O.unidirectional => opts.unidirectional_new_file = true,
            O.ign_name_case => opts.ignore_file_name_case = true,
            O.no_ign_name_case => opts.ignore_file_name_case = false,
            'x' => excludes.append(arena, o.arg.?) catch return oom(ctx),
            'X' => {
                if (!readPatterns(ctx, arena, o.arg.?, &excludes)) return 2;
            },
            'S' => opts.starting_file = o.arg.?,
            O.from_file => from_file = o.arg.?,
            O.to_file => to_file = o.arg.?,
            'I' => ignores.append(arena, o.arg.?) catch return oom(ctx),
            O.strip_cr => opts.strip_trailing_cr = true,
            'd' => opts.flags.minimal = true,
            'H' => opts.flags.speed_large_files = true,
            'h' => {},
            'q' => opts.brief = true,
            's' => opts.report_identical = true,
            O.color => {
                if (o.arg) |a| {
                    if (std.mem.eql(u8, a, "always") or std.mem.eql(u8, a, "yes") or std.mem.eql(u8, a, "force")) opts.color = true else if (std.mem.eql(u8, a, "never") or std.mem.eql(u8, a, "no") or std.mem.eql(u8, a, "none")) opts.color = false else if (std.mem.eql(u8, a, "auto") or std.mem.eql(u8, a, "tty") or std.mem.eql(u8, a, "if-tty")) opts.color = stdoutIsTty(ctx) else return usage(ctx, "invalid color '{s}'", .{a});
                } else opts.color = stdoutIsTty(ctx);
            },
            O.palette => parsePalette(&opts.palette, o.arg.?),
            O.json => as_json = true,
            'v', getopt.version_id => return if (cli.printVersion(ctx)) 0 else 2,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 2,
            else => unreachable,
        }
    }
    if (function_default and opts.function_regexp == null) opts.function_regexp = "^[[:alpha:]$_]";
    if (fmt_any) opts.formats = fmt;
    opts.json = as_json;
    if (as_json) {
        if (opts.style != .normal or style_set) return usage(ctx, "option --json is incompatible with an output style", .{});
        if (opts.expand_tabs or opts.initial_tab or opts.suppress_blank_empty or opts.color) return usage(ctx, "option --json is incompatible with text layout options", .{});
    }
    if (context_given) |c| opts.context = c;
    opts.exclude = excludes.items;
    opts.ignore_matching = ignores.items;
    if (from_file != null and to_file != null) {
        cli.warn(ctx, "--from-file and --to-file both specified", .{});
        return 2;
    }

    const ops = parser.operands.items;
    // Words of the command line that were options, for "diff -r a b" lines.
    {
        var sw: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        for (ctx.args) |a| {
            if (std.mem.eql(u8, a, "--")) continue;
            if (k < ops.len and std.mem.eql(u8, a, ops[k])) {
                k += 1;
                continue;
            }
            shellWord(arena, &sw, a) catch return oom(ctx);
        }
        opts.switch_string = sw.items;
    }

    var pairs: std.ArrayList([2][]const u8) = .empty;
    if (from_file != null or to_file != null) {
        for (ops) |op| {
            const pair: [2][]const u8 = if (from_file) |f| .{ f, op } else .{ op, to_file.? };
            pairs.append(arena, pair) catch return oom(ctx);
        }
    } else {
        if (ops.len < 2) {
            const last: []const u8 = if (ctx.args.len > 0) ctx.args[ctx.args.len - 1] else ctx.name;
            return usage(ctx, "missing operand after '{s}'", .{last});
        }
        if (ops.len > 2) return usage(ctx, "extra operand '{s}'", .{ops[2]});
        pairs.append(arena, .{ ops[0], ops[1] }) catch return oom(ctx);
    }

    var buf: [16384]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: diff.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    var status: u8 = 0;
    for (pairs.items) |pr| {
        const st = diff.run(env, opts, pr[0], pr[1], &stdout.interface, .{ .context = @constCast(&ctx), .func = report }) catch |e| switch (e) {
            error.OutOfMemory => {
                cli.warn(ctx, "memory exhausted", .{});
                return 2;
            },
            error.BadRegex => {
                cli.warn(ctx, "invalid regular expression", .{});
                return 2;
            },
            error.Unsupported => {
                cli.warn(ctx, "this output style is not supported yet", .{});
                return 2;
            },
            else => {
                cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
                cli.writeErrorWarn(ctx);
                return 2;
            },
        };
        if (st > status) status = st;
    }
    stdout.interface.flush() catch {
        cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
        cli.writeErrorWarn(ctx);
        return 2;
    };
    return status;
}

fn setStyle(ctx: cli.Context, opts: *diff.Options, set: *bool, st: diff.Style) bool {
    if (set.* and opts.style != st) {
        _ = usage(ctx, "conflicting output style options", .{});
        return false;
    }
    set.* = true;
    opts.style = st;
    return true;
}

fn stdoutIsTty(ctx: cli.Context) bool {
    return Io.File.stdout().isTty(ctx.io) catch false;
}

fn parsePalette(p: *diff.Palette, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, ':');
    while (it.next()) |item| {
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
        const key = item[0..eq];
        const val = item[eq + 1 ..];
        if (std.mem.eql(u8, key, "ad")) p.add = val else if (std.mem.eql(u8, key, "de")) p.delete = val else if (std.mem.eql(u8, key, "hd")) p.header = val else if (std.mem.eql(u8, key, "ln")) p.hunk = val else if (std.mem.eql(u8, key, "cc")) p.context = val;
    }
}

fn readPatterns(ctx: cli.Context, arena: std.mem.Allocator, path: []const u8, list: *std.ArrayList([]const u8)) bool {
    const data = blk: {
        const f = (if (std.mem.eql(u8, path, "-")) Io.File.stdin() else Io.Dir.cwd().openFile(ctx.io, path, .{})) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            return false;
        };
        defer if (!std.mem.eql(u8, path, "-")) f.close(ctx.io);
        var all: std.ArrayList(u8) = .empty;
        var b: [8192]u8 = undefined;
        while (true) {
            const n = cli_readChunk(ctx.io, f, &b) catch |e| {
                cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
                return false;
            };
            if (n == 0) break;
            all.appendSlice(arena, b[0..n]) catch return false;
        }
        break :blk all.items;
    };
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        list.append(arena, line) catch return false;
    }
    return true;
}

fn cli_readChunk(io: Io, f: Io.File, buf: []u8) !usize {
    return cli.readChunk(io, f, buf);
}

fn report(context: ?*anyopaque, ev: diff.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .file_error => |e| cli.warn(ctx.*, "{s}: {s}", .{ e.name, cli.errText(e.err) }),
        .no_newline => |n| cli.writeStderrNoNl(ctx.*, "{s}: {s}: No newline at end of file\n\n", .{ ctx.name, n }),
        .fatal => |t| cli.warn(ctx.*, "{s}", .{t}),
    }
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 2;
}
