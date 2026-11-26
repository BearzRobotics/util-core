// SPDX-License-Identifier: GPL-2.0-or-later
//! Replace an existing name with a hard or symbolic link, for `ln -f` and the
//! forced links of cp and mv.
//!
//! The link is first made under a temporary name in the destination's
//! directory and then renamed over the destination. If either step fails (the
//! source is on another file system, the target name is too long, ...) the
//! destination is still what it was. gnulib's force-link.c does the same.

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const E = sys.E;

pub const Kind = union(enum) {
    /// A hard link to `source`; `follow` links to the target of a symlink.
    hard: struct { follow: bool },
    /// A symbolic link whose text is `source`.
    symbolic,
};

const template = "CuXXXXXX";

/// Make `dest` a link to `source`, replacing what is there (not a directory).
/// Null on success, else the error, with `dest` unchanged.
pub fn replace(io: Io, source: []const u8, dest: []const u8, kind: Kind) ?E {
    const trimmed = std.mem.trimEnd(u8, dest, "/");
    const dir_len = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| slash + 1 else 0;
    var buf: [4096]u8 = undefined;
    if (dir_len + template.len > buf.len) return .NAMETOOLONG;
    @memcpy(buf[0..dir_len], dest[0..dir_len]);
    const temp = buf[0 .. dir_len + template.len];
    @memcpy(temp[dir_len..], template);

    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        fillRandom(io, temp[temp.len - 6 ..]);
        const failure = switch (kind) {
            .hard => |h| sys.linkPath(source, temp, h.follow),
            .symbolic => sys.symlinkPath(source, temp),
        } orelse break;
        if (failure != .EXIST or attempts == 100) return failure;
    }
    const renamed = sys.renamePath(temp, dest, 0);
    // After a failure, and also after a rename that did nothing because both
    // names were already links to one file, the temporary name is still there.
    if (renamed != null or kind == .hard) _ = sys.unlinkPath(temp, false);
    return renamed;
}

fn fillRandom(io: Io, out: []u8) void {
    const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var random: [6]u8 = undefined;
    io.random(&random);
    for (out, random[0..out.len]) |*c, r| c.* = letters[r % letters.len];
}
