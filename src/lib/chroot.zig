// SPDX-License-Identifier: GPL-2.0-or-later
//! chroot library: the decision logic of running a command with a different
//! root directory.
//! Reference: GNU coreutils manual "chroot invocation" (9.7).
//!
//! chroot(2), chdir and replacing the process are process-wide actions
//! (decision 0004) and stay in the wrapper (`src/commands/chroot.zig`); this
//! module validates the request and builds the command line.
//!
//! --userspec and --groups are not supported (they could not be verified
//! without root): `unsupported` reports them.

const std = @import("std");

pub const Options = struct {
    /// NEWROOT operand.
    newroot: []const u8,
    skip_chdir: bool = false,
    userspec: ?[]const u8 = null,
    groups: ?[]const u8 = null,
};

pub const Problem = enum {
    /// --skip-chdir with a NEWROOT other than "/".
    skip_chdir_needs_root,
};

pub fn check(opts: Options) ?Problem {
    if (opts.skip_chdir and !std.mem.eql(u8, opts.newroot, "/")) return .skip_chdir_needs_root;
    return null;
}

/// --userspec or --groups given (not supported).
pub fn unsupported(opts: Options) bool {
    return opts.userspec != null or opts.groups != null;
}

/// The command to run: `command` (the operands after NEWROOT), or an
/// interactive shell (`shell`, else /bin/sh, with -i) when there is none.
/// The result is owned by `arena`.
pub fn commandLine(arena: std.mem.Allocator, command: []const []const u8, shell: ?[]const u8) error{OutOfMemory}![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    if (command.len > 0) {
        try argv.appendSlice(arena, command);
    } else {
        try argv.append(arena, if (shell != null and shell.?.len > 0) shell.? else "/bin/sh");
        try argv.append(arena, "-i");
    }
    return argv.items;
}

test "commandLine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try commandLine(arena.allocator(), &.{}, null);
    try std.testing.expectEqualStrings("/bin/sh", a[0]);
    try std.testing.expectEqualStrings("-i", a[1]);
    const b = try commandLine(arena.allocator(), &.{ "ls", "-l" }, "/bin/zsh");
    try std.testing.expectEqual(@as(usize, 2), b.len);
    try std.testing.expect(check(.{ .newroot = "/x", .skip_chdir = true }) != null);
}
