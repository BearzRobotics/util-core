// SPDX-License-Identifier: GPL-2.0-or-later
//! What util-core needs on Windows and Zig's std does not do (0.17.1 panics on
//! setting times or permissions by name, and has no hard links there). Names
//! are resolved as std resolves them: from an open directory, long ones
//! included.

const std = @import("std");
const Io = std.Io;
const w = std.os.windows;

pub const Error = error{
    FileNotFound,
    AccessDenied,
    PathAlreadyExists,
    BadPathName,
    NotDir,
    IsDir,
    FileBusy,
    NotSameDevice,
    NotSupported,
    Unexpected,
};

fn fromStatus(status: w.NTSTATUS) Error {
    return switch (status) {
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND, .NO_SUCH_FILE => error.FileNotFound,
        .ACCESS_DENIED, .CANNOT_DELETE => error.AccessDenied,
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .OBJECT_NAME_INVALID, .OBJECT_PATH_SYNTAX_BAD => error.BadPathName,
        .NOT_A_DIRECTORY => error.NotDir,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .SHARING_VIOLATION, .DELETE_PENDING => error.FileBusy,
        .NOT_SAME_DEVICE => error.NotSameDevice,
        .NOT_SUPPORTED, .INVALID_DEVICE_REQUEST => error.NotSupported,
        else => error.Unexpected,
    };
}

const Open = struct {
    access: w.ACCESS_MASK,
    follow: bool = true,
    /// Create the file when there is none.
    create: bool = false,
    exclusive: bool = false,
    truncate: bool = false,
    file_only: bool = false,
};

/// A handle on `path`, relative to `dir`, sharing everything with others.
fn open(dir: w.HANDLE, path: []const u8, options: Open) Error!w.HANDLE {
    const space = Io.Threaded.sliceToPrefixedFileW(dir, path, .{}) catch return error.BadPathName;
    const name = space.span();
    var status_block: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    const status = w.ntdll.NtCreateFile(
        &handle,
        options.access,
        &.{
            .RootDirectory = if (Io.Dir.path.isAbsoluteWindowsWtf16(name)) null else dir,
            .ObjectName = @constCast(&w.UNICODE_STRING.init(name)),
        },
        &status_block,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        if (options.exclusive)
            .CREATE
        else if (options.create)
            (if (options.truncate) .OVERWRITE_IF else .OPEN_IF)
        else if (options.truncate)
            .OVERWRITE
        else
            .OPEN,
        .{
            .IO = .SYNCHRONOUS_NONALERT,
            .NON_DIRECTORY_FILE = options.file_only,
            .OPEN_REPARSE_POINT = !options.follow,
        },
        null,
        0,
    );
    if (status != .SUCCESS) return fromStatus(status);
    return handle;
}

const attributes_only: w.ACCESS_MASK = .{
    .STANDARD = .{ .SYNCHRONIZE = true },
    .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
};

/// utimensat(2) of `path` in `dir`.
pub fn setTimes(io: Io, dir: w.HANDLE, path: []const u8, access: Io.File.SetTimestamp, modify: Io.File.SetTimestamp, follow: bool) !void {
    const handle = try open(dir, path, .{ .access = attributes_only, .follow = follow });
    defer w.CloseHandle(handle);
    const file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    try file.setTimestamps(io, .{ .access_timestamp = access, .modify_timestamp = modify });
}

const attribute_read_only: u32 = 0x1;
const attribute_directory: u32 = 0x10;
const attribute_normal: u32 = 0x80;

/// The one permission a Windows file has: whether it may be written. The other
/// attributes stay. A directory's read-only mark does not protect it, so it is
/// left alone.
pub fn setReadOnly(dir: w.HANDLE, path: []const u8, read_only: bool, follow: bool) Error!void {
    const handle = try open(dir, path, .{ .access = attributes_only, .follow = follow });
    defer w.CloseHandle(handle);
    var status_block: w.IO_STATUS_BLOCK = undefined;
    var info: w.FILE.BASIC_INFORMATION = undefined;
    var status = w.ntdll.NtQueryInformationFile(handle, &status_block, &info, @sizeOf(w.FILE.BASIC_INFORMATION), .Basic);
    if (status != .SUCCESS) return fromStatus(status);
    var bits: u32 = @bitCast(info.FileAttributes);
    if (bits & attribute_directory != 0) return;
    const wanted = if (read_only) bits | attribute_read_only else bits & ~attribute_read_only;
    if (wanted == bits) return;
    bits = wanted & ~attribute_normal;
    if (bits == 0) bits = attribute_normal;
    // A zero time means "leave it".
    info = .{ .CreationTime = 0, .LastAccessTime = 0, .LastWriteTime = 0, .ChangeTime = 0, .FileAttributes = @bitCast(bits) };
    status = w.ntdll.NtSetInformationFile(handle, &status_block, &info, @sizeOf(w.FILE.BASIC_INFORMATION), .Basic);
    if (status != .SUCCESS) return fromStatus(status);
}

/// FILE_LINK_INFORMATION.
const LinkInformation = extern struct {
    replace_if_exists: u32,
    root_directory: ?w.HANDLE,
    name_length: u32,
    name: [w.PATH_MAX_WIDE]u16,
};

/// link(2): another name for the file `old`. The new name must be free.
pub fn hardLink(old_dir: w.HANDLE, old: []const u8, new_dir: w.HANDLE, new: []const u8, follow: bool) Error!void {
    const handle = try open(old_dir, old, .{
        .access = .{ .STANDARD = .{ .SYNCHRONIZE = true }, .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } } },
        .follow = follow,
        .file_only = true,
    });
    defer w.CloseHandle(handle);
    const space = Io.Threaded.sliceToPrefixedFileW(new_dir, new, .{}) catch return error.BadPathName;
    const name = space.span();
    var info: LinkInformation = undefined;
    info.replace_if_exists = 0;
    info.root_directory = if (Io.Dir.path.isAbsoluteWindowsWtf16(name)) null else new_dir;
    info.name_length = @intCast(name.len * 2);
    @memcpy(info.name[0..name.len], name);
    var status_block: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtSetInformationFile(
        handle,
        &status_block,
        &info,
        @intCast(@offsetOf(LinkInformation, "name") + name.len * 2),
        .Link,
    );
    if (status != .SUCCESS) return fromStatus(status);
}

/// Open `path` so that every write goes to the end of the file, whoever else
/// is writing it: O_APPEND. Windows does that for a handle that may append and
/// may not write.
pub fn openAppend(dir: w.HANDLE, path: []const u8, create: bool, exclusive: bool, truncate: bool, follow: bool) Error!w.HANDLE {
    // Truncating needs the right to write data, which would end the appending:
    // empty the file first.
    if (truncate) {
        const empty = try open(dir, path, .{
            .access = .{ .STANDARD = .{ .SYNCHRONIZE = true }, .GENERIC = .{ .WRITE = true } },
            .create = create,
            .truncate = true,
            .follow = follow,
            .file_only = true,
        });
        w.CloseHandle(empty);
    }
    return open(dir, path, .{
        .access = .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .APPEND_DATA = true, .READ_ATTRIBUTES = true, .WRITE_ATTRIBUTES = true } },
        },
        .create = create,
        .exclusive = exclusive and !truncate,
        .follow = follow,
        .file_only = true,
    });
}

extern "kernel32" fn SetPriorityClass(process: w.HANDLE, class: u32) callconv(.winapi) c_int;
extern "advapi32" fn GetUserNameW(buffer: [*]u16, size: *u32) callconv(.winapi) c_int;

extern "kernel32" fn OpenProcess(access: u32, inherit: c_int, id: u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn QueryFullProcessImageNameW(process: w.HANDLE, flags: u32, name: [*]u16, size: *u32) callconv(.winapi) c_int;

/// Whether the program that started this one is cmd.exe.
pub fn startedByCmd() bool {
    var basic: w.PROCESS.BASIC_INFORMATION = undefined;
    const status = w.ntdll.NtQueryInformationProcess(w.GetCurrentProcess(), .BasicInformation, &basic, @sizeOf(w.PROCESS.BASIC_INFORMATION), null);
    if (status != .SUCCESS) return false;
    const limited_information: u32 = 0x1000; // PROCESS_QUERY_LIMITED_INFORMATION
    const parent = OpenProcess(limited_information, 0, @truncate(basic.InheritedFromUniqueProcessId)) orelse return false;
    defer w.CloseHandle(parent);
    var wide: [1024]u16 = undefined;
    var size: u32 = wide.len;
    if (QueryFullProcessImageNameW(parent, 0, &wide, &size) == 0) return false;
    var buf: [3 * wide.len]u8 = undefined;
    const path = buf[0..std.unicode.wtf16LeToWtf8(&buf, wide[0..size])];
    const slash = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return false;
    return std.ascii.eqlIgnoreCase(path[slash + 1 ..], "cmd.exe");
}

/// Windows has priority classes where POSIX has niceness. A program started
/// from here keeps the two lower ones. False when the class cannot be set.
pub fn setNice(value: i32) bool {
    const class: u32 = if (value >= 10) 0x40 // IDLE_PRIORITY_CLASS
    else if (value > 0) 0x4000 // BELOW_NORMAL_PRIORITY_CLASS
    else if (value == 0) 0x20 // NORMAL_PRIORITY_CLASS
    else 0x8000; // ABOVE_NORMAL_PRIORITY_CLASS
    return SetPriorityClass(w.GetCurrentProcess(), class) != 0;
}

/// The name of the user this process runs as, as UTF-8 in `buf`.
pub fn userName(buf: []u8) ?[]const u8 {
    var wide: [257]u16 = undefined;
    var size: u32 = wide.len;
    if (GetUserNameW(&wide, &size) == 0 or size == 0) return null;
    // The size counts the terminating zero.
    const name = wide[0 .. size - 1];
    if (name.len * 3 > buf.len) return null;
    return buf[0..std.unicode.wtf16LeToWtf8(buf, name)];
}
