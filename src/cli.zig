//! Shared command-line facilities: the per-invocation context handed to every
//! command frontend, and small helpers for the --help/--version convention.
//!
//! Nothing here owns process-wide state. Commands receive everything they need
//! through `Context`, which is what lets the same command run as a standalone
//! executable or behind the multicall dispatcher (SPEC.md §6.2, §7).

const std = @import("std");
const Io = std.Io;

pub const version = "0.0.0-dev";

/// Everything a command frontend needs for one invocation.
pub const Context = struct {
    /// Command name as the user invoked it (used in diagnostics).
    name: []const u8,
    /// Arguments after the command name. Borrowed; valid for the whole run.
    args: []const [:0]const u8,
    io: Io,
    /// General-purpose allocator for temporary allocations.
    gpa: std.mem.Allocator,
    /// Environment variables; null when the host provides none (tests).
    environ: ?*const std.process.Environ.Map = null,
};

/// Value of an environment variable, or null when unset or unavailable.
pub fn getenv(ctx: Context, key: []const u8) ?[]const u8 {
    const map = ctx.environ orelse return null;
    return map.get(key);
}

/// The usual auto / always / never choice for --color and similar options.
pub const When = enum {
    auto,
    always,
    never,

    pub fn parse(text: []const u8) ?When {
        return std.meta.stringToEnum(When, text);
    }
};

/// True when NO_COLOR is set to a non-empty string (any value), per
/// https://no-color.org. See SPEC §5.4.
pub fn noColor(ctx: Context) bool {
    const v = getenv(ctx, "NO_COLOR") orelse return false;
    return v.len > 0;
}

/// Decide whether to emit color/text-style escapes on one output stream.
/// Precedence (SPEC §5.4): an explicit `always` / `never` wins; for `auto`,
/// color is used only when the stream is a terminal, TERM is not "dumb", and
/// NO_COLOR is not set.
pub fn colorEnabled(ctx: Context, when: When, stream_is_tty: bool) bool {
    switch (when) {
        .always => return true,
        .never => return false,
        .auto => {},
    }
    if (!stream_is_tty) return false;
    if (noColor(ctx)) return false;
    if (getenv(ctx, "TERM")) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    return true;
}

/// Decide whether non-color text styles (bold, faint, ...) may be emitted.
/// NO_COLOR does not affect them (SPEC §5.4); `never` removes all styling.
pub fn styleEnabled(ctx: Context, when: When, stream_is_tty: bool) bool {
    switch (when) {
        .always => return true,
        .never => return false,
        .auto => {},
    }
    if (!stream_is_tty) return false;
    if (getenv(ctx, "TERM")) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    return true;
}

/// A command frontend: returns the process exit status.
pub const CommandFn = *const fn (ctx: Context) u8;

/// True when `args` is exactly one argument equal to `flag`. GNU true/false
/// recognise --help/--version only in this position.
pub fn soleArg(args: []const [:0]const u8, flag: []const u8) bool {
    return args.len == 1 and std.mem.eql(u8, args[0], flag);
}

/// Result of matching a "--name" against a command's long options, following
/// getopt_long: an exact match wins, otherwise a unique prefix is accepted.
pub const LongMatch = union(enum) { found: usize, none, ambiguous };

/// `name` is the option text after "--" and before any "=value".
pub fn matchLong(name: []const u8, names: []const []const u8) LongMatch {
    var found: ?usize = null;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return .{ .found = i };
        if (name.len > 0 and std.mem.startsWith(u8, n, name)) {
            if (found != null) return .ambiguous;
            found = i;
        }
    }
    return if (found) |i| .{ .found = i } else .none;
}

/// Print the standard "invalid option" diagnostic for a short option.
pub fn invalidShort(ctx: Context, c: u8) void {
    warn(ctx, "invalid option -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
}

/// Print the standard diagnostic for an unknown or ambiguous long option.
pub fn badLong(ctx: Context, arg: []const u8, m: LongMatch) void {
    switch (m) {
        .ambiguous => warn(ctx, "option '{s}' is ambiguous\nTry '{s} --help' for more information.", .{ arg, ctx.name }),
        else => warn(ctx, "unrecognized option '{s}'\nTry '{s} --help' for more information.", .{ arg, ctx.name }),
    }
}

/// Write `text` to stdout. Returns false on write failure (e.g. closed pipe);
/// callers decide the exit status.
pub fn writeStdout(io: Io, text: []const u8) bool {
    Io.File.stdout().writeStreamingAll(io, text) catch return false;
    return true;
}

/// Print `<name> (core-utils) <version>` to stdout.
pub fn printVersion(ctx: Context) bool {
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} (core-utils) {s}\n", .{ ctx.name, version }) catch unreachable;
    return writeStdout(ctx.io, line);
}

/// Print a diagnostic `<name>: <message>\n` to stderr. Best effort.
pub fn warn(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: " ++ fmt ++ "\n", .{ctx.name} ++ args) catch return;
    Io.File.stderr().writeStreamingAll(ctx.io, msg) catch {};
}

/// Print an informational line `<name>: <message>\n` to stdout (used by the
/// -v/--verbose options of mkdir, rmdir, ...). Best effort.
pub fn say(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}: " ++ fmt ++ "\n", .{ctx.name} ++ args) catch return;
    _ = writeStdout(ctx.io, msg);
}

/// A file name as GNU `quotef` prints it in diagnostics (shell-escape quoting
/// with ':' treated as special): plain when safe, otherwise in single quotes
/// (double quotes when the name contains only a ' as the problem), and
/// $'...' runs for control and non-ASCII bytes. Derived by probing GNU
/// coreutils 9.7 (`md5sum NAME` on every ASCII character).
/// Use with `{f}`: `cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), msg })`.
pub const Quoted = struct {
    name: []const u8,

    pub fn format(q: Quoted, w: *Io.Writer) Io.Writer.Error!void {
        const name = q.name;
        if (name.len == 0) return w.writeAll("''");
        var has_ctl = false;
        var needs = false;
        var has_squote = false;
        var has_other = false; // specials other than the single quote
        for (name, 0..) |c, i| {
            if (c < 0x20 or c >= 0x7f) {
                has_ctl = true;
                continue;
            }
            switch (c) {
                '\'' => has_squote = true,
                ' ', '!', '"', '$', '&', '(', ')', '*', ';', '<', '=', '>', '?', '[', '\\', '^', '`', '|', ':' => has_other = true,
                '#', '~' => if (i == 0) {
                    has_other = true;
                },
                '{', '}' => if (name.len == 1) {
                    has_other = true;
                },
                else => {},
            }
        }
        needs = has_ctl or has_squote or has_other;
        if (!needs) return w.writeAll(name);
        if (!has_ctl and has_squote and !has_other and std.mem.indexOfAny(u8, name, "\"$`\\") == null) {
            try w.writeByte('"');
            try w.writeAll(name);
            return w.writeByte('"');
        }
        // Printable runs in '...' (a ' becomes '\''), other runs in $'...'.
        var i: usize = 0;
        var first = true;
        while (i < name.len) {
            const ctl = name[i] < 0x20 or name[i] >= 0x7f;
            var j = i;
            while (j < name.len and ((name[j] < 0x20 or name[j] >= 0x7f) == ctl)) j += 1;
            if (ctl) {
                if (first) try w.writeAll("''");
                try w.writeAll("$'");
                for (name[i..j]) |c| switch (c) {
                    7 => try w.writeAll("\\a"),
                    8 => try w.writeAll("\\b"),
                    9 => try w.writeAll("\\t"),
                    10 => try w.writeAll("\\n"),
                    11 => try w.writeAll("\\v"),
                    12 => try w.writeAll("\\f"),
                    13 => try w.writeAll("\\r"),
                    else => try w.print("\\{o:0>3}", .{c}),
                };
                try w.writeByte('\'');
            } else {
                try w.writeByte('\'');
                for (name[i..j]) |c| {
                    if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
                }
                try w.writeByte('\'');
            }
            first = false;
            i = j;
        }
    }
};

pub fn quote(name: []const u8) Quoted {
    return .{ .name = name };
}

/// Human-readable text for common file errors, matching strerror() wording
/// that GNU tools print. Falls back to the Zig error name.
pub fn errText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.BrokenPipe => "Broken pipe",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.PathAlreadyExists => "File exists",
        error.DirNotEmpty => "Directory not empty",
        error.ReadOnlyFileSystem => "Read-only file system",
        error.NoSpaceLeft => "No space left on device",
        error.DiskQuota => "Disk quota exceeded",
        error.FileBusy => "Device or resource busy",
        error.LinkQuotaExceeded => "Too many links",
        error.SystemResources => "Cannot allocate memory",
        else => @errorName(err),
    };
}

/// Buffered stdout. Not thread-safe. Failures are sticky: after the first
/// failed write `failed` is set and further writes are dropped, so callers
/// can check once at the end instead of after every call.
pub const Out = struct {
    io: Io,
    buf: [8192]u8 = undefined,
    len: usize = 0,
    failed: bool = false,
    /// Destination; standard output when null.
    file: ?Io.File = null,

    pub fn init(io: Io) Out {
        return .{ .io = io };
    }

    /// An Out that writes to `file` instead of standard output.
    pub fn initFile(io: Io, file: Io.File) Out {
        return .{ .io = io, .file = file };
    }

    fn sink(o: *Out, bytes: []const u8) bool {
        if (o.file) |f| {
            f.writeStreamingAll(o.io, bytes) catch return false;
            return true;
        }
        return writeStdout(o.io, bytes);
    }

    pub fn write(o: *Out, bytes: []const u8) void {
        if (o.failed) return;
        if (bytes.len > o.buf.len - o.len) {
            o.flush();
            if (o.failed) return;
            if (bytes.len >= o.buf.len) {
                if (!o.sink(bytes)) o.failed = true;
                return;
            }
        }
        @memcpy(o.buf[o.len..][0..bytes.len], bytes);
        o.len += bytes.len;
    }

    pub fn writeByte(o: *Out, byte: u8) void {
        if (o.len < o.buf.len and !o.failed) {
            o.buf[o.len] = byte;
            o.len += 1;
            return;
        }
        o.write(&.{byte});
    }

    pub fn print(o: *Out, comptime fmt: []const u8, args: anytype) void {
        var tmp: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch {
            o.failed = true;
            return;
        };
        o.write(s);
    }

    pub fn flush(o: *Out) void {
        if (o.failed or o.len == 0) return;
        if (!o.sink(o.buf[0..o.len])) o.failed = true;
        o.len = 0;
    }
};

/// Open `path` for reading; "-" means stdin. Directories are rejected with
/// error.IsDir at open time.
pub fn openInput(io: Io, path: []const u8) !Io.File {
    if (std.mem.eql(u8, path, "-")) return Io.File.stdin();
    return Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
}

pub fn closeInput(io: Io, file: Io.File) void {
    if (file.handle != Io.File.stdin().handle) file.close(io);
}

/// POSIX 1.4 (utility description defaults): a utility that stops reading a
/// seekable input before end of file must leave the file offset just past the
/// last byte it processed. Call with the number of bytes read but not
/// consumed; a no-op (and no error) for pipes and terminals.
pub fn giveBack(io: Io, file: Io.File, unread: u64) void {
    if (unread == 0) return;
    const st = file.stat(io) catch return;
    if (st.kind != .file) return;
    io.vtable.fileSeekBy(io.userdata, file, -@as(i64, @intCast(@min(unread, std.math.maxInt(i63))))) catch {};
}

/// Read up to `buf.len` bytes; returns 0 at end of input.
pub fn readChunk(io: Io, file: Io.File, buf: []u8) !usize {
    return file.readStreaming(io, &.{buf}) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => e,
    };
}

fn testCtx(map: *const std.process.Environ.Map) Context {
    return .{ .name = "t", .args = &.{}, .io = undefined, .gpa = std.testing.allocator, .environ = map };
}

test "colorEnabled: NO_COLOR, TERM, tty and explicit options" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = testCtx(&env);

    try std.testing.expect(colorEnabled(ctx, .auto, true));
    try std.testing.expect(!colorEnabled(ctx, .auto, false));
    try std.testing.expect(colorEnabled(ctx, .always, false));
    try std.testing.expect(!colorEnabled(ctx, .never, true));

    try env.put("NO_COLOR", "1");
    ctx = testCtx(&env);
    try std.testing.expect(!colorEnabled(ctx, .auto, true));
    try std.testing.expect(colorEnabled(ctx, .always, true)); // explicit option wins

    try env.put("NO_COLOR", "0"); // any non-empty value counts
    try std.testing.expect(!colorEnabled(testCtx(&env), .auto, true));

    try env.put("NO_COLOR", ""); // empty is ignored
    try std.testing.expect(colorEnabled(testCtx(&env), .auto, true));

    // NO_COLOR removes color but not other styles.
    try env.put("NO_COLOR", "1");
    try std.testing.expect(!colorEnabled(testCtx(&env), .auto, true));
    try std.testing.expect(styleEnabled(testCtx(&env), .auto, true));
    try std.testing.expect(!styleEnabled(testCtx(&env), .never, true));
    try std.testing.expect(!styleEnabled(testCtx(&env), .auto, false));
    try env.put("NO_COLOR", "");

    try env.put("TERM", "dumb");
    try std.testing.expect(!colorEnabled(testCtx(&env), .auto, true));
    try std.testing.expect(!styleEnabled(testCtx(&env), .auto, true));
    try std.testing.expect(!colorEnabled(.{ .name = "t", .args = &.{}, .io = undefined, .gpa = std.testing.allocator }, .auto, false));
}

test "quote follows GNU quotef" {
    const t = std.testing;
    const cases = [_][2][]const u8{
        .{ "plain.txt", "plain.txt" },       .{ "a b", "'a b'" },       .{ "a'b", "\"a'b\"" },
        .{ "", "''" },                       .{ "#x", "'#x'" },         .{ "a#x", "a#x" },
        .{ "{", "'{'" },                     .{ "{}", "{}" },           .{ "a:b", "'a:b'" },
        .{ "a\tb", "'a'$'\\t''b'" },        .{ "\xc3\xa9", "''$'\\303\\251'" },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try quote(c[0]).format(&w);
        try t.expectEqualStrings(c[1], w.buffered());
    }
}
