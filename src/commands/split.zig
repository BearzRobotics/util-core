//! split — split a file into pieces.
//! Reference: GNU coreutils manual "split invocation" (9.7). POSIX.1-2024 split
//! specifies only -a, -b, -l and the alphabetic suffixes.
//!
//! Output names are PREFIX + suffix + --additional-suffix. Without -a the
//! suffix grows when the sequence runs out, in an order-preserving way
//! (x89 -> x9000, xyz -> xzaaa), exactly as GNU does; with -a (or a numeric
//! start value) running out is an error.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const count_arg = @import("../count_arg.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const help_text = @embedFile("../help/split.txt");

const Mode = enum { lines, bytes, line_bytes, chunk_bytes, chunk_lines, chunk_rr };

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
    ctx: cli.Context,
    prefix: []const u8,
    additional: []const u8,
    suffix: Suffix,
    verbose: bool,
    filter: ?[]const u8,
    unbuffered: bool,
    elide: bool,
    input_stat: ?sys.FileStat,
    out: ?cli.Out = null,
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
            cli.warn(st.ctx, "output file suffixes exhausted", .{});
            return false;
        }
        st.cur_name.appendSlice(st.ctx.gpa, st.prefix) catch return false;
        st.suffix.current(&st.cur_name) catch return false;
        st.cur_name.appendSlice(st.ctx.gpa, st.additional) catch return false;
        return true;
    }

    /// Close the current output (if any) and open the next one.
    fn openNext(st: *State) bool {
        if (!st.closeCurrent()) return false;
        if (!st.nextName()) return false;
        const name = st.cur_name.items;
        if (st.verbose) {
            var b: [4096]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "creating file {f}\n", .{cli.quoteA(name)}) catch "";
            _ = cli.writeStdout(st.ctx.io, m);
        }
        if (st.filter) |cmd| {
            var env = std.process.Environ.Map.init(st.ctx.gpa);
            defer env.deinit();
            if (st.ctx.environ) |src| {
                var it = src.iterator();
                while (it.next()) |e| env.put(e.key_ptr.*, e.value_ptr.*) catch return false;
            }
            env.put("FILE", name) catch return false;
            const shell = cli.getenv(st.ctx, "SHELL");
            const sh: []const u8 = if (shell != null and shell.?.len > 0) shell.? else "/bin/sh";
            var child = std.process.spawn(st.ctx.io, .{
                .argv = &.{ sh, "-c", cmd },
                .environ_map = &env,
                .stdin = .pipe,
            }) catch |e| {
                cli.warn(st.ctx, "failed to run command: \"{s} -c {s}\": {s}", .{ sh, cmd, cli.errText(e) });
                return false;
            };
            st.out = cli.Out.initFile(st.ctx.io, child.stdin.?);
            st.child = child;
            child.stdin = null;
            st.child.?.stdin = st.out.?.file;
            return true;
        }
        const f = Io.Dir.cwd().createFile(st.ctx.io, name, .{ .truncate = true }) catch |e| {
            cli.warn(st.ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
            return false;
        };
        if (st.input_stat) |ins| {
            var err: std.os.linux.E = .SUCCESS;
            if (sys.fileStat(name, true, &err)) |os| {
                if (os.ino == ins.ino and os.dev_major == ins.dev_major and os.dev_minor == ins.dev_minor and ins.isReg()) {
                    f.close(st.ctx.io);
                    cli.warn(st.ctx, "{f} would overwrite input; aborting", .{cli.quote(name)});
                    return false;
                }
            }
        }
        st.out = cli.Out.initFile(st.ctx.io, f);
        st.files_made += 1;
        return true;
    }

    fn closeCurrent(st: *State) bool {
        if (st.out) |*o| {
            o.flush();
            const bad = o.failed;
            if (st.child) |*c| {
                if (o.file) |f| f.close(st.ctx.io);
                c.stdin = null;
                const term = c.wait(st.ctx.io) catch null;
                st.child = null;
                if (term) |t| switch (t) {
                    .exited => |code| if (code != 0) {
                        cli.warn(st.ctx, "with FILE={s}, exit {d} from command: {s}", .{ st.cur_name.items, code, st.filter.? });
                        st.filter_status = code;
                        return false;
                    },
                    .signal => |sig| if (@intFromEnum(sig) != 13) {
                        cli.warn(st.ctx, "with FILE={s}, signal {d} from command: {s}", .{ st.cur_name.items, @intFromEnum(sig), st.filter.? });
                        st.filter_status = 1;
                        return false;
                    },
                    else => {},
                };
            } else if (o.file) |f| f.close(st.ctx.io);
            st.out = null;
            if (bad) {
                cli.warn(st.ctx, "{f}: write error", .{cli.quote(st.cur_name.items)});
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
                cli.warn(st.ctx, "{f}: write error", .{cli.quote(st.cur_name.items)});
                return false;
            }
        }
        return true;
    }
};

fn parseSize(ctx: cli.Context, text: []const u8, what: []const u8) ?u64 {
    const c = count_arg.parse(text);
    if (c == null or c.?.sign != .none or text.len == 0 or !std.ascii.isDigit(text[0]) or c.?.value == 0) {
        cli.warn(ctx, "invalid number of {s}: {f}", .{ what, cli.quoteC(text) });
        return null;
    }
    return c.?.value;
}

pub fn main(ctx: cli.Context) u8 {
    var mode: ?Mode = null;
    var size: u64 = 1000;
    var chunks: u64 = 0;
    var chunk_k: u64 = 0;
    var suffix_len: ?usize = null;
    var numeric = false;
    var hex = false;
    var numeric_start: ?[]const u8 = null;
    var additional: []const u8 = "";
    var elide = false;
    var filter: ?[]const u8 = null;
    var unbuffered = false;
    var verbose = false;
    var sep: u8 = '\n';
    var sep_set = false;
    var n_text: ?[]const u8 = null;

    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(ctx.gpa);
    var p = getopt.Parser.init(ctx, "0123456789a:b:C:dl:n:t:uxe", &.{
        .{ .name = "bytes", .arg = .required, .id = 'b' },
        .{ .name = "lines", .arg = .required, .id = 'l' },
        .{ .name = "line-bytes", .arg = .required, .id = 'C' },
        .{ .name = "number", .arg = .required, .id = 'n' },
        .{ .name = "elide-empty-files", .id = 'e' },
        .{ .name = "unbuffered", .id = 'u' },
        .{ .name = "suffix-length", .arg = .required, .id = 'a' },
        .{ .name = "additional-suffix", .arg = .required, .id = 1100 },
        .{ .name = "numeric-suffixes", .arg = .optional, .id = 1101 },
        .{ .name = "hex-suffixes", .arg = .optional, .id = 1102 },
        .{ .name = "filter", .arg = .required, .id = 1103 },
        .{ .name = "verbose", .id = 1104 },
        .{ .name = "separator", .arg = .required, .id = 't' },
    });
    defer p.deinit();
    const set_mode = struct {
        fn f(c: cli.Context, cur: *?Mode, m: Mode) bool {
            if (cur.* != null and cur.*.? != m) {
                getopt.usageError(c, "cannot split in more than one way", .{});
                return false;
            }
            cur.* = m;
            return true;
        }
    }.f;
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'a' => {
                const v = std.fmt.parseInt(usize, o.arg.?, 10) catch {
                    cli.warn(ctx, "invalid suffix length: {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                };
                suffix_len = if (v == 0) null else v; // GNU: -a 0 means "automatic"
            },
            'b' => {
                if (!set_mode(ctx, &mode, .bytes)) return 1;
                size = parseSize(ctx, o.arg.?, "bytes") orelse return 1;
            },
            'C' => {
                if (!set_mode(ctx, &mode, .line_bytes)) return 1;
                size = parseSize(ctx, o.arg.?, "lines") orelse return 1;
            },
            'l' => {
                if (!set_mode(ctx, &mode, .lines)) return 1;
                size = parseSize(ctx, o.arg.?, "lines") orelse return 1;
            },
            'n' => {
                if (mode != null) {
                    getopt.usageError(ctx, "cannot split in more than one way", .{});
                    return 1;
                }
                n_text = o.arg;
                mode = .chunk_bytes; // refined below
            },
            'd' => numeric = true,
            'x' => hex = true,
            1101 => {
                numeric = true;
                numeric_start = o.arg;
            },
            1102 => {
                hex = true;
                numeric_start = o.arg;
            },
            'e' => elide = true,
            1100 => additional = o.arg.?,
            1103 => filter = o.arg,
            't' => {
                var s = o.arg.?;
                if (std.mem.eql(u8, s, "\\0")) s = "\x00";
                if (s.len != 1) {
                    cli.warn(ctx, "multi-character separator {f}", .{cli.quoteC(o.arg.?)});
                    return 1;
                }
                if (sep_set and sep != s[0]) {
                    cli.warn(ctx, "multiple separator characters specified", .{});
                    return 1;
                }
                sep = s[0];
                sep_set = true;
            },
            'u' => unbuffered = true,
            1104 => verbose = true,
            '0'...'9' => |d| digits.append(ctx.gpa, @intCast(d)) catch return 1,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (digits.items.len > 0) {
        if (!set_mode(ctx, &mode, .lines)) return 1;
        size = parseSize(ctx, digits.items, "lines") orelse return 1;
    }
    if (mode == null) mode = .lines;
    if (n_text) |t| {
        // N, K/N, l/N, l/K/N, r/N, r/K/N
        var rest: []const u8 = t;
        var kind: Mode = .chunk_bytes;
        if (rest.len >= 2 and (rest[0] == 'l' or rest[0] == 'r') and rest[1] == '/') {
            kind = if (rest[0] == 'l') .chunk_lines else .chunk_rr;
            rest = rest[2..];
        }
        var n_str: []const u8 = rest;
        var k_str: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
            k_str = rest[0..i];
            n_str = rest[i + 1 ..];
        }
        if (k_str) |ks| {
            const kk = std.fmt.parseInt(u64, ks, 10) catch 0;
            if (kk == 0) {
                cli.warn(ctx, "invalid chunk number: {f}", .{cli.quoteC(ks)});
                return 1;
            }
            chunk_k = kk;
        }
        const nn = std.fmt.parseInt(u64, n_str, 10) catch 0;
        if (nn == 0) {
            cli.warn(ctx, "invalid number of chunks: {f}", .{cli.quoteC(n_str)});
            return 1;
        }
        chunks = nn;
        if (chunk_k > nn) {
            cli.warn(ctx, "invalid chunk number: {f}", .{cli.quoteC(k_str.?)});
            return 1;
        }
        mode = kind;
    }

    var infile: []const u8 = "-";
    var prefix: []const u8 = "x";
    const ops = p.operands.items;
    if (ops.len > 0) infile = ops[0];
    if (ops.len > 1) prefix = ops[1];
    if (ops.len > 2) {
        getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(ops[2])});
        return 1;
    }
    if (std.mem.indexOfScalar(u8, additional, '/') != null) {
        getopt.usageError(ctx, "invalid suffix {f}, contains directory separator", .{cli.quoteC(additional)});
        return 1;
    }
    if (filter != null and chunk_k != 0) {
        getopt.usageError(ctx, "--filter does not process a chunk extracted to stdout", .{});
        return 1;
    }

    // Suffix configuration.
    const alphabet: []const u8 = if (hex) "0123456789abcdef" else if (numeric) "0123456789" else "abcdefghijklmnopqrstuvwxyz";
    var auto = suffix_len == null and numeric_start == null;
    var slen: usize = suffix_len orelse 2;
    if (chunks > 0 and suffix_len == null) {
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
        if (cap < chunks and suffix_len != null) {
            var need: usize = 1;
            var c2: u64 = alphabet.len;
            while (c2 < chunks) : (need += 1) c2 *|= alphabet.len;
            cli.warn(ctx, "the suffix length needs to be at least {d}", .{need});
            return 1;
        }
    }
    var sfx: Suffix = .{ .gpa = ctx.gpa, .alphabet = alphabet, .auto = auto };
    defer sfx.free.deinit(ctx.gpa);
    sfx.free.resize(ctx.gpa, slen) catch return 1;
    for (sfx.free.items) |*f| f.* = 0;
    if (numeric_start) |ns| {
        // Start value: digits in the suffix alphabet, right aligned.
        if (ns.len > slen) {
            getopt.usageError(ctx, "numerical suffix start value is too large for the suffix length", .{});
            return 1;
        }
        for (ns, 0..) |ch, i| {
            const idx = std.mem.indexOfScalar(u8, alphabet, std.ascii.toLower(ch)) orelse {
                getopt.usageError(ctx, "{f}: invalid start value for numerical suffix", .{cli.quoteC(ns)});
                return 1;
            };
            sfx.free.items[slen - ns.len + i] = idx;
        }
    }

    var st: State = .{
        .ctx = ctx,
        .prefix = prefix,
        .additional = additional,
        .suffix = sfx,
        .verbose = verbose,
        .filter = filter,
        .unbuffered = unbuffered,
        .elide = elide,
        .input_stat = null,
    };
    defer st.cur_name.deinit(ctx.gpa);

    // Input.
    const stdin_is_dash = std.mem.eql(u8, infile, "-");
    const file = cli.openInput(ctx.io, infile) catch |e| {
        if (e == error.IsDir)
            cli.warn(ctx, "{f}: Is a directory", .{cli.quote(infile)})
        else
            cli.warn(ctx, "cannot open {f} for reading: {s}", .{ cli.quoteA(infile), cli.errText(e) });
        return 1;
    };
    defer cli.closeInput(ctx.io, file);
    var ferr: std.os.linux.E = .SUCCESS;
    if (!stdin_is_dash) st.input_stat = sys.fileStat(infile, true, &ferr);
    if (st.input_stat == null) {
        // stdin: the descriptor may still be a regular file.
        const s = file.stat(ctx.io) catch null;
        if (s != null and s.?.kind == .file) st.input_stat = null;
    }

    const ok = run(&st, file, mode.?, size, chunks, chunk_k, sep);
    const closed = st.closeCurrent();
    if (st.filter_status != 0) return st.filter_status;
    return if (ok and closed) 0 else 1;
}

fn readAll(io: Io, file: Io.File, buf: []u8) !usize {
    var n: usize = 0;
    while (n < buf.len) {
        const r = try cli.readChunk(io, file, buf[n..]);
        if (r == 0) break;
        n += r;
    }
    return n;
}

fn run(st: *State, file: Io.File, mode: Mode, size: u64, chunks: u64, chunk_k: u64, sep: u8) bool {
    const gpa = st.ctx.gpa;
    const io = st.ctx.io;
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
    cli.warn(st.ctx, "read error: {s}", .{cli.errText(e)});
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
    const io = st.ctx.io;
    const gpa = st.ctx.gpa;
    // Chunks by size need the input size; round-robin does not.
    var total: u64 = 0;
    if (mode != .chunk_rr) {
        const s = file.stat(io) catch {
            cli.warn(st.ctx, "{f}: cannot determine file size", .{cli.quote("-")});
            return false;
        };
        if (s.kind == .file) {
            total = s.size;
        } else if (s.kind != .character_device) {
            cli.warn(st.ctx, "{f}: cannot determine file size", .{cli.quote("-")});
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
        st.out = cli.Out.init(io);
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
                    return !st.out.?.failed;
                }
            }
            return true;
        },
        .chunk_lines, .chunk_rr => {
            var rec: std.ArrayList(u8) = .empty;
            defer rec.deinit(gpa);
            var rr_index: u64 = 0;
            var files_open: std.ArrayList(?cli.Out) = .empty;
            defer files_open.deinit(gpa);
            _ = &files_open;
            // Round robin needs all N outputs open at once; lines mode only one.
            var outs: []?cli.Out = &.{};
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |nm| gpa.free(nm);
                names.deinit(gpa);
                gpa.free(outs);
            }
            if (mode == .chunk_rr and !to_stdout) {
                outs = gpa.alloc(?cli.Out, @intCast(n)) catch return false;
                for (outs) |*o| o.* = null;
            }
            const handle = struct {
                fn rrWrite(s: *State, outs_: []?cli.Out, names_: *std.ArrayList([]u8), idx: u64, bytes: []const u8) bool {
                    const g = s.ctx.gpa;
                    if (outs_[@intCast(idx)] == null) {
                        // Files are created in chunk order the first time they get data.
                        if (!s.nextName()) return false;
                        const nm = g.dupe(u8, s.cur_name.items) catch return false;
                        names_.append(g, nm) catch return false;
                        const f = Io.Dir.cwd().createFile(s.ctx.io, nm, .{ .truncate = true }) catch |e| {
                            cli.warn(s.ctx, "{f}: {s}", .{ cli.quote(nm), cli.errText(e) });
                            return false;
                        };
                        outs_[@intCast(idx)] = cli.Out.initFile(s.ctx.io, f);
                    }
                    const o = &outs_[@intCast(idx)].?;
                    o.write(bytes);
                    if (s.unbuffered) o.flush();
                    return !o.failed;
                }
            };
            _ = handle;
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
                        const f = Io.Dir.cwd().createFile(io, st.cur_name.items, .{ .truncate = true }) catch |e| {
                            cli.warn(st.ctx, "{f}: {s}", .{ cli.quote(st.cur_name.items), cli.errText(e) });
                            return false;
                        };
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
                return !st.out.?.failed;
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
    outs: *[]?cli.Out,
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
            const f = Io.Dir.cwd().createFile(st.ctx.io, st.cur_name.items, .{ .truncate = true }) catch |e| {
                cli.warn(st.ctx, "{f}: {s}", .{ cli.quote(st.cur_name.items), cli.errText(e) });
                return false;
            };
            outs.*[@intCast(idx)] = cli.Out.initFile(st.ctx.io, f);
        } else if (outs.*[@intCast(idx)] == null) {
            // GNU creates the files for chunks in order 0..N-1 up front when
            // the round robin starts, so names follow chunk numbers.
            var j: u64 = 0;
            while (j < n) : (j += 1) {
                if (!st.nextName()) return false;
                const nm = st.ctx.gpa.dupe(u8, st.cur_name.items) catch return false;
                defer st.ctx.gpa.free(nm);
                if (st.verbose) {
                    var b: [4096]u8 = undefined;
                    const m = std.fmt.bufPrint(&b, "creating file {f}\n", .{cli.quoteA(nm)}) catch "";
                    _ = cli.writeStdout(st.ctx.io, m);
                }
                const f = Io.Dir.cwd().createFile(st.ctx.io, nm, .{ .truncate = true }) catch |e| {
                    cli.warn(st.ctx, "{f}: {s}", .{ cli.quote(nm), cli.errText(e) });
                    return false;
                };
                outs.*[@intCast(j)] = cli.Out.initFile(st.ctx.io, f);
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
