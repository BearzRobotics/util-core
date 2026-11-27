// SPDX-License-Identifier: GPL-2.0-or-later
//! Shared library of cksum, md5sum, sha1sum, sha224sum, sha256sum, sha384sum,
//! sha512sum and b2sum: computing, printing and verifying checksums.
//! References: GNU coreutils manual (9.7) "cksum invocation", "md5sum
//! invocation", "b2sum invocation", "sha2 utilities"; POSIX.1-2024 cksum.
//!
//! Output formats (manual, "cksum output modes"):
//!   * legacy (cksum with crc/crc32b/sysv/bsd): "SUM BYTES [NAME]";
//!   * tagged:   "TAG (NAME) = DIGEST";
//!   * untagged: "DIGEST<space><mode>NAME", mode '*' (binary) or ' ' (text).
//! A file name containing backslash, newline or carriage return is escaped
//! (and the line starts with a backslash) unless `zero` is set.
//!
//! Extension: `Options.json` (one JSON object per input, see digestinfo.zig).
//! A name "-" inside a checksum list refers to standard input (GNU).

const std = @import("std");
const numparse = @import("../numparse.zig");
const Io = std.Io;
const common = @import("common.zig");
const hash = @import("../hash.zig");
const digestinfo = @import("../digestinfo.zig");

pub const Input = common.Input;
pub const Env = common.Env;

pub const Tool = enum { cksum, md5sum, sha1sum, sha224sum, sha256sum, sha384sum, sha512sum, b2sum };

pub const Options = struct {
    tool: Tool,
    algo: hash.Algo,
    /// The algorithm was chosen explicitly (cksum --algorithm).
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
    json: bool = false,

    /// The defaults of one command (its algorithm, its output form).
    pub fn init(tool: Tool) Options {
        return .{ .tool = tool, .algo = defaultAlgo(tool) };
    }

    fn standalone(c: Options) bool {
        return c.tool != .cksum;
    }
};

pub fn defaultAlgo(t: Tool) hash.Algo {
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

/// Algorithm names accepted by cksum --algorithm.
pub const alg_names = [_][]const u8{ "bsd", "sysv", "crc", "crc32b", "md5", "sha1", "sha224", "sha256", "sha384", "sha512", "blake2b", "sm3" };

/// A problem that does not end the run; the caller words it.
pub const Event = union(enum) {
    /// A file (or, with `list`, a checksum list) could not be opened.
    open_failed: Failure,
    /// Reading a file (or a checksum list) failed.
    read_failed: Failure,
    /// `check` only: line `line` of `list` is not a checksum line; `label` is
    /// the algorithm name GNU prints ("MD5", "BLAKE2b", "CRC", ...).
    improper_line: struct { list: []const u8, line: u64, label: []const u8 },
    /// `check` only: the list has no checksum line at all.
    no_valid_lines: []const u8,
    /// `check` only, per list: counts for the summary warnings (not sent when
    /// `Options.status` is set).
    improper_total: u64,
    unreadable_total: u64,
    mismatch_total: u64,
    /// `check` with `ignore_missing`: nothing in the list was verified.
    none_verified: []const u8,

    pub const Failure = struct {
        name: []const u8,
        err: anyerror,
        /// The file is a checksum list, not a file named by one.
        list: bool = false,
    };
};
pub const Observer = common.Observer(Event);

pub const Result = struct {
    /// True when the exit status must be 1 (a failure was reported).
    failed: bool = false,
};

pub const Error = Io.Writer.Error || std.mem.Allocator.Error;

// ------------------------------------------------------------- generating

/// The result of reading one input.
pub const Digest = struct {
    /// Digest bytes (modern algorithms).
    bytes: [hash.max_digest]u8 = undefined,
    len: usize = 0,
    /// Legacy: first and second number of the output line.
    n1: u64 = 0,
    n2: u64 = 0,
    bytes_read: u64 = 0,
};

/// Read `file` to the end and compute the checksum selected by `algo`.
pub fn compute(io: Io, algo: hash.Algo, length: usize, file: Io.File, buf: []u8) !Digest {
    var d: Digest = .{};
    switch (algo) {
        .crc => {
            var s: hash.PosixCrc = .{};
            while (true) {
                const n = try common.readChunk(io, file, buf);
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
                const n = try common.readChunk(io, file, buf);
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
                const n = try common.readChunk(io, file, buf);
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
                const n = try common.readChunk(io, file, buf);
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
                const n = try common.readChunk(io, file, buf);
                if (n == 0) break;
                h.update(buf[0..n]);
            }
            d.len = h.final(&d.bytes);
        },
    }
    return d;
}

/// Checksum every input and write one line (or JSON object, or raw digest)
/// per input to `out`. An input with `name == null` is standard input given
/// implicitly: legacy lines then carry no name and JSON has `"file":null`.
/// The caller flushes `out`.
pub fn generate(env: Env, o: Options, inputs: []const Input, out: *Io.Writer, observer: Observer) Error!Result {
    const buf = try env.gpa.alloc(u8, 128 * 1024);
    defer env.gpa.free(buf);
    var result: Result = .{};
    for (inputs) |in| {
        const shown = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            observer.emit(.{ .open_failed = .{ .name = shown, .err = e } });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        const d = compute(env.io, o.algo, o.length, opened.file, buf) catch |e| {
            observer.emit(.{ .read_failed = .{ .name = shown, .err = e } });
            result.failed = true;
            continue;
        };
        if (o.json) {
            const legacy = !o.algo.isDigest();
            try digestinfo.writeJson(out, .{
                .file = in.name,
                .algorithm = o.algo.name(),
                .digest = if (legacy) null else d.bytes[0..d.len],
                .checksum = if (legacy) d.n1 else null,
                .size = switch (o.algo) {
                    .crc, .crc32b => d.n2,
                    .bsd, .sysv => d.bytes_read,
                    else => null,
                },
                .blocks = switch (o.algo) {
                    .bsd, .sysv => d.n2,
                    else => null,
                },
            });
            continue;
        }
        if (o.raw) {
            try writeRaw(out, o.algo, d);
        } else if (!o.algo.isDigest()) {
            try writeLegacy(out, o, d, in.name);
        } else {
            try writeDigestLine(out, o, d, shown);
        }
    }
    return result;
}

fn writeRaw(out: *Io.Writer, algo: hash.Algo, d: Digest) Io.Writer.Error!void {
    if (algo.isDigest()) return out.writeAll(d.bytes[0..d.len]);
    // Big-endian number: crc/crc32b are 32 bit, bsd and sysv 16 bit.
    var b: [4]u8 = undefined;
    switch (algo) {
        .crc, .crc32b => {
            std.mem.writeInt(u32, &b, @intCast(d.n1), .big);
            try out.writeAll(&b);
        },
        else => {
            std.mem.writeInt(u16, b[0..2], @intCast(d.n1), .big);
            try out.writeAll(b[0..2]);
        },
    }
}

fn writeLegacy(out: *Io.Writer, o: Options, d: Digest, name: ?[]const u8) Io.Writer.Error!void {
    switch (o.algo) {
        .bsd => try out.print("{d:0>5} {d: >5}", .{ d.n1, d.n2 }),
        else => try out.print("{d} {d}", .{ d.n1, d.n2 }),
    }
    if (name) |n| {
        try out.writeByte(' ');
        try out.writeAll(n); // legacy lines never escape the name
    }
    try out.writeByte(if (o.zero) 0 else '\n');
}

fn writeDigestLine(out: *Io.Writer, o: Options, d: Digest, name: []const u8) Io.Writer.Error!void {
    const escape = !o.zero and needsEscape(name);
    const tagged = if (o.standalone()) o.tag else !o.untagged;
    if (escape) try out.writeByte('\\');
    if (tagged) {
        try out.writeAll(o.algo.tag());
        if (o.algo == .blake2b and d.len != 64) try out.print("-{d}", .{d.len * 8});
        try out.writeAll(" (");
        try writeName(out, name, !o.zero);
        try out.writeAll(") = ");
        try writeDigest(out, o, d);
    } else {
        try writeDigest(out, o, d);
        try out.writeByte(' ');
        try out.writeByte(if (o.binary) '*' else ' ');
        try writeName(out, name, !o.zero);
    }
    try out.writeByte(if (o.zero) 0 else '\n');
}

fn writeDigest(out: *Io.Writer, o: Options, d: Digest) Io.Writer.Error!void {
    if (o.base64) {
        var enc: [96]u8 = undefined;
        return out.writeAll(std.base64.standard.Encoder.encode(&enc, d.bytes[0..d.len]));
    }
    const hex = "0123456789abcdef";
    for (d.bytes[0..d.len]) |b| {
        try out.writeByte(hex[b >> 4]);
        try out.writeByte(hex[b & 15]);
    }
}

fn needsEscape(name: []const u8) bool {
    return std.mem.indexOfAny(u8, name, "\\\n\r") != null;
}

fn writeName(out: *Io.Writer, name: []const u8, escape: bool) Io.Writer.Error!void {
    if (!escape) return out.writeAll(name);
    for (name) |c| switch (c) {
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(c),
    };
}

// --------------------------------------------------------------- checking

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

/// Verify every checksum list in `lists`, writing "NAME: OK" / "NAME: FAILED"
/// lines to `out` unless `Options.status` is set. Listed files are opened
/// relative to the current directory ("-" is standard input). The caller
/// flushes `out`.
pub fn check(env: Env, o: Options, lists: []const Input, out: *Io.Writer, observer: Observer) Error!Result {
    const buf = try env.gpa.alloc(u8, 128 * 1024);
    defer env.gpa.free(buf);
    var result: Result = .{};
    for (lists) |list| {
        const shown = list.name orelse "-";
        const opened = list.open(env.io) catch |e| {
            observer.emit(.{ .open_failed = .{ .name = shown, .err = e, .list = true } });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        if (!try checkOne(env, o, out, opened.file, shown, buf, observer)) result.failed = true;
    }
    return result;
}

/// Verify one checksum list. Returns false when the exit status must be 1.
fn checkOne(env: Env, o: Options, out: *Io.Writer, list: Io.File, list_name: []const u8, buf: []u8, observer: Observer) Error!bool {
    var t: Totals = .{};
    var lineno: u64 = 0;
    var any_valid = false;
    var name_buf: std.ArrayList(u8) = .empty;
    defer name_buf.deinit(env.gpa);
    var label_algo = o.algo; // algorithm named in "improperly formatted" warnings
    // The list is verified as it is read.
    var batches: common.Batcher = .{};
    defer batches.deinit(env.gpa);
    var chunk: [16 * 1024]u8 = undefined;
    const from_stdin = list.handle == Io.File.stdin().handle;
    var at_end = false;
    while (!at_end) {
        // What is verified goes out before a read that may wait.
        try out.flush();
        const n = common.readChunk(env.io, list, &chunk) catch |e| {
            observer.emit(.{ .read_failed = .{ .name = list_name, .err = e, .list = true } });
            return false;
        };
        at_end = n == 0;
        const text = if (at_end) batches.rest() else try batches.add(env.gpa, chunk[0..n], "\n") orelse continue;
        var pos: usize = 0;
        while (pos < text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
            const end = nl orelse text.len;
            var raw = text[pos..end];
            pos = if (nl) |k| k + 1 else text.len;
            lineno += 1;
            // A list written on Windows ends its lines with CR LF. A name that
            // really ends in CR is written escaped, as "\r".
            if (std.mem.endsWith(u8, raw, "\r")) raw = raw[0 .. raw.len - 1];
            if (raw.len == 0 or raw[0] == '#') continue;
            var entry = parseLine(env.gpa, o, raw, &name_buf);
            // As in GNU, a list on standard input cannot name it: checking
            // that entry would read the rest of the list.
            if (entry) |p| if (from_stdin and std.mem.eql(u8, p.name, "-")) {
                entry = null;
            };
            const parsed = entry orelse {
                t.improper += 1;
                if (o.warn) observer.emit(.{ .improper_line = .{ .list = list_name, .line = lineno, .label = checkLabel(label_algo) } });
                continue;
            };
            any_valid = true;
            label_algo = parsed.algo;
            try verifyOne(env, o, out, parsed, &t, buf, observer);
        }
    }

    if (!any_valid) {
        observer.emit(.{ .no_valid_lines = list_name });
        return false;
    }
    if (!o.status) {
        if (t.improper > 0) observer.emit(.{ .improper_total = t.improper });
        if (t.unreadable > 0) observer.emit(.{ .unreadable_total = t.unreadable });
        if (t.mismatch > 0) observer.emit(.{ .mismatch_total = t.mismatch });
    }
    if (o.ignore_missing and t.ok == 0 and t.mismatch == 0 and t.unreadable == 0) {
        observer.emit(.{ .none_verified = list_name });
        return false;
    }
    if (t.mismatch > 0 or t.unreadable > 0) return false;
    if (o.strict and t.improper > 0) return false;
    return true;
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

fn verifyOne(env: Env, o: Options, out: *Io.Writer, ln: Line, t: *Totals, buf: []u8, observer: Observer) Io.Writer.Error!void {
    const in: Input = if (std.mem.eql(u8, ln.name, "-"))
        .{ .name = ln.name, .source = .{ .file = Io.File.stdin() } }
    else
        .{ .name = ln.name, .source = .{ .path = ln.name } };
    const opened = in.open(env.io) catch |e| {
        if (o.ignore_missing and e == error.FileNotFound) {
            t.missing += 1;
            return;
        }
        observer.emit(.{ .open_failed = .{ .name = ln.name, .err = e } });
        t.unreadable += 1;
        return printResult(out, o, ln.name, "FAILED open or read", true);
    };
    defer opened.close(env.io);
    const d = compute(env.io, ln.algo, ln.length, opened.file, buf) catch |e| {
        observer.emit(.{ .read_failed = .{ .name = ln.name, .err = e } });
        t.unreadable += 1;
        return printResult(out, o, ln.name, "FAILED open or read", true);
    };
    if (d.len == ln.length and std.mem.eql(u8, d.bytes[0..d.len], ln.digest[0..ln.length])) {
        t.ok += 1;
        try printResult(out, o, ln.name, "OK", false);
    } else {
        t.mismatch += 1;
        try printResult(out, o, ln.name, "FAILED", true);
    }
}

fn printResult(out: *Io.Writer, o: Options, name: []const u8, verdict: []const u8, failure: bool) Io.Writer.Error!void {
    if (o.status) return;
    if (!failure and o.quiet) return;
    if (needsEscape(name)) try out.writeByte('\\');
    try writeName(out, name, needsEscape(name));
    try out.writeAll(": ");
    try out.writeAll(verdict);
    try out.writeByte('\n');
}

/// Parse one line of a checksum list in any of the three formats.
fn parseLine(gpa: std.mem.Allocator, o: Options, raw: []const u8, name_buf: *std.ArrayList(u8)) ?Line {
    var s = raw;
    var escaped = false;
    if (s.len > 0 and s[0] == '\\') {
        escaped = true;
        s = s[1..];
    }
    var ln: Line = .{ .algo = o.algo, .length = 0, .digest = undefined, .name = "", .binary = false };
    var name_text: []const u8 = undefined;

    if (parseTagged(o, s, &ln, &name_text)) {
        // done
    } else if (parseUntagged(o, s, &ln, &name_text)) {
        // done
    } else return null;

    name_buf.clearRetainingCapacity();
    if (escaped) {
        var i: usize = 0;
        while (i < name_text.len) : (i += 1) {
            if (name_text[i] != '\\') {
                name_buf.append(gpa, name_text[i]) catch return null;
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
            name_buf.append(gpa, c) catch return null;
        }
        ln.name = name_buf.items;
    } else {
        ln.name = name_text;
    }
    return ln;
}

/// "TAG (NAME) = DIGEST", with the tag of the selected algorithm (any known
/// algorithm for cksum) and "BLAKE2b-BITS" for shortened BLAKE2b digests.
fn parseTagged(o: Options, s: []const u8, ln: *Line, name_out: *[]const u8) bool {
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
                const n = numparse.parseInt(usize, tag["BLAKE2b-".len..], 10) catch return false;
                if (n == 0 or n > 512 or n % 8 != 0) return false;
                algo = a;
                bits = n;
                found = true;
            }
        }
    }
    if (!found) return false;
    if (o.standalone() and algo != o.algo) return false;
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
fn parseUntagged(o: Options, s: []const u8, ln: *Line, name_out: *[]const u8) bool {
    const sp = std.mem.indexOfScalar(u8, s, ' ') orelse return false;
    const digest_text = s[0..sp];
    var rest = s[sp + 1 ..];
    if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '*')) {
        ln.binary = rest[0] == '*';
        rest = rest[1..];
    }
    if (rest.len == 0) return false;
    if (o.tool == .cksum and !o.algo_given) return false; // untagged lists need -a
    ln.algo = o.algo;
    if (!decodeDigest(digest_text, o.algo, null, ln)) return false;
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

// ------------------------------------------------------------------ tests

test "tagged and untagged lines parse and name escapes decode" {
    var nb: std.ArrayList(u8) = .empty;
    defer nb.deinit(std.testing.allocator);
    const o = Options.init(.md5sum);
    const ln = parseLine(std.testing.allocator, o, "d41d8cd98f00b204e9800998ecf8427e  a\\nb", &nb).?;
    try std.testing.expectEqualStrings("a\\nb", ln.name); // not escaped: no leading backslash
    const ln2 = parseLine(std.testing.allocator, o, "\\d41d8cd98f00b204e9800998ecf8427e  a\\nb", &nb).?;
    try std.testing.expectEqualStrings("a\nb", ln2.name);
    const ln3 = parseLine(std.testing.allocator, o, "MD5 (x) = d41d8cd98f00b204e9800998ecf8427e", &nb).?;
    try std.testing.expectEqualStrings("x", ln3.name);
    try std.testing.expect(parseLine(std.testing.allocator, o, "SHA1 (x) = d41d8cd98f00b204e9800998ecf8427e", &nb) == null);
}

test "digest lines: untagged, tagged, escaped, NUL-terminated" {
    var storage: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&storage);
    var d: Digest = .{};
    d.len = 16;
    @memset(d.bytes[0..16], 0xab);
    var o = Options.init(.md5sum);
    try writeDigestLine(&w, o, d, "f");
    o.tag = true;
    try writeDigestLine(&w, o, d, "a\nb");
    o.tag = false;
    o.zero = true;
    try writeDigestLine(&w, o, d, "z");
    const hex = "abababababababababababababababab";
    try std.testing.expectEqualStrings(
        hex ++ "  f\n\\MD5 (a\\nb) = " ++ hex ++ "\n" ++ hex ++ "  z\x00",
        w.buffered(),
    );
}

test "legacy lines" {
    var storage: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&storage);
    const d: Digest = .{ .n1 = 12, .n2 = 3 };
    var o = Options.init(.cksum);
    o.algo = .bsd;
    try writeLegacy(&w, o, d, "f");
    try writeLegacy(&w, o, d, null);
    try std.testing.expectEqualStrings("00012     3 f\n00012     3\n", w.buffered());
}
