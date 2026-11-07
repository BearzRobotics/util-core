//! sha384sum — see src/hashsum.zig.
const cli = @import("../cli.zig");
const hashsum = @import("../hashsum.zig");

pub fn main(ctx: cli.Context) u8 {
    return hashsum.main(ctx, .sha384sum);
}
