// SPDX-License-Identifier: GPL-2.0-or-later
//! Finding a program to run on Windows without looking in the current
//! directory.
//!
//! There, a bare program name is first looked for in the directory the new
//! process will run in, whatever PATH says (std.process.spawn does the same,
//! as CreateProcess and cmd.exe do). find -exec and -execdir and xargs run
//! commands in directories whose contents someone else may have chosen, so they
//! look the name up in PATH themselves and start the program by its full path.
//! Elsewhere only PATH is searched anyway, and names are passed on unchanged.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const common = @import("lib/common.zig");

const default_pathext = ".COM;.EXE;.BAT;.CMD";

/// What to start for the command name `name`: on Windows, for a bare name,
/// the full path found through PATH (allocated with `gpa`); otherwise `name`
/// itself. error.FileNotFound when PATH has no such program: the bare name
/// must then not be started.
pub fn resolve(env: common.Env, gpa: std.mem.Allocator, name: []const u8) error{ FileNotFound, OutOfMemory }![]const u8 {
    if (builtin.os.tag != .windows) return name;
    if (!isBare(name)) return name;
    const Files = struct {
        fn exists(io: *const Io, path: []const u8) bool {
            const st = Io.Dir.cwd().statFile(io.*, path, .{}) catch return false;
            return st.kind != .directory;
        }
    };
    const io = env.io;
    return try search(gpa, name, env.getenv("PATH") orelse "", env.getenv("PATHEXT") orelse default_pathext, &io, Files.exists) orelse error.FileNotFound;
}

/// A name with no directory or drive part, which is the kind that gets
/// searched for. Anything else says where the program is.
fn isBare(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfAny(u8, name, "/\\:") == null;
}

/// The first file for `name` in an absolute directory of the Windows path
/// list `path`, trying the name itself and then each extension of `pathext`.
/// Relative and empty entries would lead back into the current directory.
fn search(
    gpa: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    pathext: []const u8,
    context: anytype,
    exists: *const fn (@TypeOf(context), []const u8) bool,
) error{OutOfMemory}!?[]u8 {
    var dirs = std.mem.tokenizeScalar(u8, path, ';');
    while (dirs.next()) |entry| {
        const dir = std.mem.trim(u8, entry, "\"");
        if (!std.fs.path.isAbsoluteWindows(dir)) continue;
        const slash: []const u8 = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/') "" else "\\";
        var extensions = std.mem.tokenizeScalar(u8, pathext, ';');
        var extension: []const u8 = "";
        while (true) {
            const full = try std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ dir, slash, name, extension });
            if (exists(context, full)) return full;
            gpa.free(full);
            extension = extensions.next() orelse break;
        }
    }
    return null;
}

test "only absolute PATH entries are searched, with the PATHEXT extensions" {
    const t = std.testing;
    const Fake = struct {
        files: []const []const u8,
        fn exists(f: *const @This(), path: []const u8) bool {
            for (f.files) |x| if (std.ascii.eqlIgnoreCase(x, path)) return true;
            return false;
        }
    };
    const fake: Fake = .{ .files = &.{ "tool.exe", ".\\tool.exe", "bin\\tool.exe", "C:\\a b\\tool.cmd", "C:\\bin\\tool.exe", "D:\\x\\run.ps1" } };
    const found = (try search(t.allocator, "tool", ";.;bin;\"C:\\a b\";C:\\bin\\", default_pathext, &fake, Fake.exists)).?;
    defer t.allocator.free(found);
    try t.expect(std.ascii.eqlIgnoreCase("C:\\a b\\tool.cmd", found));
    const exact = (try search(t.allocator, "run.ps1", "D:\\x", default_pathext, &fake, Fake.exists)).?;
    defer t.allocator.free(exact);
    try t.expectEqualStrings("D:\\x\\run.ps1", exact);
    try t.expectEqual(null, try search(t.allocator, "tool", ".;bin;", default_pathext, &fake, Fake.exists));
    try t.expect(isBare("tool.exe"));
    for ([_][]const u8{ "", ".\\tool", "sub/tool", "C:tool", "C:\\tool" }) |name| try t.expect(!isBare(name));
}
