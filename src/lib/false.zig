// SPDX-License-Identifier: GPL-2.0-or-later
//! false: do nothing, unsuccessfully (library form, decision 0004).

pub const Options = struct {};

/// Exit status of `false`.
pub const exit_status: u8 = 1;

/// The status `false` ends with; it has no other effect.
pub fn run(opts: Options) u8 {
    _ = opts;
    return exit_status;
}

test "false fails" {
    try @import("std").testing.expectEqual(@as(u8, 1), run(.{}));
}
