// SPDX-License-Identifier: GPL-2.0-or-later
//! strerror()-style wording for the file errors the commands report. Shared
//! by `cli.zig` and the command libraries.

/// Human-readable text for common file errors, matching strerror() wording
/// that GNU tools print. Falls back to the Zig error name.
pub fn errText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied => "Permission denied",
        error.PermissionDenied => "Operation not permitted",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.BrokenPipe => "Broken pipe",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.PathAlreadyExists => "File exists",
        error.DirNotEmpty => "Directory not empty",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.NoSpaceLeft => "No space left on device",
        error.FileTooBig => "File too large",
        error.InputOutput => "Input/output error",
        error.NotOpenForReading, error.NotOpenForWriting => "Bad file descriptor",
        error.DiskQuota => "Disk quota exceeded",
        error.FileBusy => "Device or resource busy",
        error.LinkQuotaExceeded => "Too many links",
        error.SystemResources => "Cannot allocate memory",
        error.ProcessFdQuotaExceeded => "Too many open files",
        error.SystemFdQuotaExceeded => "Too many open files in system",
        else => @errorName(err),
    };
}
