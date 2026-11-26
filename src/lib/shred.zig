// SPDX-License-Identifier: GPL-2.0-or-later
//! shred library: overwrite a file to hide its contents, and optionally
//! delete it.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "shred invocation"
//! (9.7) and GNU coreutils 9.6 src/shred.c (pass structure, pattern groups,
//! file-name wiping). The pseudo-random generator is not GNU's ISAAC: random
//! passes and the pass order come from the operating system (or, with a
//! caller-supplied random source file, from the bytes of that file), so a
//! random source does not reproduce GNU's exact sequence.
//!
//! The caller parses the command line, opens the --random-source file and
//! words the diagnostics (here: `Event.diag` is the GNU message text without
//! the program-name prefix; names in it are already quoted).

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const quote = @import("../quote.zig");
const sys = @import("../sys.zig");
const human = @import("../human.zig");
const E = std.os.linux.E;

pub const Env = common.Env;

pub const Remove = enum { none, unlink, wipe, wipesync };

pub const Options = struct {
    force: bool = false,
    n_iterations: u64 = 3,
    /// Bytes to shred; -1 means the file size.
    size: i64 = -1,
    remove: Remove = .none,
    verbose: bool = false,
    exact: bool = false,
    zero_fill: bool = false,
    /// Random bytes come from this file (not closed here); null: the
    /// operating system's generator.
    random_source: ?Io.File = null,
};

pub const Event = union(enum) {
    /// A diagnostic or progress line for standard error.
    diag: []const u8,
};
pub const Observer = common.Observer(Event);

pub const Error = error{
    OutOfMemory,
    /// The --random-source file ran out of bytes; GNU exits at once.
    RandomSourceExhausted,
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    observer: Observer,
};

fn warn(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
    const t = std.fmt.allocPrint(ctx.gpa, fmt, args) catch return;
    defer ctx.gpa.free(t);
    ctx.observer.emit(.{ .diag = t });
}

const patterns = [_]i32{
    -2, 2, 0x000, 0xFFF, 2, 0x555, 0xAAA, -1,
    6, 0x249, 0x492, 0x6DB, 0x924, 0xB6D, 0xDB6, 12, 0x111, 0x222, 0x333, 0x444, 0x666, 0x777, 0x888, 0x999, 0xBBB, 0xCCC, 0xDDD, 0xEEE,
    -1, 8, 0x1000, 0x1249, 0x1492, 0x16DB, 0x1924, 0x1B6D, 0x1DB6, 0x1FFF,
    14, 0x1111, 0x1222, 0x1333, 0x1444, 0x1555, 0x1666, 0x1777, 0x1888, 0x1999, 0x1AAA, 0x1BBB, 0x1CCC, 0x1DDD, 0x1EEE,
    -1, 0,
};

const Rng = struct {
    file: ?Io.File = null,
    io: Io,
    prng: std.Random.DefaultPrng,

    fn bytes(r: *Rng, buf: []u8) error{RandomSourceExhausted}!void {
        if (r.file) |f| {
            var got: usize = 0;
            while (got < buf.len) {
                const n = common.readChunk(r.io, f, buf[got..]) catch 0;
                if (n == 0) return error.RandomSourceExhausted;
                got += n;
            }
        } else r.prng.random().bytes(buf);
    }

    fn choose(r: *Rng, n: u64) error{RandomSourceExhausted}!u64 {
        if (n <= 1) return 0;
        // Rejection sampling over 64-bit values.
        const limit = std.math.maxInt(u64) - (std.math.maxInt(u64) % n) - 1;
        while (true) {
            var b: [8]u8 = undefined;
            try r.bytes(&b);
            const v = std.mem.readInt(u64, &b, .little);
            if (v <= limit) return v % n;
        }
    }
};

const Fail = error{RandomSourceExhausted};

fn periodic(t: i32) bool {
    if (t <= 0) return false;
    var bits: u32 = @as(u32, @intCast(t)) & 0xfff;
    bits |= bits << 12;
    const r0: u8 = @truncate(bits >> 4);
    const r1: u8 = @truncate(bits >> 8);
    const r2: u8 = @truncate(bits);
    return r0 != r1 or r0 != r2;
}

fn fillPattern(t: i32, r: []u8, size: usize) void {
    var bits: u32 = @as(u32, @intCast(t)) & 0xfff;
    bits |= bits << 12;
    r[0] = @truncate(bits >> 4);
    r[1] = @truncate(bits >> 8);
    r[2] = @truncate(bits);
    var i: usize = 3;
    while (i <= size / 2) : (i *= 2) @memcpy(r[i .. 2 * i], r[0..i]);
    if (i < size) @memcpy(r[i..size], r[0 .. size - i]);
    if (t & 0x1000 != 0) {
        var k: usize = 0;
        while (k < size) : (k += 512) r[k] ^= 0x80;
    }
}

fn genPattern(dest: []i32, rng: *Rng) Fail!void {
    const num = dest.len;
    if (num == 0) return;
    var p: usize = 0;
    var randpasses: usize = 0;
    var d: usize = 0;
    var n: usize = num;
    while (true) {
        var k: i32 = patterns[p];
        p += 1;
        if (k == 0) {
            p = 0;
        } else if (k < 0) {
            k = -k;
            if (@as(usize, @intCast(k)) >= n) {
                randpasses += n;
                break;
            }
            randpasses += @intCast(k);
            n -= @intCast(k);
        } else if (@as(usize, @intCast(k)) <= n) {
            const ku: usize = @intCast(k);
            @memcpy(dest[d .. d + ku], patterns[p .. p + ku]);
            p += ku;
            d += ku;
            n -= ku;
        } else if (n < 2 or 3 * n < @as(usize, @intCast(k))) {
            randpasses += n;
            break;
        } else {
            while (true) {
                if (n == @as(usize, @intCast(k)) or try rng.choose(@intCast(k)) < n) {
                    dest[d] = patterns[p];
                    d += 1;
                    n -= 1;
                }
                p += 1;
                k -= 1;
                if (n == 0) break;
            }
            break;
        }
    }
    var top = num - randpasses;
    randpasses -%= 1;
    var accum = randpasses;
    var i: usize = 0;
    while (i < num) : (i += 1) {
        if (accum <= randpasses) {
            accum += num - 1;
            dest[top] = dest[i];
            top += 1;
            dest[i] = -1;
        } else {
            const swap = i + try rng.choose(top - i);
            const k = dest[i];
            dest[i] = dest[swap];
            dest[swap] = k;
        }
        accum -%= randpasses;
    }
}

fn doSync(ctx: *Ctx, fd: sys.Handle, qname: []const u8) bool {
    if (sys.syncFile(fd, .data)) |e| {
        if (!(e == .INVAL or e == .BADF or e == .ISDIR)) {
            warn(ctx, "{s}: fdatasync failed: {s}", .{ qname, sys.errnoText(e) });
            return false;
        }
        if (sys.syncFile(fd, .file)) |e2| {
            if (!(e2 == .INVAL or e2 == .BADF or e2 == .ISDIR)) {
                warn(ctx, "{s}: fsync failed: {s}", .{ qname, sys.errnoText(e2) });
                return false;
            }
            _ = sys.syncFile(fd, .all);
        }
    }
    return true;
}

const PassResult = enum { ok, write_error, other_error };

fn doPass(ctx: *Ctx, rng: *Rng, fd: sys.Handle, st: sys.FileStat, qname: []const u8, sizep: *i64, ptype: i32, k: u64, n: u64) Fail!PassResult {
    var size = sizep.*;
    const output_size: usize = if (periodic(ptype)) 60 * 1024 else 64 * 1024;
    const fill_size = ((output_size + 2) / 3) * 3;
    const pbuf = ctx.gpa.alloc(u8, fill_size) catch return .other_error;
    defer ctx.gpa.free(pbuf);
    var e: E = .SUCCESS;
    var write_error = false;

    // rewind
    const off0 = sys.seekFd(fd, 0, 0, &e) orelse {
        warn(ctx, "{s}: cannot rewind: {s}", .{ qname, sys.errnoText(e) });
        return .other_error;
    };
    if (off0 != 0) {
        warn(ctx, "{s}: cannot rewind: {s}", .{ qname, sys.errnoText(.INVAL) });
        return .other_error;
    }
    _ = st;
    var pass_string: [6]u8 = undefined;
    var pass_name: []const u8 = "random";
    if (ptype >= 0) {
        const lim: usize = if (size >= 0 and @as(usize, @intCast(size)) < fill_size) @intCast(size) else fill_size;
        fillPattern(ptype, pbuf, @max(lim, 3));
        pass_name = std.fmt.bufPrint(&pass_string, "{x:0>2}{x:0>2}{x:0>2}", .{ pbuf[0], pbuf[1], pbuf[2] }) catch "";
    }
    if (n != 0) warn(ctx, "{s}: pass {d}/{d} ({s})...", .{ qname, k, n, pass_name });
    var offset: i64 = 0;
    var previous_human: [human.longest]u8 = undefined;
    var previous_len: usize = 0;
    var last_report_ns: i96 = Io.Timestamp.now(ctx.io, .real).toNanoseconds();
    while (true) {
        var lim: usize = output_size;
        if (size >= 0 and size - offset < @as(i64, @intCast(output_size))) {
            if (size < offset) break;
            lim = @intCast(size - offset);
            if (lim == 0) break;
        }
        if (ptype < 0) try rng.bytes(pbuf[0..lim]);
        var soff: usize = 0;
        while (soff < lim) {
            var we: E = .SUCCESS;
            const rc = sys.writeFd(fd, pbuf[soff..lim], &we) orelse 0;
            if (we != .SUCCESS or rc == 0) {
                if (size < 0 and (rc == 0 or we == .NOSPC)) {
                    size = offset + @as(i64, @intCast(soff));
                    sizep.* = size;
                    break;
                }
                const eerr: E = if (rc == 0) .NOSPC else we;
                warn(ctx, "{s}: error writing at offset {d}: {s}", .{ qname, offset + @as(i64, @intCast(soff)), sys.errnoText(eerr) });
                if (eerr == .IO and size >= 0 and (soff | 511) < lim) {
                    const soff1 = (soff | 511) + 1;
                    if (sys.seekFd(fd, offset + @as(i64, @intCast(soff1)), 0, &e) != null) {
                        soff = soff1;
                        write_error = true;
                        continue;
                    }
                    warn(ctx, "{s}: lseek failed: {s}", .{ qname, sys.errnoText(e) });
                }
                return .other_error;
            }
            soff += rc;
        }
        offset += @intCast(soff);
        const done = offset == size;
        const now = Io.Timestamp.now(ctx.io, .real).toNanoseconds();
        if (n != 0 and ((done and previous_len > 0) or now - last_report_ns >= 5_000_000_000)) {
            var ob: [human.longest]u8 = undefined;
            var sb: [human.longest]u8 = undefined;
            const hopts: u32 = human.autoscale | human.si | human.base_1024 | human.b_suffix;
            var human_offset = human.readable(@intCast(offset), &ob, human.floor | hopts, 1, 1);
            if (done or !std.mem.eql(u8, previous_human[0..previous_len], human_offset)) {
                if (size < 0) {
                    warn(ctx, "{s}: pass {d}/{d} ({s})...{s}", .{ qname, k, n, pass_name, human_offset });
                } else {
                    const percent: u64 = if (size == 0) 100 else @intCast(@divTrunc(@as(i128, offset) * 100, size));
                    const human_size = human.readable(@intCast(size), &sb, human.ceiling | hopts, 1, 1);
                    if (done) human_offset = human_size;
                    warn(ctx, "{s}: pass {d}/{d} ({s})...{s}/{s} {d}%", .{ qname, k, n, pass_name, human_offset, human_size, percent });
                }
                @memcpy(previous_human[0..human_offset.len], human_offset);
                previous_len = human_offset.len;
                last_report_ns = now;
                if (!doSync(ctx, fd, qname)) return .other_error;
            }
        }
    }
    if (!doSync(ctx, fd, qname)) return .other_error;
    return if (write_error) .write_error else .ok;
}

fn doWipeFd(ctx: *Ctx, rng: *Rng, fd: sys.Handle, qname: []const u8, o: Options) Fail!bool {
    var e: E = .SUCCESS;
    var n: u64 = 0;
    if (o.verbose) n = o.n_iterations + @intFromBool(o.zero_fill);
    const st = sys.fstatFd(fd, &e) orelse {
        warn(ctx, "{s}: fstat failed: {s}", .{ qname, sys.errnoText(e) });
        return false;
    };
    const ftype = st.mode & 0o170000;
    if ((ftype == 0o020000 and (Io.File.stdout().isTty(ctx.io) catch false) and fd == Io.File.stdout().handle) or ftype == 0o010000 or ftype == 0o140000) {
        warn(ctx, "{s}: invalid file type", .{qname});
        return false;
    }
    const passarray = ctx.gpa.alloc(i32, @intCast(o.n_iterations)) catch return false;
    defer ctx.gpa.free(passarray);
    var size: i64 = o.size;
    var i_size: i64 = 0;
    const blksize: i64 = if (st.blksize != 0) st.blksize else 4096;
    if (size == -1) {
        if (st.isReg()) {
            size = @intCast(st.size);
            if (!o.exact) {
                const remainder = @rem(size, blksize);
                if (size != 0 and size < blksize) i_size = size;
                if (remainder != 0) size += blksize - remainder;
            }
        } else {
            const end = sys.seekFd(fd, 0, 2, &e) orelse -1;
            size = if (end <= 0) -1 else end;
        }
    } else if (st.isReg() and @as(i64, @intCast(st.size)) < @min(blksize, size)) {
        i_size = @intCast(st.size);
    }
    try genPattern(passarray, rng);
    var ok = true;
    while (true) {
        var pass_size: i64 = undefined;
        var pn = n;
        if (i_size != 0) {
            pass_size = i_size;
            i_size = 0;
            pn = 0;
        } else if (size != 0) {
            pass_size = size;
            size = 0;
        } else break;
        var i: u64 = 0;
        while (i < o.n_iterations + @intFromBool(o.zero_fill)) : (i += 1) {
            const ptype: i32 = if (i < o.n_iterations) passarray[@intCast(i)] else 0;
            switch (try doPass(ctx, rng, fd, st, qname, &pass_size, ptype, i + 1, pn)) {
                .ok => {},
                .write_error => ok = false,
                .other_error => return false,
            }
        }
    }
    if (o.remove != .none) {
        if (sys.ftruncateFd(fd, 0)) |te| {
            if (st.isReg()) {
                warn(ctx, "{s}: error truncating: {s}", .{ qname, sys.errnoText(te) });
                return false;
            }
        }
    }
    return ok;
}

const nameset = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_.";

fn incname(name: []u8) bool {
    var len = name.len;
    while (len > 0) {
        len -= 1;
        const idx = std.mem.indexOfScalar(u8, nameset, name[len]).?;
        if (idx + 1 < nameset.len) {
            name[len] = nameset[idx + 1];
            return true;
        }
        name[len] = nameset[0];
    }
    return false;
}

fn wipeName(ctx: *Ctx, oldname: []const u8, qoldname: []const u8, o: Options) bool {
    var ok = true;
    const slash = std.mem.lastIndexOfScalar(u8, oldname, '/');
    const dir: []const u8 = if (slash) |s| (if (s == 0) "/" else oldname[0..s]) else ".";
    const base_off = if (slash) |s| s + 1 else 0;
    var cur = ctx.gpa.dupe(u8, oldname) catch return false;
    defer ctx.gpa.free(cur);
    var dir_fd: sys.Handle = sys.invalid_handle;
    var e: E = .SUCCESS;
    if (o.remove == .wipesync) dir_fd = sys.openFd(dir, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NOCTTY | sys.O.NONBLOCK, 0, &e) orelse sys.invalid_handle;
    if (o.verbose) warn(ctx, "{s}: removing", .{qoldname});
    var first = true;
    if (o.remove != .unlink) {
        var len = cur.len - base_off;
        var warned = false;
        while (len != 0) : (len -= 1) {
            const next = ctx.gpa.dupe(u8, cur[0 .. base_off + len]) catch return false;
            defer ctx.gpa.free(next);
            @memset(next[base_off..], nameset[0]);
            var rename_ok = false;
            while (true) {
                if (sys.renamePath(cur, next, sys.RENAME_NOREPLACE)) |re| {
                    if (re == .EXIST and incname(next[base_off..])) continue;
                    // GNU says nothing here, though some or all of the old
                    // name may then survive in the directory.
                    if (re != .EXIST and !warned) {
                        warn(ctx, "{s}: warning: cannot rename, so the name is not fully wiped: {s}", .{ qoldname, sys.errnoText(re) });
                        warned = true;
                    }
                    break;
                }
                rename_ok = true;
                break;
            }
            if (rename_ok) {
                if (dir_fd != sys.invalid_handle and !doSync(ctx, dir_fd, dir)) ok = false;
                if (o.verbose) {
                    warn(ctx, "{s}: renamed to {s}", .{ if (first) qoldname else cur, next });
                    first = false;
                }
                ctx.gpa.free(cur);
                cur = ctx.gpa.dupe(u8, next) catch return false;
            }
        }
    }
    if (sys.unlinkPath(cur, false)) |ue| {
        warn(ctx, "{s}: failed to remove: {s}", .{ qoldname, sys.errnoText(ue) });
        ok = false;
    } else if (o.verbose) warn(ctx, "{s}: removed", .{qoldname});
    if (dir_fd != sys.invalid_handle) {
        if (!doSync(ctx, dir_fd, dir)) ok = false;
        if (sys.closeFd(dir_fd)) |ce| {
            warn(ctx, "{s}: failed to close: {s}", .{ dir, sys.errnoText(ce) });
            ok = false;
        }
    }
    return ok;
}

fn wipeFile(ctx: *Ctx, rng: *Rng, name: []const u8, qname: []const u8, o: Options) Fail!bool {
    var e: E = .SUCCESS;
    var fd = sys.openFd(name, sys.O.WRONLY | sys.O.NOCTTY, 0, &e);
    if (fd == null and e == .ACCES and o.force) {
        if (sys.chmodPath(name, 0o200, false) == null) fd = sys.openFd(name, sys.O.WRONLY | sys.O.NOCTTY, 0, &e);
    }
    const f = fd orelse {
        warn(ctx, "{s}: failed to open for writing: {s}", .{ qname, sys.errnoText(e) });
        return false;
    };
    var ok = try doWipeFd(ctx, rng, f, qname, o);
    if (sys.closeFd(f)) |ce| {
        warn(ctx, "{s}: failed to close: {s}", .{ qname, sys.errnoText(ce) });
        ok = false;
    }
    if (ok and o.remove != .none) ok = wipeName(ctx, name, qname, o);
    return ok;
}


/// Shred each named file ("-" is standard output). Returns false when any
/// failed.
pub fn run(env: Env, options: Options, names: []const []const u8, observer: Observer) Error!bool {
    var ctx: Ctx = .{ .gpa = env.gpa, .io = env.io, .observer = observer };
    var seed: [8]u8 = undefined;
    env.io.random(&seed);
    var rng: Rng = .{ .file = options.random_source, .io = env.io, .prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little)) };
    var ok = true;
    for (names) |name| {
        const qname = std.fmt.allocPrint(env.gpa, "{f}", .{quote.quote(name)}) catch return error.OutOfMemory;
        defer env.gpa.free(qname);
        if (std.mem.eql(u8, name, "-")) {
            var fe: E = .SUCCESS;
            const stdout_h = std.Io.File.stdout().handle;
            const fl = sys.getStatusFlags(stdout_h, &fe);
            if (fl == null) {
                warn(&ctx, "{s}: fcntl failed: {s}", .{ qname, sys.errnoText(fe) });
                ok = false;
            } else if (fl.? & 0o2000 != 0) {
                warn(&ctx, "{s}: cannot shred append-only file descriptor", .{qname});
                ok = false;
            } else if (!(doWipeFd(&ctx, &rng, stdout_h, qname, options) catch return error.RandomSourceExhausted)) ok = false;
        } else if (!(wipeFile(&ctx, &rng, name, qname, options) catch return error.RandomSourceExhausted)) ok = false;
    }
    return ok;
}
