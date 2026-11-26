// SPDX-License-Identifier: GPL-2.0-or-later
//! tail library (decision 0004): output the last part of each input.
//! References: GNU coreutils manual "tail invocation" (9.7); POSIX.1-2024.
//!
//! Strategy: a regular file named by path is read backwards from its end,
//! where its size can be believed; other inputs (an open descriptor, pipes,
//! small files such as those of /proc and /sys) are streamed while holding
//! only the last N items in memory. Following (by descriptor or by name) polls,
//! and `run` does not return until the follow ends (the --pid process dies,
//! no file remains, or an output error occurs).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const scan = @import("../bytes.zig");
const sys = @import("../sys.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Header = enum { auto, always, never };

pub const Options = struct {
    /// Count bytes instead of lines.
    bytes: bool = false,
    count: u64 = 10,
    /// `+NUM`: start at item NUM instead of counting from the end.
    from_start: bool = false,
    delimiter: u8 = '\n',
    follow: bool = false,
    follow_name: bool = false,
    retry: bool = false,
    sleep_seconds: f64 = 1.0,
    pid: ?i32 = null,
    header: Header = .auto,
};

pub const Kind = enum {
    /// `err` is why the input could not be opened.
    open_failed,
    /// A directory: GNU opens it and fails on the first read.
    is_dir,
    /// `err` is the read error.
    read_failed,
    /// Following found no file left to follow (`name` is empty).
    no_files_remaining,
    /// A followed file vanished; `detail` is the system error text.
    inaccessible,
    /// Same, but --retry keeps trying.
    inaccessible_retry,
    appeared,
    replaced,
    truncated,
};

/// A problem or a follow-mode notice; the run continues unless it says so.
pub const Event = struct {
    name: []const u8,
    kind: Kind,
    err: ?anyerror = null,
    detail: []const u8 = "",
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

const Followed = struct {
    file: ?Io.File,
    /// The library closes the file when it is replaced or at the end.
    owned: bool,
    path: []const u8,
    pos: u64,
    dev: u64 = 0,
    ino: u64 = 0,
    ignored: bool = false,
};

pub fn run(env: Env, cfg: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    const show_header = switch (cfg.header) {
        .always => true,
        .never => false,
        .auto => inputs.len > 1,
    };

    var out = stickyout.Out.init(writer);
    var status: u8 = 0;
    var first = true;
    var followed: std.ArrayList(Followed) = .empty;
    defer followed.deinit(env.gpa);
    defer for (followed.items) |f| if (f.file) |fl| if (f.owned) fl.close(env.io);

    var buf: [64 * 1024]u8 = undefined;
    for (inputs) |in| {
        const name = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            if (e == error.IsDir) {
                if (show_header) printHeader(&out, name, &first);
                out.flush();
                observer.emit(.{ .name = name, .kind = .is_dir });
            } else {
                out.flush();
                observer.emit(.{ .name = name, .kind = .open_failed, .err = e });
                if (cfg.follow and cfg.retry) {
                    try followed.append(env.gpa, .{ .file = null, .owned = true, .path = name, .pos = 0 });
                }
            }
            status = 1;
            continue;
        };
        const file = opened.file;
        var keep = false;
        defer if (!keep) opened.close(env.io);
        if (show_header) printHeader(&out, name, &first);
        const is_regular = if (file.stat(env.io)) |st| st.kind == .file else |_| false;
        const end = tail(env, &out, file, cfg, is_regular and in.source == .path, &buf) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            out.flush();
            observer.emit(.{ .name = name, .kind = .read_failed, .err = e });
            status = 1;
            continue;
        };
        if (cfg.follow and is_regular) {
            const resume_at = switch (in.source) {
                .path => end,
                // An open descriptor need not have started at offset 0, so the
                // number of bytes read from it says nothing about where it is.
                .file => followStart(file, cfg) orelse end,
            };
            var fe: std.os.linux.E = .SUCCESS;
            const fst = sys.fstatFd(file.handle, &fe);
            try followed.append(env.gpa, .{
                .file = file,
                .owned = opened.owned,
                .path = name,
                .pos = resume_at,
                .dev = if (fst) |f| (@as(u64, f.dev_major) << 32) | f.dev_minor else 0,
                .ino = if (fst) |f| f.ino else 0,
            });
            keep = true;
        }
    }
    try out.finish();
    if (cfg.follow and followed.items.len == 0) {
        if (!cfg.retry or !cfg.follow_name) {
            observer.emit(.{ .name = "", .kind = .no_files_remaining });
            return .{ .failed = true };
        }
    }
    if (cfg.follow and followed.items.len > 0) {
        return followLoop(env, &out, followed.items, cfg, show_header or inputs.len > 1, cfg.header != .never, &buf, status, observer);
    }
    return .{ .failed = status != 0 };
}

fn printHeader(out: *stickyout.Out, name: []const u8, first: *bool) void {
    if (!first.*) out.writeByte('\n');
    first.* = false;
    out.write("==> ");
    out.write(if (std.mem.eql(u8, name, "-")) "standard input" else name);
    out.write(" <==\n");
}

/// Where to start following a file that was handed to us already open: where
/// reading it stopped, or its end when nothing was to be read.
fn followStart(file: Io.File, cfg: Options) ?u64 {
    if (!cfg.from_start and cfg.count == 0) {
        var e: sys.E = .SUCCESS;
        // As in GNU, the shared descriptor is left at the end.
        _ = sys.seekFd(file.handle, 0, 2, &e);
    }
    return sys.filePosition(file.handle);
}

/// Print the requested tail of `file`. Returns the offset just past the last
/// byte consumed (for a file we opened ourselves, where --follow starts).
fn tail(env: Env, out: *stickyout.Out, file: Io.File, cfg: Options, seekable: bool, buf: []u8) !u64 {
    if (!cfg.from_start and cfg.count == 0) {
        // Nothing to print; for -f still start following at the current end.
        return if (seekable) try file.length(env.io) else 0;
    }
    if (cfg.from_start) return fromStart(env, out, file, cfg, buf);
    if (seekable) return lastFromSeekable(env, out, file, cfg, buf);
    return lastFromStream(env, out, file, cfg, buf);
}

/// `+NUM`: skip NUM-1 items, copy the rest.
fn fromStart(env: Env, out: *stickyout.Out, file: Io.File, cfg: Options, buf: []u8) !u64 {
    var skip: u64 = if (cfg.count > 0) cfg.count - 1 else 0;
    var total: u64 = 0;
    while (true) {
        const n = try common.readChunk(env.io, file, buf);
        if (n == 0) return total;
        total += n;
        var chunk = buf[0..n];
        if (skip > 0) {
            if (cfg.bytes) {
                const drop: usize = @intCast(@min(skip, chunk.len));
                skip -= drop;
                chunk = chunk[drop..];
            } else {
                var start: usize = 0;
                while (skip > 0) {
                    const idx = std.mem.indexOfScalarPos(u8, chunk, start, cfg.delimiter) orelse {
                        start = chunk.len;
                        break;
                    };
                    skip -= 1;
                    start = idx + 1;
                }
                chunk = chunk[start..];
            }
        }
        out.write(chunk);
        if (out.failed) return total;
    }
}

/// Read the last N bytes/lines of a regular file by looking only at its end.
fn lastFromSeekable(env: Env, out: *stickyout.Out, file: Io.File, cfg: Options, buf: []u8) !u64 {
    const size = try file.length(env.io);
    if (!try sizeIsReal(env, file, size)) return lastFromStream(env, out, file, cfg, buf);
    var start: u64 = 0;
    if (cfg.bytes) {
        start = if (size > cfg.count) size - cfg.count else 0;
    } else {
        // Scan backwards for the N-th delimiter from the end. A delimiter
        // that is the very last byte only terminates the last line.
        var pos = size;
        var found: u64 = 0;
        var skipped_final = false;
        scanning: while (pos > 0) {
            const want: usize = @intCast(@min(pos, buf.len));
            pos -= want;
            const got = try file.readPositionalAll(env.io, buf[0..want], pos);
            // Nothing has been written, and positional reads left the file
            // position where it was.
            if (got < want) return lastFromStream(env, out, file, cfg, buf);
            var hi = got; // look for delimiters in buf[0..hi]
            while (scan.lastIndexOf(buf[0..hi], cfg.delimiter)) |k| {
                hi = k;
                if (!skipped_final and pos + k == size - 1) {
                    skipped_final = true;
                    continue;
                }
                found += 1;
                if (found == cfg.count) {
                    start = pos + k + 1;
                    break :scanning;
                }
            }
        }
    }
    var off = start;
    while (true) {
        const n = try file.readPositional(env.io, &.{buf}, off);
        if (n == 0) return off;
        off += n;
        out.write(buf[0..n]);
        if (out.failed) return off;
    }
}

/// Whether the reported size can be used to find the end. procfs reports 0
/// for files with contents, and sysfs one block (4096) for a few bytes; as in
/// GNU only a size over a block is trusted, and then only if its last byte can
/// be read. Streaming such a short file costs nothing.
fn sizeIsReal(env: Env, file: Io.File, size: u64) !bool {
    var e: std.os.linux.E = .SUCCESS;
    const block: u64 = if (sys.fstatFd(file.handle, &e)) |st| st.blksize else 0;
    if (size <= @max(block, 4096)) return false;
    var last: [1]u8 = undefined;
    return try file.readPositionalAll(env.io, &last, size - 1) == 1;
}

/// Stream the input keeping only the last N items.
fn lastFromStream(env: Env, out: *stickyout.Out, file: Io.File, cfg: Options, buf: []u8) !u64 {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(env.gpa);
    var start: usize = 0;
    var delims: u64 = 0;
    var total: u64 = 0;
    while (true) {
        const n = try common.readChunk(env.io, file, buf);
        if (n == 0) break;
        total += n;
        try pending.appendSlice(env.gpa, buf[0..n]);
        if (cfg.bytes) {
            const held = pending.items.len - start;
            if (held > cfg.count) start += @intCast(held - cfg.count);
        } else {
            delims += scan.count(buf[0..n], cfg.delimiter);
            while (true) {
                const partial: u64 = @intFromBool(pending.items.len > start and pending.items[pending.items.len - 1] != cfg.delimiter);
                if (delims + partial <= cfg.count) break;
                const idx = std.mem.indexOfScalarPos(u8, pending.items, start, cfg.delimiter).?;
                start = idx + 1;
                delims -= 1;
            }
        }
        if (start > 0 and start >= pending.items.len / 2) {
            const rest = pending.items.len - start;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[start..]);
            pending.shrinkRetainingCapacity(rest);
            start = 0;
        }
    }
    out.write(pending.items[start..]);
    return total;
}

/// The part of the follow loop that copies data out of the open files.
const Follower = struct {
    env: Env,
    out: *stickyout.Out,
    buf: []u8,
    /// Whether a header names the file whenever the output changes files.
    headers: bool,
    last_printed: ?usize,
    observer: Observer,
    exit_status: u8,
    activity: bool = false,

    /// Copy what has been added to the open file `f` since the last call. This
    /// is also the last thing done with a descriptor before it is closed: after
    /// a rotation, the lines written just before it exist only there.
    fn drain(follower: *Follower, f: *Followed, idx: usize) void {
        const env = follower.env;
        const out = follower.out;
        const buf = follower.buf;
        const fl = f.file orelse return;
        const size = fl.length(env.io) catch return;
        if (size < f.pos) {
            out.flush();
            follower.observer.emit(.{ .name = f.path, .kind = .truncated });
            f.pos = 0;
        }
        while (f.pos < size) {
            const n = fl.readPositional(env.io, &.{buf}, f.pos) catch |e| {
                out.flush();
                follower.observer.emit(.{ .name = f.path, .kind = .read_failed, .err = e });
                follower.exit_status = 1;
                break;
            };
            if (n == 0) break;
            if (follower.headers and follower.last_printed != idx) {
                out.write("\n==> ");
                out.write(f.path);
                out.write(" <==\n");
                follower.last_printed = idx;
            }
            out.write(buf[0..n]);
            f.pos += n;
            follower.activity = true;
        }
    }
};

/// --follow=descriptor / --follow=name: poll for growth (and, by name, for
/// removal, replacement and re-creation).
fn followLoop(env: Env, out: *stickyout.Out, files: []Followed, cfg: Options, multiple: bool, headers_ok: bool, buf: []u8, status: u8, observer: Observer) error{WriteFailed}!Result {
    var follower: Follower = .{
        .env = env,
        .out = out,
        .buf = buf,
        .headers = multiple and headers_ok,
        .last_printed = if (files.len > 0) files.len - 1 else null,
        .observer = observer,
        .exit_status = status,
    };
    const interval_ns: i96 = @intFromFloat(@min(cfg.sleep_seconds, 1e9) * std.time.ns_per_s);
    while (true) {
        follower.activity = false;
        for (files, 0..) |*f, idx| {
            if (f.ignored) continue;
            if (cfg.follow_name or f.file == null) {
                var se: std.os.linux.E = .SUCCESS;
                const st = sys.fileStat(f.path, true, &se);
                if (st == null) {
                    if (f.file) |fl| {
                        follower.drain(f, idx);
                        out.flush();
                        observer.emit(.{
                            .name = f.path,
                            .kind = if (cfg.retry) .inaccessible_retry else .inaccessible,
                            .detail = sys.errnoText(se),
                        });
                        if (f.owned) fl.close(env.io);
                        f.file = null;
                        f.ignored = !cfg.retry;
                        if (!cfg.retry) follower.exit_status = 1;
                    }
                    continue;
                }
                const dev = (@as(u64, st.?.dev_major) << 32) | st.?.dev_minor;
                const fresh = f.file == null;
                if (fresh or (cfg.follow_name and (dev != f.dev or st.?.ino != f.ino))) {
                    const nf = Io.Dir.cwd().openFile(env.io, f.path, .{ .allow_directory = false }) catch continue;
                    follower.drain(f, idx); // the replaced file, if still open
                    out.flush();
                    if (f.file) |old| if (f.owned) old.close(env.io);
                    observer.emit(.{ .name = f.path, .kind = if (fresh) .appeared else .replaced });
                    f.file = nf;
                    f.owned = true;
                    f.pos = 0;
                    f.dev = dev;
                    f.ino = st.?.ino;
                }
            }
            follower.drain(f, idx);
        }
        try out.finish();
        var live = false;
        for (files) |f| if (!f.ignored) {
            live = true;
        };
        if (!live) {
            observer.emit(.{ .name = "", .kind = .no_files_remaining });
            return .{ .failed = true };
        }
        if (!follower.activity) if (cfg.pid) |pid| if (!sys.processAlive(pid)) return .{ .failed = follower.exit_status != 0 };
        std.Io.sleep(env.io, .fromNanoseconds(interval_ns), .awake) catch return .{ .failed = follower.exit_status != 0 };
    }
}
