//! fold — wrap input lines to fit a given width.
//! References: GNU coreutils manual "fold invocation" (9.7); POSIX.1-2024 fold.
//!
//! Columns follow POSIX: a tab advances to the next multiple of 8, backspace
//! decrements (never below 0), carriage return resets to 0; with -b every
//! byte is one column. Characters are bytes (C locale); wide and multibyte
//! characters are not interpreted. -s breaks after the last blank (space or
//! tab) in the pending segment when there is one.

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "bytes", "spaces", "width", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var bytes_mode = false;
    var spaces = false;
    var width: usize = 80;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    var width_digits: ?usize = null; // obsolete -N
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
                0 => bytes_mode = true,
                1 => spaces = true,
                2 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--width' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        val = args[i];
                    }
                    width = parseWidth(ctx, val) orelse return 1;
                },
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'b' => bytes_mode = true,
            's' => spaces = true,
            '0'...'9' => {
                width_digits = (width_digits orelse 0) *| 10 +| (a[j] - '0');
                width = width_digits.?;
                if (width == 0) {
                    cli.warn(ctx, "invalid number of columns: '0': Numerical result out of range", .{});
                    return 1;
                }
            },
            'w' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 'w'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    val = args[i];
                }
                width = parseWidth(ctx, val) orelse return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.gpa);
    for (inputs) |path| {
        const file = cli.openInput(ctx.io, path) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        if (!foldFile(ctx, &out, file, &line, width, bytes_mode, spaces)) {
            cli.warn(ctx, "{s}: read error", .{path});
            status = 1;
        }
        if (out.failed) break;
    }
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return status;
}

fn parseWidth(ctx: cli.Context, text: []const u8) ?usize {
    var v: usize = 0;
    var ok = text.len > 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) {
            ok = false;
            break;
        }
        v = v *| 10 +| (c - '0');
    }
    if (!ok) {
        cli.warn(ctx, "invalid number of columns: '{s}'", .{text});
        return null;
    }
    if (v == 0) {
        cli.warn(ctx, "invalid number of columns: '{s}': Numerical result out of range", .{text});
        return null;
    }
    return v;
}

/// Column after printing `c` at column `col`.
fn advance(col: usize, c: u8, bytes_mode: bool) usize {
    if (bytes_mode) return col + 1;
    return switch (c) {
        '\r' => 0,
        '\t' => col + 8 - col % 8,
        '\x08' => if (col > 0) col - 1 else 0,
        else => col + 1,
    };
}

fn columnOf(text: []const u8, bytes_mode: bool) usize {
    var col: usize = 0;
    for (text) |c| col = advance(col, c, bytes_mode);
    return col;
}

/// Fold one file. `line` is the pending output segment (reused across files).
/// Returns false on a read error.
fn foldFile(ctx: cli.Context, out: *cli.Out, file: Io.File, line: *std.ArrayList(u8), width: usize, bytes_mode: bool, spaces: bool) bool {
    var buf: [64 * 1024]u8 = undefined;
    var column: usize = 0;
    line.clearRetainingCapacity();
    while (true) {
        const n = cli.readChunk(ctx.io, file, &buf) catch return false;
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c == '\n') {
                line.append(ctx.gpa, c) catch return false;
                out.write(line.items);
                line.clearRetainingCapacity();
                column = 0;
                continue;
            }
            while (true) {
                const newcol = advance(column, c, bytes_mode);
                if (newcol <= width) {
                    column = newcol;
                    line.append(ctx.gpa, c) catch return false;
                    break;
                }
                // The character does not fit: break the line first.
                if (spaces) {
                    var end = line.items.len;
                    var found = false;
                    while (end > 0) {
                        end -= 1;
                        if (line.items[end] == ' ' or line.items[end] == '\t') {
                            found = true;
                            break;
                        }
                    }
                    if (found) {
                        const upto = end + 1;
                        out.write(line.items[0..upto]);
                        out.writeByte('\n');
                        const rest = line.items.len - upto;
                        std.mem.copyForwards(u8, line.items[0..rest], line.items[upto..]);
                        line.shrinkRetainingCapacity(rest);
                        column = columnOf(line.items, bytes_mode);
                        continue;
                    }
                }
                if (line.items.len == 0) {
                    // A single character wider than the width: emit it alone.
                    line.append(ctx.gpa, c) catch return false;
                    column = newcol;
                    break;
                }
                line.append(ctx.gpa, '\n') catch return false;
                out.write(line.items);
                line.clearRetainingCapacity();
                column = 0;
            }
        }
        if (out.failed) return true;
    }
    if (line.items.len > 0) out.write(line.items);
    line.clearRetainingCapacity();
    return true;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: fold [OPTION]... [FILE]...\n" ++
        "Wrap input lines in each FILE, writing to standard output.\n\n" ++
        "  -b, --bytes         count bytes rather than columns\n" ++
        "  -s, --spaces        break at spaces\n" ++
        "  -w, --width=WIDTH   use WIDTH columns instead of 80\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}

test "advance and columnOf" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 8), advance(0, '\t', false));
    try t.expectEqual(@as(usize, 16), advance(8, '\t', false));
    try t.expectEqual(@as(usize, 8), advance(7, '\t', false));
    try t.expectEqual(@as(usize, 0), advance(0, '\x08', false));
    try t.expectEqual(@as(usize, 4), advance(5, '\x08', false));
    try t.expectEqual(@as(usize, 0), advance(9, '\r', false));
    try t.expectEqual(@as(usize, 1), advance(0, '\t', true));
    try t.expectEqual(@as(usize, 3), columnOf("abc", false));
}
