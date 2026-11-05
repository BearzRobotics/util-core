//! Command registry. Each command lives in src/commands/<name>.zig and exports
//! `pub fn main(ctx: cli.Context) u8`.
//!
//! To add a command: create its file, then add it to both `all` and `modules`.

const std = @import("std");
const cli = @import("cli.zig");

/// Every command this source tree knows about.
pub const all = [_][]const u8{ "true", "false", "yes", "echo", "basename", "dirname", "cat", "wc", "dircolors", "pwd", "printenv", "sleep", "tee", "head", "tac", "tail", "seq", "mkdir", "rmdir", "cut", "paste", "uniq", "fold", "nl", "tr" };

/// Command source files, keyed by command name. @import needs a string
/// literal, so each command is listed here explicitly. Importing a file only
/// parses it; a command's code is compiled into a binary only when `get`
/// references it.
pub const modules = .{
    .true = @import("commands/true.zig"),
    .false = @import("commands/false.zig"),
    .yes = @import("commands/yes.zig"),
    .echo = @import("commands/echo.zig"),
    .basename = @import("commands/basename.zig"),
    .dirname = @import("commands/dirname.zig"),
    .cat = @import("commands/cat.zig"),
    .wc = @import("commands/wc.zig"),
    .dircolors = @import("commands/dircolors.zig"),
    .pwd = @import("commands/pwd.zig"),
    .printenv = @import("commands/printenv.zig"),
    .sleep = @import("commands/sleep.zig"),
    .tee = @import("commands/tee.zig"),
    .head = @import("commands/head.zig"),
    .tac = @import("commands/tac.zig"),
    .tail = @import("commands/tail.zig"),
    .seq = @import("commands/seq.zig"),
    .mkdir = @import("commands/mkdir.zig"),
    .rmdir = @import("commands/rmdir.zig"),
    .cut = @import("commands/cut.zig"),
    .paste = @import("commands/paste.zig"),
    .uniq = @import("commands/uniq.zig"),
    .fold = @import("commands/fold.zig"),
    .nl = @import("commands/nl.zig"),
    .tr = @import("commands/tr.zig"),
};

/// Frontend for a command known at comptime.
pub fn get(comptime name: []const u8) cli.CommandFn {
    return @field(modules, name).main;
}

/// Runtime lookup restricted to the `enabled` command names.
pub fn find(comptime enabled: []const []const u8, name: []const u8) ?cli.CommandFn {
    inline for (enabled) |e| {
        if (std.mem.eql(u8, e, name)) return get(e);
    }
    return null;
}
