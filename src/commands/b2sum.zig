// SPDX-License-Identifier: GPL-2.0-or-later
//! b2sum — see src/hashsum.zig.
const cli = @import("../cli.zig");
const hashsum = @import("../hashsum.zig");

pub fn main(ctx: cli.Context) u8 {
    return hashsum.main(ctx, .b2sum);
}
