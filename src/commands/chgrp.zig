//! chgrp — change group ownership. See chown.zig.

const cli = @import("../cli.zig");
const chown = @import("chown.zig");

pub fn main(ctx: cli.Context) u8 {
    return chown.run(ctx, .chgrp);
}
