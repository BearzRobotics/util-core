// SPDX-License-Identifier: GPL-2.0-or-later
//! false — do nothing, unsuccessfully. Reference: GNU coreutils false(1).
//! Ignores all arguments except a sole --help or --version, and exits 1 even
//! for those.

const cli = @import("../cli.zig");

pub const exit_status: u8 = 1;

pub fn main(ctx: cli.Context) u8 {
    if (cli.soleArg(ctx.args, "--help")) {
        _ = cli.writeStdout(ctx.io, "Usage: false [ignored command line arguments]\n" ++
            "Exit with a status code indicating failure.\n");
    } else if (cli.soleArg(ctx.args, "--version")) {
        _ = cli.printVersion(ctx);
    }
    return exit_status;
}
