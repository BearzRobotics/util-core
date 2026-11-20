// SPDX-License-Identifier: GPL-2.0-or-later
//! cmp: thin wrapper over `util_core.cmp` (decision 0004). Parses arguments the
//! way GNU cmp does and words the diagnostics; the comparison and the report
//! are in src/lib/cmp.zig.
//! References: GNU diffutils manual "Invoking cmp" (3.12); POSIX.1-2024 cmp.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const cmp = @import("../lib/cmp.zig");

const help_text = @embedFile("../help/cmp.txt");
const json_id: u32 = 1100;

const Parsed = struct {
    ok: bool,
    val: u64 = 0,
    /// Index just after the number and its suffix.
    end: usize = 0,
    /// Something follows the number that is not a valid suffix.
    bad_suffix: bool = false,
};

/// GNU's xstrtoumax(s, &end, 0, &val, "kKMGTPEZY0"): decimal, octal or hex,
/// optional multiplier suffix; overflow saturates; a suffix alone means 1.
fn parseNumber(s: []const u8) Parsed {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    if (i < s.len and s[i] == '-') return .{ .ok = false };
    if (i < s.len and s[i] == '+') i += 1;
    var base: u8 = 10;
    if (i + 2 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X') and std.ascii.isHex(s[i + 2])) {
        base = 16;
        i += 2;
    } else if (i < s.len and s[i] == '0') base = 8;
    const start = i;
    var v: u128 = 0;
    var overflow = false;
    while (i < s.len) : (i += 1) {
        const d = std.fmt.charToDigit(s[i], base) catch break;
        v = v * base + d;
        if (v > std.math.maxInt(u64)) {
            overflow = true;
            v = std.math.maxInt(u64);
        }
    }
    if (i == start and base != 8) {
        // No digits: only a valid suffix letter makes this a number (1).
        if (i < s.len and std.mem.indexOfScalar(u8, "kKMGTPEZY", s[i]) != null) v = 1 else return .{ .ok = false };
    } else if (i == start) {
        if (i < s.len and std.mem.indexOfScalar(u8, "kKMGTPEZY", s[i]) != null) v = 1 else return .{ .ok = false };
    }
    var res: Parsed = .{ .ok = true, .val = @intCast(v), .end = i };
    if (i < s.len) {
        const c = s[i];
        if (std.mem.indexOfScalar(u8, "kKMGTPEZY", c) == null) {
            res.bad_suffix = true;
            return res;
        }
        var b: u128 = 1024;
        var used: usize = 1;
        if (i + 1 < s.len) switch (s[i + 1]) {
            'i' => if (i + 2 < s.len and s[i + 2] == 'B') {
                used = 3;
            },
            'B', 'D' => {
                b = 1000;
                used = 2;
            },
            else => {},
        };
        const power: u7 = switch (c) {
            'k', 'K' => 1,
            'M' => 2,
            'G' => 3,
            'T' => 4,
            'P' => 5,
            'E' => 6,
            'Z' => 7,
            else => 8,
        };
        var m: u128 = 1;
        var k: u7 = 0;
        while (k < power) : (k += 1) m *= b;
        const total = @as(u128, res.val) * m;
        if (overflow or total > std.math.maxInt(u64)) res.val = std.math.maxInt(u64) else res.val = @intCast(total);
        res.end = i + used;
        if (res.end < s.len) res.bad_suffix = true;
    } else if (overflow) res.val = std.math.maxInt(u64);
    return res;
}

fn tryHelp(ctx: cli.Context, comptime fmt: []const u8, args: anytype) u8 {
    cli.warn(ctx, fmt, args);
    cli.warn(ctx, "Try '{s} --help' for more information.", .{ctx.name});
    return 2;
}

/// -i value or SKIP operand: `text` may hold SKIP1:SKIP2 when `delim` is ':'.
/// Returns the text after the value on success, null when invalid.
fn specifyInitial(ctx: cli.Context, text: []const u8, delim: ?u8, skip: *[2]u64, which: usize) ?[]const u8 {
    const r = parseNumber(text);
    const at_delim = r.ok and r.end < text.len and delim != null and text[r.end] == delim.?;
    if (!r.ok or (r.end < text.len and !at_delim)) {
        _ = tryHelp(ctx, "invalid --ignore-initial value '{s}'", .{text});
        return null;
    }
    if (skip[which] < r.val) skip[which] = r.val;
    return text[r.end..];
}

pub fn main(ctx: cli.Context) u8 {
    var opts: cmp.Options = .{};
    var as_json = false;
    var l_seen = false;
    var s_seen = false;
    var parser = getopt.Parser.init(ctx, "bci:ln:sv", &.{
        .{ .name = "print-bytes", .id = 'b' },
        .{ .name = "print-chars", .id = 'c' },
        .{ .name = "ignore-initial", .arg = .required, .id = 'i' },
        .{ .name = "verbose", .id = 'l' },
        .{ .name = "bytes", .arg = .required, .id = 'n' },
        .{ .name = "quiet", .id = 's' },
        .{ .name = "silent", .id = 's' },
        .{ .name = "json", .id = json_id },
    });
    parser.ext_min = json_id;
    parser.try_prefix = true;
    defer parser.deinit();
    while (true) switch (parser.next()) {
        .done => break,
        .bad => return 2,
        .opt => |o| switch (o.id) {
            'b', 'c' => opts.print_bytes = true,
            'l' => l_seen = true,
            's' => s_seen = true,
            'i' => {
                const a = o.arg.?;
                const rest = specifyInitial(ctx, a, ':', &opts.skip, 0) orelse return 2;
                if (rest.len > 0 and rest[0] == ':') {
                    _ = specifyInitial(ctx, rest[1..], null, &opts.skip, 1) orelse return 2;
                } else opts.skip[1] = opts.skip[0];
            },
            'n' => {
                const r = parseNumber(o.arg.?);
                if (!r.ok or r.bad_suffix) return tryHelp(ctx, "invalid --bytes value '{s}'", .{o.arg.?});
                opts.limit = r.val;
            },
            json_id => as_json = true,
            'v', getopt.version_id => return if (cli.printVersion(ctx)) 0 else 2,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 2,
            else => unreachable,
        },
    };
    if (l_seen and s_seen) return tryHelp(ctx, "options -l and -s are incompatible", .{});
    if (as_json and (s_seen or opts.print_bytes)) {
        return tryHelp(ctx, "option --json is incompatible with {s}", .{if (s_seen) "-s" else "-b"});
    }
    opts.mode = if (l_seen) .all_diffs else if (s_seen) .status else .first_diff;

    const ops = parser.operands.items;
    if (ops.len == 0) {
        const last: []const u8 = if (ctx.args.len > 0) ctx.args[ctx.args.len - 1] else ctx.name;
        return tryHelp(ctx, "missing operand after '{s}'", .{last});
    }
    const f1 = ops[0];
    const f2: []const u8 = if (ops.len > 1) ops[1] else "-";
    if (ops.len > 2) {
        var skip = opts.skip;
        _ = specifyInitial(ctx, ops[2], 0, &skip, 0) orelse return 2;
        opts.skip[0] = skip[0];
        if (ops.len > 3) {
            _ = specifyInitial(ctx, ops[3], 0, &skip, 1) orelse return 2;
            opts.skip[1] = skip[1];
        }
        if (ops.len > 4) return tryHelp(ctx, "extra operand '{s}'", .{ops[4]});
    }

    const inputs: [2]cmp.Input = .{ mkInput(f1), mkInput(f2) };
    var buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    const env: cmp.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    var rep: Reporter = .{ .ctx = ctx, .opts = opts, .names = .{ f1, f2 } };
    const result = cmp.run(env, opts, inputs, if (as_json) .json else .text, &stdout.interface, .{
        .context = &rep,
        .func = Reporter.on,
    }) catch |e| switch (e) {
        error.OutOfMemory => {
            cli.warn(ctx, "memory exhausted", .{});
            return 2;
        },
        else => return writeFailed(ctx, &stdout),
    };
    stdout.interface.flush() catch return writeFailed(ctx, &stdout);
    return result.status;
}

fn writeFailed(ctx: cli.Context, stdout: *Io.File.Writer) u8 {
    cli.warn(ctx, "standard output: {s}", .{cli.errText(stdout.err orelse error.WriteFailed)});
    return 2;
}

fn mkInput(path: []const u8) cmp.Input {
    if (std.mem.eql(u8, path, "-")) return .{ .name = path, .source = .{ .file = Io.File.stdin() } };
    return .{ .name = path, .source = .{ .path = path } };
}

const Reporter = struct {
    ctx: cli.Context,
    opts: cmp.Options,
    names: [2][]const u8,

    fn on(context: ?*anyopaque, ev: cmp.Event) void {
        const r: *Reporter = @ptrCast(@alignCast(context.?));
        switch (ev) {
            .open_error => |e| if (r.opts.mode != .status) cli.warn(r.ctx, "{s}: {s}", .{ r.names[e.file], cli.errText(e.err) }),
            .read_error => |e| cli.warn(r.ctx, "{s}: {s}", .{ r.names[e.file], cli.errText(e.err) }),
            .eof => |e| {
                var buf: [4200]u8 = undefined;
                var w: Io.Writer = .fixed(&buf);
                cmp.writeEof(&w, r.opts, r.names, e) catch {};
                // GNU prints this one with a fixed "cmp: " prefix.
                cli.writeStderr(r.ctx, "cmp: {s}", .{w.buffered()});
            },
            else => {},
        }
    }
};
