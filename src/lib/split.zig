// SPDX-License-Identifier: GPL-2.0-or-later
//! split library — split a file into pieces (decision 0004). Argument
//! parsing, option validation and the GNU diagnostics are in
//! src/commands/split.zig.
//! Reference: GNU coreutils manual "split invocation" (9.7). POSIX.1-2024 split
//! specifies only -a, -b, -l and the alphabetic suffixes.
//!
//! Output names are PREFIX + suffix + --additional-suffix. Without -a the
//! suffix grows when the sequence runs out, in an order-preserving way
//! (x89 -> x9000, xyz -> xzaaa), exactly as GNU does; with -a (or a numeric
//! start value) running out is an error.
//!
//! The library creates the output files (and runs the --filter command) in
//! the current directory; standard output is only used for `-n K/N`, through
//! the writer the caller passes.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const wsink = @import("wsink.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Mode = enum { lines, bytes, line_bytes, chunk_bytes, chunk_lines, chunk_rr };

pub const SuffixKind = enum { alpha, numeric, hex };

pub const Options = struct {
    mode: Mode = .lines,
    /// -l, -b or -C size.
    size: u64 = 1000,
    /// N of -n (chunk modes).
    chunks: u64 = 0,
    /// K of -n K/N: write only that chunk to standard output.
    chunk_k: u64 = 0,
    /// Record separator (-t).
    separator: u8 = '\n',
    prefix: []const u8 = "x",
    additional_suffix: []const u8 = "",
    suffix_kind: SuffixKind = .alpha,
    /// -a; null: automatic length.
    suffix_length: ?usize = null,
    /// Value of --numeric-suffixes=FROM / --hex-suffixes=FROM.
    suffix_start: ?[]const u8 = null,
    elide_empty: bool = false,
    filter: ?[]const u8 = null,
    unbuffered: bool = false,
    verbose: bool = false,
};

/// Problems and progress, in the order they occur. `run` also returns
/// `Result.failed` when one of the failure events happened.
pub const Event = union(enum) {
    /// --verbose: a file is about to be created (the host prints the message).
    creating_file: []const u8,
    suffixes_exhausted,
    /// -a too small for the number of chunks.
    suffix_length_too_small: usize,
    suffix_start_too_large,
    suffix_start_invalid: []const u8,
    open_input: struct { name: []const u8, err: anyerror },
    spawn_failed: struct { shell: []const u8, command: []const u8, err: anyerror },
    create_failed: struct { name: []const u8, err: anyerror },
    /// -n r/N: an output that had been closed to free its descriptor could
    /// not be opened again.
    reopen_failed: struct { name: []const u8, errno: std.os.linux.E },
    would_overwrite: []const u8,
    filter_exit: struct { file: []const u8, code: u8, command: []const u8 },
    filter_signal: struct { file: []const u8, signal: u32, command: []const u8 },
    write_error: struct { name: []const u8, err: anyerror },
    /// close() failed: some file systems only report a failed write there.
    close_error: struct { name: []const u8, errno: std.os.linux.E },
    read_error: anyerror,
    /// -C: no room for the record that is being held back.
    out_of_memory,
    /// -n needs the size first, and reading or spooling the input to find it
    /// failed.
    cannot_determine_size: struct { name: []const u8, err: anyerror },
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// Something failed (already reported through the observer, except
    /// out-of-memory conditions).
    failed: bool = false,
    /// Exit status of a failed --filter command, else 0.
    filter_status: u8 = 0,
    /// Writing to the caller's standard-output writer failed.
    stdout_failed: bool = false,
};

/// Split `input` into files according to `opts`. `stdout` receives chunk K of
/// `-n K/N`. Option validation (the usage errors) is the caller's job; the
/// suffix configuration is checked here because it depends on the chunk count.
///
/// With a filter, SIGPIPE is ignored for the duration of the call when it had
/// its default action (a filter may exit before it has read everything), and
/// each filter is started with the default restored. That setting belongs to
/// the whole process.
pub fn run(env: Env, opts: Options, input: Input, stdout: *Io.Writer, obs: Observer) Result {
    const gpa = env.gpa;
    var result: Result = .{ .failed = true };

    // Suffix configuration.
    const alphabet: []const u8 = switch (opts.suffix_kind) {
        .hex => "0123456789abcdef",
        .numeric => "0123456789",
        .alpha => "abcdefghijklmnopqrstuvwxyz",
    };
    const chunks = opts.chunks;
    var auto = opts.suffix_length == null and opts.suffix_start == null;
    var slen: usize = opts.suffix_length orelse 2;
    if (chunks > 0 and opts.suffix_length == null) {
        // Enough digits for N files (GNU: the suffix auto-length is computed from N).
        var need: usize = 1;
        var cap: u64 = alphabet.len;
        while (cap < chunks) : (need += 1) cap *|= alphabet.len;
        if (need > slen) slen = need;
        auto = false;
    }
    if (chunks > 0) {
        var cap: u64 = 1;
        for (0..slen) |_| cap *|= alphabet.len;
        if (cap < chunks and opts.suffix_length != null) {
            var need: usize = 1;
            var c2: u64 = alphabet.len;
            while (c2 < chunks) : (need += 1) c2 *|= alphabet.len;
            obs.emit(.{ .suffix_length_too_small = need });
            return result;
        }
    }
    var sfx: Suffix = .{ .gpa = gpa, .alphabet = alphabet, .auto = auto };
    defer sfx.free.deinit(gpa);
    sfx.free.resize(gpa, slen) catch return result;
    for (sfx.free.items) |*f| f.* = 0;
    if (opts.suffix_start) |ns| {
        // Start value: digits in the suffix alphabet, right aligned.
        if (ns.len > slen) {
            obs.emit(.suffix_start_too_large);
            return result;
        }
        for (ns, 0..) |ch, i| {
            const idx = std.mem.indexOfScalar(u8, alphabet, std.ascii.toLower(ch)) orelse {
                obs.emit(.{ .suffix_start_invalid = ns });
                return result;
            };
            sfx.free.items[slen - ns.len + i] = idx;
        }
    }

    var st: State = .{
        .env = env,
        .obs = obs,
        .stdout = stdout,
        .prefix = opts.prefix,
        .additional = opts.additional_suffix,
        .suffix = sfx,
        .verbose = opts.verbose,
        .filter = opts.filter,
        .unbuffered = opts.unbuffered,
        .elide = opts.elide_empty,
        .input_stat = null,
        .input_name = input.name orelse "-",
    };
    defer st.cur_name.deinit(gpa);

    // Input.
    const in_name = input.name orelse "-";
    const opened = input.open(env.io) catch |e| {
        obs.emit(.{ .open_input = .{ .name = in_name, .err = e } });
        return result;
    };
    defer opened.close(env.io);
    const file = opened.file;
    // Of the open file, so that redirected standard input is protected too.
    var ferr: std.os.linux.E = .SUCCESS;
    st.input_stat = sys.fstatFd(file.handle, &ferr);

    st.ignore_sigpipe = opts.filter != null and sys.signalState(sys.signo.PIPE).disp == .default;
    if (st.ignore_sigpipe) sys.ignoreSignal(.pipe);
    defer if (st.ignore_sigpipe) sys.defaultSignal(.pipe);

    const ok = runMode(&st, file, opts.mode, opts.size, chunks, opts.chunk_k, opts.separator);
    const closed = st.closeCurrent();
    result.stdout_failed = st.stdout_failed;
    result.filter_status = st.filter_status;
    result.failed = !(ok and closed);
    return result;
}

fn stdoutOkImpl(st: *State) bool {
    const o = &st.out.?;
    o.flush();
    if (o.failed) st.stdout_failed = true;
    return !o.failed;
}

const Suffix = struct {
    gpa: std.mem.Allocator,
    alphabet: []const u8,
    auto: bool,
    /// Leading symbols that are the last symbol of the alphabet ("9" in x9000).
    prefix: usize = 0,
    /// The changing part, as indexes into the alphabet.
    free: std.ArrayList(usize) = .empty,
    started: bool = false,
    exhausted: bool = false,

    fn current(s: *const Suffix, out: *std.ArrayList(u8)) !void {
        for (0..s.prefix) |_| try out.append(s.gpa, s.alphabet[s.alphabet.len - 1]);
        for (s.free.items) |i| try out.append(s.gpa, s.alphabet[i]);
    }

    /// Advance to the next suffix; false when the sequence is exhausted.
    fn advance(s: *Suffix) !bool {
        if (!s.started) {
            s.started = true;
            return true;
        }
        const n = s.free.items.len;
        var i = n;
        while (i > 0) {
            i -= 1;
            // In auto mode the leading free symbol may not become the last symbol:
            // that is the point where the suffix grows instead.
            const limit: usize = if (s.auto and i == 0) s.alphabet.len - 2 else s.alphabet.len - 1;
            if (s.free.items[i] < limit) {
                s.free.items[i] += 1;
                return true;
            }
            s.free.items[i] = 0;
        }
        if (!s.auto) return false;
        // Grow: one more symbol joins the fixed prefix, one more free digit.
        s.prefix += 1;
        for (s.free.items) |*f| f.* = 0;
        try s.free.append(s.gpa, 0);
        return true;
    }
};

const State = struct {
    env: Env,
    obs: Observer,
    stdout: *Io.Writer,
    stdout_failed: bool = false,
    prefix: []const u8,
    additional: []const u8,
    suffix: Suffix,
    verbose: bool,
    filter: ?[]const u8,
    unbuffered: bool,
    elide: bool,
    input_stat: ?sys.FileStat,
    input_name: []const u8,
    out: ?wsink.Sink = null,
    child: ?std.process.Child = null,
    cur_name: std.ArrayList(u8) = .empty,
    failed: bool = false,
    /// Exit status to use when a --filter command failed.
    filter_status: u8 = 0,
    /// SIGPIPE is ignored here but not for the filters.
    ignore_sigpipe: bool = false,
    /// -n r/N: how many filters stopped reading before the end.
    filters_gone: u64 = 0,
    /// -n r/N: the outputs. With more of them than there are descriptors,
    /// files are closed and later reopened to append.
    rr: []?RrOutput = &.{},
    /// The slot of `rr` that is being opened.
    rr_opening: usize = 0,

    const Release = enum { released, nothing, failed };

    /// Close one -n r/N output file to free its descriptor. As GNU does,
    /// take the nearest one before the slot being opened: in a round robin
    /// that is the one whose turn comes last. A filter cannot be reopened.
    fn releaseOutput(st: *State) Release {
        var i = st.rr_opening;
        var others = st.rr.len -| 1;
        while (others > 0) : (others -= 1) {
            i = (if (i == 0) st.rr.len else i) - 1;
            const o = if (st.rr[i]) |*o| o else continue;
            if (o.closed or o.output.child != null) continue;
            o.closed = true;
            return if (st.closeOutput(&o.output.sink, o.name, false)) .released else .failed;
        }
        return .nothing;
    }

    /// Open the released output in slot `i` again; false when that fails
    /// (reported).
    fn reopenOutput(st: *State, i: usize) bool {
        const o = &st.rr[i].?;
        st.rr_opening = i;
        var err: std.os.linux.E = .SUCCESS;
        // O_NONBLOCK: do not wait for ever if this is a FIFO whose reader
        // left when it was closed.
        const flags = sys.O.WRONLY | sys.O.APPEND | sys.O.NONBLOCK | sys.O.NOCTTY;
        const fd = while (true) {
            if (sys.openFd(o.name, flags, 0, &err)) |fd| break fd;
            if (err == .MFILE or err == .NFILE) switch (st.releaseOutput()) {
                .released => continue,
                .failed => return false,
                .nothing => {},
            };
            st.obs.emit(.{ .reopen_failed = .{ .name = o.name, .errno = err } });
            return false;
        };
        if (sys.getStatusFlags(fd, &err)) |old| _ = sys.setStatusFlags(fd, old & ~@as(usize, sys.O.NONBLOCK));
        // For the systems where O_APPEND is not passed on.
        _ = sys.seekFd(fd, 0, 2, &err);
        o.output.sink = wsink.Sink.initFile(st.env.io, .{ .handle = fd, .flags = .{ .nonblocking = false } });
        o.closed = false;
        return true;
    }

    fn nextName(st: *State) bool {
        st.cur_name.clearRetainingCapacity();
        const ok = st.suffix.advance() catch return false;
        if (!ok) {
            st.obs.emit(.suffixes_exhausted);
            return false;
        }
        st.cur_name.appendSlice(st.env.gpa, st.prefix) catch return false;
        st.suffix.current(&st.cur_name) catch return false;
        st.cur_name.appendSlice(st.env.gpa, st.additional) catch return false;
        return true;
    }

    /// Close the current output (if any) and open the next one.
    fn openNext(st: *State) bool {
        if (!st.closeCurrent()) return false;
        if (!st.nextName()) return false;
        const name = st.cur_name.items;
        if (st.verbose) {
            st.obs.emit(.{ .creating_file = name });
        }
        const output = st.startOutput(name) orelse return false;
        st.out = output.sink;
        st.child = output.child;
        return true;
    }

    /// Start the output called `name`: the --filter command with FILE set to
    /// it, or the file itself. Null (already reported) when that fails.
    fn startOutput(st: *State, name: []const u8) ?Output {
        if (st.filter) |cmd| {
            var env = std.process.Environ.Map.init(st.env.gpa);
            defer env.deinit();
            if (st.env.environ) |src| {
                var it = src.iterator();
                while (it.next()) |e| env.put(e.key_ptr.*, e.value_ptr.*) catch return null;
            }
            env.put("FILE", name) catch return null;
            const shell = st.env.getenv("SHELL");
            const sh: []const u8 = if (shell != null and shell.?.len > 0) shell.? else "/bin/sh";
            if (st.ignore_sigpipe) sys.defaultSignal(.pipe);
            const spawned = std.process.spawn(st.env.io, .{
                .argv = &.{ sh, "-c", cmd },
                .environ_map = &env,
                .stdin = .pipe,
            });
            if (st.ignore_sigpipe) sys.ignoreSignal(.pipe);
            var child = spawned catch |e| {
                st.obs.emit(.{ .spawn_failed = .{ .shell = sh, .command = cmd, .err = e } });
                return null;
            };
            // The sink now owns the pipe; finishOutput closes it.
            const pipe = child.stdin.?;
            child.stdin = null;
            return .{ .sink = wsink.Sink.initFile(st.env.io, pipe), .child = child };
        }
        const f = st.createOutput(name) orelse return null;
        return .{ .sink = wsink.Sink.initFile(st.env.io, f) };
    }

    /// Create or empty the output file `name`; null (already reported) when
    /// that fails. It is opened without truncation so that the input is still
    /// intact when `name` turns out to be it.
    fn createOutput(st: *State, name: []const u8) ?Io.File {
        const io = st.env.io;
        const f = while (true) {
            if (Io.Dir.cwd().createFile(io, name, .{ .truncate = false })) |f| break f else |e| {
                if (e == error.ProcessFdQuotaExceeded or e == error.SystemFdQuotaExceeded) switch (st.releaseOutput()) {
                    .released => continue,
                    .failed => return null,
                    .nothing => {},
                };
                st.obs.emit(.{ .create_failed = .{ .name = name, .err = e } });
                return null;
            }
        };
        var err: std.os.linux.E = .SUCCESS;
        const out = sys.fstatFd(f.handle, &err) orelse {
            f.close(io);
            st.obs.emit(.{ .create_failed = .{ .name = name, .err = error.Unexpected } });
            return null;
        };
        if (st.input_stat) |in| {
            if (out.ino == in.ino and out.dev_major == in.dev_major and out.dev_minor == in.dev_minor) {
                f.close(io);
                st.obs.emit(.{ .would_overwrite = name });
                return null;
            }
        }
        // Devices and pipes have no length to cut.
        if (out.isReg()) f.setLength(io, 0) catch |e| {
            f.close(io);
            st.obs.emit(.{ .create_failed = .{ .name = name, .err = e } });
            return null;
        };
        return f;
    }

    fn writeError(st: *State, sink: *const wsink.Sink, name: []const u8) void {
        const err: anyerror = if (sink.file_error) |e| e else error.WriteFailed;
        st.obs.emit(.{ .write_error = .{ .name = name, .err = err } });
    }

    /// Flush and close one output file. False when some of its data may be
    /// lost, which is reported unless `quiet` (after an earlier failure).
    fn closeOutput(st: *State, sink: *wsink.Sink, name: []const u8, quiet: bool) bool {
        sink.flush();
        const close_failure = sys.closeFd(sink.file.?.handle);
        if (sink.failed) {
            if (!quiet) st.writeError(sink, name);
            return false;
        }
        if (close_failure) |errno| {
            if (!quiet) st.obs.emit(.{ .close_error = .{ .name = name, .errno = errno } });
            return false;
        }
        return true;
    }

    /// Flush and close an output that startOutput made, waiting for its
    /// filter. False when it failed, which is reported unless `quiet`.
    fn finishOutput(st: *State, sink: *wsink.Sink, child: *?std.process.Child, name: []const u8, quiet: bool) bool {
        if (child.* == null) return st.closeOutput(sink, name, quiet);
        // A filter's pipe.
        sink.flush();
        sink.file.?.close(st.env.io);
        const term = child.*.?.wait(st.env.io) catch null;
        child.* = null;
        if (term) |t| switch (t) {
            .exited => |code| if (code != 0) {
                if (!quiet) {
                    st.obs.emit(.{ .filter_exit = .{ .file = name, .code = code, .command = st.filter.? } });
                    st.filter_status = code;
                }
                return false;
            },
            .signal => |sig| if (@backingInt(sig) != 13) {
                if (!quiet) {
                    st.obs.emit(.{ .filter_signal = .{ .file = name, .signal = @backingInt(sig), .command = st.filter.? } });
                    st.filter_status = 1;
                }
                return false;
            },
            else => {},
        };
        if (sink.failed and !pipeClosed(sink)) {
            if (!quiet) st.writeError(sink, name);
            return false;
        }
        return true;
    }

    /// Whether a write to a filter failed only because it no longer reads. As
    /// in GNU that is not an error: the rest of its chunk is dropped.
    fn pipeClosed(sink: *const wsink.Sink) bool {
        return if (sink.file_error) |e| e == error.BrokenPipe else false;
    }

    fn closeCurrent(st: *State) bool {
        // Taken out first: whatever fails below, it is not closed again.
        var o = st.out orelse return true;
        st.out = null;
        if (o.file != null) return st.finishOutput(&o, &st.child, st.cur_name.items, false);
        // The caller's writer for -n K/N.
        o.flush();
        return !o.failed or st.sinkFailed(&o);
    }

    /// Report the failure of the current output; always false.
    fn sinkFailed(st: *State, sink: *const wsink.Sink) bool {
        // Without a file it is the caller's writer (-n K/N), and its owner
        // knows the reason.
        if (sink.file == null) st.stdout_failed = true else st.writeError(sink, st.cur_name.items);
        return false;
    }

    fn write(st: *State, bytes: []const u8) bool {
        if (st.out) |*o| {
            o.write(bytes);
            if (st.unbuffered) o.flush();
            if (o.failed) {
                if (st.child != null and pipeClosed(o)) return true;
                return st.sinkFailed(o);
            }
        }
        return true;
    }
};

/// An output that is open: a file, or the pipe to a --filter command.
const Output = struct {
    sink: wsink.Sink,
    /// The filter reading from the pipe.
    child: ?std.process.Child = null,
};

/// One of the N outputs that -n r/N writes in turn.
const RrOutput = struct {
    output: Output,
    name: []u8,
    /// The file was closed, with everything written, to free its descriptor.
    closed: bool = false,

    /// Start the output with the next name; null when that fails (reported).
    fn create(st: *State, verbose: bool) ?RrOutput {
        if (!st.nextName()) return null;
        const name = st.env.gpa.dupe(u8, st.cur_name.items) catch return null;
        if (verbose and st.verbose) st.obs.emit(.{ .creating_file = name });
        const output = st.startOutput(name) orelse {
            st.env.gpa.free(name);
            return null;
        };
        return .{ .output = output, .name = name };
    }

    fn finish(o: *RrOutput, st: *State, quiet: bool) bool {
        const ok = o.closed or st.finishOutput(&o.output.sink, &o.output.child, o.name, quiet);
        st.env.gpa.free(o.name);
        return ok;
    }
};
fn readAll(io: Io, file: Io.File, buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        const r = try common.readChunk(io, file, buf[n..]);
        if (r == 0) break;
        n += r;
    }
    return n;
}

/// The input of the -n modes, which may have been read ahead to find its size.
const ChunkInput = struct {
    file: Io.File,
    /// Bytes already read from `file`, handed out before anything else.
    held: []const u8 = &.{},
    /// There is nothing to read after `held` (a terminal must not be asked
    /// again).
    ended: bool = false,
    /// The temporary file that `file` now is, if it was spooled.
    spool: ?Spool = null,

    fn read(in: *ChunkInput, io: Io, buf: []u8) !usize {
        if (in.held.len > 0) {
            const n = @min(buf.len, in.held.len);
            @memcpy(buf[0..n], in.held[0..n]);
            in.held = in.held[n..];
            return n;
        }
        if (in.ended) return 0;
        return readAll(io, in.file, buf);
    }

    /// The number of bytes left in the input. As GNU does: if it ends within
    /// the first block that is the answer. Otherwise the file system is
    /// believed where it can be (a regular file whose size covers what has
    /// been read; files under /proc say 0), and anything else, such as a
    /// pipe, is copied to a temporary file. `first` must outlive the input.
    fn measure(in: *ChunkInput, env: Env, first: []u8) !u64 {
        const got = try readAll(env.io, in.file, first);
        in.held = first[0..got];
        if (got < first.len) {
            in.ended = true;
            return got;
        }
        var err: std.os.linux.E = .SUCCESS;
        if (sys.fstatFd(in.file.handle, &err)) |info| {
            if (info.isReg()) {
                if (sys.seekFd(in.file.handle, 0, 1, &err)) |pos| {
                    // Standard input may not have been at the start.
                    if (pos >= got and info.size >= pos) return info.size - (@as(u64, @intCast(pos)) - got);
                }
            }
        }
        const spool = try Spool.create(env);
        in.spool = spool;
        try spool.file.writeStreamingAll(env.io, in.held);
        var total: u64 = got;
        while (true) {
            const n = try readAll(env.io, in.file, first);
            if (n == 0) break;
            try spool.file.writeStreamingAll(env.io, first[0..n]);
            total += n;
        }
        var err2: std.os.linux.E = .SUCCESS;
        if (sys.seekFd(spool.file.handle, 0, 0, &err2) == null) return error.Unseekable;
        in.file = spool.file;
        in.held = &.{};
        return total;
    }
};

/// An unnamed temporary file in $TMPDIR.
const Spool = struct {
    file: Io.File,
    /// Set when the name could not be removed while the file was open.
    path: ?[]u8 = null,
    gpa: std.mem.Allocator,

    fn create(env: Env) !Spool {
        const set = env.getenv("TMPDIR") orelse env.getenv("TEMP");
        const dir = if (set != null and set.?.len > 0) set.? else "/tmp";
        var random: u64 = undefined;
        env.io.random(std.mem.asBytes(&random));
        const path = try std.fmt.allocPrint(env.gpa, "{s}/split.{x}", .{ dir, random });
        errdefer env.gpa.free(path);
        const file = try Io.Dir.cwd().createFile(env.io, path, .{ .read = true, .exclusive = true, .permissions = sys.permissionsFromMode(0o600) });
        Io.Dir.cwd().deleteFile(env.io, path) catch return .{ .file = file, .path = path, .gpa = env.gpa };
        env.gpa.free(path);
        return .{ .file = file, .gpa = env.gpa };
    }

    fn close(s: Spool, io: Io) void {
        s.file.close(io);
        if (s.path) |path| {
            Io.Dir.cwd().deleteFile(io, path) catch {};
            s.gpa.free(path);
        }
    }
};

fn runMode(st: *State, file: Io.File, mode: Mode, size: u64, chunks: u64, chunk_k: u64, sep: u8) bool {
    const gpa = st.env.gpa;
    const io = st.env.io;
    const buf = gpa.alloc(u8, 1 << 17) catch return false;
    defer gpa.free(buf);

    switch (mode) {
        .bytes => {
            var left: u64 = 0; // bytes still allowed in the current file
            while (true) {
                const n = readAll(io, file, buf) catch |e| return readFail(st, e);
                if (n == 0) break;
                var off: usize = 0;
                while (off < n) {
                    if (left == 0) {
                        if (!st.openNext()) return false;
                        left = size;
                    }
                    const take: usize = @intCast(@min(left, n - off));
                    if (!st.write(buf[off .. off + take])) return false;
                    off += take;
                    left -= take;
                }
            }
            return true;
        },
        .lines => {
            var lines_left: u64 = 0;
            while (true) {
                const n = readAll(io, file, buf) catch |e| return readFail(st, e);
                if (n == 0) break;
                var start: usize = 0;
                while (start < n) {
                    if (lines_left == 0) {
                        if (!st.openNext()) return false;
                        lines_left = size;
                    }
                    // Write up to the end of the file's quota of lines.
                    var end = start;
                    while (end < n and lines_left > 0) {
                        const nl = std.mem.indexOfScalar(u8, buf[end..n], sep) orelse {
                            end = n;
                            break;
                        };
                        end += nl + 1;
                        lines_left -= 1;
                    }
                    if (!st.write(buf[start..end])) return false;
                    start = end;
                }
            }
            return true;
        },
        .line_bytes => {
            var out: LineBytes = .{ .size = size };
            defer out.held.deinit(gpa);
            while (true) {
                const n = readAll(io, file, buf) catch |e| return readFail(st, e);
                if (n == 0) break;
                var pos: usize = 0;
                while (pos < n) {
                    const nl = std.mem.indexOfScalar(u8, buf[pos..n], sep);
                    const end = if (nl) |i| pos + i + 1 else n;
                    if (!out.take(st, buf[pos..end], nl != null)) return false;
                    pos = end;
                }
            }
            return out.finish(st);
        },
        .chunk_bytes, .chunk_lines, .chunk_rr => return runChunks(st, file, mode, chunks, chunk_k, sep, buf),
    }
}

fn readFail(st: *State, e: anyerror) bool {
    st.obs.emit(.{ .read_error = e });
    return false;
}

/// -C: whole records, a new file when the next one does not fit, and a record
/// longer than SIZE cut into SIZE-byte pieces. A record is held back only
/// while it may still fit in the current file, so never more than SIZE bytes.
const LineBytes = struct {
    size: u64,
    /// Bytes in the current file.
    used: u64 = 0,
    have_file: bool = false,
    /// The start of a record that may still fit in the current file.
    held: std.ArrayList(u8) = .empty,
    /// The record being read no longer waits: its bytes are written at once.
    passing: bool = false,

    /// The next bytes of a record; `ends` when they finish it.
    fn take(l: *LineBytes, st: *State, bytes: []const u8, ends: bool) bool {
        if (!l.passing) {
            const room = if (l.have_file) l.size - l.used else l.size;
            if (l.held.items.len + bytes.len <= room) {
                l.held.appendSlice(st.env.gpa, bytes) catch {
                    st.obs.emit(.out_of_memory);
                    return false;
                };
                return !ends or l.finish(st);
            }
            // It does not fit here: it starts a file of its own.
            if (!l.have_file or l.used > 0) {
                if (!l.nextFile(st)) return false;
            }
            l.passing = true;
            if (!l.write(st, l.held.items)) return false;
            l.held.clearRetainingCapacity();
        }
        if (!l.write(st, bytes)) return false;
        if (ends) l.passing = false;
        return true;
    }

    /// Write what is held back, which is known to fit.
    fn finish(l: *LineBytes, st: *State) bool {
        if (l.held.items.len == 0) return true;
        if (!l.have_file and !l.nextFile(st)) return false;
        if (!l.write(st, l.held.items)) return false;
        l.held.clearRetainingCapacity();
        return true;
    }

    fn nextFile(l: *LineBytes, st: *State) bool {
        if (!st.openNext()) return false;
        l.have_file = true;
        l.used = 0;
        return true;
    }

    fn write(l: *LineBytes, st: *State, bytes: []const u8) bool {
        var rest = bytes;
        while (rest.len > 0) {
            if (l.used == l.size and !l.nextFile(st)) return false;
            const n: usize = @intCast(@min(l.size - l.used, rest.len));
            if (!st.write(rest[0..n])) return false;
            l.used += n;
            rest = rest[n..];
        }
        return true;
    }
};

fn runChunks(st: *State, file: Io.File, mode: Mode, n: u64, k: u64, sep: u8, buf: []u8) bool {
    const io = st.env.io;
    const gpa = st.env.gpa;
    // Chunks by size need the input size; round-robin does not.
    var input: ChunkInput = .{ .file = file };
    defer if (input.spool) |spool| spool.close(io);
    var first: []u8 = &.{};
    defer gpa.free(first);
    var total: u64 = 0;
    if (mode != .chunk_rr) {
        first = gpa.alloc(u8, buf.len) catch return false;
        total = input.measure(st.env, first) catch |e| {
            st.obs.emit(.{ .cannot_determine_size = .{ .name = st.input_name, .err = e } });
            return false;
        };
    }
    const per = total / n;
    const rem = total % n;
    // Byte offset at which chunk i (0-based) ends.
    const end_of = struct {
        fn f(i: u64, per_: u64, rem_: u64) u64 {
            return per_ * (i + 1) + @min(i + 1, rem_);
        }
    }.f;

    if (k != 0) {
        // Output chunk K to standard output.
        st.out = wsink.Sink.initWriter(st.stdout);
    }
    const to_stdout = k != 0;
    var chunk: u64 = 0; // current chunk index
    var written_total: u64 = 0; // bytes consumed so far
    var opened_chunk: ?u64 = null;

    const want = struct {
        fn f(kk: u64, c: u64) bool {
            return kk == 0 or c + 1 == kk;
        }
    };
    _ = want;

    switch (mode) {
        .chunk_bytes => {
            // Bytes [start, end) of chunk i; empty chunks still get a file (unless -e).
            var i: u64 = 0;
            var pos: u64 = 0;
            var data_off: u64 = 0;
            _ = &data_off;
            var rd: usize = 0;
            var have: usize = 0;
            while (i < n) : (i += 1) {
                const end = end_of(i, per, rem);
                if (!to_stdout or i + 1 == k) {
                    if (!to_stdout and !(st.elide and end == pos)) {
                        if (!st.openNext()) return false;
                    }
                }
                while (pos < end) {
                    if (rd == have) {
                        have = input.read(io, buf) catch |e| return readFail(st, e);
                        rd = 0;
                        if (have == 0) {
                            pos = end;
                            break;
                        }
                    }
                    const take: usize = @intCast(@min(end - pos, have - rd));
                    if (!to_stdout or i + 1 == k) {
                        if (!st.write(buf[rd .. rd + take])) return false;
                    }
                    rd += take;
                    pos += take;
                }
                if (to_stdout and i + 1 == k) {
                    st.out.?.flush();
                    return stdoutOkImpl(st);
                }
            }
            return true;
        },
        .chunk_lines, .chunk_rr => {
            // Where the record being read goes; null between records. Its
            // bytes are passed on as they arrive, however long it is.
            var dest: ?RecordDest = null;
            var rr_index: u64 = 0;
            // Round robin writes the N outputs in turn; lines mode one at a time.
            var outs: []?RrOutput = &.{};
            defer {
                // Outputs still open here belong to a run that has failed.
                for (outs) |*slot| if (slot.*) |*o| {
                    _ = o.finish(st, true);
                };
                st.rr = &.{};
                gpa.free(outs);
            }
            if (mode == .chunk_rr and !to_stdout) {
                outs = gpa.alloc(?RrOutput, @intCast(n)) catch return false;
                for (outs) |*o| o.* = null;
                st.rr = outs;
            }
            // Lines mode: sequentially numbered files created lazily in order.
            var cur_end = end_of(0, per, rem);
            // When no round-robin filter is reading any more, stop: the input
            // may never end.
            while (st.filters_gone < n) {
                const got = input.read(io, buf) catch |e| return readFail(st, e);
                if (got == 0) break;
                var pos: usize = 0;
                while (pos < got) {
                    const nl = std.mem.indexOfScalar(u8, buf[pos..got], sep);
                    const end = if (nl) |i| pos + i + 1 else got;
                    const bytes = buf[pos..end];
                    pos = end;
                    const d = dest orelse startChunkRecord(st, mode, n, k, to_stdout, &chunk, &opened_chunk, written_total, &cur_end, per, rem, &rr_index, outs) orelse return false;
                    written_total += bytes.len;
                    if (!writeChunkBytes(st, d, bytes)) return false;
                    dest = if (nl == null) d else null;
                }
            }
            // Create the remaining (empty) files for line chunks, in order.
            if (mode == .chunk_lines and !to_stdout and !st.elide) {
                var c = (opened_chunk orelse 0);
                if (opened_chunk != null) c += 1;
                while (c < n) : (c += 1) {
                    if (!st.openNext()) return false;
                }
            }
            if (mode == .chunk_rr and !to_stdout) {
                // In chunk order. A chunk that never got a line still gets
                // its (empty) file or filter run, except with -e, where GNU
                // does not number it either.
                var closed = true;
                for (outs, 0..) |*slot, i| {
                    if (slot.* == null and !st.elide) {
                        st.rr_opening = i;
                        slot.* = RrOutput.create(st, false) orelse return false;
                    }
                    if (slot.*) |*o| {
                        if (!o.finish(st, !closed)) closed = false;
                        slot.* = null;
                    }
                }
                if (!closed) return false;
            }
            if (to_stdout) {
                st.out.?.flush();
                return stdoutOkImpl(st);
            }
            return true;
        },
        else => unreachable,
    }
}

/// Where the bytes of one -n l/ or r/ record go.
const RecordDest = union(enum) {
    /// A chunk that is not the one asked for with K/N.
    nowhere,
    /// The caller's writer (K/N).
    stdout,
    /// The current file (l/N).
    current,
    /// Round-robin output of this number.
    rr: usize,
};

/// Choose where the record that starts here goes, creating the files that are
/// due; null when that fails. `consumed` is the input before this record.
fn startChunkRecord(
    st: *State,
    mode: Mode,
    n: u64,
    k: u64,
    to_stdout: bool,
    chunk: *u64,
    opened_chunk: *?u64,
    consumed: u64,
    cur_end: *u64,
    per: u64,
    rem: u64,
    rr_index: *u64,
    outs: []?RrOutput,
) ?RecordDest {
    if (mode == .chunk_rr) {
        const idx = rr_index.* % n;
        rr_index.* += 1;
        if (to_stdout) return if (idx + 1 == k) .stdout else .nowhere;
        if (outs[@intCast(idx)] == null and st.elide) {
            // With -e only chunks that receive a line get a file.
            st.rr_opening = @intCast(idx);
            outs[@intCast(idx)] = RrOutput.create(st, false) orelse return null;
        } else if (outs[@intCast(idx)] == null) {
            // GNU creates the files for chunks in order 0..N-1 up front when
            // the round robin starts, so names follow chunk numbers.
            for (outs, 0..) |*slot, i| {
                st.rr_opening = i;
                slot.* = RrOutput.create(st, true) orelse return null;
            }
        }
        return .{ .rr = @intCast(idx) };
    }
    // Lines: the record goes to the chunk its first byte lies in.
    // Advance past chunks whose end offset has been reached.
    while (consumed >= cur_end.* and chunk.* + 1 < n) {
        chunk.* += 1;
        cur_end.* = per * (chunk.* + 1) + @min(chunk.* + 1, rem);
    }
    if (to_stdout) return if (chunk.* + 1 == k) .stdout else .nowhere;
    // Create files for chunks that were skipped (empty) and the current one.
    var c = if (opened_chunk.*) |o| o + 1 else 0;
    while (c <= chunk.*) : (c += 1) {
        if (c < chunk.* and st.elide) continue; // empty chunk elided, no suffix used
        if (!st.openNext()) return null;
    }
    opened_chunk.* = chunk.*;
    return .current;
}

fn writeChunkBytes(st: *State, dest: RecordDest, bytes: []const u8) bool {
    switch (dest) {
        .nowhere => return true,
        .stdout => {
            st.out.?.write(bytes);
            if (st.unbuffered) st.out.?.flush();
            // Nothing else ends the run of an endless input.
            return !st.out.?.failed or stdoutOkImpl(st);
        },
        .current => return st.write(bytes),
        .rr => |i| {
            const o = &st.rr[i].?;
            if (o.closed and !st.reopenOutput(i)) return false;
            const sink = &o.output.sink;
            const was_failed = sink.failed;
            sink.write(bytes);
            if (st.unbuffered) sink.flush();
            if (!sink.failed) return true;
            if (o.output.child != null and State.pipeClosed(sink)) {
                if (!was_failed) st.filters_gone += 1;
                return true;
            }
            st.writeError(sink, o.name);
            return false;
        },
    }
}
