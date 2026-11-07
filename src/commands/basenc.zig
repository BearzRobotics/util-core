//! basenc — see src/baseenc.zig.
const cli = @import("../cli.zig");
const baseenc = @import("../baseenc.zig");

pub fn main(ctx: cli.Context) u8 {
    return baseenc.main(ctx, null);
}
