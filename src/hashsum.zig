// SPDX-License-Identifier: GPL-2.0-or-later
//! Shared argument parsing and diagnostics of cksum, md5sum, sha1sum, sha224sum, sha256sum,
//! sha384sum, sha512sum and b2sum.
//! Thin wrapper over `util_core.hashsum` (decision 0004); the checksums, the
//! output formats and the verification are in src/lib/hashsum.zig.
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
const lib = @import("lib/hashsum.zig");

pub const Tool = lib.Tool;
const Config = lib.Options;

const alg_names = lib.alg_names;

const long_names = [_][]const u8{
    "algorithm", "base64", "binary", "check", "debug", "help", "ignore-missing", "length", "quiet", "raw", //  0-9
    "status", "strict", "tag", "text", "untagged", "version", "warn", "zero", //  10-17
    "json", //  18
};

pub fn main(ctx: cli.Context, tool: Tool) u8 {
    var cfg = Config.init(tool);
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
                17 => cfg.zero = true,
                else => cfg.json = true,
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

    if (cfg.json and (cfg.check or cfg.raw or cfg.base64 or cfg.tag or cfg.untagged or cfg.zero)) {
        cli.warn(ctx, "--json cannot be combined with --check, --raw, --base64, --tag, --untagged or --zero", .{});
        return 1;
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

    // Without operands, generating reads standard input unnamed; checking
    // names it "standard input" in diagnostics.
    var inputs: std.ArrayList(lib.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (files.items.len == 0) {
        const name: ?[]const u8 = if (cfg.check) "standard input" else null;
        inputs.append(ctx.gpa, .{ .name = name, .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (files.items) |path| {
        const is_stdin = std.mem.eql(u8, path, "-");
        const name: []const u8 = if (is_stdin and cfg.check) "standard input" else path;
        inputs.append(ctx.gpa, .{ .name = name, .source = if (is_stdin) .{ .file = Io.File.stdin() } else .{ .path = path } }) catch return oom(ctx);
    }

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    var sink: Sink = .{ .ctx = &ctx, .fw = &stdout };
    const observer: lib.Observer = .{ .context = &sink, .func = report };
    const env: lib.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = (if (cfg.check)
        lib.check(env, cfg, inputs.items, &stdout.interface, observer)
    else
        lib.generate(env, cfg, inputs.items, &stdout.interface, observer)) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.WriteFailed => {
            cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
            cli.warn(ctx, "write error", .{});
            return 1;
        },
    };
    if (!cli.flushWriter(&stdout)) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return if (result.failed) 1 else 0;
}

const Sink = struct { ctx: *const cli.Context, fw: *Io.File.Writer };

/// Word a library event as GNU does. Pending standard output goes first so
/// that stdout and stderr interleave in the order GNU produces them.
fn report(context: ?*anyopaque, ev: lib.Event) void {
    const sink: *Sink = @ptrCast(@alignCast(context.?));
    const ctx = sink.ctx.*;
    sink.fw.interface.flush() catch {};
    switch (ev) {
        .open_failed => |f| {
            // GNU opens a directory fine and fails when reading it.
            if (f.list and f.err == error.IsDir) cli.warn(ctx, "{f}: read error", .{cli.quote(f.name)}) else cli.warn(ctx, "{f}: {s}", .{ cli.quote(f.name), cli.errText(f.err) });
        },
        .read_failed => |f| {
            if (f.list) cli.warn(ctx, "{f}: read error", .{cli.quote(f.name)}) else cli.warn(ctx, "{f}: {s}", .{ cli.quote(f.name), cli.errText(f.err) });
        },
        .improper_line => |l| cli.warn(ctx, "{f}: {d}: improperly formatted {s} checksum line", .{ cli.quote(l.list), l.line, l.label }),
        .no_valid_lines => |n| cli.warn(ctx, "{f}: no properly formatted checksum lines found", .{cli.quote(n)}),
        .improper_total => |n| cli.warn(ctx, "WARNING: {d} {s} improperly formatted", .{ n, plural(n, "line is", "lines are") }),
        .unreadable_total => |n| cli.warn(ctx, "WARNING: {d} listed {s} could not be read", .{ n, plural(n, "file", "files") }),
        .mismatch_total => |n| cli.warn(ctx, "WARNING: {d} computed {s} did NOT match", .{ n, plural(n, "checksum", "checksums") }),
        .none_verified => |n| cli.warn(ctx, "{f}: no file was verified", .{cli.quote(n)}),
    }
}

fn plural(n: u64, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
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
        "      --json        print the result as JSON (not in GNU)\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n", .{name}) catch return 1;
    return if (cli.writeStdout(ctx.io, text)) 0 else 1;
}
