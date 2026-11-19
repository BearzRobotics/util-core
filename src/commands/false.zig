// SPDX-License-Identifier: GPL-2.0-or-later
//! false: thin wrapper over `util_core.false` (decision 0004). Ignores all
//! arguments except a sole --help or --version, and exits 1 even for those.

const cli = @import("../cli.zig");
const lib = @import("../lib/false.zig");

pub const exit_status: u8 = lib.exit_status;

pub fn main(ctx: cli.Context) u8 {
    if (cli.soleArg(ctx.args, "--help")) {
        _ = cli.writeStdout(ctx.io, "Usage: false [ignored command line arguments]\n" ++
            "Exit with a status code indicating failure.\n");
    } else if (cli.soleArg(ctx.args, "--version")) {
        _ = cli.printVersion(ctx);
    }
    return lib.run(.{});
}
