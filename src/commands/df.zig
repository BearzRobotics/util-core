// SPDX-License-Identifier: GPL-2.0-or-later
//! df — report file system space usage.
//! Thin wrapper over `util_core.df` (decision 0004): GNU's option parsing and
//! conflicts, the --output field list syntax and the wording of diagnostics
//! are here; the mount table, the file system selection, the table layout and
//! the --json output are in src/lib/df.zig.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "df invocation"
//! (9.7), POSIX.1-2024 df, and GNU coreutils 9.6 src/df.c.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const human = @import("../human.zig");
const df = @import("../lib/df.zig");
const Io = std.Io;

const help_text = @embedFile("../help/df.txt");

/// The option state the parser fills in; becomes a `df.Options`.
const S = struct {
    ctx: cli.Context,
    show_all: bool = false,
    show_local: bool = false,
    human_opts: i32 = -1,
    block_size: u64 = 0,
    require_sync: bool = false,
    select_types: std.ArrayList([]const u8) = .empty,
    exclude_types: std.ArrayList([]const u8) = .empty,
    print_type: bool = false,
    json: bool = false,
    print_grand_total: bool = false,
    header_mode: df.HeaderMode = .default,
    output_fields: std.ArrayList(df.Field) = .empty,
    output_used: [12]bool = @splat(false),
};

/// Words the library's events as GNU does.
const Report = struct {
    ctx: cli.Context,

    fn report(context: ?*anyopaque, ev: df.Event) void {
        const self: *Report = @ptrCast(@alignCast(context.?));
        const ctx = self.ctx;
        switch (ev) {
            .cannot_stat => |e| cli.warn(ctx, "{f}: {s}", .{ cli.quote(e.name), sys.errnoText(e.errno) }),
            .over_mounted => |file| cli.warn(ctx, "cannot access {f}: over-mounted by another device", .{cli.quoteA(file)}),
            .mount_table_unreadable => |e| cli.warn(ctx, "{s}cannot read table of mounted file systems: {s}", .{ if (e.fatal) "" else "Warning: ", "No such file or directory" }),
            .no_file_systems_processed => cli.warn(ctx, "no file systems processed", .{}),
        }
    }
};

/// --output: add the fields of one comma-separated list; false (after the
/// diagnostic) on an unknown or repeated field.
fn decodeOutputArg(s: *S, arg: []const u8) bool {
    const ctx = s.ctx;
    var it = std.mem.splitScalar(u8, arg, ',');
    while (it.next()) |tok| {
        const f = df.Field.parse(tok) orelse {
            cli.warn(ctx, "option --output: field {f} unknown", .{cli.quoteC(tok)});
            return false;
        };
        if (s.output_used[@intFromEnum(f)]) {
            cli.warn(ctx, "option --output: field {f} used more than once", .{cli.quoteC(f.name())});
            return false;
        }
        s.output_fields.append(ctx.gpa, f) catch {};
        s.output_used[@intFromEnum(f)] = true;
    }
    return true;
}

fn xstrtolFatal(ctx: cli.Context, e: human.StrtolError, o: getopt.Opt, arg: []const u8) void {
    const name: []const u8 = if (o.is_long) "--block-size" else "-B";
    switch (e) {
        .invalid => cli.warn(ctx, "invalid {s} argument {f}", .{ name, cli.quoteC(arg) }),
        .invalid_suffix_char, .invalid_suffix_char_with_overflow => cli.warn(ctx, "invalid suffix in {s} argument {f}", .{ name, cli.quoteC(arg) }),
        .overflow => cli.warn(ctx, "{s} argument {f} too large", .{ name, cli.quoteC(arg) }),
        .ok => {},
    }
}

pub fn main(ctx: cli.Context) u8 {
    var s: S = .{ .ctx = ctx };
    defer {
        s.select_types.deinit(ctx.gpa);
        s.exclude_types.deinit(ctx.gpa);
        s.output_fields.deinit(ctx.gpa);
    }
    return realMain(&s);
}

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

fn realMain(s: *S) u8 {
    const ctx = s.ctx;
    var posix_format = false;
    var p = getopt.Parser.init(ctx, "aB:iF:hHklmPTt:vx:", &.{
        .{ .name = "all", .id = 'a' },
        .{ .name = "block-size", .arg = .required, .id = 'B' },
        .{ .name = "inodes", .id = 'i' },
        .{ .name = "human-readable", .id = 'h' },
        .{ .name = "si", .id = 'H' },
        .{ .name = "local", .id = 'l' },
        .{ .name = "output", .arg = .optional, .id = 1100 },
        .{ .name = "portability", .id = 'P' },
        .{ .name = "print-type", .id = 'T' },
        .{ .name = "sync", .id = 1101 },
        .{ .name = "no-sync", .id = 1102 },
        .{ .name = "total", .id = 1103 },
        .{ .name = "type", .arg = .required, .id = 't' },
        .{ .name = "exclude-type", .arg = .required, .id = 'x' },
        .{ .name = "json", .id = 1104 },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'a' => s.show_all = true,
            'B' => {
                const bs = human.options(o.arg.?, null, false);
                if (bs.err != .ok) {
                    xstrtolFatal(ctx, bs.err, o, o.arg.?);
                    return 1;
                }
                s.human_opts = @intCast(bs.opts);
                s.block_size = bs.size;
            },
            'i' => {
                if (s.header_mode == .output) {
                    cli.warn(ctx, "options -i and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                s.header_mode = .inodes;
            },
            'h' => {
                s.human_opts = @intCast(human.autoscale | human.si | human.base_1024);
                s.block_size = 1;
            },
            'H' => {
                s.human_opts = @intCast(human.autoscale | human.si);
                s.block_size = 1;
            },
            'k' => {
                s.human_opts = 0;
                s.block_size = 1024;
            },
            'l' => s.show_local = true,
            'm' => {
                s.human_opts = 0;
                s.block_size = 1024 * 1024;
            },
            'T' => {
                if (s.header_mode == .output) {
                    cli.warn(ctx, "options -T and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                s.print_type = true;
            },
            'P' => {
                if (s.header_mode == .output) {
                    cli.warn(ctx, "options -P and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                posix_format = true;
            },
            1101 => s.require_sync = true,
            1102 => s.require_sync = false,
            'F', 't' => s.select_types.insert(ctx.gpa, 0, o.arg.?) catch {},
            'v' => {},
            'x' => s.exclude_types.insert(ctx.gpa, 0, o.arg.?) catch {},
            1100 => {
                if (s.header_mode == .inodes) {
                    cli.warn(ctx, "options -i and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                if (posix_format and s.header_mode == .default) {
                    cli.warn(ctx, "options -P and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                if (s.print_type) {
                    cli.warn(ctx, "options -T and --output are mutually exclusive", .{});
                    return usageFail(ctx);
                }
                s.header_mode = .output;
                if (o.arg) |a| if (!decodeOutputArg(s, a)) return usageFail(ctx);
            },
            1103 => s.print_grand_total = true,
            1104 => s.json = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };

    if (s.json and (s.human_opts != -1 or s.header_mode != .default or s.print_type or posix_format)) {
        cli.warn(ctx, "--json cannot be combined with -B, -h, -H, -k, -m, -i, -P, -T or --output", .{});
        return usageFail(ctx);
    }
    if (s.human_opts == -1) {
        if (posix_format) {
            s.human_opts = 0;
            s.block_size = if (cli.getenv(ctx, "POSIXLY_CORRECT") != null) 512 else 1024;
        } else {
            const env_bs = cli.getenv(ctx, "BLOCK_SIZE") orelse cli.getenv(ctx, "BLOCKSIZE");
            const bs = human.options(cli.getenv(ctx, "DF_BLOCK_SIZE"), env_bs, cli.getenv(ctx, "POSIXLY_CORRECT") != null);
            s.human_opts = @intCast(bs.opts);
            s.block_size = bs.size;
        }
    }
    if (s.header_mode == .inodes or s.header_mode == .output) {
        // keep
    } else if ((@as(u32, @intCast(s.human_opts)) & human.autoscale) != 0) {
        s.header_mode = .human;
    } else if (posix_format) s.header_mode = .posix;

    {
        var matched = false;
        for (s.select_types.items) |inc| {
            for (s.exclude_types.items) |exc| {
                if (std.mem.eql(u8, inc, exc)) {
                    cli.warn(ctx, "file system type {f} both selected and excluded", .{cli.quoteC(inc)});
                    matched = true;
                    break;
                }
            }
        }
        if (matched) return 1;
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    var rep: Report = .{ .ctx = ctx };
    const env: df.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = df.run(env, .{
        .show_all = s.show_all,
        .show_local = s.show_local,
        .select_types = s.select_types.items,
        .exclude_types = s.exclude_types.items,
        .human_opts = @intCast(s.human_opts),
        .block_size = s.block_size,
        .header_mode = s.header_mode,
        .output_fields = s.output_fields.items,
        .print_type = s.print_type,
        .grand_total = s.print_grand_total,
        .json = s.json,
    }, p.operands.items, &stdout.interface, .{ .context = &rep, .func = Report.report }) catch |e| switch (e) {
        error.OutOfMemory => return 1,
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            return 1;
        },
    };
    if (!cli.flushWriter(&stdout)) return 1;
    return result.status;
}
