// SPDX-License-Identifier: GPL-2.0-or-later
//! base64 — see src/baseenc.zig.
const cli = @import("../cli.zig");
const baseenc = @import("../baseenc.zig");

pub fn main(ctx: cli.Context) u8 {
    return baseenc.main(ctx, .base64);
}
