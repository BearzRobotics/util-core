// SPDX-License-Identifier: GPL-2.0-or-later
//! Fuzz tests: file-name quoting. Template for the other files in this directory.
//!
//! Pattern (drive it with `engine.fuzz`, not `std.testing.fuzz`: see engine.zig): a
//! `fn (ctx, *Smith) !void` that turns the fuzzer's bytes into the input of
//! a library entry point, runs it, and checks invariants (no crash, no hang, no leak,
//! output well-formed). Use `std.testing.allocator` so leaks fail the test. Keep the
//! input small and the work bounded.

const std = @import("std");
const quote = @import("../quote.zig");
const engine = @import("engine.zig");

fn quotedNeverFails(_: void, smith: *std.testing.Smith) anyerror!void {
    var name: [256]u8 = undefined;
    const n = smith.slice(&name);
    var out: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    inline for (.{ false, true }) |always| {
        w.end = 0;
        try quote.Quoted.format(.{ .name = name[0..n], .always = always }, &w);
        // Whatever the bytes, the result is a non-empty quoted or plain word.
        try std.testing.expect(w.end > 0);
    }
}

test "fuzz: Quoted formats any byte string" {
    try engine.fuzz({}, quotedNeverFails, .{ .corpus = &.{ "", "a b", "it's", "\x00\xff\n", "\"$`\\" } });
}
