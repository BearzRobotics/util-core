// SPDX-License-Identifier: GPL-2.0-or-later
//! tail — output the last part of files.
//! References: GNU coreutils manual "tail invocation" (9.7); POSIX.1-2024 tail.
//!
//! Implemented: -n/-c with [+]NUM[suffix], -q, -v, -z, long options, the
//! obsolete `-NUM[bcl][f]` first-argument form, and -f/--follow=descriptor|name,
//! -F, --retry, -s, --pid for regular files (by polling). Not implemented (rejected
//! with an error): --max-unchanged-stats.
//!
//! Strategy: a regular file named on the command line is read backwards from
//! its end; other inputs (stdin, pipes) are streamed while holding only the
//! last N items in memory.

const std = @import("std");
const cli = @import("../cli.zig");
const scan = @import("../bytes.zig");
const sys = @import("../sys.zig");
const count_arg = @import("../count_arg.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "bytes", "lines", "follow", "quiet", "silent", "verbose", "zero-terminated", "sleep-interval", "pid", "retry", "max-unchanged-stats", "help", "version" };

const Config = struct {
    bytes: bool = false,
    count: u64 = 10,
    /// `+NUM`: start at item NUM instead of counting from the end.
    from_start: bool = false,
    delim: u8 = '\n',
    follow: bool = false,
    follow_name: bool = false,
    retry: bool = false,
    sleep_seconds: f64 = 1.0,
    pid: ?i32 = null,
};

const Header = enum { auto, always, never };

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    var header: Header = .auto;
    const args = ctx.args;
    var i: usize = 0;

    if (args.len > 0 and isObsolete(args[0])) {
        if (!parseObsolete(ctx, args[0], &cfg)) return 1;
        i = 1;
    }

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            switch (k) {
                0, 1, 7, 8, 10 => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                            return 1;
                        }
                        val = args[i];
                    }
                    switch (k) {
                        0, 1 => if (!setCount(ctx, &cfg, k == 0, val)) return 1,
                        7 => if (!setSleep(ctx, &cfg, val)) return 1,
                        8 => if (!setPid(ctx, &cfg, val)) return 1,
                        else => return unsupported(ctx, "--max-unchanged-stats"),
                    }
                },
                2 => {
                    cfg.follow = true;
                    if (eq) |e| {
                        const how = a[e + 1 ..];
                        if (how.len == 0 or !(std.mem.startsWith(u8, "descriptor", how) or std.mem.startsWith(u8, "name", how))) {
                            cli.warn(ctx, "invalid argument '{s}' for '--follow'\nValid arguments are:\n  - 'descriptor'\n  - 'name'\nTry '{s} --help' for more information.", .{ how, ctx.name });
                            return 1;
                        }
                        cfg.follow_name = std.mem.startsWith(u8, "name", how);
                    } else cfg.follow_name = false;
                },
                3, 4 => header = .never,
                5 => header = .always,
                6 => cfg.delim = 0,
                9 => cfg.retry = true,
                11 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'q' => header = .never,
            'v' => header = .always,
            'z' => cfg.delim = 0,
            'f' => {
                cfg.follow = true;
                cfg.follow_name = false;
            },
            'F' => {
                cfg.follow = true;
                cfg.follow_name = true;
                cfg.retry = true;
            },
            '0'...'9' => {
                // GNU: digits are only valid in the obsolete first-argument form.
                cli.warn(ctx, "option used in invalid context -- {c}", .{a[j]});
                return 1;
            },
            'c', 'n', 's' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                const ok = if (a[j] == 's') setSleep(ctx, &cfg, val) else setCount(ctx, &cfg, a[j] == 'c', val);
                if (!ok) return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    if (!cfg.follow) {
        if (cfg.retry) cli.warn(ctx, "warning: --retry ignored; --retry is useful only when following", .{});
        if (cfg.pid != null) cli.warn(ctx, "warning: PID ignored; --pid=PID is useful only when following", .{});
    } else if (cfg.retry and !cfg.follow_name) {
        cli.warn(ctx, "warning: --retry only effective for the initial open", .{});
    }
    if (cfg.follow and cfg.follow_name) for (inputs) |nm| if (std.mem.eql(u8, nm, "-")) {
        cli.warn(ctx, "cannot follow '-' by name", .{});
        return 1;
    };
    const show_header = switch (header) {
        .always => true,
        .never => false,
        .auto => inputs.len > 1,
    };

    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    var first = true;
    var followed: std.ArrayList(Followed) = .empty;
    defer followed.deinit(ctx.gpa);
    defer for (followed.items) |f| if (f.file) |fl| cli.closeInput(ctx.io, fl);

    var buf: [64 * 1024]u8 = undefined;
    for (inputs) |path| {
        const file = cli.openInput(ctx.io, path) catch |e| {
            if (e == error.IsDir) {
                if (show_header) printHeader(&out, path, &first);
                out.flush();
                cli.warn(ctx, "error reading '{s}': Is a directory", .{path});
            } else {
                out.flush();
                cli.warn(ctx, "cannot open '{s}' for reading: {s}", .{ path, cli.errText(e) });
                if (cfg.follow and cfg.retry and e != error.IsDir) {
                    followed.append(ctx.gpa, .{ .file = null, .path = path, .pos = 0 }) catch return oom(ctx);
                }
            }
            status = 1;
            continue;
        };
        var keep = false;
        defer if (!keep) cli.closeInput(ctx.io, file);
        if (show_header) printHeader(&out, path, &first);
        const is_regular = if (file.stat(ctx.io)) |st| st.kind == .file else |_| false;
        const is_stdin = std.mem.eql(u8, path, "-");
        const end = tail(ctx, &out, file, cfg, is_regular and !is_stdin, &buf) catch |e| {
            out.flush();
            cli.warn(ctx, "error reading '{s}': {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
        if (cfg.follow and is_regular) {
            var fe: std.os.linux.E = .SUCCESS;
            const fst = sys.fstatFd(file.handle, &fe);
            followed.append(ctx.gpa, .{
                .file = file,
                .path = path,
                .pos = end,
                .dev = if (fst) |f| (@as(u64, f.dev_major) << 32) | f.dev_minor else 0,
                .ino = if (fst) |f| f.ino else 0,
            }) catch return oom(ctx);
            keep = true;
        }
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    if (cfg.follow and followed.items.len == 0) {
        if (!cfg.retry or !cfg.follow_name) {
            cli.warn(ctx, "no files remaining", .{});
            return 1;
        }
    }
    if (cfg.follow and followed.items.len > 0) {
        return followLoop(ctx, &out, followed.items, cfg, show_header or inputs.len > 1, header != .never, &buf, status);
    }
    return status;
}

const Followed = struct {
    file: ?Io.File,
    path: []const u8,
    pos: u64,
    dev: u64 = 0,
    ino: u64 = 0,
    ignored: bool = false,
};

fn printHeader(out: *cli.Out, path: []const u8, first: *bool) void {
    if (!first.*) out.writeByte('\n');
    first.* = false;
    out.write("==> ");
    out.write(if (std.mem.eql(u8, path, "-")) "standard input" else path);
    out.write(" <==\n");
}

/// Print the requested tail of `file`. Returns the offset just past the last
/// byte consumed (the starting position for --follow).
fn tail(ctx: cli.Context, out: *cli.Out, file: Io.File, cfg: Config, seekable: bool, buf: []u8) !u64 {
    if (!cfg.from_start and cfg.count == 0) {
        // Nothing to print; for -f still start following at the current end.
        return if (seekable) try file.length(ctx.io) else 0;
    }
    if (cfg.from_start) return fromStart(ctx, out, file, cfg, buf);
    if (seekable) return lastFromSeekable(ctx, out, file, cfg, buf);
    return lastFromStream(ctx, out, file, cfg, buf);
}

/// `+NUM`: skip NUM-1 items, copy the rest.
fn fromStart(ctx: cli.Context, out: *cli.Out, file: Io.File, cfg: Config, buf: []u8) !u64 {
    var skip: u64 = if (cfg.count > 0) cfg.count - 1 else 0;
    var total: u64 = 0;
    while (true) {
        const n = try cli.readChunk(ctx.io, file, buf);
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
                    const idx = std.mem.indexOfScalarPos(u8, chunk, start, cfg.delim) orelse {
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
fn lastFromSeekable(ctx: cli.Context, out: *cli.Out, file: Io.File, cfg: Config, buf: []u8) !u64 {
    const size = try file.length(ctx.io);
    var start: u64 = 0;
    if (cfg.bytes) {
        start = if (size > cfg.count) size - cfg.count else 0;
    } else {
        // Scan backwards for the N-th delimiter from the end. A delimiter
        // that is the very last byte only terminates the last line.
        var pos = size;
        var found: u64 = 0;
        var skipped_final = false;
        scan: while (pos > 0) {
            const want: usize = @intCast(@min(pos, buf.len));
            pos -= want;
            const got = try file.readPositionalAll(ctx.io, buf[0..want], pos);
            var hi = got; // look for delimiters in buf[0..hi]
            while (scan.lastIndexOf(buf[0..hi], cfg.delim)) |k| {
                hi = k;
                if (!skipped_final and pos + k == size - 1) {
                    skipped_final = true;
                    continue;
                }
                found += 1;
                if (found == cfg.count) {
                    start = pos + k + 1;
                    break :scan;
                }
            }
        }
    }
    var off = start;
    while (true) {
        const n = try file.readPositional(ctx.io, &.{buf}, off);
        if (n == 0) return off;
        off += n;
        out.write(buf[0..n]);
        if (out.failed) return off;
    }
}

/// Stream the input keeping only the last N items.
fn lastFromStream(ctx: cli.Context, out: *cli.Out, file: Io.File, cfg: Config, buf: []u8) !u64 {
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(ctx.gpa);
    var start: usize = 0;
    var delims: u64 = 0;
    var total: u64 = 0;
    while (true) {
        const n = try cli.readChunk(ctx.io, file, buf);
        if (n == 0) break;
        total += n;
        try pending.appendSlice(ctx.gpa, buf[0..n]);
        if (cfg.bytes) {
            const held = pending.items.len - start;
            if (held > cfg.count) start += @intCast(held - cfg.count);
        } else {
            delims += scan.count(buf[0..n], cfg.delim);
            while (true) {
                const partial: u64 = @intFromBool(pending.items.len > start and pending.items[pending.items.len - 1] != cfg.delim);
                if (delims + partial <= cfg.count) break;
                const idx = std.mem.indexOfScalarPos(u8, pending.items, start, cfg.delim).?;
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

/// --follow=descriptor / --follow=name: poll for growth (and, by name, for
/// removal, replacement and re-creation).
fn followLoop(ctx: cli.Context, out: *cli.Out, files: []Followed, cfg: Config, multiple: bool, headers_ok: bool, buf: []u8, status: u8) u8 {
    var last_printed: ?usize = if (files.len > 0) files.len - 1 else null;
    const interval_ns: i96 = @intFromFloat(@min(cfg.sleep_seconds, 1e9) * std.time.ns_per_s);
    var exit_status = status;
    while (true) {
        var activity = false;
        for (files, 0..) |*f, idx| {
            if (f.ignored) continue;
            if (cfg.follow_name or f.file == null) {
                var se: std.os.linux.E = .SUCCESS;
                const st = sys.fileStat(f.path, true, &se);
                if (st == null) {
                    if (f.file) |fl| {
                        out.flush();
                        if (cfg.retry) {
                            cli.warn(ctx, "'{s}' has become inaccessible: {s}", .{ f.path, sys.errnoText(se) });
                        } else cli.warn(ctx, "{s}: {s}", .{ f.path, sys.errnoText(se) });
                        cli.closeInput(ctx.io, fl);
                        f.file = null;
                        f.ignored = !cfg.retry;
                        exit_status = if (cfg.retry) exit_status else 1;
                    }
                    continue;
                }
                const dev = (@as(u64, st.?.dev_major) << 32) | st.?.dev_minor;
                const fresh = f.file == null;
                if (fresh or (cfg.follow_name and (dev != f.dev or st.?.ino != f.ino))) {
                    const nf = cli.openInput(ctx.io, f.path) catch continue;
                    out.flush();
                    if (f.file) |old| cli.closeInput(ctx.io, old);
                    if (fresh) {
                        cli.warn(ctx, "'{s}' has appeared;  following new file", .{f.path});
                    } else cli.warn(ctx, "'{s}' has been replaced;  following new file", .{f.path});
                    f.file = nf;
                    f.pos = 0;
                    f.dev = dev;
                    f.ino = st.?.ino;
                }
            }
            const fl = f.file orelse continue;
            const size = fl.length(ctx.io) catch continue;
            if (size < f.pos) {
                out.flush();
                cli.warn(ctx, "{s}: file truncated", .{f.path});
                f.pos = 0;
            }
            while (f.pos < size) {
                const n = fl.readPositional(ctx.io, &.{buf}, f.pos) catch |e| {
                    out.flush();
                    cli.warn(ctx, "error reading '{s}': {s}", .{ f.path, cli.errText(e) });
                    exit_status = 1;
                    break;
                };
                if (n == 0) break;
                if (multiple and headers_ok and last_printed != idx) {
                    out.write("\n==> ");
                    out.write(f.path);
                    out.write(" <==\n");
                    last_printed = idx;
                }
                out.write(buf[0..n]);
                f.pos += n;
                activity = true;
            }
        }
        out.flush();
        if (out.failed) {
            cli.writeErrorWarn(ctx);
            return 1;
        }
        var live = false;
        for (files) |f| if (!f.ignored) {
            live = true;
        };
        if (!live) {
            cli.warn(ctx, "no files remaining", .{});
            return 1;
        }
        if (!activity) if (cfg.pid) |pid| if (!sys.processAlive(pid)) return exit_status;
        std.Io.sleep(ctx.io, .fromNanoseconds(interval_ns), .awake) catch return exit_status;
    }
}

/// Obsolete `-NUM[bcl][f]` as the first argument (GNU rejects other letters,
/// unlike head). `b` means 512-byte blocks and implies bytes.
fn isObsolete(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-' or !std.ascii.isDigit(a[1])) return false;
    var i: usize = 1;
    while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
    if (i < a.len and std.mem.indexOfScalar(u8, "bcl", a[i]) != null) i += 1;
    if (i < a.len and a[i] == 'f') i += 1;
    return i == a.len;
}

fn parseObsolete(ctx: cli.Context, a: []const u8, cfg: *Config) bool {
    var i: usize = 1;
    while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
    var num = count_arg.parse(a[1..i]) orelse {
        cli.warn(ctx, "invalid number of lines: '{s}'", .{a[1..i]});
        return false;
    };
    cfg.from_start = false;
    if (i < a.len and a[i] != 'f') {
        switch (a[i]) {
            'b' => {
                num.value *|= 512;
                cfg.bytes = true;
            },
            'c' => cfg.bytes = true,
            else => cfg.bytes = false,
        }
    }
    cfg.count = num.value;
    if (a[a.len - 1] == 'f') cfg.follow = true;
    return true;
}

fn setCount(ctx: cli.Context, cfg: *Config, bytes: bool, text: []const u8) bool {
    const c = count_arg.parse(text) orelse {
        cli.warn(ctx, "invalid number of {s}: '{s}'", .{ if (bytes) "bytes" else "lines", text });
        return false;
    };
    cfg.bytes = bytes;
    cfg.count = c.value;
    cfg.from_start = c.sign == .plus;
    return true;
}

fn setSleep(ctx: cli.Context, cfg: *Config, text: []const u8) bool {
    const v = std.fmt.parseFloat(f64, text) catch -1;
    if (!(v >= 0)) {
        cli.warn(ctx, "invalid number of seconds: '{s}'", .{text});
        return false;
    }
    cfg.sleep_seconds = v;
    return true;
}

fn setPid(ctx: cli.Context, cfg: *Config, text: []const u8) bool {
    const v = std.fmt.parseInt(i32, text, 10) catch -1;
    if (v < 0) {
        cli.warn(ctx, "invalid PID: '{s}'", .{text});
        return false;
    }
    cfg.pid = v;
    return true;
}

fn unsupported(ctx: cli.Context, what: []const u8) u8 {
    cli.warn(ctx, "{s} is not supported yet", .{what});
    return 1;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tail [OPTION]... [FILE]...\n" ++
        "Print the last 10 lines of each FILE to standard output.\n" ++
        "With more than one FILE, precede each with a header giving the file name.\n\n" ++
        "  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to\n" ++
        "                             output starting with byte NUM of each file\n" ++
        "  -f, --follow[=descriptor]  output appended data as the file grows\n" ++
        "  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;\n" ++
        "                             or use -n +NUM to skip NUM-1 lines at the start\n" ++
        "      --pid=PID            with -f, terminate after process ID, PID dies\n" ++
        "  -q, --quiet, --silent    never output headers giving file names\n" ++
        "  -s, --sleep-interval=N   with -f, sleep for approximately N seconds\n" ++
        "                             (default 1.0) between iterations\n" ++
        "  -v, --verbose            always output headers giving file names\n" ++
        "  -z, --zero-terminated    line delimiter is NUL, not newline\n" ++
        "      --help               display this help and exit\n" ++
        "      --version            output version information and exit\n")) 0 else 1;
}

test "isObsolete" {
    try std.testing.expect(isObsolete("-5"));
    try std.testing.expect(isObsolete("-5f"));
    try std.testing.expect(isObsolete("-5cf"));
    try std.testing.expect(!isObsolete("-5q"));
    try std.testing.expect(!isObsolete("-5k"));
    try std.testing.expect(!isObsolete("-f"));
    try std.testing.expect(!isObsolete("-5x"));
}
