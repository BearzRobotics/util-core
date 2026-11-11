// SPDX-License-Identifier: GPL-2.0-or-later
//! Unit-test root: pulls in every command so `zig build test` covers them.
const std = @import("std");
const commands = @import("commands.zig");

test {
    _ = @import("count_arg.zig");
    _ = @import("fmt_float.zig");
    _ = @import("mode.zig");
    _ = @import("lines.zig");
    _ = @import("tabs.zig");
    _ = @import("sys.zig");
    _ = @import("bytes.zig");
    _ = @import("hash.zig");
    _ = @import("hashsum.zig");
    _ = @import("baseenc.zig");
    _ = @import("userdb.zig");
    _ = @import("paths.zig");
    _ = @import("numparse.zig");
    _ = @import("posixre.zig");
    _ = @import("unicode.zig");
    _ = @import("getopt.zig");
    _ = @import("exec.zig");
    _ = @import("tz.zig");
    _ = @import("strftime.zig");
    _ = @import("datetime.zig");
    _ = @import("quotearg.zig");
    _ = @import("human.zig");
    _ = @import("filevercmp.zig");
    _ = @import("fnmatch.zig");
    _ = @import("argmatch.zig");
    _ = @import("copy.zig");
    _ = @import("backup.zig");
    inline for (commands.all) |name| {
        _ = commands.get(name);
        std.testing.refAllDecls(@field(commands.modules, name));
    }
}

test "true/false exit statuses" {
    try std.testing.expectEqual(@as(u8, 0), commands.modules.true.exit_status);
    try std.testing.expectEqual(@as(u8, 1), commands.modules.false.exit_status);
}
