// SPDX-License-Identifier: GPL-2.0-or-later
//! File metadata as data: type and mode names, file-system type names and the
//! `--json` form of a stat result. The `stat` command prints from the same
//! `sys.FileStat` / `sys.StatFs` values; nothing here reads the file system.
//!
//! References: GNU coreutils 9.7 manual "stat invocation" (the type names and
//! the file-system type table, which follows stat.c); statx(2); inode(7).
//! The key names and value rules are util-unix decision 0007.

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const json = @import("json.zig");

pub const FsName = struct { magic: u64, name: []const u8 };
pub const fs_names = [_]FsName{
    .{ .magic = 0x5A3C69F0, .name = "aafs" },      .{ .magic = 0x61636673, .name = "acfs" },      .{ .magic = 0xADF5, .name = "adfs" },
    .{ .magic = 0xADFF, .name = "affs" },          .{ .magic = 0x5346414F, .name = "afs" },       .{ .magic = 0x09041934, .name = "anon-inode FS" },
    .{ .magic = 0x61756673, .name = "aufs" },      .{ .magic = 0x0187, .name = "autofs" },        .{ .magic = 0x13661366, .name = "balloon-kvm-fs" },
    .{ .magic = 0xCA451A4E, .name = "bcachefs" },  .{ .magic = 0x42465331, .name = "befs" },      .{ .magic = 0x62646576, .name = "bdevfs" },
    .{ .magic = 0x1BADFACE, .name = "bfs" },       .{ .magic = 0x6C6F6F70, .name = "binderfs" },  .{ .magic = 0xCAFE4A11, .name = "bpf_fs" },
    .{ .magic = 0x42494E4D, .name = "binfmt_misc" }, .{ .magic = 0x9123683E, .name = "btrfs" },   .{ .magic = 0x73727279, .name = "btrfs_test" },
    .{ .magic = 0x00C36400, .name = "ceph" },      .{ .magic = 0x0027E0EB, .name = "cgroupfs" },  .{ .magic = 0x63677270, .name = "cgroup2fs" },
    .{ .magic = 0xFF534D42, .name = "cifs" },      .{ .magic = 0x73757245, .name = "coda" },      .{ .magic = 0x012FF7B7, .name = "coh" },
    .{ .magic = 0x62656570, .name = "configfs" },  .{ .magic = 0x28CD3D45, .name = "cramfs" },    .{ .magic = 0x453DCD28, .name = "cramfs-wend" },
    .{ .magic = 0x64646178, .name = "daxfs" },     .{ .magic = 0x64626720, .name = "debugfs" },   .{ .magic = 0x1373, .name = "devfs" },
    .{ .magic = 0x454D444D, .name = "devmem" },    .{ .magic = 0x1CD1, .name = "devpts" },        .{ .magic = 0x444D4142, .name = "dma-buf-fs" },
    .{ .magic = 0xF15F, .name = "ecryptfs" },      .{ .magic = 0xDE5E81E4, .name = "efivarfs" },  .{ .magic = 0x00414A53, .name = "efs" },
    .{ .magic = 0xE0F5E1E2, .name = "erofs" },     .{ .magic = 0x2011BAB0, .name = "exfat" },     .{ .magic = 0x45584653, .name = "exfs" },
    .{ .magic = 0x5DF5, .name = "exofs" },         .{ .magic = 0x137D, .name = "ext" },           .{ .magic = 0xEF53, .name = "ext2/ext3" },
    .{ .magic = 0xEF51, .name = "ext2" },          .{ .magic = 0xF2F52010, .name = "f2fs" },      .{ .magic = 0x4006, .name = "fat" },
    .{ .magic = 0x19830326, .name = "fhgfs" },     .{ .magic = 0x65735546, .name = "fuse" },      .{ .magic = 0x65735543, .name = "fusectl" },
    .{ .magic = 0x0BAD1DEA, .name = "futexfs" },   .{ .magic = 0x01161970, .name = "gfs/gfs2" },  .{ .magic = 0x47504653, .name = "gpfs" },
    .{ .magic = 0x4244, .name = "hfs" },           .{ .magic = 0x482B, .name = "hfs+" },          .{ .magic = 0x4858, .name = "hfsx" },
    .{ .magic = 0x00C0FFEE, .name = "hostfs" },    .{ .magic = 0xF995E849, .name = "hpfs" },      .{ .magic = 0x958458F6, .name = "hugetlbfs" },
    .{ .magic = 0x11307854, .name = "inodefs" },   .{ .magic = 0x013111A8, .name = "ibrix" },     .{ .magic = 0x2BAD1DEA, .name = "inotifyfs" },
    .{ .magic = 0x9660, .name = "isofs" },         .{ .magic = 0x4004, .name = "isofs" },         .{ .magic = 0x4000, .name = "isofs" },
    .{ .magic = 0x07C0, .name = "jffs" },          .{ .magic = 0x72B6, .name = "jffs2" },         .{ .magic = 0x3153464A, .name = "jfs" },
    .{ .magic = 0x6B414653, .name = "k-afs" },     .{ .magic = 0xC97E8168, .name = "logfs" },     .{ .magic = 0x0BD00BD0, .name = "lustre" },
    .{ .magic = 0x5346314D, .name = "m1fs" },      .{ .magic = 0x137F, .name = "minix" },         .{ .magic = 0x138F, .name = "minix (30 char.)" },
    .{ .magic = 0x2468, .name = "minix v2" },      .{ .magic = 0x2478, .name = "minix v2 (30 char.)" }, .{ .magic = 0x4D5A, .name = "minix3" },
    .{ .magic = 0x19800202, .name = "mqueue" },    .{ .magic = 0x4D44, .name = "msdos" },         .{ .magic = 0x564C, .name = "novell" },
    .{ .magic = 0x6969, .name = "nfs" },           .{ .magic = 0x6E667364, .name = "nfsd" },      .{ .magic = 0x3434, .name = "nilfs" },
    .{ .magic = 0x6E736673, .name = "nsfs" },      .{ .magic = 0x5346544E, .name = "ntfs" },      .{ .magic = 0x9FA1, .name = "openprom" },
    .{ .magic = 0x7461636F, .name = "ocfs2" },     .{ .magic = 0x794C7630, .name = "overlayfs" }, .{ .magic = 0xAAD7AAEA, .name = "panfs" },
    .{ .magic = 0x50494446, .name = "pidfs" },     .{ .magic = 0x50495045, .name = "pipefs" },    .{ .magic = 0xC7571590, .name = "ppc-cmm-fs" },
    .{ .magic = 0x7C7C6673, .name = "prl_fs" },    .{ .magic = 0x9FA0, .name = "proc" },          .{ .magic = 0x6165676C, .name = "pstorefs" },
    .{ .magic = 0x002F, .name = "qnx4" },          .{ .magic = 0x68191122, .name = "qnx6" },      .{ .magic = 0x858458F6, .name = "ramfs" },
    .{ .magic = 0x07655821, .name = "rdt" },       .{ .magic = 0x52654973, .name = "reiserfs" },  .{ .magic = 0x7275, .name = "romfs" },
    .{ .magic = 0x67596969, .name = "rpc_pipefs" }, .{ .magic = 0x5DCA2DF5, .name = "sdcardfs" }, .{ .magic = 0x5345434D, .name = "secretmem" },
    .{ .magic = 0x73636673, .name = "securityfs" }, .{ .magic = 0xF97CFF8C, .name = "selinux" },   .{ .magic = 0x43415D53, .name = "smackfs" },
    .{ .magic = 0x517B, .name = "smb" },           .{ .magic = 0xFE534D42, .name = "smb2" },      .{ .magic = 0xBEEFDEAD, .name = "snfs" },
    .{ .magic = 0x534F434B, .name = "sockfs" },    .{ .magic = 0x73717368, .name = "squashfs" },  .{ .magic = 0x62656572, .name = "sysfs" },
    .{ .magic = 0x012FF7B6, .name = "sysv2" },     .{ .magic = 0x012FF7B5, .name = "sysv4" },     .{ .magic = 0x01021994, .name = "tmpfs" },
    .{ .magic = 0x74726163, .name = "tracefs" },   .{ .magic = 0x24051905, .name = "ubifs" },     .{ .magic = 0x15013346, .name = "udf" },
    .{ .magic = 0x00011954, .name = "ufs" },       .{ .magic = 0x54190100, .name = "ufs" },       .{ .magic = 0x9FA2, .name = "usbdevfs" },
    .{ .magic = 0x01021997, .name = "v9fs" },      .{ .magic = 0x786F4256, .name = "vboxsf" },    .{ .magic = 0xBACBACBC, .name = "vmhgfs" },
    .{ .magic = 0xA501FCF5, .name = "vxfs" },      .{ .magic = 0x565A4653, .name = "vzfs" },      .{ .magic = 0x53464846, .name = "wslfs" },
    .{ .magic = 0xABBA1974, .name = "xenfs" },     .{ .magic = 0x012FF7B4, .name = "xenix" },     .{ .magic = 0x58465342, .name = "xfs" },
    .{ .magic = 0x012FD16D, .name = "xia" },       .{ .magic = 0x0033, .name = "z3fold" },        .{ .magic = 0x2FC12FC1, .name = "zfs" },
    .{ .magic = 0x5A4F4653, .name = "zonefs" },    .{ .magic = 0x58295829, .name = "zsmallocfs" },
};

pub fn fileType(mode: u32, size: u64) []const u8 {
    return switch (mode & 0o170000) {
        0o100000 => if (size == 0) "regular empty file" else "regular file",
        0o040000 => "directory",
        0o120000 => "symbolic link",
        0o060000 => "block special file",
        0o020000 => "character special file",
        0o010000 => "fifo",
        0o140000 => "socket",
        else => "weird file",
    };
}

pub fn modeString(mode: u32, buf: *[10]u8) []const u8 {
    buf[0] = switch (mode & 0o170000) {
        0o100000 => '-',
        0o040000 => 'd',
        0o120000 => 'l',
        0o060000 => 'b',
        0o020000 => 'c',
        0o010000 => 'p',
        0o140000 => 's',
        else => '?',
    };
    const bits = "rwxrwxrwx";
    for (0..9) |i| buf[1 + i] = if (mode & (@as(u32, 0o400) >> @intCast(i)) != 0) bits[i] else '-';
    if (mode & 0o4000 != 0) buf[3] = if (mode & 0o100 != 0) 's' else 'S';
    if (mode & 0o2000 != 0) buf[6] = if (mode & 0o010 != 0) 's' else 'S';
    if (mode & 0o1000 != 0) buf[9] = if (mode & 0o001 != 0) 't' else 'T';
    return buf[0..10];
}


/// Machine name of the file type, stable across releases (unlike the GNU
/// description from `fileType`).
pub fn typeKey(mode: u32) []const u8 {
    return switch (mode & 0o170000) {
        0o100000 => "file",
        0o040000 => "directory",
        0o120000 => "symlink",
        0o060000 => "block_device",
        0o020000 => "char_device",
        0o010000 => "fifo",
        0o140000 => "socket",
        else => "unknown",
    };
}

/// The device number as st_dev encodes it, rebuilt from the major/minor pair.
pub fn makedev(major: u32, minor: u32) u64 {
    return (@as(u64, major) << 8) | (minor & 0xff) | ((@as(u64, minor) & ~@as(u64, 0xff)) << 12);
}

/// File system type name for a statfs magic number, or null when unknown.
pub fn fsTypeName(magic: u64) ?[]const u8 {
    for (fs_names) |e| if (e.magic == magic) return e.name;
    return null;
}

fn writeTime(w: *Io.Writer, key: []const u8, sec: i64, nsec: u32) Io.Writer.Error!void {
    try w.print(",\"{s}\":{d},\"{s}_nsec\":{d}", .{ key, sec, key, nsec });
}

/// Write one stat result as a JSON object and a newline. `link_target` is the
/// target of a symbolic link (null for anything else or when it could not be
/// read); `user` and `group` are null when the database has no such id.
/// Birth time is null when the file system does not record it; `rdev_*` are
/// null unless the file is a device.
pub fn writeJson(w: *Io.Writer, name: []const u8, st: *const sys.FileStat, link_target: ?[]const u8, user: ?[]const u8, group: ?[]const u8) Io.Writer.Error!void {
    try w.writeByte('{');
    try writeFields(w, name, st, link_target, user, group);
    try w.writeByte('\n');
}

/// Like `writeJson`, for a directory listing: the object starts with `dir`, the
/// directory the entry was listed in (null for a command-line operand), and
/// there is no trailing newline.
pub fn writeJsonIn(w: *Io.Writer, dir: ?[]const u8, name: []const u8, st: *const sys.FileStat, link_target: ?[]const u8, user: ?[]const u8, group: ?[]const u8) Io.Writer.Error!void {
    try w.writeAll("{\"dir\":");
    try json.writeOptString(w, dir);
    try w.writeByte(',');
    try writeFields(w, name, st, link_target, user, group);
}

/// An entry whose metadata could not be read: only `dir`, `name` and a type of
/// "unknown" (the stat fields are absent, not null).
pub fn writeJsonUnknownIn(w: *Io.Writer, dir: ?[]const u8, name: []const u8) Io.Writer.Error!void {
    try w.writeAll("{\"dir\":");
    try json.writeOptString(w, dir);
    try w.writeAll(",\"name\":");
    try json.writeString(w, name);
    try w.writeAll(",\"type\":\"unknown\"}");
}

fn writeFields(w: *Io.Writer, name: []const u8, st: *const sys.FileStat, link_target: ?[]const u8, user: ?[]const u8, group: ?[]const u8) Io.Writer.Error!void {
    var mb: [10]u8 = undefined;
    try w.writeAll("\"name\":");
    try json.writeString(w, name);
    try w.print(",\"type\":\"{s}\",\"type_desc\":", .{typeKey(st.mode)});
    try json.writeString(w, fileType(st.mode, st.size));
    try w.print(",\"size\":{d},\"blocks\":{d},\"block_size\":{d}", .{ st.size, st.blocks, st.blksize });
    try w.print(",\"mode\":{d},\"mode_octal\":\"{o:0>4}\",\"mode_string\":", .{ st.mode & 0o7777, st.mode & 0o7777 });
    try json.writeString(w, modeString(st.mode, &mb));
    try w.print(",\"nlink\":{d},\"inode\":{d},\"uid\":{d},\"user\":", .{ st.nlink, st.ino, st.uid });
    try json.writeOptString(w, user);
    try w.print(",\"gid\":{d},\"group\":", .{st.gid});
    try json.writeOptString(w, group);
    try w.print(",\"dev\":{d},\"dev_major\":{d},\"dev_minor\":{d}", .{ makedev(st.dev_major, st.dev_minor), st.dev_major, st.dev_minor });
    const is_dev = (st.mode & 0o170000) == 0o060000 or (st.mode & 0o170000) == 0o020000;
    if (is_dev) {
        try w.print(",\"rdev_major\":{d},\"rdev_minor\":{d}", .{ st.rdev_major, st.rdev_minor });
    } else {
        try w.writeAll(",\"rdev_major\":null,\"rdev_minor\":null");
    }
    try writeTime(w, "atime", st.atime_s, st.atime_ns);
    try writeTime(w, "mtime", st.mtime_s, st.mtime_ns);
    try writeTime(w, "ctime", st.ctime_s, st.ctime_ns);
    if (st.has_btime) {
        try writeTime(w, "birth", st.btime_s, st.btime_ns);
    } else {
        try w.writeAll(",\"birth\":null,\"birth_nsec\":null");
    }
    try w.writeAll(",\"link_target\":");
    try json.writeOptString(w, link_target);
    try w.writeByte('}');
}

/// Write one file-system (`stat -f`) result as a JSON object and a newline.
/// `type` is the statfs magic number; `type_name` is null when unknown.
pub fn writeFsJson(w: *Io.Writer, name: []const u8, fs: *const sys.StatFs) Io.Writer.Error!void {
    try w.writeAll("{\"name\":");
    try json.writeString(w, name);
    try w.print(",\"id\":\"{x}\",\"name_length\":{d},\"type\":{d},\"type_name\":", .{ fs.fsid, fs.namelen, fs.type });
    try json.writeOptString(w, fsTypeName(fs.type));
    try w.print(",\"block_size\":{d},\"fundamental_block_size\":{d}", .{ fs.bsize, if (fs.frsize != 0) fs.frsize else fs.bsize });
    try w.print(",\"blocks_total\":{d},\"blocks_free\":{d},\"blocks_available\":{d}", .{ fs.blocks, fs.bfree, fs.bavail });
    try w.print(",\"inodes_total\":{d},\"inodes_free\":{d}}}\n", .{ fs.files, fs.ffree });
}

fn sample() sys.FileStat {
    return .{
        .mode = 0o104755, .uid = 1000, .gid = 50, .nlink = 2, .ino = 77, .size = 12, .blocks = 8, .blksize = 4096,
        .dev_major = 8, .dev_minor = 1, .rdev_major = 0, .rdev_minor = 0,
        .atime_s = 10, .atime_ns = 1, .mtime_s = 20, .mtime_ns = 2, .ctime_s = 30, .ctime_ns = 3,
        .btime_s = 0, .btime_ns = 0, .has_btime = false,
    };
}

test "json: a setuid regular file with a missing group and no birth time" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const st = sample();
    try writeJson(&w, "a\"b", &st, null, "alice", null);
    try std.testing.expectEqualStrings(
        "{\"name\":\"a\\\"b\",\"type\":\"file\",\"type_desc\":\"regular file\",\"size\":12,\"blocks\":8,\"block_size\":4096," ++
            "\"mode\":2541,\"mode_octal\":\"4755\",\"mode_string\":\"-rwsr-xr-x\",\"nlink\":2,\"inode\":77,\"uid\":1000," ++
            "\"user\":\"alice\",\"gid\":50,\"group\":null,\"dev\":2049,\"dev_major\":8,\"dev_minor\":1," ++
            "\"rdev_major\":null,\"rdev_minor\":null,\"atime\":10,\"atime_nsec\":1,\"mtime\":20,\"mtime_nsec\":2," ++
            "\"ctime\":30,\"ctime_nsec\":3,\"birth\":null,\"birth_nsec\":null,\"link_target\":null}\n",
        w.buffered(),
    );
}

test "json: listing entries carry the directory" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var st = sample();
    st.mode = 0o120777;
    try writeJsonIn(&w, "src", "lnk", &st, "tgt", null, null);
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "{\"dir\":\"src\",\"name\":\"lnk\",\"type\":\"symlink\""));
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\"link_target\":\"tgt\"}"));
    var w2: Io.Writer = .fixed(&buf);
    try writeJsonUnknownIn(&w2, null, "x");
    try std.testing.expectEqualStrings("{\"dir\":null,\"name\":\"x\",\"type\":\"unknown\"}", w2.buffered());
}

test "json: device numbers, birth time and link target" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var st = sample();
    st.mode = 0o020666;
    st.rdev_major = 1;
    st.rdev_minor = 3;
    st.has_btime = true;
    st.btime_s = 5;
    try writeJson(&w, "/dev/null", &st, "tgt", null, null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"char_device\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rdev_major\":1,\"rdev_minor\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"birth\":5,\"birth_nsec\":0") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\"link_target\":\"tgt\"}\n"));
}

test "json: file system" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const fs: sys.StatFs = .{ .type = 0xEF53, .bsize = 4096, .blocks = 100, .bfree = 40, .bavail = 30, .files = 10, .ffree = 5, .fsid = 0xab, .namelen = 255, .frsize = 0 };
    try writeFsJson(&w, "/", &fs);
    try std.testing.expectEqualStrings(
        "{\"name\":\"/\",\"id\":\"ab\",\"name_length\":255,\"type\":61267,\"type_name\":\"ext2/ext3\",\"block_size\":4096," ++
            "\"fundamental_block_size\":4096,\"blocks_total\":100,\"blocks_free\":40,\"blocks_available\":30,\"inodes_total\":10,\"inodes_free\":5}\n",
        w.buffered(),
    );
}
