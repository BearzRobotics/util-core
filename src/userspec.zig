//! Parsing of OWNER[:[GROUP]] specifications (gnulib userspec.c, coreutils
//! 9.6 lib/userspec.c, consulted 2026-11-07), against /etc/passwd and
//! /etc/group.

const std = @import("std");
const userdb = @import("userdb.zig");

pub const unset: u32 = std.math.maxInt(u32);

pub const Spec = struct {
    /// Null when the specification is valid.
    err: ?[]const u8 = null,
    /// True when a '.' separator was accepted ("warning: '.' should be ':'").
    dot_warning: bool = false,
    uid: u32 = unset,
    gid: u32 = unset,
    /// The names as typed; null when the id was given numerically.
    user_name: ?[]const u8 = null,
    group_name: ?[]const u8 = null,
};

/// xstrtoul(s, NULL, 10, &v, "") restricted to 0..max-1 ids.
fn parseId(s: []const u8) ?u32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or (s[i] >= '\t' and s[i] <= '\r'))) i += 1;
    if (i < s.len and s[i] == '-') return null;
    if (i < s.len and s[i] == '+') i += 1;
    const start = i;
    var v: u64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v * 10 + (s[i] - '0');
        if (v > std.math.maxInt(u32)) return null;
    }
    if (i == start or i != s.len) return null;
    if (v == unset) return null;
    return @intCast(v);
}

fn withSeparator(db: *const userdb.Db, gpa: std.mem.Allocator, spec: []const u8, sep: ?usize, want_gid: bool, out: *Spec, scratch: *std.ArrayList([]u8)) ?[]const u8 {
    var unum: u32 = out.uid;
    var gnum: u32 = if (want_gid) out.gid else unset;
    var err: ?[]const u8 = null;
    var user_name: ?[]const u8 = null;
    var group_name: ?[]const u8 = null;

    var u: ?[]const u8 = null;
    if (sep) |si| {
        if (si != 0) u = spec[0..si];
    } else if (spec.len > 0) u = spec;
    const g: ?[]const u8 = if (sep == null or sep.? + 1 >= spec.len) null else spec[sep.? + 1 ..];

    if (u) |uu| {
        const pw = if (uu[0] == '+') null else db.userByName(uu);
        if (pw == null) {
            const use_login_group = sep != null and g == null;
            if (use_login_group) {
                err = "invalid spec";
            } else if (parseId(uu)) |v| {
                unum = v;
            } else err = "invalid user";
        } else {
            unum = pw.?.uid;
            user_name = uu;
            if (g == null and sep != null) {
                gnum = pw.?.gid;
                if (db.groupByGid(gnum)) |gr| {
                    group_name = gr.name;
                } else {
                    const t = std.fmt.allocPrint(gpa, "{d}", .{gnum}) catch "";
                    scratch.append(gpa, @constCast(t)) catch {};
                    group_name = t;
                }
            }
        }
    }
    if (g != null and err == null) {
        const gg = g.?;
        const gr = if (gg[0] == '+') null else db.groupByName(gg);
        if (gr == null) {
            if (parseId(gg)) |v| {
                gnum = v;
            } else err = "invalid group";
        } else {
            gnum = gr.?.gid;
            group_name = gg;
        }
    }
    if (err == null) {
        out.uid = unum;
        if (want_gid) out.gid = gnum;
        out.user_name = user_name;
        out.group_name = group_name;
    }
    return err;
}

/// Parse `spec`. `want_gid` false means a plain user name (no ':' handling).
/// Strings in the result point into `spec`, `db` or `scratch` (which the
/// caller frees).
pub fn parse(db: *const userdb.Db, gpa: std.mem.Allocator, spec: []const u8, want_gid: bool, scratch: *std.ArrayList([]u8)) Spec {
    var out: Spec = .{};
    const colon: ?usize = if (want_gid) std.mem.indexOfScalar(u8, spec, ':') else null;
    const err = withSeparator(db, gpa, spec, colon, want_gid, &out, scratch);
    if (want_gid and colon == null and err != null) {
        if (std.mem.indexOfScalar(u8, spec, '.')) |dot| {
            var again: Spec = .{};
            if (withSeparator(db, gpa, spec, dot, want_gid, &again, scratch) == null) {
                again.dot_warning = true;
                return again;
            }
        }
    }
    out.err = err;
    return out;
}
