// SPDX-License-Identifier: GPL-2.0-or-later
//! true: do nothing, successfully (library form, decision 0004).

pub const Options = struct {};

/// Exit status of `true`.
pub const exit_status: u8 = 0;

/// The status `true` ends with; it has no other effect.
pub fn run(opts: Options) u8 {
    _ = opts;
    return exit_status;
}

test "true succeeds" {
    try @import("std").testing.expectEqual(@as(u8, 0), run(.{}));
}
