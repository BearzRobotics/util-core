// SPDX-License-Identifier: GPL-2.0-or-later
//! date library: parse date strings (GNU parse_datetime and the POSIX
//! MMDDhhmm[[CC]YY] form), format them with strftime, and write the result or
//! the `--json` object. Reference: GNU coreutils manual "date invocation"
//! (9.7), POSIX.1-2024 date.
//!
//! -d/-f use src/datetime.zig (GNU's parse_datetime), output uses
//! src/strftime.zig, zones come from src/tz.zig (TZ, /etc/localtime, TZif).
//! Setting the clock is available as `setSystemTime`; nothing in this module
//! calls it on its own.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const datetime = @import("../datetime.zig");
const dateinfo = @import("../dateinfo.zig");

pub const Env = common.Env;
pub const Timespec = datetime.Timespec;
pub const Zone = tzmod.Zone;

/// GNU's default output format.
pub const default_format = "%a %b %e %H:%M:%S %Z %Y";
/// What `--resolution` formats.
pub const resolution_format = "%s.%N";
pub const rfc_email_format = "%a, %d %b %Y %H:%M:%S %z";

pub const Options = struct {
    /// strftime format for each date; ignored with `json`.
    format: []const u8 = default_format,
    /// Extension (decision 0003): one JSON object per date (see dateinfo.zig).
    json: bool = false,
    /// Use UTC regardless of TZ (`-u`).
    utc: bool = false,
};

/// Problems that do not stop the run.
pub const Event = union(enum) {
    /// A line of a batch (`-f`) is not a date.
    invalid_date: []const u8,
};

pub const Error = error{ OutOfMemory, WriteFailed, FormatFailed };

/// `%-N` becomes `%9N` (the clock's 1 ns resolution). Result owned by `gpa`.
pub fn normalizeFormat(gpa: std.mem.Allocator, f: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < f.len) {
        if (f[i] == '%' and i + 2 < f.len + 0 and f[i + 1] == '-' and f[i + 2] == 'N') {
            try out.appendSlice(gpa, "%9N");
            i += 3;
        } else if (f[i] == '%' and i + 1 < f.len) {
            try out.appendSlice(gpa, f[i .. i + 2]);
            i += 2;
        } else {
            try out.append(gpa, f[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The current time of the real-time clock.
pub fn now(env: Env) Timespec {
    const ts = Io.Timestamp.now(env.io, .real);
    return .{
        .sec = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ts.nanoseconds, std.time.ns_per_s)),
    };
}

/// Modification time of `path` (symlinks followed); null with `err` set when
/// it cannot be examined.
pub fn fileMtime(path: []const u8, err: *std.os.linux.E) ?Timespec {
    const st = sys.fileStat(path, true, err) orelse return null;
    return .{ .sec = st.mtime_s, .nsec = st.mtime_ns };
}

/// Set the system clock; null on success, otherwise the errno. Only the
/// caller decides to do this (it is the `date -s` operation).
pub fn setSystemTime(when: Timespec) ?std.os.linux.E {
    return sys.setRealtime(when.sec, when.nsec);
}

/// A time zone and a notion of "now" shared by the dates of one run.
pub const Date = struct {
    env: Env,
    options: Options,
    zone: Zone,
    now: Timespec,

    /// The zone is TZ from `env` (or UTC with `options.utc`).
    pub fn init(env: Env, options: Options) Date {
        const tz_env: ?[]const u8 = if (options.utc) "UTC0" else env.getenv("TZ");
        return .{
            .env = env,
            .options = options,
            .zone = tzmod.load(env.gpa, env.io, tz_env),
            .now = now(env),
        };
    }

    pub fn deinit(d: *Date) void {
        d.zone.deinit();
    }

    /// GNU parse_datetime relative to `d.now`; null if `text` is not a date.
    pub fn parse(d: *Date, text: []const u8) ?Timespec {
        return datetime.parse(d.env.gpa, d.env.io, text, d.now, &d.zone);
    }

    /// The POSIX `MMDDhhmm[[CC]YY]` operand form; null if it does not match.
    pub fn parsePosix(d: *Date, text: []const u8) ?Timespec {
        const cur = tzmod.localtime(&d.zone, d.now.sec);
        const t = datetime.posixTime(&d.zone, text, false, cur.year) orelse return null;
        return .{ .sec = t, .nsec = 0 };
    }

    /// Write one date: the formatted line (`options.format` plus a newline)
    /// or the JSON object. `format` must already be `normalizeFormat`ted.
    pub fn show(d: *Date, writer: *Io.Writer, when: Timespec) Error!void {
        const gpa = d.env.gpa;
        const tm = tzmod.localtime(&d.zone, when.sec);
        if (d.options.json) {
            var aw: Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            dateinfo.writeJson(&aw.writer, &tm, when.sec, when.nsec) catch return error.FormatFailed;
            try writer.writeAll(aw.written());
            return;
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try strftime.format(&buf, gpa, d.options.format, &tm, when.sec, when.nsec);
        try writer.writeAll(buf.items);
        try writer.writeByte('\n');
    }

    /// `-f`: show the date on each line of `data`. A line that is not a date
    /// is reported through `observer` (the caller flushes before wording it)
    /// and makes the result false; a line that cannot be formatted does too.
    pub fn showLines(d: *Date, writer: *Io.Writer, data: []const u8, observer: common.Observer(Event)) Error!bool {
        var ok = true;
        var pos: usize = 0;
        while (pos < data.len) {
            const e = std.mem.indexOfScalarPos(u8, data, pos, '\n');
            const stop = e orelse data.len;
            const line = data[pos..stop];
            pos = if (e) |x| x + 1 else data.len;
            if (d.parse(line)) |when| {
                d.show(writer, when) catch |err| switch (err) {
                    error.FormatFailed => ok = false,
                    else => |other| return other,
                };
            } else {
                observer.emit(.{ .invalid_date = line });
                ok = false;
            }
        }
        return ok;
    }
};

test "normalizeFormat widens %-N and leaves other directives alone" {
    const a = std.testing.allocator;
    const r = try normalizeFormat(a, "%H:%-N %% %Y");
    defer a.free(r);
    try std.testing.expectEqualStrings("%H:%9N %% %Y", r);
}

test "show formats a fixed instant in UTC" {
    const gpa = std.testing.allocator;
    const env: Env = .{ .io = std.testing.io, .gpa = gpa };
    var d = Date.init(env, .{ .utc = true, .format = "%Y-%m-%d %H:%M:%S" });
    defer d.deinit();
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try d.show(&aw.writer, .{ .sec = 86400 * 365, .nsec = 0 });
    try std.testing.expectEqualStrings("1971-01-01 00:00:00\n", aw.written());
}
