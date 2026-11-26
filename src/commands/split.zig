// SPDX-License-Identifier: GPL-2.0-or-later
//! split: thin wrapper over `util_core.split` (decision 0004). Parses
//! arguments the way GNU split does and words the diagnostics; the splitting,
//! suffix sequence and --filter handling are in src/lib/split.zig.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const count_arg = @import("../count_arg.zig");
const split = @import("../lib/split.zig");
const sys = @import("../sys.zig");
const Io = std.Io;

const help_text = @embedFile("../help/split.txt");

const Mode = split.Mode;

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


    const input: split.Input = if (std.mem.eql(u8, infile, "-"))
        .{ .name = infile, .source = .{ .file = Io.File.stdin() } }
    else
        .{ .name = infile, .source = .{ .path = infile } };
    const opts: split.Options = .{
        .mode = mode.?,
        .size = size,
        .chunks = chunks,
        .chunk_k = chunk_k,
        .separator = sep,
        .prefix = prefix,
        .additional_suffix = additional,
        .suffix_kind = if (hex) .hex else if (numeric) .numeric else .alpha,
        .suffix_length = suffix_len,
        .suffix_start = numeric_start,
        .elide_empty = elide,
        .filter = filter,
        .unbuffered = unbuffered,
        .verbose = verbose,
    };

    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: split.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const result = split.run(env, opts, input, &stdout.interface, .{ .context = @constCast(&ctx), .func = report });
    if (result.stdout_failed) cli.noteStdoutFailure(cli.errText(stdout.err orelse error.WriteFailed));
    if (result.filter_status != 0) return result.filter_status;
    return if (result.failed) 1 else 0;
}


fn report(context: ?*anyopaque, ev: split.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .creating_file => |name| {
            var b: [4096]u8 = undefined;
            const m = std.fmt.bufPrint(&b, "creating file {f}\n", .{cli.quoteA(name)}) catch "";
            _ = cli.writeStdout(ctx.io, m);
        },
        .suffixes_exhausted => cli.warn(ctx.*, "output file suffixes exhausted", .{}),
        .suffix_length_too_small => |need| cli.warn(ctx.*, "the suffix length needs to be at least {d}", .{need}),
        .suffix_start_too_large => {
            getopt.usageError(ctx.*, "numerical suffix start value is too large for the suffix length", .{});
        },
        .suffix_start_invalid => |ns| {
            getopt.usageError(ctx.*, "{f}: invalid start value for numerical suffix", .{cli.quoteC(ns)});
        },
        .open_input => |e| {
            if (e.err == error.IsDir)
                cli.warn(ctx.*, "{f}: Is a directory", .{cli.quote(e.name)})
            else
                cli.warn(ctx.*, "cannot open {f} for reading: {s}", .{ cli.quoteA(e.name), cli.errText(e.err) });
        },
        .spawn_failed => |e| cli.warn(ctx.*, "failed to run command: \"{s} -c {s}\": {s}", .{ e.shell, e.command, cli.errText(e.err) }),
        .create_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .reopen_failed => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), sys.errnoText(e.errno) }),
        .would_overwrite => |name| cli.warn(ctx.*, "{f} would overwrite input; aborting", .{cli.quoteA(name)}),
        .filter_exit => |e| cli.warn(ctx.*, "with FILE={s}, exit {d} from command: {s}", .{ e.file, e.code, e.command }),
        .filter_signal => |e| cli.warn(ctx.*, "with FILE={s}, signal {d} from command: {s}", .{ e.file, e.signal, e.command }),
        .write_error => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
        .close_error => |e| cli.warn(ctx.*, "{f}: {s}", .{ cli.quote(e.name), sys.errnoText(e.errno) }),
        .out_of_memory => cli.warn(ctx.*, "memory exhausted", .{}),
        .read_error => |e| cli.warn(ctx.*, "read error: {s}", .{cli.errText(e)}),
        .cannot_determine_size => |e| cli.warn(ctx.*, "{f}: cannot determine file size: {s}", .{ cli.quote(e.name), cli.errText(e.err) }),
    }
}
