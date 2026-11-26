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
    would_overwrite: []const u8,
    filter_exit: struct { file: []const u8, code: u8, command: []const u8 },
    filter_signal: struct { file: []const u8, signal: u32, command: []const u8 },
    write_error: []const u8,
    read_error: anyerror,
    cannot_determine_size,
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
    out: ?wsink.Sink = null,
    child: ?std.process.Child = null,
    cur_name: std.ArrayList(u8) = .empty,
    failed: bool = false,
    files_made: usize = 0,
    /// Exit status to use when a --filter command failed.
    filter_status: u8 = 0,

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
        if (st.filter) |cmd| {
            var env = std.process.Environ.Map.init(st.env.gpa);
            defer env.deinit();
            if (st.env.environ) |src| {
                var it = src.iterator();
                while (it.next()) |e| env.put(e.key_ptr.*, e.value_ptr.*) catch return false;
            }
            env.put("FILE", name) catch return false;
            const shell = st.env.getenv("SHELL");
            const sh: []const u8 = if (shell != null and shell.?.len > 0) shell.? else "/bin/sh";
            var child = std.process.spawn(st.env.io, .{
                .argv = &.{ sh, "-c", cmd },
                .environ_map = &env,
                .stdin = .pipe,
            }) catch |e| {
                st.obs.emit(.{ .spawn_failed = .{ .shell = sh, .command = cmd, .err = e } });
                return false;
            };
            st.out = wsink.Sink.initFile(st.env.io, child.stdin.?);
            st.child = child;
            child.stdin = null;
            st.child.?.stdin = st.out.?.file;
            return true;
        }
        const f = st.createOutput(name) orelse return false;
        st.out = wsink.Sink.initFile(st.env.io, f);
        st.files_made += 1;
        return true;
    }

    /// Create or empty the output file `name`; null (already reported) when
    /// that fails. It is opened without truncation so that the input is still
    /// intact when `name` turns out to be it.
    fn createOutput(st: *State, name: []const u8) ?Io.File {
        const io = st.env.io;
        const f = Io.Dir.cwd().createFile(io, name, .{ .truncate = false }) catch |e| {
            st.obs.emit(.{ .create_failed = .{ .name = name, .err = e } });
            return null;
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

    fn closeCurrent(st: *State) bool {
        if (st.out) |*o| {
            o.flush();
            const bad = o.failed;
            if (st.child) |*c| {
                if (o.file) |f| f.close(st.env.io);
                c.stdin = null;
                const term = c.wait(st.env.io) catch null;
                st.child = null;
                if (term) |t| switch (t) {
                    .exited => |code| if (code != 0) {
                        st.obs.emit(.{ .filter_exit = .{ .file = st.cur_name.items, .code = code, .command = st.filter.? } });
                        st.filter_status = code;
                        return false;
                    },
                    .signal => |sig| if (@intFromEnum(sig) != 13) {
                        st.obs.emit(.{ .filter_signal = .{ .file = st.cur_name.items, .signal = @intFromEnum(sig), .command = st.filter.? } });
                        st.filter_status = 1;
                        return false;
                    },
                    else => {},
                };
            } else if (o.file) |f| f.close(st.env.io);
            st.out = null;
            if (bad) {
                st.obs.emit(.{ .write_error = st.cur_name.items });
                return false;
            }
        }
        return true;
    }

    fn write(st: *State, bytes: []const u8) bool {
        if (st.out) |*o| {
            o.write(bytes);
            if (st.unbuffered) o.flush();
            if (o.failed) {
                // A filter that exits early (SIGPIPE) is not an error.
                if (st.filter != null) return true;
                st.obs.emit(.{ .write_error = st.cur_name.items });
                return false;
            }
        }
        return true;
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
            var cur: u64 = 0; // bytes in the current file
            var have_file = false;
            var rec: std.ArrayList(u8) = .empty;
            defer rec.deinit(gpa);
            while (true) {
                const n = readAll(io, file, buf) catch |e| return readFail(st, e);
                if (n == 0) break;
                var pos: usize = 0;
                while (pos < n) {
                    const nl = std.mem.indexOfScalar(u8, buf[pos..n], sep);
                    const end = if (nl) |i| pos + i + 1 else n;
                    rec.appendSlice(gpa, buf[pos..end]) catch return false;
                    pos = end;
                    if (nl == null) break; // record continues in the next block
                    if (!emitRecord(st, rec.items, size, &cur, &have_file)) return false;
                    rec.clearRetainingCapacity();
                }
            }
            if (rec.items.len > 0 and !emitRecord(st, rec.items, size, &cur, &have_file)) return false;
            return true;
        },
        .chunk_bytes, .chunk_lines, .chunk_rr => return runChunks(st, file, mode, chunks, chunk_k, sep, buf),
    }
}

fn readFail(st: *State, e: anyerror) bool {
    st.obs.emit(.{ .read_error = e });
    return false;
}

/// -C: write whole records, starting a new file when a record does not fit;
/// a record longer than SIZE is cut into SIZE-byte pieces.
fn emitRecord(st: *State, rec: []const u8, size: u64, cur: *u64, have_file: *bool) bool {
    var r = rec;
    if (!have_file.*) {
        if (!st.openNext()) return false;
        have_file.* = true;
        cur.* = 0;
    }
    if (cur.* + r.len <= size) {
        cur.* += r.len;
        return st.write(r);
    }
    if (r.len <= size or cur.* > 0) {
        // Does not fit here: it starts a fresh file (if the current one is non-empty).
        if (cur.* > 0) {
            if (!st.openNext()) return false;
            cur.* = 0;
        }
    }
    while (r.len > 0) {
        const room = size - cur.*;
        const take: usize = @intCast(@min(room, r.len));
        if (!st.write(r[0..take])) return false;
        cur.* += take;
        r = r[take..];
        if (r.len > 0) {
            if (!st.openNext()) return false;
            cur.* = 0;
        }
    }
    return true;
}

fn runChunks(st: *State, file: Io.File, mode: Mode, n: u64, k: u64, sep: u8, buf: []u8) bool {
    const io = st.env.io;
    const gpa = st.env.gpa;
    // Chunks by size need the input size; round-robin does not.
    var total: u64 = 0;
    if (mode != .chunk_rr) {
        const s = file.stat(io) catch {
            st.obs.emit(.cannot_determine_size);
            return false;
        };
        if (s.kind == .file) {
            total = s.size;
        } else if (s.kind != .character_device) {
            st.obs.emit(.cannot_determine_size);
            return false;
        }
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
                        have = readAll(io, file, buf) catch |e| return readFail(st, e);
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
            var rec: std.ArrayList(u8) = .empty;
            defer rec.deinit(gpa);
            var rr_index: u64 = 0;
            var files_open: std.ArrayList(?wsink.Sink) = .empty;
            defer files_open.deinit(gpa);
            _ = &files_open;
            // Round robin needs all N outputs open at once; lines mode only one.
            var outs: []?wsink.Sink = &.{};
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |nm| gpa.free(nm);
                names.deinit(gpa);
                gpa.free(outs);
            }
            if (mode == .chunk_rr and !to_stdout) {
                outs = gpa.alloc(?wsink.Sink, @intCast(n)) catch return false;
                for (outs) |*o| o.* = null;
            }
            // Lines mode: sequentially numbered files created lazily in order.
            var cur_end = end_of(0, per, rem);
            while (true) {
                const got = readAll(io, file, buf) catch |e| return readFail(st, e);
                if (got == 0) break;
                var pos: usize = 0;
                while (pos < got) {
                    const nl = std.mem.indexOfScalar(u8, buf[pos..got], sep);
                    const end = if (nl) |i| pos + i + 1 else got;
                    rec.appendSlice(gpa, buf[pos..end]) catch return false;
                    pos = end;
                    if (nl == null) break;
                    if (!emitChunkRecord(st, mode, rec.items, n, k, to_stdout, &chunk, &opened_chunk, &written_total, &cur_end, per, rem, &rr_index, &outs, &names)) return false;
                    rec.clearRetainingCapacity();
                }
            }
            if (rec.items.len > 0) {
                if (!emitChunkRecord(st, mode, rec.items, n, k, to_stdout, &chunk, &opened_chunk, &written_total, &cur_end, per, rem, &rr_index, &outs, &names)) return false;
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
                // Files for chunks that never got a line (empty) are still created.
                for (outs, 0..) |*o, i| {
                    _ = i;
                    if (o.* == null and !st.elide) {
                        if (!st.nextName()) return false;
                        const f = st.createOutput(st.cur_name.items) orelse return false;
                        f.close(io);
                    } else if (o.* == null) {
                        // elided: the name is skipped as GNU does not number it
                    }
                }
                for (outs) |*o| if (o.*) |*oo| {
                    oo.flush();
                    if (oo.file) |f| f.close(io);
                };
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

fn emitChunkRecord(
    st: *State,
    mode: Mode,
    rec: []const u8,
    n: u64,
    k: u64,
    to_stdout: bool,
    chunk: *u64,
    opened_chunk: *?u64,
    consumed: *u64,
    cur_end: *u64,
    per: u64,
    rem: u64,
    rr_index: *u64,
    outs: *[]?wsink.Sink,
    names: *std.ArrayList([]u8),
) bool {
    _ = names;
    if (mode == .chunk_rr) {
        const idx = rr_index.* % n;
        rr_index.* += 1;
        if (to_stdout) {
            if (idx + 1 == k) {
                st.out.?.write(rec);
                if (st.unbuffered) st.out.?.flush();
            }
            return true;
        }
        if (outs.*[@intCast(idx)] == null and st.elide) {
            // With -e only chunks that receive a line get a file.
            if (!st.nextName()) return false;
            const f = st.createOutput(st.cur_name.items) orelse return false;
            outs.*[@intCast(idx)] = wsink.Sink.initFile(st.env.io, f);
        } else if (outs.*[@intCast(idx)] == null) {
            // GNU creates the files for chunks in order 0..N-1 up front when
            // the round robin starts, so names follow chunk numbers.
            var j: u64 = 0;
            while (j < n) : (j += 1) {
                if (!st.nextName()) return false;
                const nm = st.env.gpa.dupe(u8, st.cur_name.items) catch return false;
                defer st.env.gpa.free(nm);
                if (st.verbose) {
                    st.obs.emit(.{ .creating_file = nm });
                }
                const f = st.createOutput(nm) orelse return false;
                outs.*[@intCast(j)] = wsink.Sink.initFile(st.env.io, f);
            }
        }
        const o = &outs.*[@intCast(idx)].?;
        o.write(rec);
        if (st.unbuffered) o.flush();
        return !o.failed;
    }
    // Lines: the record goes to the chunk its first byte lies in.
    // Advance past chunks whose end offset has been reached.
    while (consumed.* >= cur_end.* and chunk.* + 1 < n) {
        chunk.* += 1;
        cur_end.* = per * (chunk.* + 1) + @min(chunk.* + 1, rem);
    }
    consumed.* += rec.len;
    if (to_stdout) {
        if (chunk.* + 1 == k) {
            st.out.?.write(rec);
        }
        return true;
    }
    // Create files for chunks that were skipped (empty) and the current one.
    var c = if (opened_chunk.*) |o| o + 1 else 0;
    while (c <= chunk.*) : (c += 1) {
        if (c < chunk.* and st.elide) continue; // empty chunk elided, no suffix used
        if (!st.openNext()) return false;
    }
    opened_chunk.* = chunk.*;
    return st.write(rec);
}
