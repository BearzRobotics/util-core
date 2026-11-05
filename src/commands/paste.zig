//! paste — merge corresponding lines of files.
//! References: GNU coreutils manual "paste invocation" (9.7); POSIX.1-2024
//! paste.
//!
//! Parallel mode joins line N of every file with the delimiters in -d (used
//! circularly, restarting for each output line); -s joins all lines of each
//! file. An exhausted file behaves like empty lines. Every `-` operand reads
//! successive lines from the one shared standard input. With no operand GNU
//! reads standard input (POSIX requires at least one).

const std = @import("std");
const cli = @import("../cli.zig");
const lines = @import("../lines.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "serial", "delimiters", "zero-terminated", "help", "version" };

const Source = struct {
    reader: *lines.LineReader,
    name: []const u8,
    done: bool = false,
};

pub fn main(ctx: cli.Context) u8 {
    var serial = false;
    var delim_text: []const u8 = "\t";
    var term: u8 = '\n';
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
                0 => serial = true,
                1 => {
                    if (eq) |e| {
                        delim_text = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--delimiters' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        delim_text = args[i];
                    }
                },
                2 => term = 0,
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            's' => serial = true,
            'z' => term = 0,
            'd' => {
                if (j + 1 < a.len) {
                    delim_text = a[j + 1 ..];
                } else {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 'd'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    delim_text = args[i];
                }
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    // Delimiters: each element is one byte or empty (from "\0").
    var delims: std.ArrayList([]const u8) = .empty;
    defer delims.deinit(ctx.gpa);
    if (!expandDelims(ctx, delim_text, &delims)) return 1;

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;

    // Open everything first. All "-" operands share one reader.
    var readers = ctx.gpa.alloc(lines.LineReader, inputs.len) catch return oom(ctx);
    defer ctx.gpa.free(readers);
    var sources = ctx.gpa.alloc(Source, inputs.len) catch return oom(ctx);
    defer ctx.gpa.free(sources);
    var opened: usize = 0;
    defer for (readers[0..opened]) |*r| {
        if (r.file.handle != Io.File.stdin().handle) r.file.close(ctx.io);
        r.deinit();
    };
    var stdin_idx: ?usize = null;
    var status: u8 = 0;
    for (inputs, 0..) |path, k| {
        if (std.mem.eql(u8, path, "-")) {
            if (stdin_idx == null) {
                readers[k] = lines.LineReader.init(ctx.gpa, ctx.io, Io.File.stdin(), term);
                opened = k + 1;
                stdin_idx = k;
            }
            sources[k] = .{ .reader = &readers[stdin_idx.?], .name = "standard input" };
            continue;
        }
        const file = cli.openInput(ctx.io, path) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            return 1;
        };
        readers[k] = lines.LineReader.init(ctx.gpa, ctx.io, file, term);
        opened = k + 1;
        sources[k] = .{ .reader = &readers[k], .name = path };
    }
    // `opened` counts a prefix; shared-stdin slots past a skipped index are
    // still initialised only when used, so make the unused ones inert.
    for (readers[opened..]) |*r| r.* = lines.LineReader.init(ctx.gpa, ctx.io, Io.File.stdin(), term);
    opened = readers.len;

    var out = cli.Out.init(ctx.io);
    if (serial) {
        status = pasteSerial(ctx, &out, sources, delims.items, term);
    } else status = pasteParallel(ctx, &out, sources, delims.items, term);
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return status;
}

fn nextLine(ctx: cli.Context, s: *Source, status: *u8) ?[]const u8 {
    if (s.done) return null;
    const l = s.reader.next() catch |e| {
        cli.warn(ctx, "{s}: {s}", .{ s.name, cli.errText(e) });
        status.* = 1;
        s.done = true;
        return null;
    };
    if (l) |line| return line.text;
    s.done = true;
    return null;
}

fn pasteParallel(ctx: cli.Context, out: *cli.Out, sources: []Source, delims: []const []const u8, term: u8) u8 {
    var status: u8 = 0;
    // One output row is assembled first: if every file is exhausted nothing
    // (not even the delimiters) is written for that round.
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(ctx.gpa);
    while (true) {
        row.clearRetainingCapacity();
        var got_any = false;
        for (sources, 0..) |*s, k| {
            if (nextLine(ctx, s, &status)) |t| {
                got_any = true;
                row.appendSlice(ctx.gpa, t) catch return 1;
            }
            if (k + 1 < sources.len and delims.len > 0) row.appendSlice(ctx.gpa, delims[k % delims.len]) catch return 1;
        }
        if (!got_any) return status;
        row.append(ctx.gpa, term) catch return 1;
        out.write(row.items);
        if (out.failed) return status;
    }
}

fn pasteSerial(ctx: cli.Context, out: *cli.Out, sources: []Source, delims: []const []const u8, term: u8) u8 {
    var status: u8 = 0;
    for (sources) |*s| {
        var k: usize = 0;
        var first = true;
        while (nextLine(ctx, s, &status)) |t| {
            if (!first and delims.len > 0) {
                out.write(delims[k % delims.len]);
                k += 1;
            }
            first = false;
            out.write(t);
        }
        out.writeByte(term);
        if (out.failed) return status;
    }
    return status;
}

/// Split a -d list into elements: plain bytes, and the escapes \n \t \\ \0.
fn expandDelims(ctx: cli.Context, text: []const u8, list: *std.ArrayList([]const u8)) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            list.append(ctx.gpa, text[i .. i + 1]) catch return false;
            continue;
        }
        i += 1;
        if (i >= text.len) {
            cli.warn(ctx, "delimiter list ends with an unescaped backslash: {s}", .{text});
            return false;
        }
        const e: []const u8 = switch (text[i]) {
            'n' => "\n",
            't' => "\t",
            '\\' => "\\",
            '0' => "",
            else => text[i .. i + 1], // GNU: backslash before another character stands for it
        };
        list.append(ctx.gpa, e) catch return false;
    }
    return true;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: paste [OPTION]... [FILE]...\n" ++
        "Write lines consisting of the sequentially corresponding lines from\n" ++
        "each FILE, separated by TABs, to standard output.\n\n" ++
        "  -d, --delimiters=LIST   reuse characters from LIST instead of TABs\n" ++
        "  -s, --serial            paste one file at a time instead of in parallel\n" ++
        "  -z, --zero-terminated   line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
