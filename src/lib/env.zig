// SPDX-License-Identifier: GPL-2.0-or-later
//! env library: build the modified environment of a command, split -S
//! strings, and print an environment.
//! Reference: GNU coreutils manual "env invocation" (9.7); POSIX.1-2024 env.
//!
//! Options are processed in order by the caller, each acting on the
//! environment as it stands; this module supplies the steps. Changing signal
//! dispositions, the current directory and replacing the process are
//! process-wide actions (decision 0004) and stay in the wrapper
//! (`src/commands/env.zig`).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;
pub const Map = std.process.Environ.Map;

/// Copy of `source` (null: empty). `arena` owns it.
pub fn copyEnvironment(arena: std.mem.Allocator, source: ?*const Map) error{OutOfMemory}!Map {
    var env = Map.init(arena);
    if (source) |src| {
        var it = src.iterator();
        while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.*);
    }
    return env;
}

/// A name that -u may remove: non-empty and without '='.
pub fn validUnsetName(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfScalar(u8, name, '=') == null;
}

pub const Event = union(enum) {
    /// A NAME=VALUE operand was applied (the whole operand).
    setenv: []const u8,
};
pub const Observer = common.Observer(Event);

/// Apply the leading NAME=VALUE operands to `env` and return the rest (the
/// command). An operand with an empty name cannot be stored and is skipped,
/// as the stored environment cannot hold it.
pub fn applyAssignments(env: *Map, operands: []const []const u8, obs: Observer) error{OutOfMemory}![]const []const u8 {
    var k: usize = 0;
    while (k < operands.len) : (k += 1) {
        const eq = std.mem.indexOfScalar(u8, operands[k], '=') orelse break;
        if (eq == 0) continue;
        obs.emit(.{ .setenv = operands[k] });
        try env.put(operands[k][0..eq], operands[k][eq + 1 ..]);
    }
    return operands[k..];
}

/// Option combinations GNU rejects (with a usage hint).
pub const Problem = enum { null_with_command, chdir_without_command, argv0_without_command };

pub fn check(command_len: usize, nul: bool, chdir: ?[]const u8, argv0: ?[]const u8) ?Problem {
    if (nul and command_len > 0) return .null_with_command;
    if (command_len == 0 and chdir != null) return .chdir_without_command;
    if (command_len == 0 and argv0 != null) return .argv0_without_command;
    return null;
}

/// The argument vector: `command`, with --argv0 replacing the first element.
pub fn commandArgv(arena: std.mem.Allocator, command: []const []const u8, argv0: ?[]const u8) error{OutOfMemory}![]const []const u8 {
    const argv = try arena.alloc([]const u8, command.len);
    for (command, 0..) |c, i| argv[i] = c;
    if (argv0) |z| argv[0] = z;
    return argv;
}

/// GNU hints at -S when a command name with blanks was not found.
pub fn wantsShebangHint(command0: []const u8) bool {
    return std.mem.indexOfAny(u8, command0, " \t\n\x0b\x0c\r") != null;
}

/// Print the environment, one NAME=VALUE per entry ended by newline or NUL.
pub fn print(env: *const Map, nul: bool, out: *Io.Writer) Io.Writer.Error!void {
    var it = env.iterator();
    while (it.next()) |e| {
        try out.writeAll(e.key_ptr.*);
        try out.writeByte('=');
        try out.writeAll(e.value_ptr.*);
        try out.writeByte(if (nul) 0 else '\n');
    }
}

/// Why a -S string could not be split.
pub const SplitProblem = union(enum) {
    no_terminating_quote,
    backslash_at_end,
    /// The character after a backslash that has no meaning.
    invalid_sequence: u8,
    /// `$` not followed by `{NAME}`; the rest of the text from the `$`.
    bad_expansion: []const u8,
};

pub const Split = union(enum) {
    ok: []const [:0]const u8,
    bad: SplitProblem,
};

/// Split a `-S` string into arguments. Rules (GNU manual, "-S/--split-string
/// usage in scripts"): blanks separate words; '...' is literal except \\ and
/// \'; "..." allows escapes and ${VAR}; unquoted \_ is a separator; \c ends
/// the string; # at the start of a word starts a comment. `env` supplies the
/// ${VAR} values. `a` owns the result.
pub fn splitString(a: std.mem.Allocator, env: *const Map, text: []const u8) error{OutOfMemory}!Split {
    var out: std.ArrayList([:0]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    const blanks = " \t\n\x0b\x0c\r";
    while (i < text.len) {
        const c = text[i];
        if (std.mem.indexOfScalar(u8, blanks, c) != null) {
            if (in_word) try flush(a, &out, &word, &in_word);
            i += 1;
            continue;
        }
        if (c == '#' and !in_word) break;
        in_word = true;
        switch (c) {
            '\'' => {
                i += 1;
                while (true) {
                    if (i >= text.len) return .{ .bad = .no_terminating_quote };
                    const d = text[i];
                    if (d == '\'') break;
                    if (d == '\\' and i + 1 < text.len and (text[i + 1] == '\'' or text[i + 1] == '\\')) {
                        try word.append(a, text[i + 1]);
                        i += 2;
                        continue;
                    }
                    try word.append(a, d);
                    i += 1;
                }
                i += 1;
            },
            '"' => {
                i += 1;
                while (true) {
                    if (i >= text.len) return .{ .bad = .no_terminating_quote };
                    const d = text[i];
                    if (d == '"') break;
                    if (d == '\\') {
                        i += 1;
                        if (i >= text.len) return .{ .bad = .backslash_at_end };
                        const e = text[i];
                        switch (e) {
                            '"', '\\', '$' => try word.append(a, e),
                            '_' => try word.append(a, ' '),
                            'c' => {
                                try flush(a, &out, &word, &in_word);
                                return .{ .ok = out.items };
                            },
                            'f' => try word.append(a, 12),
                            'n' => try word.append(a, 10),
                            'r' => try word.append(a, 13),
                            't' => try word.append(a, 9),
                            'v' => try word.append(a, 11),
                            else => return .{ .bad = .{ .invalid_sequence = e } },
                        }
                        i += 1;
                        continue;
                    }
                    if (d == '$') {
                        i = switch (try expand(a, env, text, i, &word)) {
                            .next => |n| n,
                            .bad => |b| return .{ .bad = b },
                        };
                        continue;
                    }
                    try word.append(a, d);
                    i += 1;
                }
                i += 1;
            },
            '$' => i = switch (try expand(a, env, text, i, &word)) {
                .next => |n| n,
                .bad => |b| return .{ .bad = b },
            },
            '\\' => {
                i += 1;
                if (i >= text.len) return .{ .bad = .backslash_at_end };
                const e = text[i];
                switch (e) {
                    '_' => try flush(a, &out, &word, &in_word),
                    'c' => {
                        if (in_word and word.items.len > 0) try flush(a, &out, &word, &in_word);
                        return .{ .ok = out.items };
                    },
                    '#', '$', '"', '\'', '\\' => try word.append(a, e),
                    'f' => try word.append(a, 12),
                    'n' => try word.append(a, 10),
                    'r' => try word.append(a, 13),
                    't' => try word.append(a, 9),
                    'v' => try word.append(a, 11),
                    else => return .{ .bad = .{ .invalid_sequence = e } },
                }
                i += 1;
            },
            else => {
                try word.append(a, c);
                i += 1;
            },
        }
    }
    if (in_word) try flush(a, &out, &word, &in_word);
    return .{ .ok = out.items };
}

fn flush(a: std.mem.Allocator, out: *std.ArrayList([:0]const u8), word: *std.ArrayList(u8), in_word: *bool) error{OutOfMemory}!void {
    const z = try a.dupeSentinel(u8, word.items, 0);
    try out.append(a, z);
    word.clearRetainingCapacity();
    in_word.* = false;
}

const Expanded = union(enum) { next: usize, bad: SplitProblem };

/// `${NAME}` at text[i]; yields the index after it.
fn expand(a: std.mem.Allocator, env: *const Map, text: []const u8, i: usize, word: *std.ArrayList(u8)) error{OutOfMemory}!Expanded {
    const bad: Expanded = .{ .bad = .{ .bad_expansion = text[i..] } };
    if (i + 1 >= text.len or text[i + 1] != '{') return bad;
    var j = i + 2;
    if (j >= text.len or !(std.ascii.isAlphabetic(text[j]) or text[j] == '_')) return bad;
    while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) j += 1;
    if (j >= text.len or text[j] != '}') return bad;
    if (env.get(text[i + 2 .. j])) |v| try word.appendSlice(a, v);
    return .{ .next = j + 1 };
}

fn splitOk(a: std.mem.Allocator, env: *const Map, text: []const u8) ![]const [:0]const u8 {
    return switch (try splitString(a, env, text)) {
        .ok => |p| p,
        .bad => error.Bad,
    };
}

test "splitString words, quotes and variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = Map.init(a);
    try m.put("X", "val");
    const p = try splitOk(a, &m, "a 'b c' \"d ${X}\" e\\_f");
    try std.testing.expectEqual(@as(usize, 5), p.len);
    try std.testing.expectEqualStrings("a", p[0]);
    try std.testing.expectEqualStrings("b c", p[1]);
    try std.testing.expectEqualStrings("d val", p[2]);
    try std.testing.expectEqualStrings("e", p[3]);
    try std.testing.expectEqualStrings("f", p[4]);
}

test "splitString errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = Map.init(a);
    try std.testing.expect((try splitString(a, &m, "'abc")).bad == .no_terminating_quote);
    try std.testing.expect((try splitString(a, &m, "a\\")).bad == .backslash_at_end);
    try std.testing.expect((try splitString(a, &m, "a $B")).bad == .bad_expansion);
    try std.testing.expectEqual(@as(u8, 'q'), (try splitString(a, &m, "\\q")).bad.invalid_sequence);
}

test "applyAssignments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Map.init(arena.allocator());
    const rest = try applyAssignments(&m, &.{ "A=1", "B=", "cmd", "C=3" }, .none);
    try std.testing.expectEqual(@as(usize, 2), rest.len);
    try std.testing.expectEqualStrings("1", m.get("A").?);
    try std.testing.expectEqualStrings("", m.get("B").?);
}
