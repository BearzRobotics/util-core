// SPDX-License-Identifier: GPL-2.0-or-later
//! Shared implementation of cksum, md5sum, sha1sum, sha224sum, sha256sum,
//! sha384sum, sha512sum and b2sum.
//! References: GNU coreutils manual (9.7) "cksum invocation", "md5sum
//! invocation", "b2sum invocation", "sha2 utilities"; POSIX.1-2024 cksum.
//!
//! Output formats (manual, "cksum output modes"):
//!   * legacy (cksum with crc/crc32b/sysv/bsd): "SUM BYTES [NAME]";
//!   * tagged:   "TAG (NAME) = DIGEST";
//!   * untagged: "DIGEST<space><mode>NAME", mode '*' (binary) or ' ' (text).
//! A file name containing backslash, newline or carriage return is escaped
//! (and the line starts with a backslash) unless -z is given.

const std = @import("std");
const cli = @import("cli.zig");
const hash = @import("hash.zig");
const Io = std.Io;

pub const Tool = enum { cksum, md5sum, sha1sum, sha224sum, sha256sum, sha384sum, sha512sum, b2sum };

const Config = struct {
    tool: Tool,
    algo: hash.Algo,
    algo_given: bool = false,
    check: bool = false,
    tag: bool = false,
    untagged: bool = false,
    binary: bool = false,
    text: bool = false,
    zero: bool = false,
    ignore_missing: bool = false,
    quiet: bool = false,
    status: bool = false,
    strict: bool = false,
    warn: bool = false,
    base64: bool = false,
    raw: bool = false,
    /// BLAKE2b digest length in bytes.
    length: usize = 64,
    length_given: bool = false,

    fn standalone(c: Config) bool {
        return c.tool != .cksum;
    }
};

fn defaultAlgo(t: Tool) hash.Algo {
    return switch (t) {
        .cksum => .crc,
        .md5sum => .md5,
        .sha1sum => .sha1,
        .sha224sum => .sha224,
        .sha256sum => .sha256,
        .sha384sum => .sha384,
        .sha512sum => .sha512,
        .b2sum => .blake2b,
    };
}

const alg_names = [_][]const u8{ "bsd", "sysv", "crc", "crc32b", "md5", "sha1", "sha224", "sha256", "sha384", "sha512", "blake2b", "sm3" };

const long_names = [_][]const u8{
    "algorithm", "base64", "binary", "check", "debug", "help", "ignore-missing", "length", "quiet", "raw", //  0-9
    "status", "strict", "tag", "text", "untagged", "version", "warn", "zero", //  10-17
};

pub fn main(ctx: cli.Context, tool: Tool) u8 {
    var cfg: Config = .{ .tool = tool, .algo = defaultAlgo(tool) };
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    const cks = tool == .cksum;
    const b2 = tool == .b2sum;

    var i: usize = 0;
    var only_operands = false;
    while (i < ctx.args.len) : (i += 1) {
        const a: []const u8 = ctx.args[i];
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
            // Options that belong to one tool only are unknown to the others.
            const allowed = switch (k) {
                0, 1, 4, 9, 14 => cks, // algorithm base64 debug raw untagged
                7 => cks or b2, // length
                2, 13 => !cks, // binary text
                else => true,
            };
            if (!allowed) {
                cli.badLong(ctx, a, .none);
                return 1;
            }
            const takes = k == 0 or k == 7;
            var value: ?[]const u8 = if (eq) |e| a[e + 1 ..] else null;
            if (takes and value == null) {
                i += 1;
                if (i >= ctx.args.len) {
                    cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                    return 1;
                }
                value = ctx.args[i];
            } else if (!takes and value != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => if (!setAlgo(ctx, &cfg, value.?)) return 1,
                1 => cfg.base64 = true,
                2 => {
                    cfg.binary = true;
                    cfg.text = false;
                },
                3 => cfg.check = true,
                4 => {},
                5 => return help(ctx, tool),
                6 => cfg.ignore_missing = true,
                7 => if (!setLength(ctx, &cfg, value.?)) return 1,
                8 => cfg.quiet = true,
                9 => cfg.raw = true,
                10 => cfg.status = true,
                11 => cfg.strict = true,
                12 => {
                    cfg.tag = true;
                    cfg.untagged = false;
                },
                13 => {
                    cfg.text = true;
                    cfg.binary = false;
                },
                14 => {
                    cfg.untagged = true;
                    cfg.tag = false;
                },
                15 => return if (cli.printVersion(ctx)) 0 else 1,
                16 => cfg.warn = true,
                else => cfg.zero = true,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) {
            const c = a[j];
            switch (c) {
                'a', 'l' => {
                    if ((c == 'a' and !cks) or (c == 'l' and !cks and !b2)) {
                        cli.invalidShort(ctx, c);
                        return 1;
                    }
                    var value: []const u8 = a[j + 1 ..];
                    if (value.len == 0) {
                        i += 1;
                        if (i >= ctx.args.len) {
                            cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ c, ctx.name });
                            return 1;
                        }
                        value = ctx.args[i];
                    }
                    if (c == 'a') {
                        if (!setAlgo(ctx, &cfg, value)) return 1;
                    } else if (!setLength(ctx, &cfg, value)) return 1;
                    j = a.len;
                },
                'b' => {
                    cfg.binary = true;
                    cfg.text = false;
                },
                't' => {
                    cfg.text = true;
                    cfg.binary = false;
                },
                'c' => cfg.check = true,
                'w' => cfg.warn = true,
                'z' => cfg.zero = true,
                else => {
                    cli.invalidShort(ctx, c);
                    return 1;
                },
            }
        }
    }

    if (cfg.length_given and cfg.algo != .blake2b and !cfg.check) {
        cli.warn(ctx, "--length is only supported with --algorithm=blake2b", .{});
        return 1;
    }
    if (!cfg.check) {
        if (cfg.ignore_missing) return mustCheck(ctx, "ignore-missing");
        if (cfg.status) return mustCheck(ctx, "status");
        if (cfg.warn) return mustCheck(ctx, "warn");
        if (cfg.quiet) return mustCheck(ctx, "quiet");
        if (cfg.strict) return mustCheck(ctx, "strict");
    }
    if (cks and cfg.text and !cfg.untagged and !cfg.check) {
        cli.warn(ctx, "--text mode is only supported with --untagged\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (cfg.tag and cfg.text) {
        cli.warn(ctx, "--tag does not support --text mode\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (cfg.raw and files.items.len > 1) {
        cli.warn(ctx, "the --raw option is not supported with multiple files", .{});
        return 1;
    }
    if (cfg.zero and cfg.check) {
        cli.warn(ctx, "the --zero option is not supported when verifying checksums\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (cfg.check and cfg.tag and !cks) {
        cli.warn(ctx, "the --tag option is meaningless when verifying checksums\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (cfg.check and cfg.raw) {
        cli.warn(ctx, "the --raw option is not supported when verifying checksums\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (cfg.check and !cfg.algo.isDigest() and cfg.algo_given) {
        cli.warn(ctx, "--check is not supported with --algorithm={{bsd,sysv,crc,crc32b}}", .{});
        return 1;
    }

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    if (cfg.check) return checkAll(ctx, &cfg, inputs);
    return generateAll(ctx, &cfg, inputs, files.items.len == 0);
}

fn mustCheck(ctx: cli.Context, what: []const u8) u8 {
    cli.warn(ctx, "the --{s} option is meaningful only when verifying checksums\nTry '{s} --help' for more information.", .{ what, ctx.name });
    return 1;
}

fn setAlgo(ctx: cli.Context, cfg: *Config, v: []const u8) bool {
    for (alg_names) |n| {
        if (std.mem.eql(u8, n, v)) {
            cfg.algo = std.meta.stringToEnum(hash.Algo, n).?;
            cfg.algo_given = true;
            return true;
        }
    }
    cli.warn(ctx, "invalid argument '{s}' for '--algorithm'\nValid arguments are:\n  - 'bsd'\n  - 'sysv'\n  - 'crc'\n  - 'crc32b'\n  - 'md5'\n  - 'sha1'\n  - 'sha224'\n  - 'sha256'\n  - 'sha384'\n  - 'sha512'\n  - 'blake2b'\n  - 'sm3'\nTry '{s} --help' for more information.", .{ v, ctx.name });
    return false;
}

fn setLength(ctx: cli.Context, cfg: *Config, v: []const u8) bool {
    // GNU validates the value only once it knows the algorithm accepts a length.
    const bad = if (std.fmt.parseInt(u64, v, 10)) |b| b % 8 != 0 else |_| true;
    if (bad and cfg.algo != .blake2b and !cfg.check) {
        cli.warn(ctx, "--length is only supported with --algorithm=blake2b", .{});
        return false;
    }
    const bits = std.fmt.parseInt(u64, v, 10) catch {
        cli.warn(ctx, "invalid length: '{s}'", .{v});
        return false;
    };
    if (bits % 8 != 0) {
        cli.warn(ctx, "invalid length: '{s}'", .{v});
        cli.warn(ctx, "length is not a multiple of 8", .{});
        return false;
    }
    cfg.length_given = true;
    // 0 and anything above 512 bits mean the full 64-byte digest (GNU).
    cfg.length = if (bits == 0 or bits > 512) 64 else @intCast(bits / 8);
    return true;
}

// -------------------------------------------------------------- generating

const Digest = struct {
    /// Digest bytes (modern algorithms) or the formatted legacy fields.
    bytes: [hash.max_digest]u8 = undefined,
    len: usize = 0,
    /// Legacy: first and second number of the output line.
    n1: u64 = 0,
    n2: u64 = 0,
    bytes_read: u64 = 0,
};

/// Read `file` to the end and compute the checksum selected by `algo`.
fn compute(ctx: cli.Context, algo: hash.Algo, length: usize, file: Io.File, buf: []u8) !Digest {
    var d: Digest = .{};
    switch (algo) {
        .crc => {
            var s: hash.PosixCrc = .{};
            while (true) {
                const n = try cli.readChunk(ctx.io, file, buf);
                if (n == 0) break;
                s.update(buf[0..n]);
            }
            d.n1 = s.final();
            d.n2 = s.len;
        },
        .crc32b => {
            var s = std.hash.Crc32.init();
            var total: u64 = 0;
            while (true) {
                const n = try cli.readChunk(ctx.io, file, buf);
                if (n == 0) break;
                s.update(buf[0..n]);
                total += n;
            }
            d.n1 = s.final();
            d.n2 = total;
        },
        .bsd => {
            var s: hash.BsdSum = .{};
            while (true) {
                const n = try cli.readChunk(ctx.io, file, buf);
                if (n == 0) break;
                s.update(buf[0..n]);
            }
            d.n1 = s.sum;
            d.n2 = (s.len + 1023) / 1024;
            d.bytes_read = s.len;
        },
        .sysv => {
            var s: hash.SysvSum = .{};
            while (true) {
                const n = try cli.readChunk(ctx.io, file, buf);
                if (n == 0) break;
                s.update(buf[0..n]);
            }
            d.n1 = s.final();
            d.n2 = (s.len + 511) / 512;
            d.bytes_read = s.len;
        },
        else => {
            var h = hash.Hasher.init(algo, length);
            while (true) {
                const n = try cli.readChunk(ctx.io, file, buf);
                if (n == 0) break;
                h.update(buf[0..n]);
            }
            d.len = h.final(&d.bytes);
        },
    }
    return d;
}

fn generateAll(ctx: cli.Context, cfg: *const Config, inputs: []const []const u8, no_operands: bool) u8 {
    var out = cli.Out.init(ctx.io);
    const buf = ctx.gpa.alloc(u8, 128 * 1024) catch return oom(ctx);
    defer ctx.gpa.free(buf);
    var status: u8 = 0;
    for (inputs) |name| {
        const file = cli.openInput(ctx.io, name) catch |e| {
            out.flush();
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        const d = compute(ctx, cfg.algo, cfg.length, file, buf) catch |e| {
            out.flush();
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
            status = 1;
            continue;
        };
        if (cfg.raw) {
            writeRaw(&out, cfg.algo, d);
        } else if (!cfg.algo.isDigest()) {
            writeLegacy(&out, cfg, d, name, no_operands);
        } else {
            writeDigestLine(&out, cfg, d, name);
        }
        if (out.failed) break;
    }
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return status;
}

fn writeRaw(out: *cli.Out, algo: hash.Algo, d: Digest) void {
    if (algo.isDigest()) {
        out.write(d.bytes[0..d.len]);
        return;
    }
    // Big-endian number: crc/crc32b are 32 bit, bsd and sysv 16 bit.
    var b: [4]u8 = undefined;
    switch (algo) {
        .crc, .crc32b => {
            std.mem.writeInt(u32, &b, @intCast(d.n1), .big);
            out.write(&b);
        },
        else => {
            std.mem.writeInt(u16, b[0..2], @intCast(d.n1), .big);
            out.write(b[0..2]);
        },
    }
}

fn writeLegacy(out: *cli.Out, cfg: *const Config, d: Digest, name: []const u8, no_operands: bool) void {
    switch (cfg.algo) {
        .bsd => out.print("{d:0>5} {d: >5}", .{ d.n1, d.n2 }),
        else => out.print("{d} {d}", .{ d.n1, d.n2 }),
    }
    if (!no_operands) {
        out.writeByte(' ');
        out.write(name); // legacy lines never escape the name
    }
    out.writeByte(if (cfg.zero) 0 else '\n');
}

fn writeDigestLine(out: *cli.Out, cfg: *const Config, d: Digest, name: []const u8) void {
    const escape = !cfg.zero and needsEscape(name);
    const tagged = if (cfg.standalone()) cfg.tag else !cfg.untagged;
    if (escape) out.writeByte('\\');
    if (tagged) {
        out.write(cfg.algo.tag());
        if (cfg.algo == .blake2b and d.len != 64) out.print("-{d}", .{d.len * 8});
        out.write(" (");
        writeName(out, name, !cfg.zero);
        out.write(") = ");
        writeDigest(out, cfg, d);
    } else {
        writeDigest(out, cfg, d);
        out.writeByte(' ');
        out.writeByte(if (cfg.binary) '*' else ' ');
        writeName(out, name, !cfg.zero);
    }
    out.writeByte(if (cfg.zero) 0 else '\n');
}

fn writeDigest(out: *cli.Out, cfg: *const Config, d: Digest) void {
    if (cfg.base64) {
        var enc: [96]u8 = undefined;
        out.write(std.base64.standard.Encoder.encode(&enc, d.bytes[0..d.len]));
        return;
    }
    const hex = "0123456789abcdef";
    for (d.bytes[0..d.len]) |b| {
        out.writeByte(hex[b >> 4]);
        out.writeByte(hex[b & 15]);
    }
}

fn needsEscape(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "\\\n\r") != null;
}

fn writeName(out: *cli.Out, name: []const u8, escape: bool) void {
    if (!escape) return out.write(name);
    for (name) |c| switch (c) {
        '\\' => out.write("\\\\"),
        '\n' => out.write("\\n"),
        '\r' => out.write("\\r"),
        else => out.writeByte(c),
    };
}

// ---------------------------------------------------------------- checking

const Line = struct {
    algo: hash.Algo,
    length: usize, // digest bytes
    digest: [hash.max_digest]u8,
    name: []const u8, // unescaped, valid until the next call
    binary: bool,
};

const Totals = struct {
    ok: u64 = 0,
    mismatch: u64 = 0,
    unreadable: u64 = 0,
    improper: u64 = 0,
    missing: u64 = 0,
};

fn checkAll(ctx: cli.Context, cfg: *const Config, inputs: []const []const u8) u8 {
    var out = cli.Out.init(ctx.io);
    const buf = ctx.gpa.alloc(u8, 128 * 1024) catch return oom(ctx);
    defer ctx.gpa.free(buf);
    var status: u8 = 0;
    for (inputs) |list_name| {
        const file = cli.openInput(ctx.io, list_name) catch |e| {
            out.flush();
            // GNU opens a directory fine and fails when reading it.
            if (e == error.IsDir) cli.warn(ctx, "{f}: read error", .{cli.quote(list_name)}) else cli.warn(ctx, "{f}: {s}", .{ cli.quote(list_name), cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        const shown = if (std.mem.eql(u8, list_name, "-")) "standard input" else list_name;
        if (!checkOne(ctx, cfg, &out, file, shown, buf)) status = 1;
    }
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return status;
}

/// Verify one checksum list. Returns false when the exit status must be 1.
fn checkOne(ctx: cli.Context, cfg: *const Config, out: *cli.Out, list: Io.File, list_name: []const u8, buf: []u8) bool {
    // The list is read whole: lines are short and their order matters.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(ctx.gpa);
    while (true) {
        text.ensureUnusedCapacity(ctx.gpa, 64 * 1024) catch {
            _ = oom(ctx);
            return false;
        };
        const n = cli.readChunk(ctx.io, list, text.unusedCapacitySlice()) catch {
            cli.warn(ctx, "{f}: read error", .{cli.quote(list_name)});
            return false;
        };
        if (n == 0) break;
        text.items.len += n;
    }

    var t: Totals = .{};
    var lineno: u64 = 0;
    var any_valid = false;
    var name_buf: std.ArrayList(u8) = .empty;
    defer name_buf.deinit(ctx.gpa);
    var label_algo = cfg.algo; // algorithm named in "improperly formatted" warnings
    var pos: usize = 0;
    while (pos < text.items.len) {
        const nl = std.mem.indexOfScalarPos(u8, text.items, pos, '\n');
        const end = nl orelse text.items.len;
        const raw = text.items[pos..end];
        pos = if (nl) |k| k + 1 else text.items.len;
        lineno += 1;
        if (raw.len == 0 or raw[0] == '#') continue;
        const parsed = parseLine(ctx, cfg, raw, &name_buf) orelse {
            t.improper += 1;
            if (cfg.warn) {
                out.flush();
                cli.warn(ctx, "{f}: {d}: improperly formatted {s} checksum line", .{ cli.quote(list_name), lineno, checkLabel(label_algo) });
            }
            continue;
        };
        any_valid = true;
        label_algo = parsed.algo;
        verifyOne(ctx, cfg, out, parsed, &t, buf);
        if (out.failed) return false;
    }
    out.flush();

    if (!any_valid) {
        cli.warn(ctx, "{f}: no properly formatted checksum lines found", .{cli.quote(list_name)});
        return false;
    }
    if (t.improper > 0 and !cfg.status) {
        cli.warn(ctx, "WARNING: {d} {s} improperly formatted", .{ t.improper, plural(t.improper, "line is", "lines are") });
    }
    if (t.unreadable > 0 and !cfg.status) {
        cli.warn(ctx, "WARNING: {d} listed {s} could not be read", .{ t.unreadable, plural(t.unreadable, "file", "files") });
    }
    if (t.mismatch > 0 and !cfg.status) {
        cli.warn(ctx, "WARNING: {d} computed {s} did NOT match", .{ t.mismatch, plural(t.mismatch, "checksum", "checksums") });
    }
    if (cfg.ignore_missing and t.ok == 0 and t.mismatch == 0 and t.unreadable == 0) {
        cli.warn(ctx, "{f}: no file was verified", .{cli.quote(list_name)});
        return false;
    }
    if (t.mismatch > 0 or t.unreadable > 0) return false;
    if (cfg.strict and t.improper > 0) return false;
    return true;
}

fn plural(n: u64, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// Name used in "improperly formatted ... checksum line".
fn checkLabel(algo: hash.Algo) []const u8 {
    return switch (algo) {
        .crc => "CRC",
        .crc32b => "CRC32B",
        .sysv => "SYSV",
        .bsd => "BSD",
        else => algo.tag(),
    };
}

fn verifyOne(ctx: cli.Context, cfg: *const Config, out: *cli.Out, ln: Line, t: *Totals, buf: []u8) void {
    const file = cli.openInput(ctx.io, ln.name) catch |e| {
        if (cfg.ignore_missing and e == error.FileNotFound) {
            t.missing += 1;
            return;
        }
        out.flush();
        cli.warn(ctx, "{f}: {s}", .{ cli.quote(ln.name), cli.errText(e) });
        t.unreadable += 1;
        printResult(out, cfg, ln.name, "FAILED open or read", true);
        return;
    };
    defer cli.closeInput(ctx.io, file);
    const d = compute(ctx, ln.algo, ln.length, file, buf) catch |e| {
        out.flush();
        cli.warn(ctx, "{f}: {s}", .{ cli.quote(ln.name), cli.errText(e) });
        t.unreadable += 1;
        printResult(out, cfg, ln.name, "FAILED open or read", true);
        return;
    };
    if (d.len == ln.length and std.mem.eql(u8, d.bytes[0..d.len], ln.digest[0..ln.length])) {
        t.ok += 1;
        printResult(out, cfg, ln.name, "OK", false);
    } else {
        t.mismatch += 1;
        printResult(out, cfg, ln.name, "FAILED", true);
    }
}

fn printResult(out: *cli.Out, cfg: *const Config, name: []const u8, verdict: []const u8, failure: bool) void {
    if (cfg.status) return;
    if (!failure and cfg.quiet) return;
    if (needsEscape(name)) out.writeByte('\\');
    writeName(out, name, needsEscape(name));
    out.write(": ");
    out.write(verdict);
    out.writeByte('\n');
}

/// Parse one line of a checksum list in any of the three formats.
fn parseLine(ctx: cli.Context, cfg: *const Config, raw: []const u8, name_buf: *std.ArrayList(u8)) ?Line {
    var s = raw;
    var escaped = false;
    if (s.len > 0 and s[0] == '\\') {
        escaped = true;
        s = s[1..];
    }
    var ln: Line = .{ .algo = cfg.algo, .length = 0, .digest = undefined, .name = "", .binary = false };
    var name_text: []const u8 = undefined;

    if (parseTagged(cfg, s, &ln, &name_text)) {
        // done
    } else if (parseUntagged(cfg, s, &ln, &name_text)) {
        // done
    } else return null;

    name_buf.clearRetainingCapacity();
    if (escaped) {
        var i: usize = 0;
        while (i < name_text.len) : (i += 1) {
            if (name_text[i] != '\\') {
                name_buf.append(ctx.gpa, name_text[i]) catch return null;
                continue;
            }
            i += 1;
            if (i >= name_text.len) return null;
            const c: u8 = switch (name_text[i]) {
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                else => return null,
            };
            name_buf.append(ctx.gpa, c) catch return null;
        }
        ln.name = name_buf.items;
    } else {
        ln.name = name_text;
    }
    return ln;
}

/// "TAG (NAME) = DIGEST", with the tag of the selected algorithm (any known
/// algorithm for cksum) and "BLAKE2b-BITS" for shortened BLAKE2b digests.
fn parseTagged(cfg: *const Config, s: []const u8, ln: *Line, name_out: *[]const u8) bool {
    const paren = std.mem.indexOf(u8, s, " (") orelse return false;
    const tag = s[0..paren];
    var algo: hash.Algo = undefined;
    var bits: ?usize = null;
    var found = false;
    inline for ([_]hash.Algo{ .md5, .sha1, .sha224, .sha256, .sha384, .sha512, .blake2b, .sm3 }) |a| {
        if (!found) {
            const tg = comptime a.tag();
            if (std.mem.eql(u8, tag, tg)) {
                algo = a;
                if (a == .blake2b) bits = 512;
                found = true;
            } else if (a == .blake2b and std.mem.startsWith(u8, tag, "BLAKE2b-")) {
                const n = std.fmt.parseInt(usize, tag["BLAKE2b-".len..], 10) catch return false;
                if (n == 0 or n > 512 or n % 8 != 0) return false;
                algo = a;
                bits = n;
                found = true;
            }
        }
    }
    if (!found) return false;
    if (cfg.standalone() and algo != cfg.algo) return false;
    const rest = s[paren + 2 ..];
    const close = std.mem.lastIndexOf(u8, rest, ") = ") orelse return false;
    const name = rest[0..close];
    const digest_text = rest[close + 4 ..];
    ln.algo = algo;
    if (!decodeDigest(digest_text, algo, bits, ln)) return false;
    ln.binary = true;
    name_out.* = name;
    return true;
}

/// "DIGEST NAME" (two spaces or ' *' between) or the BSD-reversed one-space form.
fn parseUntagged(cfg: *const Config, s: []const u8, ln: *Line, name_out: *[]const u8) bool {
    const sp = std.mem.indexOfScalar(u8, s, ' ') orelse return false;
    const digest_text = s[0..sp];
    var rest = s[sp + 1 ..];
    if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '*')) {
        ln.binary = rest[0] == '*';
        rest = rest[1..];
    }
    if (rest.len == 0) return false;
    if (cfg.tool == .cksum and !cfg.algo_given) return false; // untagged lists need -a
    ln.algo = cfg.algo;
    if (!decodeDigest(digest_text, cfg.algo, null, ln)) return false;
    name_out.* = rest;
    return true;
}

/// Hex (or, for cksum, base64) digest of the length that `algo` produces.
fn decodeDigest(text: []const u8, algo: hash.Algo, bits: ?usize, ln: *Line) bool {
    if (!algo.isDigest()) return false;
    const full = algo.digestLen();
    // BLAKE2b: the length is whatever the line carries (a tag may say it).
    if (algo == .blake2b) {
        if (bits) |b| {
            if (text.len != (b / 8) * 2) return decodeBase64(text, b / 8, ln);
        }
    }
    const want = if (algo == .blake2b)
        (if (bits) |b| b / 8 else text.len / 2)
    else
        full;
    if (want == 0 or want > hash.max_digest) return false;
    if (text.len == want * 2) {
        for (0..want) |i| {
            const hi = std.fmt.charToDigit(text[2 * i], 16) catch return false;
            const lo = std.fmt.charToDigit(text[2 * i + 1], 16) catch return false;
            ln.digest[i] = @as(u8, hi) << 4 | lo;
        }
        ln.length = want;
        return true;
    }
    return decodeBase64(text, want, ln);
}

fn decodeBase64(text: []const u8, want: usize, ln: *Line) bool {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(text) catch return false;
    if (n != want) return false;
    dec.decode(ln.digest[0..want], text) catch return false;
    ln.length = want;
    return true;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "memory exhausted", .{});
    return 1;
}

fn help(ctx: cli.Context, tool: Tool) u8 {
    const name = @tagName(tool);
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Usage: {s} [OPTION]... [FILE]...\n" ++
        "Print or check checksums.\n\n" ++
        "With no FILE, or when FILE is -, read standard input.\n\n" ++
        "  -c, --check           read checksums from the FILEs and check them\n" ++
        "      --tag             create a BSD-style checksum\n" ++
        "  -z, --zero            end each output line with NUL, not newline,\n" ++
        "                          and disable file name escaping\n\n" ++
        "The following five options are useful only when verifying checksums:\n" ++
        "      --ignore-missing  don't fail or report status for missing files\n" ++
        "      --quiet           don't print OK for each successfully verified file\n" ++
        "      --status          don't output anything, status code shows success\n" ++
        "      --strict          exit non-zero for improperly formatted checksum lines\n" ++
        "  -w, --warn            warn about improperly formatted checksum lines\n\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n", .{name}) catch return 1;
    return if (cli.writeStdout(ctx.io, text)) 0 else 1;
}
