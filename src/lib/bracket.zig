// SPDX-License-Identifier: GPL-2.0-or-later
//! `[` library: the bracketed form of test. The arguments must end in "]"; the
//! expression before it is evaluated by `test.zig` (the evaluation is shared,
//! with GNU's one `[`-specific diagnostic selected by `Options.bracket`).

const std = @import("std");
const test_lib = @import("test.zig");

pub const Env = test_lib.Env;
pub const Event = test_lib.Event;
pub const Observer = test_lib.Observer;

pub const Error = test_lib.Error || error{MissingBracket};

/// Evaluate `args` as the arguments of `[`: the expression and a closing "]".
/// `error.MissingBracket` when the last argument is not "]" (or there are no
/// arguments); otherwise as `test.evaluate`.
pub fn evaluate(env: Env, args: []const []const u8, observer: Observer) Error!bool {
    if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) return error.MissingBracket;
    return test_lib.evaluate(env, args[0 .. args.len - 1], .{ .bracket = true }, observer);
}
