// SPDX-License-Identifier: GPL-2.0-or-later
//! numfmt: thin wrapper over `util_core.numfmt` (decision 0004). Parses the
//! options the way GNU numfmt does and words the diagnostics; the number
//! parsing, scaling and formatting are in src/lib/numfmt.zig.

const std = @import("std");
const numparse = @import("../numparse.zig");
const Io = std.Io;
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const numfmt = @import("../lib/numfmt.zig");

const help_text = @embedFile("../help/numfmt.txt");

fn argMatch(ctx: cli.Context, opt: []const u8, value: []const u8, names: []const []const u8) ?usize {
    var found: ?usize = null;
    var ambiguous = false;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, value)) return i;
        if (std.mem.startsWith(u8, n, value)) {
            if (found != null) ambiguous = true;
            found = i;
        }
    }
    if (found != null and !ambiguous) return found;
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    for (names) |nm| {
        const piece = std.fmt.bufPrint(buf[n..], "\n  - {f}", .{cli.quoteC(nm)}) catch break;
        n += piece.len;
    }
    cli.warn(ctx, "{s} argument {f} for {f}\nValid arguments are:{s}\nTry '{s} --help' for more information.", .{
        if (ambiguous) "ambiguous" else "invalid",
        cli.quoteC(value),
        cli.quoteC(opt),
        buf[0..n],
        ctx.name,
    });
    return null;
}

fn unitToU64(ctx: cli.Context, text: []const u8) ?u64 {
    return numfmt.parseUnit(text) orelse {
        cli.warn(ctx, "invalid unit size: {f}", .{cli.quoteC(text)});
        return null;
    };
}

/// Word a --field problem (GNU cut-style messages plus the usage hint).
fn fieldsProblem(ctx: cli.Context, pr: numfmt.FieldsProblem) void {
    switch (pr.kind) {
        .out_of_memory => return,
        .invalid_range => cli.warn(ctx, "invalid field range\nTry '{s} --help' for more information.", .{ctx.name}),
        .from_one => cli.warn(ctx, "fields are numbered from 1\nTry '{s} --help' for more information.", .{ctx.name}),
        .decreasing => cli.warn(ctx, "invalid decreasing range\nTry '{s} --help' for more information.", .{ctx.name}),
        .too_large => cli.warn(ctx, "field number {f} is too large\nTry '{s} --help' for more information.", .{ cli.quoteC(pr.text), ctx.name }),
        .invalid_value => cli.warn(ctx, "invalid field value {f}\nTry '{s} --help' for more information.", .{ cli.quoteC(pr.text), ctx.name }),
        .missing_list => cli.warn(ctx, "missing list of fields\nTry '{s} --help' for more information.", .{ctx.name}),
    }
}

fn formatProblem(ctx: cli.Context, e: numfmt.FormatError, fmt: []const u8) void {
    switch (e) {
        error.NoDirective => cli.warn(ctx, "format {f} has no % directive", .{cli.quoteC(fmt)}),
        error.EndsInPercent => cli.warn(ctx, "format {f} ends in %", .{cli.quoteC(fmt)}),
        error.InvalidPrecision => cli.warn(ctx, "invalid precision in format {f}", .{cli.quoteC(fmt)}),
        error.InvalidDirective => cli.warn(ctx, "invalid format {f}, directive must be %[0]['][-][N][.][N]f", .{cli.quoteC(fmt)}),
        error.TooManyDirectives => cli.warn(ctx, "format {f} has too many % directives", .{cli.quoteC(fmt)}),
    }
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var o: numfmt.Options = .{};
    var fields_owned: ?[]numfmt.Range = null;
    defer if (fields_owned) |f| gpa.free(f);
    const observer: numfmt.Observer = .{ .context = @constCast(&ctx), .func = report };
    var format_str: ?[]const u8 = null;
    var field_spec: ?[]const u8 = null;

    var p = getopt.Parser.init(ctx, "d:z", &.{
        .{ .name = "from", .arg = .required, .id = 1100 },
        .{ .name = "from-unit", .arg = .required, .id = 1101 },
        .{ .name = "to", .arg = .required, .id = 1102 },
        .{ .name = "to-unit", .arg = .required, .id = 1103 },
        .{ .name = "round", .arg = .required, .id = 1104 },
        .{ .name = "padding", .arg = .required, .id = 1105 },
        .{ .name = "suffix", .arg = .required, .id = 1106 },
        .{ .name = "grouping", .id = 1107 },
        .{ .name = "delimiter", .arg = .required, .id = 'd' },
        .{ .name = "field", .arg = .required, .id = 1108 },
        .{ .name = "debug", .id = 1109 },
        .{ .name = "header", .arg = .optional, .id = 1110 },
        .{ .name = "format", .arg = .required, .id = 1111 },
        .{ .name = "invalid", .arg = .required, .id = 1112 },
        .{ .name = "zero-terminated", .id = 'z' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |opt| switch (opt.id) {
            1100 => {
                const names = [_][]const u8{ "none", "auto", "si", "iec", "iec-i" };
                const k = argMatch(ctx, "--from", opt.arg.?, &names) orelse return 1;
                o.scale_from = @fromBackingInt(@intCast(k));
            },
            1101 => o.from_unit = unitToU64(ctx, opt.arg.?) orelse return 1,
            1102 => {
                const names = [_][]const u8{ "none", "si", "iec", "iec-i" };
                const k = argMatch(ctx, "--to", opt.arg.?, &names) orelse return 1;
                o.scale_to = switch (k) {
                    0 => .none,
                    1 => .si,
                    2 => .iec,
                    else => .iec_i,
                };
            },
            1103 => o.to_unit = unitToU64(ctx, opt.arg.?) orelse return 1,
            1104 => {
                const names = [_][]const u8{ "up", "down", "from-zero", "towards-zero", "nearest" };
                const k = argMatch(ctx, "--round", opt.arg.?, &names) orelse return 1;
                o.round = @fromBackingInt(@intCast(k));
            },
            1105 => {
                const v = numparse.parseInt(i64, opt.arg.?, 10) catch |e| blk: {
                    if (e == error.Overflow) break :blk @as(i64, if (opt.arg.?[0] == '-') std.math.minInt(i64) else std.math.maxInt(i64));
                    cli.warn(ctx, "invalid padding value {f}", .{cli.quoteC(opt.arg.?)});
                    return 1;
                };
                if (v == 0) {
                    cli.warn(ctx, "invalid padding value {f}", .{cli.quoteC(opt.arg.?)});
                    return 1;
                }
                o.padding_width = v;
            },
            1106 => o.suffix = opt.arg,
            1107 => o.grouping = true,
            'd' => {
                const a = opt.arg.?;
                if (a.len > 1) {
                    cli.warn(ctx, "the delimiter must be a single character", .{});
                    return 1;
                }
                o.delimiter = if (a.len == 0) 0 else a[0];
            },
            1108 => {
                if (field_spec != null) {
                    cli.warn(ctx, "multiple field specifications", .{});
                    return 1;
                }
                field_spec = opt.arg;
                var problem: numfmt.FieldsProblem = .{};
                fields_owned = numfmt.parseFields(gpa, opt.arg.?, &problem) orelse {
                    fieldsProblem(ctx, problem);
                    return 1;
                };
                o.fields = fields_owned;
            },
            1109 => o.debug = true,
            1110 => {
                if (opt.arg) |a| {
                    const v = numparse.parseInt(u64, a, 10) catch 0;
                    if (v == 0) {
                        cli.warn(ctx, "invalid header value {f}", .{cli.quoteC(a)});
                        return 1;
                    }
                    o.header = v;
                } else o.header = 1;
            },
            1111 => format_str = opt.arg,
            1112 => {
                const names = [_][]const u8{ "abort", "fail", "warn", "ignore" };
                const k = argMatch(ctx, "--invalid", opt.arg.?, &names) orelse return 1;
                o.invalid = @fromBackingInt(@intCast(k));
            },
            'z' => o.line_delim = 0,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };

    if (format_str != null and o.grouping) {
        cli.warn(ctx, "--grouping cannot be combined with --format", .{});
        return 1;
    }
    if (o.debug and o.scale_from == .none and o.scale_to == .none and !o.grouping and o.padding_width == 0 and format_str == null)
        cli.warn(ctx, "no conversion option specified", .{});
    if (format_str) |f| numfmt.applyFormat(&o, f, observer) catch |e| {
        formatProblem(ctx, e, f);
        return 1;
    };
    if (o.grouping) {
        if (o.scale_to != .none) {
            cli.warn(ctx, "grouping cannot be combined with --to", .{});
            return 1;
        }
        if (o.debug) cli.warn(ctx, "grouping has no effect in this locale", .{});
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: numfmt.Env = .{ .io = ctx.io, .gpa = gpa, .environ = ctx.environ };
    const operands = p.operands.items;
    var rbuf: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(ctx.io, &rbuf);
    const input: numfmt.Input = if (operands.len > 0) .{ .operands = operands } else .{ .reader = &stdin.interface };
    const result = numfmt.run(env, o, input, &stdout.interface, observer) catch |e| switch (e) {
        error.OutOfMemory => {
            cli.warn(ctx, "memory exhausted", .{});
            return 1;
        },
        error.ReadFailed => {
            cli.warn(ctx, "error reading input", .{});
            return 1;
        },
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    // --invalid=abort: output so far is flushed; exit at once with status 2.
    if (result.aborted) std.process.exit(2);
    if (!result.valid and o.invalid != .warn and o.invalid != .ignore) return 2;
    return 0;
}

fn report(context: ?*anyopaque, ev: numfmt.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .bad_number => |b| {
            const q = cli.quoteC(b.input);
            switch (b.kind) {
                .overflow => cli.warn(ctx.*, "value too large to be converted: {f}", .{q}),
                .invalid_number => cli.warn(ctx.*, "invalid number: {f}", .{q}),
                .forbidden_suffix => cli.warn(ctx.*, "rejecting suffix in input: {f} (consider using --from)", .{q}),
                .invalid_suffix => cli.warn(ctx.*, "invalid suffix in input: {f}", .{q}),
                .missing_i => cli.warn(ctx.*, "missing 'i' suffix in input: {f} (e.g Ki/Mi/Gi)", .{q}),
                else => {},
            }
        },
        .invalid_suffix_in_input => |b| cli.warn(ctx.*, "invalid suffix in input {f}: {f}", .{ cli.quoteC(b.input), cli.quoteC(b.rest) }),
        .precision_loss => |t| cli.warn(ctx.*, "large input value {f}: possible precision loss", .{cli.quoteC(t)}),
        .too_large_with_precision => |b| cli.warn(ctx.*, "value/precision too large to be printed: '{s}/{d}' (consider using --to)", .{ b.value, b.precision }),
        .too_large => |g| cli.warn(ctx.*, "value too large to be printed: '{s}' (consider using --to)", .{g}),
        .too_large_for_scale => |g| cli.warn(ctx.*, "value too large to be printed: '{s}' (cannot handle values > 999Q)", .{g}),
        .header_ignored => cli.warn(ctx.*, "--header ignored with command-line input", .{}),
        .padding_overridden => cli.warn(ctx.*, "--format padding overriding --padding", .{}),
        .some_failed => cli.warn(ctx.*, "failed to convert some of the input numbers", .{}),
    }
}
