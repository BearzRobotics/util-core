// SPDX-License-Identifier: GPL-2.0-or-later
//! dir — list directory contents in columns (ls -C -b). See ls.zig.

const cli = @import("../cli.zig");
const ls = @import("ls.zig");

pub fn main(ctx: cli.Context) u8 {
    return ls.run(ctx, .multi_col);
}
