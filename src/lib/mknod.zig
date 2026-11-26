// SPDX-License-Identifier: GPL-2.0-or-later
//! mknod library: make block or character special files, or named pipes.
//! Reference: GNU coreutils manual "mknod invocation" (9.7).
//!
//! The caller supplies the umask: reading it is a process-wide operation, so
//! it stays in the wrapper.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const mode_mod = @import("../mode.zig");
const sys = @import("../sys.zig");
const dirat = @import("../dirat.zig");

pub const Env = common.Env;

pub const Kind = enum { block, char, fifo };

/// Kind named by the first character of the TYPE operand (GNU looks only at
/// that one); null for an unknown type.
pub fn kindOf(type_text: []const u8) ?Kind {
    const c: u8 = if (type_text.len > 0) type_text[0] else 0;
    return switch (c) {
        'b' => .block,
        'c', 'u' => .char,
        'p' => .fifo,
        else => null,
    };
}

/// Parse a MAJOR or MINOR number as GNU does, with strtoumax(3) in base 0:
/// optional leading white space and "+", then decimal, 0x hex, 0b binary or
/// 0 octal digits. Null when it is not one or does not fit in 32 bits (a
/// larger value would silently name another device).
pub fn parseNumber(text: []const u8) ?u32 {
    var s = std.mem.trimStart(u8, text, " \t\n\x0b\x0c\r");
    if (s.len > 0 and s[0] == '+') s = s[1..];
    var base: u8 = 10;
    if (s.len > 1 and s[0] == '0') switch (s[1]) {
        'x', 'X' => {
            base = 16;
            s = s[2..];
        },
        'b', 'B' => {
            base = 2;
            s = s[2..];
        },
        else => base = 8,
    };
    if (s.len == 0) return null;
    var value: u32 = 0;
    for (s) |c| {
        // Not parseInt: it would also take a sign and '_' separators.
        const digit = std.fmt.charToDigit(c, base) catch return null;
        value = std.math.mul(u32, value, base) catch return null;
        value = std.math.add(u32, value, digit) catch return null;
    }
    return value;
}

/// The device number glibc reserves for "no device" (makedev of all ones).
pub const no_device: u64 = std.math.maxInt(u64);

/// glibc makedev(): split the numbers into the kernel's dev_t layout.
pub fn makedev(major: u64, minor: u64) u64 {
    return ((major & 0xfffff000) << 32) | ((major & 0xfff) << 8) | ((minor & 0xffffff00) << 12) | (minor & 0xff);
}

pub const ModeError = error{ InvalidMode, NotPermissionBits };

/// Resolve the -m text to the exact permission bits (null without -m).
pub fn resolveMode(text: ?[]const u8, umask: u16) ModeError!?u16 {
    const t = text orelse return null;
    const final = mode_mod.apply(t, 0o666, false, umask) orelse return error.InvalidMode;
    if (final > 0o777) return error.NotPermissionBits;
    return final;
}

pub const Failure = union(enum) {
    /// mknod(2) failed.
    create: std.os.linux.E,
    /// The follow-up chmod for -m failed.
    permissions: std.os.linux.E,
};

pub const Options = struct {
    kind: Kind,
    /// Device number from `makedev`; 0 for a FIFO.
    dev: u64 = 0,
    /// Exact mode from `resolveMode`; null: 0666 minus the umask.
    mode: ?u16 = null,
};

/// Create the node `name`; returns the failure, if any.
pub fn run(env: Env, name: []const u8, opts: Options) error{OutOfMemory}!?Failure {
    _ = env; // every command library takes it
    const file_type: u32 = switch (opts.kind) {
        .block => 0o060000,
        .char => 0o020000,
        .fifo => 0o010000,
    };
    var pe: sys.E = .SUCCESS;
    const spot = dirat.Spot.open(name, &pe) orelse return .{ .create = pe };
    defer spot.close();
    if (sys.mknodAt(spot.dir, spot.name, file_type | (opts.mode orelse 0o666), opts.dev)) |e| return .{ .create = e };
    if (opts.mode) |m| if (spot.setMode(file_type, m)) |e| return .{ .permissions = e };
    return null;
}
