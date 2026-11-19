// SPDX-License-Identifier: GPL-2.0-or-later
//! cut — select bytes, characters or fields from each line.
//! References: GNU coreutils manual "cut invocation" (9.7); POSIX.1-2024 cut.
//!
//! Characters are bytes (C locale): -c is the same as -b and -n is accepted
//! and ignored, which matches GNU's behaviour in a single-byte locale; the
//! multibyte behaviour of UTF-8 locales is not implemented.
//! GNU extensions: --complement, --output-delimiter, -z, long options.

const std = @import("std");
const cli = @import("../cli.zig");
const cut = @import("../lib/cut.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "bytes", "characters", "fields", "delimiter", "only-delimited", "output-delimiter", "complement", "zero-terminated", "help", "version" };


const Mode = enum { none, bytes, fields };

pub fn main(ctx: cli.Context) u8 {
    var mode: Mode = .none;
    var list_text: ?[]const u8 = null;
    var delim: ?u8 = null;
    var only_delimited = false;
    var out_delim: ?[]const u8 = null;
    var complement = false;
    var line_delim: u8 = '\n';
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);

    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
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
            switch (k) {
                0, 1, 2, 3, 5 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                            return 1;
                        }
                        val = args[i];
                    }
                    switch (k) {
                        0, 1 => if (!setList(ctx, &mode, &list_text, .bytes, val)) return 1,
                        2 => if (!setList(ctx, &mode, &list_text, .fields, val)) return 1,
                        3 => if (!setDelim(ctx, &delim, val)) return 1,
                        else => out_delim = val,
                    }
                },
                4 => only_delimited = true,
                6 => complement = true,
                7 => line_delim = 0,
                8 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'n' => {},
            's' => only_delimited = true,
            'z' => line_delim = 0,
            'b', 'c', 'f', 'd' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                const ok = switch (a[j]) {
                    'b', 'c' => setList(ctx, &mode, &list_text, .bytes, val),
                    'f' => setList(ctx, &mode, &list_text, .fields, val),
                    else => setDelim(ctx, &delim, val),
                };
                if (!ok) return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    if (mode == .none) {
        cli.warn(ctx, "you must specify a list of bytes, characters, or fields\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (mode == .bytes and delim != null) {
        cli.warn(ctx, "an input delimiter may be specified only when operating on fields\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (mode == .bytes and only_delimited) {
        cli.warn(ctx, "suppressing non-delimited lines makes sense\n\tonly when operating on fields\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    const ranges = parseList(ctx, list_text.?, mode == .fields) orelse return 1;
    defer ctx.gpa.free(ranges);

    var inputs: std.ArrayList(cut.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        inputs.append(ctx.gpa, .{ .name = "-", .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (files.items) |path| {
        const in: cut.Input = if (std.mem.eql(u8, path, "-"))
            .{ .name = path, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = path, .source = .{ .path = path } };
        inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: cut.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = cut.run(env, .{
        .mode = if (mode == .bytes) .bytes else .fields,
        .ranges = ranges,
        .complement = complement,
        .delimiter = delim orelse '\t',
        .only_delimited = only_delimited,
        .output_delimiter = out_delim,
        .line_delimiter = line_delim,
    }, inputs.items, &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    return if (result.failed) 1 else 0;
}
fn setList(ctx: cli.Context, mode: *Mode, text: *?[]const u8, want: Mode, val: []const u8) bool {
    if (mode.* != .none and mode.* != want) {
        cli.warn(ctx, "only one list may be specified\nTry '{s} --help' for more information.", .{ctx.name});
        return false;
    }
    mode.* = want;
    text.* = val;
    return true;
}

fn setDelim(ctx: cli.Context, delim: *?u8, val: []const u8) bool {
    if (val.len > 1) {
        cli.warn(ctx, "the delimiter must be a single character\nTry '{s} --help' for more information.", .{ctx.name});
        return false;
    }
    delim.* = if (val.len == 0) 0 else val[0];
    return true;
}

/// Parse the position list, wording GNU cut's diagnostics for a bad one.
fn parseList(ctx: cli.Context, text: []const u8, fields: bool) ?[]cut.Range {
    var problem: cut.ListProblem = undefined;
    return cut.parseList(ctx.gpa, text, &problem) catch |e| {
        if (e == error.OutOfMemory) return null;
        switch (problem) {
            .no_endpoint => cli.warn(ctx, "invalid range with no endpoint: -\nTry '{s} --help' for more information.", .{ctx.name}),
            .zero_position => cli.warn(ctx, "{s} are numbered from 1\nTry '{s} --help' for more information.", .{ if (fields) "fields" else "byte/character positions", ctx.name }),
            .bad_value => |tok| if (fields) {
                cli.warn(ctx, "invalid field value '{s}'\nTry '{s} --help' for more information.", .{ tok, ctx.name });
            } else cli.warn(ctx, "invalid byte/character position '{s}'\nTry '{s} --help' for more information.", .{ tok, ctx.name }),
            .decreasing => cli.warn(ctx, "invalid decreasing range\nTry '{s} --help' for more information.", .{ctx.name}),
        }
        return null;
    };
}

fn report(context: ?*anyopaque, ev: cut.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    cli.warn(ctx.*, "{s}: {s}", .{ ev.name, cli.errText(ev.err) });
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: cut OPTION... [FILE]...\n" ++
        "Print selected parts of lines from each FILE to standard output.\n\n" ++
        "  -b, --bytes=LIST        select only these bytes\n" ++
        "  -c, --characters=LIST   select only these characters\n" ++
        "  -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter\n" ++
        "  -f, --fields=LIST       select only these fields; also print any line\n" ++
        "                            that contains no delimiter character, unless\n" ++
        "                            the -s option is specified\n" ++
        "  -n                      (ignored)\n" ++
        "      --complement        complement the set of selected bytes, characters\n" ++
        "                            or fields\n" ++
        "  -s, --only-delimited    do not print lines not containing delimiters\n" ++
        "      --output-delimiter=STRING  use STRING as the output delimiter\n" ++
        "                            the default is to use the input delimiter\n" ++
        "  -z, --zero-terminated   line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n\n" ++
        "Use one, and only one of -b, -c or -f.  Each LIST is made up of one\n" ++
        "range, or many ranges separated by commas.\n")) 0 else 1;
}
