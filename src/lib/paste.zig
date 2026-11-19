// SPDX-License-Identifier: GPL-2.0-or-later
//! paste library (decision 0004): merge corresponding lines of inputs.
//! References: GNU coreutils manual "paste invocation" (9.7); POSIX.1-2024.
//!
//! Parallel mode joins line N of every input with the delimiters (used
//! circularly, restarting for each output line); serial mode joins all lines
//! of each input. An exhausted input behaves like empty lines. Inputs that
//! are the same open file (several standard-input operands) share one reader
//! and so read successive lines.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const lines = @import("../lines.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Options = struct {
    serial: bool = false,
    /// The delimiter list as given to -d: bytes used circularly, with the
    /// escapes `\n`, `\t`, `\\` and `\0` (an empty delimiter).
    delimiters: []const u8 = "\t",
    /// Line terminator for input and output.
    terminator: u8 = '\n',
};

/// A problem with one input. An input that cannot be opened ends the run
/// before any output; a read error ends only that input.
pub const Event = struct {
    name: []const u8,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

pub const RunError = error{
    OutOfMemory,
    WriteFailed,
    /// `Options.delimiters` ends with an unescaped backslash.
    UnescapedBackslash,
};

const Source = struct {
    reader: *lines.LineReader,
    name: []const u8,
    done: bool = false,
};

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) RunError!Result {
    // Delimiters: each element is one byte or empty (from "\0").
    var delims: std.ArrayList([]const u8) = .empty;
    defer delims.deinit(env.gpa);
    try expandDelims(env.gpa, options.delimiters, &delims);

    const term = options.terminator;
    const readers = try env.gpa.alloc(lines.LineReader, inputs.len);
    defer env.gpa.free(readers);
    const owned = try env.gpa.alloc(bool, inputs.len);
    defer env.gpa.free(owned);
    const sources = try env.gpa.alloc(Source, inputs.len);
    defer env.gpa.free(sources);
    for (readers, owned) |*r, *o| {
        r.* = lines.LineReader.init(env.gpa, env.io, Io.File.stdin(), term);
        o.* = false;
    }
    defer for (readers, owned) |*r, o| {
        if (o) r.file.close(env.io);
        r.deinit();
    };

    for (inputs, 0..) |in, k| {
        switch (in.source) {
            .file => |f| {
                const stdin_like = in.name == null or std.mem.eql(u8, in.name.?, "-");
                var shared: ?usize = null;
                for (inputs[0..k], 0..) |prev, j| switch (prev.source) {
                    .file => |pf| if (pf.handle == f.handle and shared == null) {
                        shared = j;
                    },
                    .path => {},
                };
                if (shared) |j| {
                    sources[k] = .{ .reader = sources[j].reader, .name = sources[j].name };
                } else {
                    readers[k] = lines.LineReader.init(env.gpa, env.io, f, term);
                    sources[k] = .{ .reader = &readers[k], .name = if (stdin_like) "standard input" else in.name.? };
                }
            },
            .path => |p| {
                const opened = in.open(env.io) catch |e| {
                    observer.emit(.{ .name = in.name orelse p, .err = e });
                    return .{ .failed = true };
                };
                readers[k] = lines.LineReader.init(env.gpa, env.io, opened.file, term);
                owned[k] = opened.owned;
                sources[k] = .{ .reader = &readers[k], .name = in.name orelse p };
            },
        }
    }

    var out = stickyout.Out.init(writer);
    var status: u8 = 0;
    if (options.serial) {
        try pasteSerial(env, &out, sources, delims.items, term, observer, &status);
    } else try pasteParallel(env, &out, sources, delims.items, term, observer, &status);
    try out.finish();
    return .{ .failed = status != 0 };
}

fn nextLine(s: *Source, status: *u8, observer: Observer) ?[]const u8 {
    if (s.done) return null;
    const l = s.reader.next() catch |e| {
        observer.emit(.{ .name = s.name, .err = e });
        status.* = 1;
        s.done = true;
        return null;
    };
    if (l) |line| return line.text;
    s.done = true;
    return null;
}

fn pasteParallel(env: Env, out: *stickyout.Out, sources: []Source, delims: []const []const u8, term: u8, observer: Observer, status: *u8) !void {
    // One output row is assembled first: if every input is exhausted nothing
    // (not even the delimiters) is written for that round.
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(env.gpa);
    while (true) {
        row.clearRetainingCapacity();
        var got_any = false;
        for (sources, 0..) |*s, k| {
            if (nextLine(s, status, observer)) |t| {
                got_any = true;
                try row.appendSlice(env.gpa, t);
            }
            if (k + 1 < sources.len and delims.len > 0) try row.appendSlice(env.gpa, delims[k % delims.len]);
        }
        if (!got_any) return;
        try row.append(env.gpa, term);
        out.write(row.items);
        if (out.failed) return;
    }
}

fn pasteSerial(env: Env, out: *stickyout.Out, sources: []Source, delims: []const []const u8, term: u8, observer: Observer, status: *u8) !void {
    _ = env;
    for (sources) |*s| {
        var k: usize = 0;
        var first = true;
        while (nextLine(s, status, observer)) |t| {
            if (!first and delims.len > 0) {
                out.write(delims[k % delims.len]);
                k += 1;
            }
            first = false;
            out.write(t);
        }
        out.writeByte(term);
        if (out.failed) return;
    }
}

/// Split a -d list into elements: plain bytes, and the escapes \n \t \\ \0.
fn expandDelims(gpa: std.mem.Allocator, text: []const u8, list: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            try list.append(gpa, text[i .. i + 1]);
            continue;
        }
        i += 1;
        if (i >= text.len) return error.UnescapedBackslash;
        const e: []const u8 = switch (text[i]) {
            'n' => "\n",
            't' => "\t",
            '\\' => "\\",
            '0' => "",
            else => text[i .. i + 1], // GNU: backslash before another character stands for it
        };
        try list.append(gpa, e);
    }
}

test "expandDelims" {
    const t = std.testing;
    var l: std.ArrayList([]const u8) = .empty;
    defer l.deinit(t.allocator);
    try expandDelims(t.allocator, "a\\tb\\0", &l);
    try t.expectEqual(@as(usize, 4), l.items.len);
    try t.expectEqualStrings("\t", l.items[1]);
    try t.expectEqualStrings("", l.items[3]);
    try t.expectError(error.UnescapedBackslash, expandDelims(t.allocator, "a\\", &l));
}
