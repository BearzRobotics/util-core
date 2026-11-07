//! Individual-executable entry point: one binary per command. The command is
//! fixed at build time through the `build_options.command` option.

const std = @import("std");
const options = @import("build_options");
const cli = @import("cli.zig");
const sys = @import("sys.zig");
const commands = @import("commands.zig");

pub fn main(init: std.process.Init) !u8 {
    sys.restoreSigpipe();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return commands.get(options.command)(.{
        .name = options.command,
        .args = args[1..],
        .io = init.io,
        .gpa = init.gpa,
        .environ = init.environ_map,
    });
}
