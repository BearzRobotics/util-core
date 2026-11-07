//! shred — overwrite a file to hide its contents, and optionally delete it.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "shred invocation"
//! (9.7) and GNU coreutils 9.6 src/shred.c (pass structure, pattern groups,
//! file-name wiping). The pseudo-random generator is not GNU's ISAAC: random
//! passes and the pass order come from the operating system (or, with
//! --random-source, from the bytes of that file), so --random-source does not
//! reproduce GNU's exact sequence.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const human = @import("../human.zig");
const argmatch = @import("../argmatch.zig");
const Io = std.Io;
const E = std.os.linux.E;

const help_text = @embedFile("../help/shred.txt");

const Remove = enum { none, unlink, wipe, wipesync };
const remove_table = [_]argmatch.Entry{ .{ .name = "unlink", .value = 1 }, .{ .name = "wipe", .value = 2 }, .{ .name = "wipesync", .value = 3 } };

const Opts = struct {
    force: bool = false,
    n_iterations: u64 = 3,
    size: i64 = -1,
    remove: Remove = .none,
    verbose: bool = false,
    exact: bool = false,
    zero_fill: bool = false,
};

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

    fn bytes(r: *Rng, ctx: cli.Context, buf: []u8, name: []const u8) void {
        if (r.file) |f| {
            var got: usize = 0;
            while (got < buf.len) {
                const n = cli.readChunk(r.io, f, buf[got..]) catch 0;
                if (n == 0) {
                    cli.warn(ctx, "{f}: end of file", .{cli.quoteA(name)});
                    std.process.exit(1);
                }
                got += n;
            }
        } else r.prng.random().bytes(buf);
    }

    fn choose(r: *Rng, ctx: cli.Context, n: u64, name: []const u8) u64 {
        if (n <= 1) return 0;
        // Rejection sampling over 64-bit values.
        const limit = std.math.maxInt(u64) - (std.math.maxInt(u64) % n) - 1;
        while (true) {
            var b: [8]u8 = undefined;
            r.bytes(ctx, &b, name);
            const v = std.mem.readInt(u64, &b, .little);
            if (v <= limit) return v % n;
        }
    }
};

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

fn genPattern(ctx: cli.Context, dest: []i32, rng: *Rng, name: []const u8) void {
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
                if (n == @as(usize, @intCast(k)) or rng.choose(ctx, @intCast(k), name) < n) {
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
            const swap = i + rng.choose(ctx, top - i, name);
            const k = dest[i];
            dest[i] = dest[swap];
            dest[swap] = k;
        }
        accum -%= randpasses;
    }
}

fn doSync(ctx: cli.Context, fd: i32, qname: []const u8) bool {
    if (sys.syncFile(fd, .data)) |e| {
        if (!(e == .INVAL or e == .BADF or e == .ISDIR)) {
            cli.warn(ctx, "{s}: fdatasync failed: {s}", .{ qname, sys.errnoText(e) });
            return false;
        }
        if (sys.syncFile(fd, .file)) |e2| {
            if (!(e2 == .INVAL or e2 == .BADF or e2 == .ISDIR)) {
                cli.warn(ctx, "{s}: fsync failed: {s}", .{ qname, sys.errnoText(e2) });
                return false;
            }
            _ = sys.syncFile(fd, .all);
        }
    }
    return true;
}

const PassResult = enum { ok, write_error, other_error };

fn doPass(ctx: cli.Context, rng: *Rng, rng_name: []const u8, fd: i32, st: sys.FileStat, qname: []const u8, sizep: *i64, ptype: i32, k: u64, n: u64) PassResult {
    var size = sizep.*;
    const output_size: usize = if (periodic(ptype)) 60 * 1024 else 64 * 1024;
    const fill_size = ((output_size + 2) / 3) * 3;
    const pbuf = ctx.gpa.alloc(u8, fill_size) catch return .other_error;
    defer ctx.gpa.free(pbuf);
    var e: E = .SUCCESS;
    var write_error = false;

    // rewind
    const off0 = sys.seekFd(fd, 0, 0, &e) orelse {
        cli.warn(ctx, "{s}: cannot rewind: {s}", .{ qname, sys.errnoText(e) });
        return .other_error;
    };
    if (off0 != 0) {
        cli.warn(ctx, "{s}: cannot rewind: {s}", .{ qname, sys.errnoText(.INVAL) });
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
    if (n != 0) cli.warn(ctx, "{s}: pass {d}/{d} ({s})...", .{ qname, k, n, pass_name });
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
        if (ptype < 0) rng.bytes(ctx, pbuf[0..lim], rng_name);
        var soff: usize = 0;
        while (soff < lim) {
            const rc = std.os.linux.write(fd, pbuf.ptr + soff, lim - soff);
            const we = std.os.linux.errno(rc);
            if (we == .INTR) continue;
            if (we != .SUCCESS or rc == 0) {
                if (size < 0 and (rc == 0 or we == .NOSPC)) {
                    size = offset + @as(i64, @intCast(soff));
                    sizep.* = size;
                    break;
                }
                const eerr: E = if (rc == 0) .NOSPC else we;
                cli.warn(ctx, "{s}: error writing at offset {d}: {s}", .{ qname, offset + @as(i64, @intCast(soff)), sys.errnoText(eerr) });
                if (eerr == .IO and size >= 0 and (soff | 511) < lim) {
                    const soff1 = (soff | 511) + 1;
                    if (sys.seekFd(fd, offset + @as(i64, @intCast(soff1)), 0, &e) != null) {
                        soff = soff1;
                        write_error = true;
                        continue;
                    }
                    cli.warn(ctx, "{s}: lseek failed: {s}", .{ qname, sys.errnoText(e) });
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
                    cli.warn(ctx, "{s}: pass {d}/{d} ({s})...{s}", .{ qname, k, n, pass_name, human_offset });
                } else {
                    const percent: u64 = if (size == 0) 100 else @intCast(@divTrunc(@as(i128, offset) * 100, size));
                    const human_size = human.readable(@intCast(size), &sb, human.ceiling | hopts, 1, 1);
                    if (done) human_offset = human_size;
                    cli.warn(ctx, "{s}: pass {d}/{d} ({s})...{s}/{s} {d}%", .{ qname, k, n, pass_name, human_offset, human_size, percent });
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

fn doWipeFd(ctx: cli.Context, rng: *Rng, rng_name: []const u8, fd: i32, qname: []const u8, o: Opts) bool {
    var e: E = .SUCCESS;
    var n: u64 = 0;
    if (o.verbose) n = o.n_iterations + @intFromBool(o.zero_fill);
    const st = sys.fstatFd(fd, &e) orelse {
        cli.warn(ctx, "{s}: fstat failed: {s}", .{ qname, sys.errnoText(e) });
        return false;
    };
    const ftype = st.mode & 0o170000;
    if ((ftype == 0o020000 and (Io.File.stdout().isTty(ctx.io) catch false) and fd == 1) or ftype == 0o010000 or ftype == 0o140000) {
        cli.warn(ctx, "{s}: invalid file type", .{qname});
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
    genPattern(ctx, passarray, rng, rng_name);
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
            switch (doPass(ctx, rng, rng_name, fd, st, qname, &pass_size, ptype, i + 1, pn)) {
                .ok => {},
                .write_error => ok = false,
                .other_error => return false,
            }
        }
    }
    if (o.remove != .none) {
        if (sys.ftruncateFd(fd, 0)) |te| {
            if (st.isReg()) {
                cli.warn(ctx, "{s}: error truncating: {s}", .{ qname, sys.errnoText(te) });
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

fn wipeName(ctx: cli.Context, oldname: []const u8, qoldname: []const u8, o: Opts) bool {
    var ok = true;
    const slash = std.mem.lastIndexOfScalar(u8, oldname, '/');
    const dir: []const u8 = if (slash) |s| (if (s == 0) "/" else oldname[0..s]) else ".";
    const base_off = if (slash) |s| s + 1 else 0;
    var cur = ctx.gpa.dupe(u8, oldname) catch return false;
    defer ctx.gpa.free(cur);
    var dir_fd: i32 = -1;
    var e: E = .SUCCESS;
    if (o.remove == .wipesync) dir_fd = sys.openFd(dir, sys.O.RDONLY | sys.O.DIRECTORY | sys.O.NOCTTY | sys.O.NONBLOCK, 0, &e) orelse -1;
    if (o.verbose) cli.warn(ctx, "{s}: removing", .{qoldname});
    var first = true;
    if (o.remove != .unlink) {
        var len = cur.len - base_off;
        while (len != 0) : (len -= 1) {
            const next = ctx.gpa.dupe(u8, cur[0 .. base_off + len]) catch return false;
            defer ctx.gpa.free(next);
            @memset(next[base_off..], nameset[0]);
            var rename_ok = false;
            while (true) {
                if (sys.renamePath(cur, next, sys.RENAME_NOREPLACE)) |re| {
                    if (re == .EXIST and incname(next[base_off..])) continue;
                    break;
                }
                rename_ok = true;
                break;
            }
            if (rename_ok) {
                if (dir_fd >= 0 and !doSync(ctx, dir_fd, dir)) ok = false;
                if (o.verbose) {
                    cli.warn(ctx, "{s}: renamed to {s}", .{ if (first) qoldname else cur, next });
                    first = false;
                }
                ctx.gpa.free(cur);
                cur = ctx.gpa.dupe(u8, next) catch return false;
            }
        }
    }
    if (sys.unlinkPath(cur, false)) |ue| {
        cli.warn(ctx, "{s}: failed to remove: {s}", .{ qoldname, sys.errnoText(ue) });
        ok = false;
    } else if (o.verbose) cli.warn(ctx, "{s}: removed", .{qoldname});
    if (dir_fd >= 0) {
        if (!doSync(ctx, dir_fd, dir)) ok = false;
        if (sys.closeFd(dir_fd)) |ce| {
            cli.warn(ctx, "{s}: failed to close: {s}", .{ dir, sys.errnoText(ce) });
            ok = false;
        }
    }
    return ok;
}

fn wipeFile(ctx: cli.Context, rng: *Rng, rng_name: []const u8, name: []const u8, qname: []const u8, o: Opts) bool {
    var e: E = .SUCCESS;
    var fd = sys.openFd(name, sys.O.WRONLY | sys.O.NOCTTY, 0, &e);
    if (fd == null and e == .ACCES and o.force) {
        if (sys.chmodPath(name, 0o200, false) == null) fd = sys.openFd(name, sys.O.WRONLY | sys.O.NOCTTY, 0, &e);
    }
    const f = fd orelse {
        cli.warn(ctx, "{s}: failed to open for writing: {s}", .{ qname, sys.errnoText(e) });
        return false;
    };
    var ok = doWipeFd(ctx, rng, rng_name, f, qname, o);
    if (sys.closeFd(f)) |ce| {
        cli.warn(ctx, "{s}: failed to close: {s}", .{ qname, sys.errnoText(ce) });
        ok = false;
    }
    if (ok and o.remove != .none) ok = wipeName(ctx, name, qname, o);
    return ok;
}

fn usageFail(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 1;
}

pub fn main(ctx: cli.Context) u8 {
    var o: Opts = .{};
    var random_source: ?[]const u8 = null;
    var p = getopt.Parser.init(ctx, "fn:s:uvxz", &.{
        .{ .name = "exact", .id = 'x' },
        .{ .name = "force", .id = 'f' },
        .{ .name = "iterations", .arg = .required, .id = 'n' },
        .{ .name = "size", .arg = .required, .id = 's' },
        .{ .name = "random-source", .arg = .required, .id = 1100 },
        .{ .name = "remove", .arg = .optional, .id = 'u' },
        .{ .name = "verbose", .id = 'v' },
        .{ .name = "zero", .id = 'z' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |opt| switch (opt.id) {
            'f' => o.force = true,
            'n' => {
                const r = human.strtoumaxBase(opt.arg.?, "", true);
                if (r.err != .ok or r.value > std.math.maxInt(usize) / 4) {
                    if (r.err == .overflow)
                        cli.warn(ctx, "invalid number of passes: {f}: Value too large for defined data type", .{cli.quoteC(opt.arg.?)})
                    else
                        cli.warn(ctx, "invalid number of passes: {f}", .{cli.quoteC(opt.arg.?)});
                    return 1;
                }
                o.n_iterations = r.value;
            },
            1100 => {
                if (random_source != null and !std.mem.eql(u8, random_source.?, opt.arg.?)) {
                    cli.warn(ctx, "multiple random sources specified", .{});
                    return 1;
                }
                random_source = opt.arg.?;
            },
            'u' => {
                if (opt.arg) |a| {
                    const r = argmatch.match(a, &remove_table);
                    switch (r) {
                        .ok => |v| o.remove = @enumFromInt(v),
                        else => {
                            argmatch.die(ctx, a, "--remove", &remove_table, r);
                            return 1;
                        },
                    }
                } else o.remove = .wipesync;
            },
            's' => {
                const r = human.strtoumaxBase(opt.arg.?, "cbBkKMGTPEZYRQ0", true);
                if (r.err != .ok or r.value > std.math.maxInt(i64)) {
                    cli.warn(ctx, "invalid file size: {f}", .{cli.quoteC(opt.arg.?)});
                    return 1;
                }
                o.size = @intCast(r.value);
            },
            'v' => o.verbose = true,
            'x' => o.exact = true,
            'z' => o.zero_fill = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    const files = p.operands.items;
    if (files.len == 0) {
        cli.warn(ctx, "missing file operand", .{});
        return usageFail(ctx);
    }
    var seed: [8]u8 = undefined;
    ctx.io.random(&seed);
    var rng: Rng = .{ .io = ctx.io, .prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little)) };
    var rng_name: []const u8 = "getrandom";
    if (random_source) |rs| {
        rng.file = Io.Dir.cwd().openFile(ctx.io, rs, .{}) catch |err| {
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(rs), cli.errText(err) });
            return 1;
        };
        rng_name = rs;
    }
    defer if (rng.file) |f| f.close(ctx.io);

    var ok = true;
    for (files) |name| {
        const qname = std.fmt.allocPrint(ctx.gpa, "{f}", .{cli.quote(name)}) catch return 1;
        defer ctx.gpa.free(qname);
        if (std.mem.eql(u8, name, "-")) {
            const fl = std.os.linux.fcntl(1, std.os.linux.F.GETFL, 0);
            if (std.os.linux.errno(fl) != .SUCCESS) {
                cli.warn(ctx, "{s}: fcntl failed: {s}", .{ qname, sys.errnoText(std.os.linux.errno(fl)) });
                ok = false;
            } else if (fl & 0o2000 != 0) {
                cli.warn(ctx, "{s}: cannot shred append-only file descriptor", .{qname});
                ok = false;
            } else if (!doWipeFd(ctx, &rng, rng_name, 1, qname, o)) ok = false;
        } else if (!wipeFile(ctx, &rng, rng_name, name, qname, o)) ok = false;
    }
    return if (ok) 0 else 1;
}
