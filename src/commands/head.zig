// SPDX-License-Identifier: GPL-2.0-or-later
//! head — output the first part of files.
//! References: GNU coreutils manual "head invocation" (9.7); POSIX.1-2024 head.
//!
//! POSIX: -n/-c with a positive count. GNU extensions implemented: size
//! suffixes, a leading '-' on the count (all but the last NUM), -q/-v/-z,
//! long options, and the obsolete `-NUM[bkm][cqv]` form when it is the first
//! argument. Files are streamed; "all but the last N" buffers the last N
//! items in memory (as GNU does for non-seekable input).

const std = @import("std");
const cli = @import("../cli.zig");
const count_arg = @import("../count_arg.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "bytes", "lines", "quiet", "silent", "verbose", "zero-terminated", "help", "version" };

const Config = struct {
    bytes: bool = false,
    count: u64 = 10,
    /// "all but the last `count`" instead of "the first `count`".
    skip_last: bool = false,
    delim: u8 = '\n',
};

const Header = enum { auto, always, never };

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    var header: Header = .auto;
    var args = ctx.args;

    // Obsolete -NUM form: only as the first argument.
    if (args.len > 0 and isObsolete(args[0])) {
        if (!parseObsolete(ctx, args[0], &cfg, &header)) return 1;
        args = args[1..];
    }

    var i: usize = 0;
    var only_operands = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
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
                0, 1 => {
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
                    if (!setCount(ctx, &cfg, k == 0, val)) return 1;
                },
                2, 3 => header = .never,
                4 => header = .always,
                5 => cfg.delim = 0,
                6 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'q' => header = .never,
            'v' => header = .always,
            'z' => cfg.delim = 0,
            'c', 'n' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                if (!setCount(ctx, &cfg, a[j] == 'c', val)) return 1;
                break;
            },
            '0'...'9' => {
                // GNU: digits are only valid in the obsolete first-argument form.
                cli.warn(ctx, "invalid trailing option -- {c}\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                return 1;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    const show_header = switch (header) {
        .always => true,
        .never => false,
        .auto => inputs.len > 1,
    };

    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    var first = true;
    var buf: [64 * 1024]u8 = undefined;
    for (inputs) |path| {
        const file = cli.openInput(ctx.io, path) catch |e| {
            if (e == error.IsDir) {
                // GNU opens directories fine and fails on read.
                if (show_header) printHeader(&out, path, &first);
                cli.warn(ctx, "error reading '{s}': Is a directory", .{path});
            } else cli.warn(ctx, "cannot open '{s}' for reading: {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        if (show_header) printHeader(&out, path, &first);
        if (head(ctx, &out, file, cfg, &buf)) |unread| {
            cli.giveBack(ctx.io, file, unread);
        } else |e| {
            out.flush();
            cli.warn(ctx, "error reading '{s}': {s}", .{ path, cli.errText(e) });
            status = 1;
        }
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return status;
}

fn printHeader(out: *cli.Out, path: []const u8, first: *bool) void {
    if (!first.*) out.writeByte('\n');
    first.* = false;
    out.write("==> ");
    out.write(if (std.mem.eql(u8, path, "-")) "standard input" else path);
    out.write(" <==\n");
}

/// Copy the head of `file`. Returns how many bytes were read beyond what was
/// output (to be given back to a seekable input, see cli.giveBack).
fn head(ctx: cli.Context, out: *cli.Out, file: Io.File, cfg: Config, buf: []u8) !u64 {
    if (cfg.skip_last) {
        try headAllButLast(ctx, out, file, cfg, buf);
        return 0;
    }
    var remaining = cfg.count;
    while (remaining > 0) {
        const n = try cli.readChunk(ctx.io, file, buf);
        if (n == 0) return 0;
        const chunk = buf[0..n];
        if (cfg.bytes) {
            const take: usize = @intCast(@min(remaining, n));
            out.write(chunk[0..take]);
            remaining -= take;
            if (remaining == 0) {
                return n - take;
            }
        } else {
            var start: usize = 0;
            while (remaining > 0) {
                const idx = std.mem.indexOfScalarPos(u8, chunk, start, cfg.delim) orelse {
                    start = chunk.len; // no delimiter left: the whole tail belongs to the current line
                    break;
                };
                remaining -= 1;
                start = idx + 1;
            }
            out.write(chunk[0..start]);
            if (remaining == 0) return chunk.len - start;
        }
        if (out.failed) return 0;
    }
    return 0;
}

/// Everything except the last `count` bytes/lines. Holds back at most
/// `count` items (plus one read chunk) in `pending`.
fn headAllButLast(ctx: cli.Context, out: *cli.Out, file: Io.File, cfg: Config, buf: []u8) !void {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(ctx.gpa);
    var start: usize = 0; // bytes before `start` are already written
    var delims: u64 = 0; // delimiters in pending[start..]
    while (true) {
        const n = try cli.readChunk(ctx.io, file, buf);
        if (n == 0) return;
        const chunk = buf[0..n];
        pending.appendSlice(ctx.gpa, chunk) catch return error.OutOfMemory;
        if (cfg.bytes) {
            const held = pending.items.len - start;
            if (held > cfg.count) {
                const emit: usize = @intCast(held - cfg.count);
                out.write(pending.items[start..][0..emit]);
                start += emit;
            }
        } else {
            for (chunk) |c| delims += @intFromBool(c == cfg.delim);
            // Held-back lines are the complete ones (`delims`) plus an unterminated
            // last line, which counts as a line. Release the oldest while more
            // than `count` are held. Only count == 0 can release a partial line.
            while (true) {
                const partial: u64 = @intFromBool(pending.items.len > start and pending.items[pending.items.len - 1] != cfg.delim);
                if (delims + partial <= cfg.count) break;
                if (delims == 0) {
                    out.write(pending.items[start..]);
                    start = pending.items.len;
                    break;
                }
                const idx = std.mem.indexOfScalarPos(u8, pending.items, start, cfg.delim).?;
                out.write(pending.items[start .. idx + 1]);
                start = idx + 1;
                delims -= 1;
            }
        }
        if (out.failed) return;
        // Compact so memory stays proportional to what is held back.
        if (start > 0 and start >= pending.items.len / 2) {
            const rest = pending.items.len - start;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[start..]);
            pending.shrinkRetainingCapacity(rest);
            start = 0;
        }
    }
}

/// Obsolete `-NUM[bkm][cqv]`: '-' then at least one digit, then only letters
/// from b k m c l q v.
fn isObsolete(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-' or !std.ascii.isDigit(a[1])) return false;
    var i: usize = 1;
    while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
    for (a[i..]) |c| if (std.mem.indexOfScalar(u8, "bkmclqv", c) == null) return false;
    return true;
}

fn parseObsolete(ctx: cli.Context, a: []const u8, cfg: *Config, header: *Header) bool {
    var i: usize = 1;
    while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
    var digits_end = i;
    // A size letter directly after the digits belongs to the count.
    if (i < a.len and std.mem.indexOfScalar(u8, "bkm", a[i]) != null) digits_end = i + 1;
    const num = count_arg.parse(a[1..digits_end]) orelse {
        cli.warn(ctx, "invalid number of lines: '{s}'", .{a[1..digits_end]});
        return false;
    };
    cfg.count = num.value;
    cfg.skip_last = false;
    cfg.bytes = false;
    for (a[digits_end..]) |c| switch (c) {
        'c' => cfg.bytes = true,
        'l' => cfg.bytes = false,
        'q' => header.* = .never,
        'v' => header.* = .always,
        else => {},
    };
    return true;
}

fn setCount(ctx: cli.Context, cfg: *Config, bytes: bool, text: []const u8) bool {
    const c = count_arg.parse(text) orelse {
        cli.warn(ctx, "invalid number of {s}: '{s}'", .{ if (bytes) "bytes" else "lines", text });
        return false;
    };
    cfg.bytes = bytes;
    cfg.count = c.value;
    cfg.skip_last = c.sign == .minus;
    return true;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: head [OPTION]... [FILE]...\n" ++
        "Print the first 10 lines of each FILE to standard output.\n" ++
        "With more than one FILE, precede each with a header giving the file name.\n\n" ++
        "  -c, --bytes=[-]NUM       print the first NUM bytes of each file;\n" ++
        "                             with the leading '-', print all but the last\n" ++
        "                             NUM bytes of each file\n" ++
        "  -n, --lines=[-]NUM       print the first NUM lines instead of the first 10;\n" ++
        "                             with the leading '-', print all but the last\n" ++
        "                             NUM lines of each file\n" ++
        "  -q, --quiet, --silent    never print headers giving file names\n" ++
        "  -v, --verbose            always print headers giving file names\n" ++
        "  -z, --zero-terminated    line delimiter is NUL, not newline\n" ++
        "      --help               display this help and exit\n" ++
        "      --version            output version information and exit\n\n" ++
        "NUM may have a multiplier suffix: b 512, kB 1000, K 1024, MB 1000*1000,\n" ++
        "M 1024*1024, GB, G, T, P, E, Z, Y, R, Q.\n")) 0 else 1;
}

test "isObsolete" {
    try std.testing.expect(isObsolete("-5"));
    try std.testing.expect(isObsolete("-5q"));
    try std.testing.expect(isObsolete("-12kc"));
    try std.testing.expect(!isObsolete("-n"));
    try std.testing.expect(!isObsolete("-5x"));
    try std.testing.expect(!isObsolete("5"));
}
