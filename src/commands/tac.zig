//! tac — concatenate and print files in reverse.
//! Reference: GNU coreutils manual "tac invocation" (9.7). POSIX does not
//! specify tac.
//!
//! Each file is read completely into memory, split into records, and the
//! records are written last to first. Options: -b (separator attached before
//! the record), -s SEP (record separator; empty means NUL). Not implemented:
//! -r (regular-expression separator) is rejected with an error.

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "before", "regex", "separator", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var before = false;
    var sep: []const u8 = "\n";
    const args = ctx.args;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
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
                0 => before = true,
                1 => return regexUnsupported(ctx),
                2 => {
                    if (eq) |e| {
                        sep = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--separator' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        sep = args[i];
                    }
                },
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'b' => before = true,
            'r' => return regexUnsupported(ctx),
            's' => {
                if (j + 1 < a.len) {
                    sep = a[j + 1 ..];
                } else {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 's'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    sep = args[i];
                }
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }
    if (sep.len == 0) sep = "\x00"; // GNU: an empty separator means NUL

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;

    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.gpa);
    var buf: [64 * 1024]u8 = undefined;
    for (inputs) |path| {
        data.clearRetainingCapacity();
        readAll(ctx, path, &data, &buf) catch |e| {
            if (e != error.Reported) cli.warn(ctx, "{s}: read error: {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
        reverseRecords(&out, data.items, sep, before);
    }
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return status;
}

fn readAll(ctx: cli.Context, path: []const u8, data: *std.ArrayList(u8), buf: []u8) !void {
    const file = cli.openInput(ctx.io, path) catch |e| {
        cli.warn(ctx, "failed to open '{s}' for reading: {s}", .{ path, cli.errText(e) });
        return error.Reported;
    };
    defer cli.closeInput(ctx.io, file);
    while (true) {
        const n = try cli.readChunk(ctx.io, file, buf);
        if (n == 0) return;
        try data.appendSlice(ctx.gpa, buf[0..n]);
    }
}

/// Write the records of `data` in reverse order. Records end with `sep`
/// (default) or start with it (`before`); the unterminated piece at the far
/// end of the file is a record too.
pub fn reverseRecords(out: *cli.Out, data: []const u8, sep: []const u8, before: bool) void {
    var end = data.len; // exclusive end of the not-yet-written prefix
    if (before) {
        // Records begin at a separator: [sep rec][sep rec]... with a possible
        // leading piece that has no separator.
        while (end > 0) {
            const start = std.mem.lastIndexOf(u8, data[0..end], sep) orelse 0;
            out.write(data[start..end]);
            end = start;
        }
    } else {
        // Records end at a separator. The final piece after the last separator
        // (if any) is unterminated and forms the last record.
        var cur = data.len;
        if (cur >= sep.len and std.mem.endsWith(u8, data, sep)) cur -= sep.len; // terminator of the last record
        while (end > 0) {
            const start = if (std.mem.lastIndexOf(u8, data[0..cur], sep)) |p| p + sep.len else 0;
            out.write(data[start..end]);
            end = start;
            cur = if (start >= sep.len) start - sep.len else 0;
            if (start == 0) break;
        }
    }
}

fn regexUnsupported(ctx: cli.Context) u8 {
    cli.warn(ctx, "option -r/--regex is not supported yet", .{});
    return 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tac [OPTION]... [FILE]...\n" ++
        "Write each FILE to standard output, last line first.\n\n" ++
        "  -b, --before             attach the separator before instead of after\n" ++
        "  -r, --regex              interpret the separator as a regular expression\n" ++
        "  -s, --separator=STRING   use STRING as the separator instead of newline\n" ++
        "      --help               display this help and exit\n" ++
        "      --version            output version information and exit\n")) 0 else 1;
}
