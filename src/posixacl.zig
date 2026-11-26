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
const builtin = @import("builtin");
const sys = @import("sys.zig");
const dirat = @import("dirat.zig");

const access_name = "system.posix_acl_access";
const default_name = "system.posix_acl_default";

/// XATTR_SIZE_MAX.
const max_len = 64 * 1024;

/// A file by its open descriptor, by path (following links, as chmod does;
/// sources only), or by its name in an open directory (destinations only).
pub const Place = union(enum) { fd: sys.Handle, path: []const u8, entry: Entry };

/// A directory or special file of kind `type_bits` (as in st_mode). A
/// symbolic link at the name is not followed, unless `through` gives the
/// directory that a link the caller means to go through led to.
pub const Entry = struct {
    spot: dirat.Spot,
    type_bits: u32,
    through: ?sys.FileStat = null,

    pub fn setMode(e: Entry, mode: u32) ?sys.E {
        if (e.through) |seen| return e.spot.setModeThroughLink(mode, seen);
        return e.spot.setMode(e.type_bits, mode);
    }

    fn setAcl(e: Entry, name: [:0]const u8, value: []const u8) ?sys.E {
        // No ACL is read on other systems, so none is ever written.
        if (builtin.os.tag != .linux) return .OPNOTSUPP;
        const is_dir = e.type_bits == 0o040000;
        const nofollow: u32 = if (e.through == null) sys.O.NOFOLLOW else 0;
        const at = if (e.through == null) std.mem.trimEnd(u8, e.spot.name, "/") else e.spot.name;
        var err: sys.E = .SUCCESS;
        // A readable directory takes the attribute directly. Anything else
        // is only named, and reached through the descriptor's /proc link.
        var direct = is_dir;
        var opened: ?sys.Handle = null;
        if (is_dir) opened = sys.openFdAt(e.spot.dir, at, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NONBLOCK | nofollow, 0, &err);
        if (opened == null) {
            direct = false;
            opened = sys.openFdAt(e.spot.dir, at, sys.O.PATH | nofollow, 0, &err);
        }
        const fd = opened orelse return err;
        defer _ = sys.closeFd(fd);
        const st = sys.fstatFd(fd, &err) orelse return err;
        if (st.mode & 0o170000 != e.type_bits) return .OPNOTSUPP;
        if (e.through) |seen| {
            if (st.ino != seen.ino or dirat.devOf(st) != dirat.devOf(seen)) return .NOENT;
        }
        if (direct) return sys.setXattrFd(fd, name, value);
        var buf: [32]u8 = undefined;
        const link = std.fmt.bufPrint(&buf, "/proc/self/fd/{d}", .{fd}) catch unreachable;
        return sys.setXattr(link, name, value);
    }
};

fn read(from: Place, name: [:0]const u8, buf: []u8, err: *sys.E) ?usize {
    return switch (from) {
        .fd => |fd| sys.getXattrFd(fd, name, buf, err),
        .path => |p| sys.getXattr(p, name, true, buf, err),
        .entry => unreachable,
    };
}

fn write(to: Place, name: [:0]const u8, value: []const u8) ?sys.E {
    return switch (to) {
        .fd => |fd| sys.setXattrFd(fd, name, value),
        .path => |p| sys.setXattr(p, name, value),
        .entry => |e| e.setAcl(name, value),
    };
}

fn setMode(to: Place, mode: u32) ?sys.E {
    return switch (to) {
        .fd => |fd| sys.fchmodFd(fd, mode),
        .path => |p| sys.chmodPath(p, mode, false),
        .entry => |e| e.setMode(mode),
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

/// Give `dst`, a new file about to take the place of `src`, the permissions
/// of `src` and nothing else: unlike a copy made by cp, it does not keep an
/// access ACL it got from its directory. `mode` is the permission bits of
/// `src`; `same_group` says whether `dst` has its group. A group that is not
/// the same gets no more than others had. Returns the errno of what failed;
/// `dst` then allows nobody more than `src` did.
pub noinline fn replacement(src: sys.Handle, dst: sys.Handle, mode: u32, same_group: bool) ?sys.E {
    var buf: [max_len]u8 = undefined;
    var err: sys.E = .SUCCESS;
    var failure: ?sys.E = null;
    var granted = mode;
    if (read(.{ .fd = src }, access_name, &buf, &err)) |n| {
        if (!same_group) limitOwningGroup(buf[0..n]);
        const e = sys.setXattrFd(dst, access_name, buf[0..n]) orelse return sys.fchmodFd(dst, granted);
        failure = e;
        granted = modeWithoutAcl(mode, buf[0..n]);
    } else {
        if (!absent(err)) {
            failure = err;
            granted = mode & ~@as(u32, 0o077);
        } else if (!same_group) {
            granted = mode & ~@as(u32, 0o070) | (mode & (mode << 3) & 0o070);
        }
    }
    if (sys.getXattrFd(dst, access_name, &buf, &err) != null) {
        // An ACL of only these three entries is stored as the plain mode.
        const plain = plainAcl(granted);
        if (sys.setXattrFd(dst, access_name, &plain)) |e| {
            // The group bits would be the mask of the ACL that stays.
            failure = e;
            granted &= ~@as(u32, 0o077);
        }
    }
    return sys.fchmodFd(dst, granted) orelse failure;
}

/// The access ACL that says what the permission bits of `mode` say.
fn plainAcl(mode: u32) [4 + 3 * 8]u8 {
    var out: [4 + 3 * 8]u8 = @splat(0xff); // 0xffffffff: no user or group id
    std.mem.writeInt(u32, out[0..4], 2, .little);
    // The owner, the owning group, others.
    for ([_]u16{ 0x01, 0x04, 0x20 }, [_]u5{ 6, 3, 0 }, 0..) |tag, shift, i| {
        std.mem.writeInt(u16, out[4 + 8 * i ..][0..2], tag, .little);
        std.mem.writeInt(u16, out[6 + 8 * i ..][0..2], @intCast((mode >> shift) & 7), .little);
    }
    return out;
}

/// Let the owning group's entry of `acl` allow no more than the one for
/// others.
fn limitOwningGroup(acl: []u8) void {
    if (acl.len < 4 or (acl.len - 4) % 8 != 0) return;
    var other: u16 = 0;
    var i: usize = 4;
    while (i < acl.len) : (i += 8) {
        if (std.mem.readInt(u16, acl[i..][0..2], .little) == 0x20) other = std.mem.readInt(u16, acl[i + 2 ..][0..2], .little);
    }
    i = 4;
    while (i < acl.len) : (i += 8) {
        if (std.mem.readInt(u16, acl[i..][0..2], .little) != 0x04) continue;
        const perm = acl[i + 2 ..][0..2];
        std.mem.writeInt(u16, perm, std.mem.readInt(u16, perm, .little) & other, .little);
    }
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

test "the owning group's entry of another group" {
    var acl = testAcl(&.{ .{ 1, 6 }, .{ 2, 6 }, .{ 4, 6 }, .{ 0x10, 6 }, .{ 0x20, 4 } });
    limitOwningGroup(&acl);
    const want = testAcl(&.{ .{ 1, 6 }, .{ 2, 6 }, .{ 4, 4 }, .{ 0x10, 6 }, .{ 0x20, 4 } });
    try std.testing.expectEqualSlices(u8, &want, &acl);
    try std.testing.expectEqualSlices(u8, &testAcl(&.{ .{ 1, 6 }, .{ 4, 4 }, .{ 0x20, 0 } }), &plainAcl(0o4640));
}
