// SPDX-License-Identifier: GPL-2.0-or-later
//! uniq library (decision 0004): report or filter out repeated adjacent lines.
//! References: GNU coreutils manual "uniq invocation" (9.7); POSIX.1-2024.
//!
//! Comparison key of a line: skip `skip_fields` fields (each field is blanks
//! followed by non-blanks), then `skip_chars` characters, then keep at most
//! `check_chars` characters; `ignore_case` folds ASCII case. Characters are
//! bytes (C locale). The last line is always written with a terminator.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const lines = @import("../lines.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

/// How groups are delimited (--all-repeated / --group METHOD).
pub const Delimit = enum { none, prepend, separate, append, both };

pub const Options = struct {
    /// -c: prefix lines by the number of occurrences.
    count: bool = false,
    /// Print groups of one line (cleared by -d).
    output_unique: bool = true,
    /// Print groups of several lines (cleared by -u).
    output_first_repeated: bool = true,
    /// -D / --all-repeated.
    all_repeated: bool = false,
    /// --group.
    group: bool = false,
    method: Delimit = .none,
    ignore_case: bool = false,
    skip_fields: usize = 0,
    skip_chars: usize = 0,
    check_chars: usize = std.math.maxInt(usize),
    /// Line terminator for input and output.
    term: u8 = '\n',
};

/// A read error; the groups seen so far are still written.
pub const Event = struct {
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

/// Filter `input` onto `writer`. An input that cannot be opened is returned
/// as an error (the caller words it); there is nothing to resume then.
pub fn run(env: Env, options: Options, input: Input, writer: *Io.Writer, observer: Observer) !Result {
    const opened = try input.open(env.io);
    defer opened.close(env.io);
    var out = stickyout.Out.init(writer);
    var reader = lines.LineReader.init(env.gpa, env.io, opened.file, options.term);
    defer reader.deinit();
    const ok = try filter(env, &out, &reader, options, observer);
    try out.finish();
    return .{ .failed = !ok };
}

/// The part of `line` that takes part in comparisons.
fn keyOf(line: []const u8, cfg: Options) []const u8 {
    var p: usize = 0;
    var f = cfg.skip_fields;
    while (f > 0 and p < line.len) : (f -= 1) {
        while (p < line.len and isBlank(line[p])) p += 1;
        while (p < line.len and !isBlank(line[p])) p += 1;
    }
    p = @min(p +| cfg.skip_chars, line.len);
    const rest = line[p..];
    return rest[0..@min(rest.len, cfg.check_chars)];
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn sameKey(a: []const u8, b: []const u8, ignore_case: bool) bool {
    return if (ignore_case) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn filter(env: Env, out: *stickyout.Out, reader: *lines.LineReader, cfg: Options, observer: Observer) !bool {
    var first_line: std.ArrayList(u8) = .empty; // copy of the current group's first line
    defer first_line.deinit(env.gpa);
    var count: u64 = 0;
    var groups_started: u64 = 0;
    var groups_printed: u64 = 0; // for -D separators
    var ok = true;

    while (true) {
        const maybe = reader.next() catch |e| {
            out.flush();
            observer.emit(.{ .err = e });
            ok = false;
            break;
        };
        const line = maybe orelse break;
        if (count > 0 and sameKey(keyOf(first_line.items, cfg), keyOf(line.text, cfg), cfg.ignore_case)) {
            count += 1;
            if (cfg.all_repeated) {
                if (count == 2) {
                    startAllRepeated(out, cfg, &groups_printed);
                    // -u together with -D drops the first line of each group.
                    if (cfg.output_first_repeated) writeLine(out, first_line.items, cfg.term);
                }
                writeLine(out, line.text, cfg.term);
            } else if (cfg.group) writeLine(out, line.text, cfg.term);
            continue;
        }
        if (count > 0) finishGroup(out, first_line.items, count, cfg);
        first_line.clearRetainingCapacity();
        try first_line.appendSlice(env.gpa, line.text);
        count = 1;
        groups_started += 1;
        if (cfg.group) {
            // both = a delimiter before the first group and after every group.
            if (cfg.method == .prepend or (cfg.method == .both and groups_started == 1) or (cfg.method == .separate and groups_started > 1)) out.writeByte(cfg.term);
            writeLine(out, line.text, cfg.term);
        }
        if (out.failed) return ok;
    }
    if (count > 0) finishGroup(out, first_line.items, count, cfg);
    return ok;
}

fn startAllRepeated(out: *stickyout.Out, cfg: Options, printed: *u64) void {
    if (cfg.method == .prepend or (cfg.method == .separate and printed.* > 0)) out.writeByte(cfg.term);
    printed.* += 1;
}

fn finishGroup(out: *stickyout.Out, first: []const u8, count: u64, cfg: Options) void {
    if (cfg.group) {
        if (cfg.method == .append or cfg.method == .both) out.writeByte(cfg.term);
        return;
    }
    if (cfg.all_repeated) return; // lines were written as they arrived
    const wanted = if (count == 1) cfg.output_unique else cfg.output_first_repeated;
    if (!wanted) return;
    if (cfg.count) {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d: >7} ", .{count}) catch unreachable;
        out.write(s);
    }
    writeLine(out, first, cfg.term);
}

fn writeLine(out: *stickyout.Out, text: []const u8, term: u8) void {
    out.write(text);
    out.writeByte(term);
}

test "keyOf" {
    const t = std.testing;
    const c1: Options = .{ .skip_fields = 1 };
    try t.expectEqualStrings(" b c", keyOf("a b c", c1));
    try t.expectEqualStrings(" b c", keyOf("  a b c", c1));
    const c2: Options = .{ .skip_fields = 1, .skip_chars = 2 };
    try t.expectEqualStrings(" c", keyOf("a b c", c2));
    const c3: Options = .{ .check_chars = 2 };
    try t.expectEqualStrings("ab", keyOf("abcd", c3));
    try t.expectEqualStrings("", keyOf("a", .{ .skip_fields = 3 }));
}
