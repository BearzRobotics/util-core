// SPDX-License-Identifier: GPL-2.0-or-later
//! true — do nothing, successfully. Reference: GNU coreutils true(1).
//! Ignores all arguments except a sole --help or --version.

const cli = @import("../cli.zig");

pub const exit_status: u8 = 0;

pub fn main(ctx: cli.Context) u8 {
    if (cli.soleArg(ctx.args, "--help")) {
        _ = cli.writeStdout(ctx.io, "Usage: true [ignored command line arguments]\n" ++
            "Exit with a status code indicating success.\n");
    } else if (cli.soleArg(ctx.args, "--version")) {
        _ = cli.printVersion(ctx);
    }
    return exit_status;
}
