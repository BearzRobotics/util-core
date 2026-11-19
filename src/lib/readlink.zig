// SPDX-License-Identifier: GPL-2.0-or-later
//! readlink library: the value of a symbolic link, or a canonical file name.
//! Reference: GNU coreutils manual "readlink invocation" (9.7).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const paths = @import("../paths.zig");

pub const Env = common.Env;
pub const Mode = paths.Mode;

pub const Options = struct {
    /// `.none`: print the link value; the others canonicalise (-f, -e, -m).
    mode: Mode = .none,
    /// Write the terminator after each name (false for -n with one name).
    newline: bool = true,
    /// -z: terminate with NUL instead of newline.
    zero: bool = false,
};

/// Why one name produced no output. `link` is the readlink(2) error (mode
/// `.none`), `path` the canonicalisation error.
pub const Failure = union(enum) {
    link: anyerror,
    path: paths.Error,
};

pub const Event = struct { name: []const u8, failure: Failure };
pub const Observer = common.Observer(Event);

pub const Result = struct { failed: bool = false };

/// Resolve each name and write the result to `out`. A name that cannot be
/// resolved is reported to `obs` and makes the result `failed`; the rest are
/// still processed.
pub fn run(env: Env, opts: Options, names: []const []const u8, out: *Io.Writer, obs: Observer) (Io.Writer.Error || error{OutOfMemory})!Result {
    var res: Result = .{};
    for (names) |f| {
        var failure: Failure = .{ .path = error.NotFound };
        const result: ?[]u8 = if (opts.mode == .none) blk: {
            var buf: [4096]u8 = undefined;
            const n = Io.Dir.cwd().readLink(env.io, f, &buf) catch |e| {
                failure = .{ .link = e };
                break :blk null;
            };
            break :blk env.gpa.dupe(u8, buf[0..n]) catch null;
        } else paths.resolve(env, f, opts.mode) catch |e| blk: {
            failure = .{ .path = e };
            break :blk null;
        };
        if (result) |r| {
            defer env.gpa.free(r);
            try out.writeAll(r);
            if (opts.newline or opts.zero) try out.writeByte(if (opts.zero) 0 else '\n');
        } else {
            obs.emit(.{ .name = f, .failure = failure });
            res.failed = true;
        }
    }
    return res;
}
