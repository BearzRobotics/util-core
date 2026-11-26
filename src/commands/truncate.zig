// SPDX-License-Identifier: GPL-2.0-or-later
//! truncate: thin wrapper over `util_core.truncate` (decision 0004). Parses
//! the arguments and the SIZE operand and words the diagnostics.

const std = @import("std");
const cli = @import("../cli.zig");
const count_arg = @import("../count_arg.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "no-create", "io-blocks", "reference", "size", "help", "version" };

const truncate = @import("../lib/truncate.zig");
const Rel = truncate.Rel;

pub fn main(ctx: cli.Context) u8 {
    var no_create = false;
    var io_blocks = false;
    var reference: ?[]const u8 = null;
    var size_text: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            const takes = k == 2 or k == 3;
            if (takes and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                    return 1;
                }
                value = ctx.args[i];
            } else if (!takes and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => no_create = true,
                1 => io_blocks = true,
                2 => reference = value,
                3 => size_text = value,
                4 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'c' => no_create = true,
            'o' => io_blocks = true,
            'r', 's' => {
                var value: []const u8 = a[j + 1 ..];
                if (value.len == 0) {
                    i += 1;
                    if (i >= ctx.args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    value = ctx.args[i];
                }
                if (a[j] == 'r') reference = value else size_text = value;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }
    if (reference == null and size_text == null) {
        cli.warn(ctx, "you must specify either '--size' or '--reference'\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (files.items.len == 0) {
        cli.warn(ctx, "missing file operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var rel: Rel = .none;
    var amount: u64 = 0;
    if (size_text) |t| {
        var s = t;
        if (s.len > 0) switch (s[0]) {
            '+' => rel = .extend,
            '-' => rel = .reduce,
            '<' => rel = .at_most,
            '>' => rel = .at_least,
            '/' => rel = .round_down,
            '%' => rel = .round_up,
            else => {},
        };
        if (rel != .none) s = s[1..];
        const c = count_arg.parse(s);
        // truncate's suffixes are K, M, G... and KB, MB, ...; "b" (512) is not one of them.
        const bad_suffix = s.len > 0 and s[s.len - 1] == 'b' and (s.len < 2 or std.ascii.isDigit(s[s.len - 2]));
        if (c == null or c.?.sign != .none or s.len == 0 or !std.ascii.isDigit(s[0]) or bad_suffix) {
            // GNU shows the sign of +/- but not the other modifiers.
            cli.warn(ctx, "Invalid number: {f}", .{cli.quoteC(if (rel == .extend or rel == .reduce) t else s)});
            return 1;
        }
        amount = c.?.value;
        // count_arg saturates (head and tail treat that as "everything"); any
        // value that was clamped is beyond this limit too.
        if (amount > truncate.maxAmount(rel)) {
            cli.warn(ctx, "Invalid number: {f}: Value too large for defined data type", .{cli.quoteC(if (rel == .extend or rel == .reduce) t else s)});
            return 1;
        }
        if ((rel == .round_down or rel == .round_up) and amount == 0) {
            cli.warn(ctx, "division by zero", .{});
            return 1;
        }
    }
    if (reference != null and size_text != null and rel == .none) {
        cli.warn(ctx, "you must specify a relative '--size' with '--reference'\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    const cwd = Io.Dir.cwd();
    var ref_size: ?u64 = null;
    if (reference) |r| {
        const st = cwd.statFile(ctx.io, r, .{}) catch |e| {
            cli.warn(ctx, "cannot stat {f}: {s}", .{ cli.quoteA(r), cli.errText(e) });
            return 1;
        };
        ref_size = st.size;
        if (size_text == null) {
            amount = st.size;
        }
    }

    const env: truncate.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const ok = truncate.run(env, .{
        .no_create = no_create,
        .io_blocks = io_blocks,
        .rel = rel,
        .amount = amount,
        .ref_size = ref_size,
        .have_size = size_text != null,
    }, files.items, .{ .context = @constCast(&ctx), .func = report });
    return if (ok) 0 else 1;
}

fn report(context: ?*anyopaque, ev: truncate.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .open_failed => |f| cli.warn(ctx.*, "cannot open {f} for writing: {s}", .{ cli.quoteA(f.path), sys.errnoText(f.errno) }),
        .size_failed => |f| if (f.err) |e|
            cli.warn(ctx.*, "cannot get the size of {f}: {s}", .{ cli.quoteA(f.path), cli.errText(e) })
        else
            cli.warn(ctx.*, "cannot get the size of {f}", .{cli.quoteA(f.path)}),
        .block_overflow => |f| cli.warn(ctx.*, "overflow in {s}{d} * {d} byte blocks for file {f}", .{ if (f.negative and f.blocks != 0) "-" else "", f.blocks, f.block_size, cli.quoteA(f.path) }),
        .extend_overflow => |f| cli.warn(ctx.*, "overflow extending size of file {f}", .{cli.quoteA(f.path)}),
        .truncate_failed => |f| cli.warn(ctx.*, "failed to truncate {f} at {d} bytes: {s}", .{ cli.quoteA(f.path), f.size, cli.errText(f.err) }),
    }
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: truncate OPTION... FILE...\nShrink or extend the size of each FILE to the specified size\n\nA FILE argument that does not exist is created.\n\nIf a FILE is larger than the specified size, the extra data is lost.\nIf a FILE is shorter, it is extended and the sparse extended part (hole)\nreads as zero bytes.\n\n  -c, --no-create        do not create any files\n  -o, --io-blocks        treat SIZE as number of IO blocks instead of bytes\n  -r, --reference=RFILE  base size on RFILE\n  -s, --size=SIZE        set or adjust the file size by SIZE bytes\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
