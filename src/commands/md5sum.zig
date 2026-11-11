// SPDX-License-Identifier: GPL-2.0-or-later
//! md5sum — see src/hashsum.zig.
const cli = @import("../cli.zig");
const hashsum = @import("../hashsum.zig");

pub fn main(ctx: cli.Context) u8 {
    return hashsum.main(ctx, .md5sum);
}
