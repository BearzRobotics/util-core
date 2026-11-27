// SPDX-License-Identifier: GPL-2.0-or-later
//! join — join lines of two sorted files on a common field.
//! References: GNU coreutils manual "join invocation" (9.7); POSIX.1-2024 join.
//!
//! The merge follows GNU's structure so that diagnostics appear in the same
//! circumstances: each input holds its current line; when keys are equal the
//! following lines with the same key are read (that is when the next line is
//! order-checked), then the cross product is printed. Order checking is on
//! with --check-order, off with --nocheck-order, and otherwise only once an
//! unpairable line has been seen.

const std = @import("std");
const numparse = @import("../numparse.zig");
const cli = @import("../cli.zig");
const join = @import("../lib/join.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "ignore-case", "zero-terminated", "check-order", "nocheck-order", "header", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var cfg: join.Options = .{};
    var out_spec: std.ArrayList(join.Spec) = .empty;
    defer out_spec.deinit(ctx.gpa);
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    // The join fields given so far: a second, different one is an error.
    var join_fields: [2]?usize = .{ null, null };
    // The N of an obsolete "-j1 N" or "-j2 N"; GNU applies these last.
    var old_fields: [2]?usize = .{ null, null };

    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
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
            if (eq != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => cfg.ignore_case = true,
                1 => cfg.term = 0,
                2 => cfg.check = .on,
                3 => cfg.check = .off,
                4 => cfg.header = true,
                5 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            switch (c) {
                'i' => cfg.ignore_case = true,
                'z' => cfg.term = 0,
                'a', 'v', 'e', 'j', 'o', 't', '1', '2' => {
                    var value: []const u8 = a[j + 1 ..];
                    // Obsolete -j1 N and -j2 N.
                    var obsolete: u8 = 0;
                    if (c == 'j' and value.len == 1 and (value[0] == '1' or value[0] == '2')) {
                        obsolete = value[0];
                        value = "";
                    }
                    if (value.len == 0) {
                        i += 1;
                        if (i >= ctx.args.len) {
                            cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
                            return 1;
                        }
                        value = ctx.args[i];
                    }
                    switch (c) {
                        'a', 'v' => {
                            const n = fileNumber(ctx, value) orelse return 1;
                            if (n == 1) cfg.print1 = true else cfg.print2 = true;
                            if (c == 'v') cfg.pairs = false;
                        },
                        'e' => {
                            if (cfg.empty) |e| if (!std.mem.eql(u8, e, value)) {
                                cli.warn(ctx, "conflicting empty-field replacement strings", .{});
                                return 1;
                            };
                            cfg.empty = value;
                        },
                        'j' => {
                            const f = fieldNumber(ctx, value) orelse return 1;
                            if (obsolete == '1') old_fields[0] = f else if (obsolete == '2') old_fields[1] = f else {
                                for (&join_fields) |*slot| if (!setJoinField(ctx, slot, f)) return 1;
                            }
                        },
                        '1', '2' => {
                            const f = fieldNumber(ctx, value) orelse return 1;
                            if (!setJoinField(ctx, &join_fields[c - '1'], f)) return 1;
                        },
                        // Each -o adds to the list.
                        'o' => if (!parseOutput(ctx, &cfg, &out_spec, ctx.gpa, value)) return 1,
                        else => { // 't'
                            // null: -t '', the whole line is one field.
                            const tab: ?u8 = if (value.len == 0)
                                null
                            else if (value.len == 1)
                                value[0]
                            else if (std.mem.eql(u8, value, "\\0"))
                                0
                            else {
                                cli.warn(ctx, "multi-character tab '{s}'", .{value});
                                return 1;
                            };
                            if (cfg.tab_given and cfg.tab != tab) {
                                cli.warn(ctx, "incompatible tabs", .{});
                                return 1;
                            }
                            cfg.tab = tab;
                            cfg.tab_given = true;
                        },
                    }
                    j = a.len;
                },
                else => {
                    cli.invalidShort(ctx, c);
                    return 1;
                },
            }
        }
    }
    for (&join_fields, old_fields) |*slot, old| {
        if (old) |f| if (!setJoinField(ctx, slot, f)) return 1;
    }
    if (join_fields[0]) |f| cfg.f1 = f;
    if (join_fields[1]) |f| cfg.f2 = f;

    if (files.items.len < 2) {
        if (files.items.len == 0) {
            cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        } else {
            cli.warn(ctx, "missing operand after '{s}'\nTry '{s} --help' for more information.", .{ files.items[0], ctx.name });
        }
        return 1;
    }
    if (files.items.len > 2) {
        cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ files.items[2], ctx.name });
        return 1;
    }
    const both_stdin = std.mem.eql(u8, files.items[0], "-") and std.mem.eql(u8, files.items[1], "-");
    if (both_stdin) {
        cli.warn(ctx, "both files cannot be standard input", .{});
        return 1;
    }

    var ins: [2]join.Input = undefined;
    for (files.items, 0..) |name, k| {
        ins[k] = if (std.mem.eql(u8, name, "-"))
            .{ .name = name, .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = name, .source = .{ .path = name } };
    }
    cfg.output = out_spec.items;

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: join.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = join.run(env, cfg, ins[0], ins[1], &stdout.interface, .{
        .context = @constCast(&ctx),
        .func = report,
    }) catch |e| switch (e) {
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.writeErrorWarn(ctx);
            return 1;
        },
    };
    return if (result.failed) 1 else 0;
}

fn report(context: ?*anyopaque, ev: join.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev.kind) {
        .open_failed => if (ev.err.? == error.IsDir) {
            cli.warn(ctx.*, "read error: Is a directory", .{});
        } else cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(ev.name), cli.errText(ev.err.?) }),
        .read_failed => cli.warn(ctx.*, "{f}: read error: {s}", .{ cli.quote(ev.name), cli.errText(ev.err.?) }),
        .not_sorted => cli.warn(ctx.*, "{f}:{d}: is not sorted: {s}", .{ cli.quote(ev.name), ev.lineno, ev.text }),
        .input_disorder => cli.warn(ctx.*, "input is not in sorted order", .{}),
    }
}

fn fileNumber(ctx: cli.Context, v: []const u8) ?u8 {
    if (std.mem.eql(u8, v, "1")) return 1;
    if (std.mem.eql(u8, v, "2")) return 2;
    cli.warn(ctx, "invalid file number: '{s}'", .{v});
    return null;
}

fn fieldNumber(ctx: cli.Context, v: []const u8) ?usize {
    const n = numparse.parseInt(usize, v, 10) catch {
        cli.warn(ctx, "invalid field number: '{s}'", .{v});
        return null;
    };
    if (n == 0) {
        cli.warn(ctx, "invalid field number: '{s}'", .{v});
        return null;
    }
    return n;
}

/// Record a join field (1-based). The message counts from 0, as GNU's does.
fn setJoinField(ctx: cli.Context, slot: *?usize, field: usize) bool {
    if (slot.*) |had| if (had != field) {
        cli.warn(ctx, "incompatible join fields {d}, {d}", .{ had - 1, field - 1 });
        return false;
    };
    slot.* = field;
    return true;
}

fn parseOutput(ctx: cli.Context, cfg: *join.Options, out_spec: *std.ArrayList(join.Spec), gpa: std.mem.Allocator, text: []const u8) bool {
    if (std.mem.eql(u8, text, "auto")) {
        cfg.auto = true;
        return true;
    }
    // Every separator ends an entry, and only one at the very end may be
    // followed by nothing.
    var it = std.mem.splitAny(u8, text, ", \t");
    var first = true;
    while (it.next()) |item| : (first = false) {
        if (item.len == 0 and !first and it.peek() == null) break;
        if (std.mem.eql(u8, item, "0")) {
            out_spec.append(gpa, .{ .file = 0, .field = 0 }) catch return false;
            continue;
        }
        if (item.len >= 2 and (item[0] == '1' or item[0] == '2') and item[1] == '.') {
            const n = numparse.parseInt(usize, item[2..], 10) catch {
                cli.warn(ctx, "invalid field number: '{s}'", .{item[2..]});
                return false;
            };
            if (n == 0) {
                cli.warn(ctx, "invalid field number: '{s}'", .{item[2..]});
                return false;
            }
            out_spec.append(gpa, .{ .file = item[0] - '0', .field = n }) catch return false;
            continue;
        }
        cli.warn(ctx, "invalid file number in field spec: '{s}'", .{item});
        return false;
    }
    return true;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: join [OPTION]... FILE1 FILE2\n" ++
        "For each pair of input lines with identical join fields, write a line to\n" ++
        "standard output.  The default join field is the first, delimited by blanks.\n\n" ++
        "When FILE1 or FILE2 (not both) is -, read standard input.\n\n" ++
        "  -a FILENUM        also print unpairable lines from file FILENUM, where\n" ++
        "                      FILENUM is 1 or 2, corresponding to FILE1 or FILE2\n" ++
        "  -e STRING         replace missing input fields with STRING\n" ++
        "  -i, --ignore-case  ignore differences in case when comparing fields\n" ++
        "  -j FIELD          equivalent to '-1 FIELD -2 FIELD'\n" ++
        "  -o FORMAT         obey FORMAT while constructing output line\n" ++
        "  -t CHAR           use CHAR as input and output field separator\n" ++
        "  -v FILENUM        like -a FILENUM, but suppress joined output lines\n" ++
        "  -1 FIELD          join on this FIELD of file 1\n" ++
        "  -2 FIELD          join on this FIELD of file 2\n" ++
        "      --check-order     check that the input is correctly sorted, even\n" ++
        "                          if all input lines are pairable\n" ++
        "      --nocheck-order   do not check that the input is correctly sorted\n" ++
        "      --header      treat the first line in each file as field headers,\n" ++
        "                      print them without trying to pair them\n" ++
        "  -z, --zero-terminated     line delimiter is NUL, not newline\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
