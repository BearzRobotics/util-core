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
const scan = @import("../bytes.zig");
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
    for (inputs) |path| {
        data.clearRetainingCapacity();
        tacInput(ctx, &out, path, sep, before, &data) catch |e| {
            if (e != error.Reported) cli.warn(ctx, "{s}: read error: {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return status;
}

/// Reverse one input. A named regular file is read backwards in windows, so
/// memory stays proportional to the window (and the longest record); pipes,
/// the terminal and size-0 pseudo files are read whole into `data` first.
fn tacInput(ctx: cli.Context, out: *cli.Out, path: []const u8, sep: []const u8, before: bool, data: *std.ArrayList(u8)) !void {
    const file = cli.openInput(ctx.io, path) catch |e| {
        cli.warn(ctx, "failed to open '{s}' for reading: {s}", .{ path, cli.errText(e) });
        return error.Reported;
    };
    defer cli.closeInput(ctx.io, file);

    if (!std.mem.eql(u8, path, "-")) {
        if (file.stat(ctx.io)) |st| {
            if (st.kind == .file and st.size > 0) return tacBackwards(ctx, out, file, st.size, sep, before);
        } else |_| {}
    }
    while (true) {
        try data.ensureUnusedCapacity(ctx.gpa, 64 * 1024);
        const n = try cli.readChunk(ctx.io, file, data.unusedCapacitySlice());
        if (n == 0) break;
        data.items.len += n;
    }
    _ = reverseWindow(out, data.items, sep, before, true);
}

const window_size = 64 * 1024;

/// Read `file` (of `size` bytes) from the end in windows. `carry` is the
/// leftmost piece of the previous window whose beginning is not known yet;
/// it is glued to the right end of the next window and rescanned.
fn tacBackwards(ctx: cli.Context, out: *cli.Out, file: Io.File, size: u64, sep: []const u8, before: bool) !void {
    var window: std.ArrayList(u8) = .empty;
    defer window.deinit(ctx.gpa);
    var carry_len: usize = 0; // the carry is window.items[0..carry_len] after each pass
    var scratch: std.ArrayList(u8) = .empty; // old carry while the window is rebuilt
    defer scratch.deinit(ctx.gpa);
    var pos = size;
    while (pos > 0) {
        // Grow the window with the carry so one huge record costs O(n), not O(n^2).
        const want: usize = @intCast(@min(pos, @max(@as(u64, window_size), carry_len)));
        pos -= want;
        try scratch.resize(ctx.gpa, carry_len);
        @memcpy(scratch.items, window.items[0..carry_len]);
        try window.resize(ctx.gpa, want + carry_len);
        const got = try file.readPositionalAll(ctx.io, window.items[0..want], pos);
        if (got != want) return error.UnexpectedEof; // file shrank while reading
        @memcpy(window.items[want..], scratch.items);
        carry_len = reverseWindow(out, window.items, sep, before, pos == 0);
        if (out.failed) return;
    }
}

/// Write the complete records of `data` from the last to the first and return
/// the length of the unfinished piece at the start of `data` (0 when `final`:
/// that piece is then a record too).
///
/// Records end with `sep` (default) or start with it (`before`). With the
/// default, a separator at the very end of `data` terminates the last record
/// and the unterminated piece after the last separator is a record of its own,
/// printed first (GNU). Separators are found right to left, which fixes how
/// overlapping occurrences of a multi-byte separator are paired.
fn reverseWindow(out: *cli.Out, data: []const u8, sep: []const u8, before: bool, final: bool) usize {
    var end = data.len; // exclusive end of the not yet written suffix
    if (before) {
        while (lastIndexOfSep(data[0..end], sep)) |p| {
            out.write(data[p..end]);
            end = p;
        }
    } else {
        var cur = data.len;
        if (std.mem.endsWith(u8, data, sep)) cur -= sep.len; // terminator of the last record
        while (lastIndexOfSep(data[0..cur], sep)) |p| {
            out.write(data[p + sep.len .. end]);
            end = p + sep.len;
            cur = p;
        }
    }
    if (final) {
        out.write(data[0..end]);
        return 0;
    }
    return end;
}

fn lastIndexOfSep(hay: []const u8, sep: []const u8) ?usize {
    if (sep.len == 1) return scan.lastIndexOf(hay, sep[0]);
    return std.mem.lastIndexOf(u8, hay, sep);
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
