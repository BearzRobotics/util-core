//! `[` — the bracketed form of test; see test.zig.
const cli = @import("../cli.zig");
const test_cmd = @import("test.zig");

pub fn main(ctx: cli.Context) u8 {
    return test_cmd.run(ctx, true);
}
