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
    inline for (commands.all) |name| {
        _ = commands.get(name);
        std.testing.refAllDecls(@field(commands.modules, name));
    }
}

test "true/false exit statuses" {
    try std.testing.expectEqual(@as(u8, 0), commands.modules.true.exit_status);
    try std.testing.expectEqual(@as(u8, 1), commands.modules.false.exit_status);
}
