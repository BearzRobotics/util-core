// SPDX-License-Identifier: GPL-2.0-or-later
//! pathchk: check whether file names are valid or portable (library form,
//! decision 0004).
//!
//! `basic` (-p) checks the POSIX portable character set and the minimum
//! limits (14 bytes per component, 255 per name); `extra` (-P) rejects empty
//! names and components starting with '-'. Without `basic` the name is looked
//! at with lstat, and the limits are the Linux ones (NAME_MAX 255, PATH_MAX
//! 4096): the `pathconf` values of unusual file systems are not consulted.

const std = @import("std");
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;

pub const Options = struct {
    /// -p: portable character set and POSIX minimum limits.
    basic: bool = false,
    /// -P: reject empty names and components starting with '-'.
    extra: bool = false,
};

/// Why a name was rejected. Slices borrow from the name being checked.
pub const Event = struct {
    /// The name given.
    file: []const u8,
    problem: Problem,

    pub const Problem = union(enum) {
        empty_name,
        leading_hyphen,
        non_portable_char: u8,
        stat_failed: std.os.linux.E,
        name_too_long: struct { limit: usize, length: usize },
        component_too_long: struct { limit: usize, length: usize, component: []const u8 },
    };
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// Names that were rejected (an event was emitted for each).
    invalid: usize = 0,
};

/// Checks each of `names`.
pub fn run(env: Env, opts: Options, names: []const []const u8, obs: Observer) Result {
    var res: Result = .{};
    for (names) |n| if (!validate(env, n, opts, obs)) {
        res.invalid += 1;
    };
    return res;
}

fn portableChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == '/';
}

/// Checks one name; false (after emitting the reason) when it is rejected.
pub fn validate(env: Env, file: []const u8, opts: Options, obs: Observer) bool {
    _ = env;
    const basic = opts.basic;
    if (opts.extra and !noLeadingHyphen(file, obs)) return false;
    if ((basic or opts.extra) and file.len == 0) {
        obs.emit(.{ .file = file, .problem = .empty_name });
        return false;
    }
    if (basic) {
        for (file) |c| if (!portableChar(c)) {
            obs.emit(.{ .file = file, .problem = .{ .non_portable_char = c } });
            return false;
        };
    } else {
        var err: std.os.linux.E = .SUCCESS;
        if (sys.fileStat(file, false, &err) == null) {
            if (err != .NOENT or file.len == 0) {
                obs.emit(.{ .file = file, .problem = .{ .stat_failed = err } });
                return false;
            }
        }
    }
    const name_max: usize = if (basic) 14 else 255;
    const path_max: usize = if (basic) 256 else 4096;
    if (file.len >= path_max) {
        obs.emit(.{ .file = file, .problem = .{ .name_too_long = .{ .limit = path_max - 1, .length = file.len } } });
        return false;
    }
    var it = std.mem.splitScalar(u8, file, '/');
    while (it.next()) |comp| {
        if (comp.len > name_max) {
            obs.emit(.{ .file = file, .problem = .{ .component_too_long = .{ .limit = name_max, .length = comp.len, .component = comp } } });
            return false;
        }
    }
    return true;
}

fn noLeadingHyphen(file: []const u8, obs: Observer) bool {
    var it = std.mem.splitScalar(u8, file, '/');
    while (it.next()) |comp| {
        if (comp.len > 0 and comp[0] == '-') {
            obs.emit(.{ .file = file, .problem = .leading_hyphen });
            return false;
        }
    }
    return true;
}

const Collect = struct {
    last: ?Event.Problem = null,
    fn on(ctx: ?*anyopaque, ev: Event) void {
        const c: *Collect = @ptrCast(@alignCast(ctx.?));
        c.last = ev.problem;
    }
};

test "portable checks" {
    var c: Collect = .{};
    const obs: Observer = .{ .context = &c, .func = Collect.on };
    const env: Env = .{ .io = undefined, .gpa = std.testing.allocator };
    try std.testing.expect(validate(env, "a/b.c", .{ .basic = true }, obs));
    try std.testing.expect(!validate(env, "a b", .{ .basic = true }, obs));
    try std.testing.expectEqual(@as(u8, ' '), c.last.?.non_portable_char);
    try std.testing.expect(!validate(env, "a/-b", .{ .extra = true }, obs));
    try std.testing.expect(c.last.? == .leading_hyphen);
    try std.testing.expect(!validate(env, "", .{ .basic = true }, obs));
    try std.testing.expect(c.last.? == .empty_name);
    try std.testing.expect(!validate(env, "0123456789abcdef", .{ .basic = true }, obs));
    try std.testing.expectEqual(@as(usize, 16), c.last.?.component_too_long.length);
}
