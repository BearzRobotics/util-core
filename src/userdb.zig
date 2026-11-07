//! Look-ups in /etc/passwd and /etc/group (no NSS: GNU goes through libc, so
//! users that exist only in LDAP or similar are not found here).

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");

pub const User = struct { name: []const u8, uid: u32, gid: u32 };
pub const Group = struct { name: []const u8, gid: u32, members: []const u8 };

/// Whole contents of a small text file, or null. Caller frees.
fn slurp(gpa: std.mem.Allocator, io: Io, path: []const u8) ?[]u8 {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var list: std.ArrayList(u8) = .empty;
    while (true) {
        list.ensureUnusedCapacity(gpa, 8192) catch return null;
        const n = cli.readChunk(io, f, list.unusedCapacitySlice()) catch return null;
        if (n == 0) break;
        list.items.len += n;
    }
    return list.toOwnedSlice(gpa) catch null;
}

/// The databases, loaded once per process.
pub const Db = struct {
    gpa: std.mem.Allocator,
    passwd: []u8 = &.{},
    group: []u8 = &.{},

    pub fn load(gpa: std.mem.Allocator, io: Io) Db {
        return .{
            .gpa = gpa,
            .passwd = slurp(gpa, io, "/etc/passwd") orelse &.{},
            .group = slurp(gpa, io, "/etc/group") orelse &.{},
        };
    }

    pub fn deinit(d: *Db) void {
        d.gpa.free(d.passwd);
        d.gpa.free(d.group);
    }

    fn parseUser(line: []const u8) ?User {
        var it = std.mem.splitScalar(u8, line, ':');
        const name = it.next() orelse return null;
        _ = it.next() orelse return null; // password
        const uid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const gid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        return .{ .name = name, .uid = uid, .gid = gid };
    }

    fn parseGroup(line: []const u8) ?Group {
        var it = std.mem.splitScalar(u8, line, ':');
        const name = it.next() orelse return null;
        _ = it.next() orelse return null;
        const gid = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        return .{ .name = name, .gid = gid, .members = it.next() orelse "" };
    }

    pub fn userByUid(d: *const Db, uid: u32) ?User {
        var lines = std.mem.splitScalar(u8, d.passwd, '\n');
        while (lines.next()) |l| if (parseUser(l)) |u| if (u.uid == uid) return u;
        return null;
    }

    pub fn userByName(d: *const Db, name: []const u8) ?User {
        var lines = std.mem.splitScalar(u8, d.passwd, '\n');
        while (lines.next()) |l| if (parseUser(l)) |u| if (std.mem.eql(u8, u.name, name)) return u;
        return null;
    }

    pub fn groupByGid(d: *const Db, gid: u32) ?Group {
        var lines = std.mem.splitScalar(u8, d.group, '\n');
        while (lines.next()) |l| if (parseGroup(l)) |g| if (g.gid == gid) return g;
        return null;
    }

    /// Group ids `user` belongs to: `primary` first, then every group whose
    /// member list names the user, in file order (what getgrouplist returns).
    pub fn groupsOf(d: *const Db, gpa: std.mem.Allocator, user: []const u8, primary: u32) ![]u32 {
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(gpa);
        try out.append(gpa, primary);
        var lines = std.mem.splitScalar(u8, d.group, '\n');
        while (lines.next()) |l| {
            const g = parseGroup(l) orelse continue;
            var members = std.mem.splitScalar(u8, g.members, ',');
            while (members.next()) |m| {
                if (std.mem.eql(u8, m, user)) {
                    if (std.mem.indexOfScalar(u32, out.items, g.gid) == null) try out.append(gpa, g.gid);
                    break;
                }
            }
        }
        return out.toOwnedSlice(gpa);
    }
};
