//! unexpand — convert spaces to tabs.
//! References: GNU coreutils manual "unexpand invocation" (9.7); POSIX.1-2024
//! unexpand. Tab list syntax lives in src/tabs.zig.
//!
//! Model (checked against GNU by differential and randomised tests): runs of
//! blanks are held back; when the column reaches a tab stop they are replaced
//! by one TAB. A single space that reaches a stop after some non-blank text
//! stays a space if the next character is not a blank (a TAB would not save
//! anything); if the run continues it becomes part of the TAB. Held blanks
//! that do not reach a stop are written unchanged. Without -a only the
//! blanks before the first non-blank of a line are considered; -t implies -a
//! unless --first-only is given. Columns count bytes (C locale).

const std = @import("std");
const cli = @import("../cli.zig");
const tabs = @import("../tabs.zig");
const expand = @import("expand.zig");

const long_names = [_][]const u8{ "all", "first-only", "tabs", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var all = false;
    var first_only = false;
    var tab_text: std.ArrayList(u8) = .empty;
    defer tab_text.deinit(ctx.gpa);
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
                0 => all = true,
                1 => first_only = true,
                2 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--tabs' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        val = args[i];
                    }
                    addTabs(ctx, &tab_text, val, &all) catch return oom(ctx);
                },
                3 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        // Obsolete -N[,N...]: tab list that does not imply -a.
        if (std.mem.indexOfNone(u8, a[1..], "0123456789,") == null) {
            if (tab_text.items.len > 0) tab_text.append(ctx.gpa, ',') catch return oom(ctx);
            tab_text.appendSlice(ctx.gpa, a[1..]) catch return oom(ctx);
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'a' => all = true,
            't' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 't'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    val = args[i];
                }
                addTabs(ctx, &tab_text, val, &all) catch return oom(ctx);
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }
    if (first_only) all = false;

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const stops = expand.parseTabs(ctx, arena_state.allocator(), tab_text.items) orelse return 1;

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    var out = cli.Out.init(ctx.io);
    var st: State = .{ .stops = stops, .all = all, .gpa = ctx.gpa, .out = &out };
    defer st.pending.deinit(ctx.gpa);
    var status: u8 = 0;
    var buf: [64 * 1024]u8 = undefined;
    for (inputs) |path| {
        const file = cli.openInput(ctx.io, path) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        while (true) {
            const n = cli.readChunk(ctx.io, file, &buf) catch |e| {
                out.flush();
                cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
                status = 1;
                break;
            };
            if (n == 0) break;
            for (buf[0..n]) |c| st.feed(c) catch return oom(ctx);
            if (out.failed) break;
        }
        if (out.failed) break;
    }
    // GNU flushes held blanks at end of each input; here at the very end.
    st.flushPending();
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return status;
}

const State = struct {
    stops: tabs.Stops,
    all: bool,
    gpa: std.mem.Allocator,
    out: *cli.Out,
    pending: std.ArrayList(u8) = .empty,
    col: usize = 0,
    convert: bool = true,
    /// A non-blank has been seen on this line.
    seen_text: bool = false,
    /// `pending` is one space that reached a stop; undecided until the next byte.
    lone: bool = false,
    /// Blanks in the current run (since the last non-blank).
    run: usize = 0,

    fn flushPending(s: *State) void {
        s.out.write(s.pending.items);
        s.pending.clearRetainingCapacity();
        s.lone = false;
    }

    fn endRun(s: *State) void {
        s.run = 0;
    }

    fn feed(s: *State, c: u8) !void {
        if (s.lone) {
            // The deferred single space: a following blank turns it into a TAB.
            if (s.convert and (c == ' ' or c == '\t') and s.stops.next(s.col) != null) {
                s.out.writeByte('\t');
                s.pending.clearRetainingCapacity();
                s.lone = false;
            } else s.flushPending();
        }
        if (c == '\n') {
            s.flushPending();
            s.out.writeByte('\n');
            s.col = 0;
            s.convert = true;
            s.seen_text = false;
            s.endRun();
            return;
        }
        const blank = c == ' ' or c == '\t';
        if (s.convert and blank) {
            const nxt = s.stops.next(s.col) orelse {
                // Beyond the last tab stop: nothing more to convert on this line.
                s.flushPending();
                s.out.writeByte(c);
                s.convert = false;
                return;
            };
            try s.pending.append(s.gpa, c);
            s.run += 1;
            s.col = if (c == '\t') nxt else s.col + 1;
            if (s.col == nxt) {
                if (s.run == 1 and c == ' ' and s.seen_text) {
                    s.lone = true;
                } else {
                    s.out.writeByte('\t');
                    s.pending.clearRetainingCapacity();
                }
            }
            return;
        }
        s.flushPending();
        s.endRun();
        s.seen_text = true;
        if (s.convert) {
            if (c == '\x08') {
                if (s.col > 0) s.col -= 1;
            } else s.col += 1;
            if (!s.all) s.convert = false;
        }
        s.out.writeByte(c);
    }
};

fn addTabs(ctx: cli.Context, list: *std.ArrayList(u8), text: []const u8, all: *bool) !void {
    if (list.items.len > 0) try list.append(ctx.gpa, ',');
    try list.appendSlice(ctx.gpa, text);
    all.* = true; // -t implies -a
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: unexpand [OPTION]... [FILE]...\n" ++
        "Convert blanks in each FILE to tabs, writing to standard output.\n\n" ++
        "  -a, --all        convert all blanks, instead of just initial blanks\n" ++
        "      --first-only  convert only leading sequences of blanks (overrides -a)\n" ++
        "  -t, --tabs=N     have tabs N characters apart instead of 8 (enables -a)\n" ++
        "  -t, --tabs=LIST  use comma separated list of tab positions.\n" ++
        "                     The last specified position can be prefixed with '/'\n" ++
        "                     to specify a tab size to use after the last\n" ++
        "                     explicitly specified tab stop.  Also a prefix of '+'\n" ++
        "                     can be used to align remaining tab stops relative to\n" ++
        "                     the last specified tab stop instead of the first column\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
