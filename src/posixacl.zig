// SPDX-License-Identifier: GPL-2.0-or-later
//! Preserving a file's permissions together with its POSIX ACLs, for the
//! copies that keep the mode (cp -p, -a, --preserve=mode, and mv between file
//! systems).
//!
//! The mode alone is not enough: with an access ACL the group bits of st_mode
//! are the ACL's mask, an upper bound for the named users and groups, and not
//! what the owning group may do. Giving them to a file without the ACL would
//! hand the owning group all of it.
//!
//! As GNU does, only the ACLs the source has are transferred (the access ACL,
//! and a directory's default ACL); the destination keeps what it got from its
//! own directory otherwise. The ACLs are the Linux extended attributes
//! `system.posix_acl_*` (layout: include/uapi/linux/posix_acl_xattr.h). Other
//! systems report that they have none, and only the mode is set.

const std = @import("std");
const sys = @import("sys.zig");

const access_name = "system.posix_acl_access";
const default_name = "system.posix_acl_default";

/// XATTR_SIZE_MAX.
const max_len = 64 * 1024;

/// A file by its open descriptor, or by path (following links, as chmod does).
pub const Place = union(enum) { fd: sys.Handle, path: []const u8 };

fn read(from: Place, name: [:0]const u8, buf: []u8, err: *sys.E) ?usize {
    return switch (from) {
        .fd => |fd| sys.getXattrFd(fd, name, buf, err),
        .path => |p| sys.getXattr(p, name, true, buf, err),
    };
}

fn write(to: Place, name: [:0]const u8, value: []const u8) ?sys.E {
    return switch (to) {
        .fd => |fd| sys.setXattrFd(fd, name, value),
        .path => |p| sys.setXattr(p, name, value),
    };
}

fn setMode(to: Place, mode: u32) ?sys.E {
    return switch (to) {
        .fd => |fd| sys.fchmodFd(fd, mode),
        .path => |p| sys.chmodPath(p, mode, false),
    };
}

/// The errors that mean there is no such ACL to transfer.
fn absent(e: sys.E) bool {
    return e == .NODATA or e == .OPNOTSUPP or e == .NOSYS;
}

/// Give `dst` the permissions of `src`, whose st_mode permission bits are
/// `mode`. Returns the errno of what failed. When an ACL cannot be carried
/// over, `dst` still gets a mode, one that allows nobody more than `src` did.
pub noinline fn preserve(src: Place, dst: Place, mode: u32, is_dir: bool) ?sys.E {
    var buf: [max_len]u8 = undefined;
    var err: sys.E = .SUCCESS;
    var failure: ?sys.E = null;
    var granted = mode;
    if (read(src, access_name, &buf, &err)) |n| {
        if (write(dst, access_name, buf[0..n])) |e| {
            failure = e;
            granted = modeWithoutAcl(mode, buf[0..n]);
        }
    } else if (!absent(err)) {
        failure = err;
        granted = mode & ~@as(u32, 0o077);
    }
    if (setMode(dst, granted)) |e| return e;
    if (failure == null and is_dir) {
        if (read(src, default_name, &buf, &err)) |n| {
            failure = write(dst, default_name, buf[0..n]);
        } else if (!absent(err)) failure = err;
    }
    return failure;
}

/// The mode for a file that has to do without the access ACL `acl`. The owning
/// group gets its own entry, not the mask. A named user or group that loses its
/// entry falls under the group or the other bits, so neither may exceed what
/// any of them had.
fn modeWithoutAcl(mode: u32, acl: []const u8) u32 {
    const closed = mode & ~@as(u32, 0o077);
    if (acl.len < 4 or (acl.len - 4) % 8 != 0 or std.mem.readInt(u32, acl[0..4], .little) != 2) return closed;
    var mask: u16 = 7;
    var owning_group: u16 = 0;
    var i: usize = 4;
    while (i < acl.len) : (i += 8) {
        const tag = std.mem.readInt(u16, acl[i..][0..2], .little);
        const perm = std.mem.readInt(u16, acl[i + 2 ..][0..2], .little);
        if (tag == 0x04) owning_group = perm;
        if (tag == 0x10) mask = perm;
    }
    var limit: u16 = 7;
    i = 4;
    while (i < acl.len) : (i += 8) {
        const tag = std.mem.readInt(u16, acl[i..][0..2], .little);
        // Named users and named groups.
        if (tag == 0x02 or tag == 0x08) limit &= std.mem.readInt(u16, acl[i + 2 ..][0..2], .little) & mask;
    }
    const group: u32 = owning_group & mask & limit;
    return closed | ((group << 3) & mode) | (mode & limit);
}

fn testAcl(comptime entries: []const [2]u16) [4 + 8 * entries.len]u8 {
    var out: [4 + 8 * entries.len]u8 = @splat(0xff);
    std.mem.writeInt(u32, out[0..4], 2, .little);
    for (entries, 0..) |e, i| {
        std.mem.writeInt(u16, out[4 + 8 * i ..][0..2], e[0], .little);
        std.mem.writeInt(u16, out[6 + 8 * i ..][0..2], e[1], .little);
    }
    return out;
}

test "a mode without its ACL never allows more" {
    const t = std.testing;
    // user::rw-, user:N:rw-, group::---, mask::rw-, other::---
    const private = testAcl(&.{ .{ 1, 6 }, .{ 2, 6 }, .{ 4, 0 }, .{ 0x10, 6 }, .{ 0x20, 0 } });
    try t.expectEqual(@as(u32, 0o600), modeWithoutAcl(0o660, &private));
    // The group keeps what it and every named entry had.
    const readers = testAcl(&.{ .{ 1, 6 }, .{ 2, 4 }, .{ 4, 4 }, .{ 0x10, 6 }, .{ 0x20, 4 } });
    try t.expectEqual(@as(u32, 0o4644), modeWithoutAcl(0o4664, &readers));
    // A named user who was shut out must not get the other bits.
    const barred = testAcl(&.{ .{ 1, 6 }, .{ 2, 0 }, .{ 4, 4 }, .{ 0x10, 4 }, .{ 0x20, 4 } });
    try t.expectEqual(@as(u32, 0o600), modeWithoutAcl(0o644, &barred));
    try t.expectEqual(@as(u32, 0o700), modeWithoutAcl(0o775, "junk"));
}
