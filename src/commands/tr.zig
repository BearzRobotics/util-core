// SPDX-License-Identifier: GPL-2.0-or-later
//! tr — translate, squeeze and/or delete characters.
//! References: GNU coreutils manual "tr invocation" (9.7); POSIX.1-2024 tr.
//!
//! Characters are bytes (the C locale), so classes, ranges and the
//! complement are defined over the 256 byte values in ascending order, like
//! `LC_ALL=C tr`. Multibyte locales and collation are not implemented.
//!
//! Operand strings are parsed into constructs: a byte, a range `a-z`, a class
//! `[:alpha:]`, an equivalence class `[=a=]` and, in string2 only, a repeat
//! `[c*n]`. Backslash escapes (\a \b \f \n \r \t \v \\ and 1-3 digit octal)
//! make the following character literal. Translation pads a short string2
//! with its last byte (GNU), or truncates string1 with -t.
//! Behaviour and diagnostics were checked against GNU tr 9.7.

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "complement", "delete", "squeeze-repeats", "truncate-set1", "help", "version" };

const Class = enum { alnum, alpha, blank, cntrl, digit, graph, lower, print, punct, space, upper, xdigit };

const Item = union(enum) {
    ch: u8,
    range: struct { lo: u8, hi: u8 },
    class: Class,
    equiv: u8,
    /// n == 0 means "fill to the length of string1".
    repeat: struct { c: u8, n: u64 },
};

const Token = struct { b: u8, esc: bool };

pub fn main(ctx: cli.Context) u8 {
    var complement = false;
    var delete = false;
    var squeeze = false;
    var truncate = false;
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);

    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        // A lone "-" and anything not starting with '-' are operands; so is
        // everything after "--".
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &long_names);
            switch (m) {
                .found => |k| switch (k) {
                    0 => complement = true,
                    1 => delete = true,
                    2 => squeeze = true,
                    3 => truncate = true,
                    4 => return help(ctx),
                    else => return if (cli.printVersion(ctx)) 0 else 1,
                },
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'c', 'C' => complement = true,
            'd' => delete = true,
            's' => squeeze = true,
            't' => truncate = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }

    // Operand count rules (diagnostics as GNU).
    const n = operands.items.len;
    const try_line = "Try '{s} --help' for more information.";
    if (n == 0) {
        cli.warn(ctx, "missing operand\n" ++ try_line, .{ctx.name});
        return 1;
    }
    if (n > 2 or (delete and !squeeze and n > 1)) {
        const extra = operands.items[if (delete and !squeeze) 1 else 2];
        if (delete and !squeeze and n == 2) {
            cli.warn(ctx, "extra operand '{s}'\nOnly one string may be given when deleting without squeezing repeats.\n" ++ try_line, .{ extra, ctx.name });
        } else cli.warn(ctx, "extra operand '{s}'\n" ++ try_line, .{ extra, ctx.name });
        return 1;
    }
    if (n == 1 and !delete and !squeeze) {
        cli.warn(ctx, "missing operand after '{s}'\nTwo strings must be given when translating.\n" ++ try_line, .{ operands.items[0], ctx.name });
        return 1;
    }
    if (n == 1 and delete and squeeze) {
        cli.warn(ctx, "missing operand after '{s}'\nTwo strings must be given when both deleting and squeezing repeats.\n" ++ try_line, .{ operands.items[0], ctx.name });
        return 1;
    }
    const translate = n == 2 and !delete;

    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items1 = parseSpec(ctx, arena, operands.items[0]) orelse return 1;
    const items2: ?[]const Item = if (n == 2) (parseSpec(ctx, arena, operands.items[1]) orelse return 1) else null;

    // string1 may not contain repeats; [=c=] and non-case classes are limited
    // in string2 when translating.
    for (items1) |it| if (it == .repeat and it.repeat.n == 0) {
        cli.warn(ctx, "the [c*] repeat construct may not appear in string1", .{});
        return 1;
    };

    if (items2) |it2| {
        var fills: usize = 0;
        for (it2) |it| fills += @intFromBool(it == .repeat and it.repeat.n == 0);
        if (fills > 1) {
            cli.warn(ctx, "only one [c*] repeat construct may appear in string2", .{});
            return 1;
        }
    }

    var set1 = expand(arena, items1, std.math.maxInt(usize)) catch return oom(ctx);
    if (complement) set1 = complementOf(arena, set1) catch return oom(ctx);

    var table: [256]u8 = undefined;
    for (&table, 0..) |*t, i| t.* = @intCast(i);
    var delete_set: [256]bool = @splat(false);
    var squeeze_set: [256]bool = @splat(false);

    if (delete) for (set1) |c| {
        delete_set[c] = true;
    };

    if (translate) {
        const it2 = items2.?;
        if (!validateTranslate(ctx, items1, it2, set1.len, complement)) return 1;
        var set2 = expandFill(arena, it2, set1.len) orelse return oom(ctx);
        var len1 = set1.len;
        if (truncate and len1 > set2.len) len1 = set2.len;
        if (set2.len == 0 and len1 > 0) {
            cli.warn(ctx, "when not truncating set1, string2 must be non-empty", .{});
            return 1;
        }
        for (set1[0..len1], 0..) |c, i| {
            table[c] = set2[@min(i, set2.len - 1)];
        }
        if (squeeze) {
            // Squeeze the characters of string2 (what translation produced).
            for (set2) |c| squeeze_set[c] = true;
        }
        set2 = &.{};
    } else if (squeeze) {
        if (items2) |it2| {
            // -d -s: delete string1, squeeze string2.
            const s2 = expandFill(arena, it2, 0) orelse return oom(ctx);
            for (s2) |c| squeeze_set[c] = true;
        } else for (set1) |c| {
            squeeze_set[c] = true;
        }
    }

    // Stream stdin to stdout.
    var out = cli.Out.init(ctx.io);
    const stdin = Io.File.stdin();
    var inbuf: [64 * 1024]u8 = undefined;
    var prev: i16 = -1; // last byte written if it is in the squeeze set
    while (true) {
        const got = cli.readChunk(ctx.io, stdin, &inbuf) catch |e| {
            out.flush();
            cli.warn(ctx, "read error: {s}", .{cli.errText(e)});
            return 1;
        };
        if (got == 0) break;
        // The result is built in place (never longer than the input) and
        // written once per chunk instead of once per byte.
        const chunk = inbuf[0..got];
        var kept: usize = 0;
        if (!delete and !squeeze) {
            for (chunk) |*b| b.* = table[b.*];
            kept = chunk.len;
        } else if (!squeeze) {
            // Branch-free compaction: always store, advance only when kept.
            for (chunk) |b| {
                chunk[kept] = table[b];
                kept += @intFromBool(!delete_set[b]);
            }
        } else {
            for (chunk) |b| {
                if (delete and delete_set[b]) continue;
                const c = table[b];
                if (squeeze_set[c]) {
                    if (prev == c) continue;
                    prev = c;
                } else prev = -1;
                chunk[kept] = c;
                kept += 1;
            }
        }
        out.write(chunk[0..kept]);
        if (out.failed) break;
    }
    out.flush();
    if (out.failed) {
        cli.writeErrorWarn(ctx);
        return 1;
    }
    return 0;
}

/// Check the string2 constructs allowed when translating.
fn validateTranslate(ctx: cli.Context, items1: []const Item, items2: []const Item, len1: usize, complement: bool) bool {
    // Offsets of the class constructs in string1 (uncomplemented positions).
    var off2: usize = 0;
    for (items2) |it2| {
        switch (it2) {
            .equiv => {
                cli.warn(ctx, "[=c=] expressions may not appear in string2 when translating", .{});
                return false;
            },
            .class => |c| {
                if (c != .lower and c != .upper) {
                    cli.warn(ctx, "when translating, the only character classes that may appear in\nstring2 are 'upper' and 'lower'", .{});
                    return false;
                }
                // The opposite class must start at the same position in string1.
                var off1: usize = 0;
                var aligned = false;
                if (complement) {
                    aligned = true;
                } else for (items1) |it1| {
                    if (off1 == off2) switch (it1) {
                        .class => |c1| aligned = (c1 == .lower and c == .upper) or (c1 == .upper and c == .lower),
                        else => {},
                    };
                    off1 +|= itemLen(it1);
                }
                if (!aligned) {
                    cli.warn(ctx, "misaligned [:upper:] and/or [:lower:] construct", .{});
                    return false;
                }
            },
            else => {},
        }
        off2 +|= itemLen(it2);
    }
    // A short string2 is padded with its last byte, which cannot be a class.
    if (items2.len > 0 and items2[items2.len - 1] == .class and off2 < len1) {
        cli.warn(ctx, "when translating with string1 longer than string2,\nthe latter string must not end with a character class", .{});
        return false;
    }
    return true;
}

fn itemLen(it: Item) usize {
    return switch (it) {
        .ch, .equiv => 1,
        .range => |r| @as(usize, r.hi) - r.lo + 1,
        .class => |c| classLen(c),
        .repeat => |r| @intCast(@min(r.n, std.math.maxInt(u32))),
    };
}

fn classLen(c: Class) usize {
    var n: usize = 0;
    for (0..256) |i| n += @intFromBool(inClass(c, @intCast(i)));
    return n;
}

fn inClass(c: Class, b: u8) bool {
    return switch (c) {
        .alnum => std.ascii.isAlphanumeric(b),
        .alpha => std.ascii.isAlphabetic(b),
        .blank => b == ' ' or b == '\t',
        .cntrl => b < 32 or b == 127,
        .digit => std.ascii.isDigit(b),
        .graph => b > 32 and b < 127,
        .lower => std.ascii.isLower(b),
        .print => b >= 32 and b < 127,
        .punct => b > 32 and b < 127 and !std.ascii.isAlphanumeric(b),
        .space => b == ' ' or (b >= 9 and b <= 13),
        .upper => std.ascii.isUpper(b),
        .xdigit => std.ascii.isHex(b),
    };
}

/// Expand constructs to bytes, at most `cap` of them. A fill repeat (`[c*]`,
/// n == 0) expands to nothing here; see expandFill.
fn expand(arena: std.mem.Allocator, items: []const Item, cap: usize) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    for (items) |it| {
        if (list.items.len >= cap) break;
        switch (it) {
            .ch, .equiv => |c| try list.append(arena, c),
            .range => |r| {
                var c: usize = r.lo;
                while (c <= r.hi) : (c += 1) try list.append(arena, @intCast(c));
            },
            .class => |cl| for (0..256) |i| {
                if (inClass(cl, @intCast(i))) try list.append(arena, @intCast(i));
            },
            .repeat => |r| {
                const want = @min(r.n, cap - list.items.len);
                try list.appendNTimes(arena, r.c, @intCast(want));
            },
        }
    }
    return list.items;
}

/// string2 for translation: like expand, but a fill repeat takes as many
/// copies as needed to reach `len1` bytes in total. Output is capped at len1
/// (later bytes are never used); with len1 == 0 (a set) repeats count once.
fn expandFill(arena: std.mem.Allocator, items: []const Item, len1: usize) ?[]u8 {
    var fixed: usize = 0;
    for (items) |it| if (!(it == .repeat and it.repeat.n == 0)) {
        fixed +|= itemLen(it);
    };
    var list: std.ArrayList(u8) = .empty;
    for (items) |it| {
        switch (it) {
            .ch, .equiv => |c| list.append(arena, c) catch return null,
            .range => |r| {
                var c: usize = r.lo;
                while (c <= r.hi) : (c += 1) list.append(arena, @intCast(c)) catch return null;
            },
            .class => |cl| for (0..256) |i| {
                if (inClass(cl, @intCast(i))) list.append(arena, @intCast(i)) catch return null;
            },
            .repeat => |r| {
                var count: usize = @intCast(@min(r.n, std.math.maxInt(u32)));
                if (r.n == 0) count = if (len1 > fixed) len1 - fixed else (if (len1 == 0) 1 else 0);
                if (len1 > 0) count = @min(count, if (len1 > list.items.len) len1 - list.items.len else 0);
                if (len1 == 0) count = @min(count, 1);
                list.appendNTimes(arena, r.c, count) catch return null;
            },
        }
        if (len1 > 0 and list.items.len >= len1 and it != .repeat) {
            // Remaining constructs cannot matter, except a fill repeat of 0 bytes.
        }
    }
    return list.items;
}

fn complementOf(arena: std.mem.Allocator, set: []const u8) ![]u8 {
    var present: [256]bool = @splat(false);
    for (set) |c| present[c] = true;
    var list: std.ArrayList(u8) = .empty;
    for (0..256) |i| if (!present[i]) try list.append(arena, @intCast(i));
    return list.items;
}

// ---------------------------------------------------------------------------
// Parsing

fn parseSpec(ctx: cli.Context, arena: std.mem.Allocator, text: []const u8) ?[]const Item {
    const toks = tokenize(ctx, arena, text) orelse return null;
    var items: std.ArrayList(Item) = .empty;
    var i: usize = 0;
    while (i < toks.len) {
        const t = toks[i];
        if (t.b == '[' and !t.esc) {
            if (parseBracket(ctx, toks, i)) |res| {
                switch (res) {
                    .fail => return null,
                    .ok => |ok| {
                        items.append(arena, ok.item) catch return null;
                        i = ok.next;
                        continue;
                    },
                    .literal => {},
                }
            }
        }
        // A range lo-hi when '-' (unescaped) follows and something follows it.
        if (i + 2 < toks.len and toks[i + 1].b == '-' and !toks[i + 1].esc) {
            const lo = t.b;
            const hi = toks[i + 2].b;
            if (hi < lo) {
                cli.warn(ctx, "range-endpoints of '{c}-{c}' are in reverse collating sequence order", .{ lo, hi });
                return null;
            }
            items.append(arena, .{ .range = .{ .lo = lo, .hi = hi } }) catch return null;
            i += 3;
            continue;
        }
        items.append(arena, .{ .ch = t.b }) catch return null;
        i += 1;
    }
    return items.items;
}

const BracketResult = union(enum) {
    ok: struct { item: Item, next: usize },
    literal,
    fail,
};

/// Try to read `[:class:]`, `[=c=]` or `[c*n]` starting at toks[i] == '['.
fn parseBracket(ctx: cli.Context, toks: []const Token, i: usize) ?BracketResult {
    if (i + 1 >= toks.len) return .literal;
    const nx = toks[i + 1];
    if (nx.b == ':' and !nx.esc) {
        // find ":]"
        var j = i + 2;
        while (j + 1 < toks.len) : (j += 1) {
            if (toks[j].b == ':' and !toks[j].esc and toks[j + 1].b == ']' and !toks[j + 1].esc) {
                var name_buf: [16]u8 = undefined;
                const len = j - (i + 2);
                if (len > name_buf.len) return invalidClass(ctx, toks[i + 2 .. j]);
                for (toks[i + 2 .. j], 0..) |t, k| name_buf[k] = t.b;
                const cls = std.meta.stringToEnum(Class, name_buf[0..len]) orelse return invalidClass(ctx, toks[i + 2 .. j]);
                return .{ .ok = .{ .item = .{ .class = cls }, .next = j + 2 } };
            }
        }
        return .literal;
    }
    if (nx.b == '=' and !nx.esc) {
        var j = i + 2;
        while (j + 1 < toks.len) : (j += 1) {
            if (toks[j].b == '=' and !toks[j].esc and toks[j + 1].b == ']' and !toks[j + 1].esc) {
                if (j - (i + 2) != 1) {
                    var buf: [64]u8 = undefined;
                    var n: usize = 0;
                    for (toks[i + 2 .. j]) |t| {
                        if (n < buf.len) {
                            buf[n] = t.b;
                            n += 1;
                        }
                    }
                    cli.warn(ctx, "{s}: equivalence class operand must be a single character", .{buf[0..n]});
                    return .fail;
                }
                return .{ .ok = .{ .item = .{ .equiv = toks[i + 2].b }, .next = j + 2 } };
            }
        }
        return .literal;
    }
    // [c*n]
    if (i + 3 < toks.len + 0 and toks[i + 2].b == '*' and !toks[i + 2].esc) {
        var j = i + 3;
        while (j < toks.len and !toks[j].esc and std.ascii.isDigit(toks[j].b)) j += 1;
        if (j < toks.len and toks[j].b == ']' and !toks[j].esc) {
            var n: u64 = 0;
            const digits = toks[i + 3 .. j];
            if (digits.len > 0) {
                const octal = digits[0].b == '0';
                for (digits) |d| {
                    if (octal and d.b > '7') {
                        var buf: [32]u8 = undefined;
                        for (digits, 0..) |dd, k| buf[@min(k, buf.len - 1)] = dd.b;
                        cli.warn(ctx, "invalid repeat count '{s}' in [c*n] construct", .{buf[0..@min(digits.len, buf.len)]});
                        return .fail;
                    }
                    n = n *| (if (octal) @as(u64, 8) else 10) +| (d.b - '0');
                }
            }
            return .{ .ok = .{ .item = .{ .repeat = .{ .c = nx.b, .n = n } }, .next = j + 1 } };
        }
    }
    return .literal;
}

fn invalidClass(ctx: cli.Context, name: []const Token) BracketResult {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (name) |t| {
        if (n < buf.len) {
            buf[n] = t.b;
            n += 1;
        }
    }
    cli.warn(ctx, "invalid character class '{s}'", .{buf[0..n]});
    return .fail;
}

/// Turn backslash escapes into bytes marked as escaped (never special).
fn tokenize(ctx: cli.Context, arena: std.mem.Allocator, text: []const u8) ?[]const Token {
    var list: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c != '\\') {
            list.append(arena, .{ .b = c, .esc = false }) catch return null;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) {
            cli.warn(ctx, "warning: an unescaped backslash at end of string is not portable", .{});
            list.append(arena, .{ .b = '\\', .esc = true }) catch return null;
            break;
        }
        const e = text[i];
        if (e >= '0' and e <= '7') {
            var v: u32 = 0;
            var k: usize = 0;
            while (k < 3 and i + k < text.len and text[i + k] >= '0' and text[i + k] <= '7') : (k += 1) v = v * 8 + (text[i + k] - '0');
            if (v > 255) {
                // GNU: only the first two digits form the byte; warn.
                const two = (text[i] - '0') * 8 + (text[i + 1] - '0');
                cli.warn(ctx, "warning: the ambiguous octal escape \\{s} is being\n\tinterpreted as the 2-byte sequence \\0{c}{c}, {c}", .{ text[i .. i + 3], text[i], text[i + 1], text[i + 2] });
                list.append(arena, .{ .b = two, .esc = true }) catch return null;
                list.append(arena, .{ .b = text[i + 2], .esc = true }) catch return null;
                i += 3;
                continue;
            }
            list.append(arena, .{ .b = @intCast(v), .esc = true }) catch return null;
            i += k;
            continue;
        }
        const b: u8 = switch (e) {
            'a' => 7,
            'b' => 8,
            'f' => 12,
            'n' => 10,
            'r' => 13,
            't' => 9,
            'v' => 11,
            else => e,
        };
        list.append(arena, .{ .b = b, .esc = true }) catch return null;
        i += 1;
    }
    return list.items;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: tr [OPTION]... STRING1 [STRING2]\n" ++
        "Translate, squeeze, and/or delete characters from standard input,\n" ++
        "writing to standard output.\n\n" ++
        "  -c, -C, --complement    use the complement of STRING1\n" ++
        "  -d, --delete            delete characters in STRING1, do not translate\n" ++
        "  -s, --squeeze-repeats   replace each sequence of a repeated character\n" ++
        "                            that is listed in the last STRING, with a\n" ++
        "                            single occurrence of that character\n" ++
        "  -t, --truncate-set1     first truncate STRING1 to length of STRING2\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}

test "inClass counts" {
    try std.testing.expectEqual(@as(usize, 26), classLen(.lower));
    try std.testing.expectEqual(@as(usize, 10), classLen(.digit));
    try std.testing.expectEqual(@as(usize, 62), classLen(.alnum));
    try std.testing.expectEqual(@as(usize, 6), classLen(.space));
}
