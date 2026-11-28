// SPDX-License-Identifier: GPL-2.0-or-later
//! tr library (decision 0004): translate, squeeze and/or delete characters.
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
//! with its last byte (GNU), or truncates string1 with `truncate`.
//! Behaviour and diagnostics were checked against GNU tr 9.7.
//!
//! Operand-count rules (how many strings the options need) belong to the
//! caller; the library takes `string1` and, when translating or when both
//! deleting and squeezing, `string2`.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Options = struct {
    complement: bool = false,
    delete: bool = false,
    squeeze: bool = false,
    truncate: bool = false,
};

/// A problem with the operand strings or the input. Warnings (the first two)
/// let the run continue; every other event ends it with `error.InvalidSpec`
/// (or `error.ReadFailed`). Slices are valid only during the callback.
pub const Event = union(enum) {
    /// An unescaped backslash at the end of a string (warning).
    trailing_backslash,
    /// An octal escape of more than 255 that is read as two bytes; the three
    /// digits (warning).
    ambiguous_octal: [3]u8,
    reverse_range: struct { lo: u8, hi: u8 },
    equiv_operand: []const u8,
    invalid_class: []const u8,
    invalid_repeat: []const u8,
    repeat_in_string1,
    several_fills,
    equiv_in_string2,
    /// When translating, string2 may only name the `upper` and `lower` classes.
    string2_classes,
    misaligned_case_class,
    string2_ends_with_class,
    empty_string2,
    read_failed: anyerror,
};

pub const Observer = common.Observer(Event);

pub const RunError = error{
    OutOfMemory,
    WriteFailed,
    /// An operand string is invalid; an event says why.
    InvalidSpec,
    /// Reading the input failed; an event carries the error.
    ReadFailed,
};

/// Filter `input` onto `writer`. `string2` is null with a single operand.
pub fn run(env: Env, options: Options, string1: []const u8, string2: ?[]const u8, input: Input, writer: *Io.Writer, observer: Observer) RunError!void {
    const complement = options.complement;
    const delete = options.delete;
    const squeeze = options.squeeze;
    const truncate = options.truncate;
    const translate = string2 != null and !delete;

    var arena_state = std.heap.ArenaAllocator.init(env.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items1 = parseSpec(observer, arena, string1) orelse return error.InvalidSpec;
    const items2: ?[]const Item = if (string2) |s2| (parseSpec(observer, arena, s2) orelse return error.InvalidSpec) else null;

    // string1 may not contain repeats; [=c=] and non-case classes are limited
    // in string2 when translating.
    for (items1) |it| if (it == .repeat and it.repeat.n == 0) {
        observer.emit(.repeat_in_string1);
        return error.InvalidSpec;
    };

    if (items2) |it2| {
        var fills: usize = 0;
        for (it2) |it| fills += @intFromBool(it == .repeat and it.repeat.n == 0);
        if (fills > 1) {
            observer.emit(.several_fills);
            return error.InvalidSpec;
        }
    }

    var set1 = try expand(arena, items1, std.math.maxInt(usize));
    if (complement) set1 = try complementOf(arena, set1);

    var table: [256]u8 = undefined;
    for (&table, 0..) |*t, i| t.* = @intCast(i);
    var delete_set: [256]bool = @splat(false);
    var squeeze_set: [256]bool = @splat(false);

    if (delete) for (set1) |c| {
        delete_set[c] = true;
    };

    if (translate) {
        const it2 = items2.?;
        if (!validateTranslate(observer, items1, it2, set1.len, complement)) return error.InvalidSpec;
        var set2 = expandFill(arena, it2, set1.len) orelse return error.OutOfMemory;
        var len1 = set1.len;
        if (truncate and len1 > set2.len) len1 = set2.len;
        if (set2.len == 0 and len1 > 0) {
            observer.emit(.empty_string2);
            return error.InvalidSpec;
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
            const s2 = expandFill(arena, it2, 0) orelse return error.OutOfMemory;
            for (s2) |c| squeeze_set[c] = true;
        } else for (set1) |c| {
            squeeze_set[c] = true;
        }
    }

    // Stream the input to the writer.
    var out = stickyout.Out.init(writer);
    const opened = input.open(env.io) catch |e| {
        observer.emit(.{ .read_failed = e });
        return error.ReadFailed;
    };
    defer opened.close(env.io);
    var inbuf: [64 * 1024]u8 = undefined;
    var prev: i16 = -1; // last byte written if it is in the squeeze set
    while (true) {
        const got = common.readChunk(env.io, opened.file, &inbuf) catch |e| {
            out.flush();
            observer.emit(.{ .read_failed = e });
            return error.ReadFailed;
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
    try out.finish();
}

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

/// Check the string2 constructs allowed when translating.
fn validateTranslate(ob: Observer, items1: []const Item, items2: []const Item, len1: usize, complement: bool) bool {
    // Offsets of the class constructs in string1 (uncomplemented positions).
    var off2: usize = 0;
    for (items2) |it2| {
        switch (it2) {
            .equiv => {
                ob.emit(.equiv_in_string2);
                return false;
            },
            .class => |c| {
                if (c != .lower and c != .upper) {
                    ob.emit(.string2_classes);
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
                    ob.emit(.misaligned_case_class);
                    return false;
                }
            },
            else => {},
        }
        off2 +|= itemLen(it2);
    }
    // A short string2 is padded with its last byte, which cannot be a class.
    if (items2.len > 0 and items2[items2.len - 1] == .class and off2 < len1) {
        ob.emit(.string2_ends_with_class);
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
const longest_repeat = 1 << 20;

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
                // STRING1 is uncapped, but is only used as a set and as
                // positions in a translation, for which a repeat longer than
                // this adds nothing (short of an equally huge one in STRING2).
                const want = @min(r.n, cap - list.items.len, longest_repeat);
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

fn parseSpec(ob: Observer, arena: std.mem.Allocator, text: []const u8) ?[]const Item {
    const toks = tokenize(ob, arena, text) orelse return null;
    var items: std.ArrayList(Item) = .empty;
    var i: usize = 0;
    while (i < toks.len) {
        const t = toks[i];
        if (t.b == '[' and !t.esc) {
            if (parseBracket(ob, toks, i)) |res| {
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
                ob.emit(.{ .reverse_range = .{ .lo = lo, .hi = hi } });
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
fn parseBracket(ob: Observer, toks: []const Token, i: usize) ?BracketResult {
    if (i + 1 >= toks.len) return .literal;
    const nx = toks[i + 1];
    if (nx.b == ':' and !nx.esc) {
        // find ":]"
        var j = i + 2;
        while (j + 1 < toks.len) : (j += 1) {
            if (toks[j].b == ':' and !toks[j].esc and toks[j + 1].b == ']' and !toks[j + 1].esc) {
                var name_buf: [16]u8 = undefined;
                const len = j - (i + 2);
                if (len > name_buf.len) return invalidClass(ob, toks[i + 2 .. j]);
                for (toks[i + 2 .. j], 0..) |t, k| name_buf[k] = t.b;
                const cls = std.meta.stringToEnum(Class, name_buf[0..len]) orelse return invalidClass(ob, toks[i + 2 .. j]);
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
                    ob.emit(.{ .equiv_operand = buf[0..n] });
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
                        ob.emit(.{ .invalid_repeat = buf[0..@min(digits.len, buf.len)] });
                        return .fail;
                    }
                    n = n *| (if (octal) @as(u64, 8) else 10) +| (d.b - '0');
                }
                // As in GNU, the count must be less than the largest one.
                if (n == std.math.maxInt(u64)) {
                    var buf: [64]u8 = undefined;
                    for (digits, 0..) |dd, k| buf[@min(k, buf.len - 1)] = dd.b;
                    ob.emit(.{ .invalid_repeat = buf[0..@min(digits.len, buf.len)] });
                    return .fail;
                }
            }
            return .{ .ok = .{ .item = .{ .repeat = .{ .c = nx.b, .n = n } }, .next = j + 1 } };
        }
    }
    return .literal;
}

fn invalidClass(ob: Observer, name: []const Token) BracketResult {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (name) |t| {
        if (n < buf.len) {
            buf[n] = t.b;
            n += 1;
        }
    }
    ob.emit(.{ .invalid_class = buf[0..n] });
    return .fail;
}

/// Turn backslash escapes into bytes marked as escaped (never special).
fn tokenize(ob: Observer, arena: std.mem.Allocator, text: []const u8) ?[]const Token {
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
            ob.emit(.trailing_backslash);
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
                ob.emit(.{ .ambiguous_octal = .{ text[i], text[i + 1], text[i + 2] } });
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


test "inClass counts" {
    try std.testing.expectEqual(@as(usize, 26), classLen(.lower));
    try std.testing.expectEqual(@as(usize, 10), classLen(.digit));
    try std.testing.expectEqual(@as(usize, 62), classLen(.alnum));
    try std.testing.expectEqual(@as(usize, 6), classLen(.space));
}
