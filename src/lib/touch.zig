// SPDX-License-Identifier: GPL-2.0-or-later
//! touch library: change file timestamps.
//! Reference: GNU coreutils manual "touch invocation" (9.7); POSIX.1-2024
//! touch (-a -c -d -m -r -t). Times are set with utimensat(2) through
//! src/sys.zig. The caller resolves -d/-t/-r into concrete times (the GNU date
//! parser is in src/datetime.zig); this module applies them.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;
pub const TimeSpec = sys.TimeSpec;

pub const ch_atime = 1;
pub const ch_mtime = 2;

pub const Options = struct {
    /// Bit set of `ch_atime` / `ch_mtime`; 0 means both.
    change_times: u8 = ch_atime | ch_mtime,
    /// -c: do not create files.
    no_create: bool = false,
    /// -h: act on a symlink itself.
    no_deref: bool = false,
    /// Access and modification time to set ([0] atime, [1] mtime). Ignored
    /// when `now` is set. With `change_times` selecting only one of them, the
    /// other entry may carry `TimeSpec.now_ns`; it is replaced by "omit".
    times: [2]TimeSpec = .{ .{}, .{} },
    /// Both times are "now" (utimensat with a null array).
    now: bool = true,
};

pub const Event = union(enum) {
    /// The file could not be created or opened for touching.
    cannot_touch: struct { path: []const u8, errno: std.os.linux.E },
    /// Setting the times failed.
    set_times_failed: struct { path: []const u8, errno: std.os.linux.E },
};
pub const Observer = common.Observer(Event);

/// Touch each file ("-" is standard output). Returns false when any failed.
pub fn run(env: Env, options: Options, files: []const []const u8, observer: Observer) bool {
    var ok = true;
    for (files) |file| {
        if (!touchOne(env, file, options, observer)) ok = false;
    }
    return ok;
}

pub fn touchOne(env: Env, file: []const u8, options: Options, observer: Observer) bool {
    const change_times: u8 = if (options.change_times == 0) ch_atime | ch_mtime else options.change_times;
    var open_errno: ?std.os.linux.E = null;
    const is_stdout = std.mem.eql(u8, file, "-");
    var times = options.times;
    if (change_times != (ch_atime | ch_mtime)) {
        if (change_times == ch_mtime) times[0].nsec = sys.TimeSpec.omit_ns else times[1].nsec = sys.TimeSpec.omit_ns;
    }
    if (!is_stdout and !(options.no_create or options.no_deref)) {
        // Create the file if needed (mode 0666 & ~umask), like open(O_CREAT).
        if (Io.Dir.cwd().createFile(env.io, file, .{ .truncate = false })) |f| {
            f.close(env.io);
        } else |e| {
            open_errno = switch (e) {
                error.AccessDenied, error.PermissionDenied => .ACCES,
                error.FileNotFound => .NOENT,
                error.IsDir => .ISDIR,
                error.NotDir => .NOTDIR,
                error.ReadOnlyFileSystem => .ROFS,
                error.NameTooLong => .NAMETOOLONG,
                error.SymLinkLoop => .LOOP,
                error.NoSpaceLeft => .NOSPC,
                else => .IO,
            };
        }
    }
    const t: ?[2]sys.TimeSpec = if (options.now) null else times;
    const uerr = if (is_stdout) sys.setTimes(null, 1, t, false) else sys.setTimes(file, -1, t, options.no_deref);
    if (uerr) |ue| {
        if (is_stdout and ue == .BADF and options.no_create) return true;
        if (open_errno) |oe| {
            if (oe != .ISDIR) {
                observer.emit(.{ .cannot_touch = .{ .path = file, .errno = oe } });
                return false;
            }
        }
        if (options.no_create and ue == .NOENT) return true;
        observer.emit(.{ .set_times_failed = .{ .path = file, .errno = ue } });
        return false;
    }
    return true;
}
