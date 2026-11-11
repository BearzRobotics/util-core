// SPDX-License-Identifier: GPL-2.0-or-later
//! fmt — simple optimal text formatter.
//! Reference: GNU coreutils manual "fmt invocation" (9.7); POSIX does not
//! specify fmt. The paragraph-filling algorithm (a dynamic-programming search
//! for the cheapest set of line breaks, with penalties for ragged lines,
//! widows, orphans and breaks after punctuation) is the one documented in the
//! comments of GNU fmt.c (coreutils 9.6 source, consulted 2026-11-07); its
//! constants are part of the observable behaviour and are reproduced so that
//! output is identical, including the 1000-word / 5000-character paragraph
//! chunking.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const Io = std.Io;

const help_text = @embedFile("../help/fmt.txt");

const Cost = i64;
const max_cost: Cost = std.math.maxInt(i64);

fn sqr(n: Cost) Cost {
    return n * n;
}
fn shortCost(n: i64) Cost {
    return sqr(n * 10);
}
fn raggedCost(n: i64) Cost {
    return @divTrunc(shortCost(n), 2);
}
const line_cost_const: Cost = sqr(70);
fn widowCost(n: i64) Cost {
    return @divTrunc(sqr(200), n + 2);
}
fn orphanCost(n: i64) Cost {
    return @divTrunc(sqr(150), n + 2);
}
const sentence_bonus: Cost = sqr(50);
const nobreak_cost: Cost = sqr(600);
const paren_bonus: Cost = sqr(40);
const punct_bonus: Cost = sqr(40);
const line_credit: Cost = sqr(3);

const max_words = 1000;
const max_chars = 5000;
const tab_width = 8;
const default_width = 75;
const leeway = 7;
const def_indent = 3;
const eof: i32 = -1;

const Word = struct {
    text: usize = 0,
    length: i64 = 0,
    space: i64 = 0,
    paren: bool = false,
    period: bool = false,
    punct: bool = false,
    final: bool = false,
    line_length: i64 = 0,
    best_cost: Cost = 0,
    next_break: usize = 0,
};

const Fmt = struct {
    ctx: cli.Context,
    out: cli.Out,
    // options
    crown: bool = false,
    tagged: bool = false,
    split: bool = false,
    uniform: bool = false,
    prefix: []const u8 = "",
    max_width: i64 = default_width,
    goal_width: i64 = 0,
    prefix_full_length: i64 = 0,
    prefix_lead_space: i64 = 0,
    prefix_length: i64 = 0,
    // state
    data: []const u8 = "",
    pos: usize = 0,
    in_column: i64 = 0,
    out_column: i64 = 0,
    parabuf: [max_chars]u8 = undefined,
    wptr: usize = 0,
    word: [max_words]Word = undefined,
    word_limit: usize = 0,
    tabs: bool = false,
    prefix_indent: i64 = 0,
    first_indent: i64 = 0,
    other_indent: i64 = 0,
    next_char: i32 = 0,
    next_prefix_indent: i64 = 0,
    last_line_length: i64 = 0,

    fn getc(f: *Fmt) i32 {
        if (f.pos >= f.data.len) return eof;
        const c = f.data[f.pos];
        f.pos += 1;
        return c;
    }

    fn putchar(f: *Fmt, c: u8) void {
        f.out.writeByte(c);
    }

    fn setPrefix(f: *Fmt, p: []const u8) void {
        var s = p;
        f.prefix_lead_space = 0;
        while (s.len > 0 and s[0] == ' ') {
            f.prefix_lead_space += 1;
            s = s[1..];
        }
        f.prefix_full_length = @intCast(s.len);
        var e = s.len;
        while (e > 0 and s[e - 1] == ' ') e -= 1;
        f.prefix = s[0..e];
        f.prefix_length = @intCast(e);
    }

    fn run(f: *Fmt, data: []const u8) void {
        f.data = data;
        f.pos = 0;
        f.tabs = false;
        f.other_indent = 0;
        f.next_char = f.getPrefix();
        while (f.getParagraph()) {
            f.fmtParagraph();
            f.putParagraph(f.word_limit);
        }
    }

    fn setOtherIndent(f: *Fmt, same_paragraph: bool) void {
        if (f.split) {
            f.other_indent = f.first_indent;
        } else if (f.crown) {
            f.other_indent = if (same_paragraph) f.in_column else f.first_indent;
        } else if (f.tagged) {
            if (same_paragraph and f.in_column != f.first_indent) {
                f.other_indent = f.in_column;
            } else if (f.other_indent == f.first_indent) {
                f.other_indent = if (f.first_indent == 0) def_indent else 0;
            }
        } else {
            f.other_indent = f.first_indent;
        }
    }

    fn getParagraph(f: *Fmt) bool {
        f.last_line_length = 0;
        var c = f.next_char;
        while (c == '\n' or c == eof or f.next_prefix_indent < f.prefix_lead_space or f.in_column < f.next_prefix_indent + f.prefix_full_length) {
            c = f.copyRest(c);
            if (c == eof) {
                f.next_char = eof;
                return false;
            }
            f.putchar('\n');
            c = f.getPrefix();
        }
        f.prefix_indent = f.next_prefix_indent;
        f.first_indent = f.in_column;
        f.wptr = 0;
        f.word_limit = 0;
        c = f.getLine(c);
        f.setOtherIndent(f.samePara(c));
        if (f.split) {
            // one line only
        } else if (f.crown) {
            if (f.samePara(c)) {
                while (true) {
                    c = f.getLine(c);
                    if (!(f.samePara(c) and f.in_column == f.other_indent)) break;
                }
            }
        } else if (f.tagged) {
            if (f.samePara(c) and f.in_column != f.first_indent) {
                while (true) {
                    c = f.getLine(c);
                    if (!(f.samePara(c) and f.in_column == f.other_indent)) break;
                }
            }
        } else {
            while (f.samePara(c) and f.in_column == f.other_indent) c = f.getLine(c);
        }
        f.word[f.word_limit - 1].period = true;
        f.word[f.word_limit - 1].final = true;
        f.next_char = c;
        return true;
    }

    fn copyRest(f: *Fmt, c0: i32) i32 {
        var c = c0;
        f.out_column = 0;
        if (f.in_column > f.next_prefix_indent or (c != '\n' and c != eof)) {
            f.putSpace(f.next_prefix_indent);
            var i: usize = 0;
            while (f.out_column != f.in_column and i < f.prefix.len) : (f.out_column += 1) {
                f.putchar(f.prefix[i]);
                i += 1;
            }
            if (c != eof and c != '\n') f.putSpace(f.in_column - f.out_column);
            if (c == eof and f.in_column >= f.next_prefix_indent + f.prefix_length) f.putchar('\n');
        }
        while (c != '\n' and c != eof) {
            f.putchar(@intCast(c));
            c = f.getc();
        }
        return c;
    }

    fn samePara(f: *const Fmt, c: i32) bool {
        return f.next_prefix_indent == f.prefix_indent and
            f.in_column >= f.next_prefix_indent + f.prefix_full_length and
            c != '\n' and c != eof;
    }

    fn isSpace(c: i32) bool {
        return c == ' ' or (c >= 9 and c <= 13);
    }

    fn getLine(f: *Fmt, c0: i32) i32 {
        var c = c0;
        const end_of_word = max_words - 2;
        while (true) {
            const w = f.word_limit;
            f.word[w] = .{};
            f.word[w].text = f.wptr;
            while (true) {
                if (f.wptr == max_chars) {
                    f.setOtherIndent(true);
                    f.flushParagraph();
                }
                f.parabuf[f.wptr] = @intCast(c);
                f.wptr += 1;
                c = f.getc();
                if (c == eof or isSpace(c)) break;
            }
            const wl = f.word_limit;
            f.word[wl].length = @intCast(f.wptr - f.word[wl].text);
            f.in_column += f.word[wl].length;
            f.checkPunctuation(wl);
            const start = f.in_column;
            c = f.getSpace(c);
            f.word[wl].space = f.in_column - start;
            f.word[wl].final = c == eof or (f.word[wl].period and (c == '\n' or f.word[wl].space > 1));
            if (c == '\n' or c == eof or f.uniform) f.word[wl].space = if (f.word[wl].final) 2 else 1;
            if (f.word_limit == end_of_word) {
                f.setOtherIndent(true);
                f.flushParagraph();
            }
            f.word_limit += 1;
            if (c == '\n' or c == eof) break;
        }
        return f.getPrefix();
    }

    fn getPrefix(f: *Fmt) i32 {
        f.in_column = 0;
        var c = f.getSpace(f.getc());
        if (f.prefix_length == 0) {
            f.next_prefix_indent = if (f.prefix_lead_space < f.in_column) f.prefix_lead_space else f.in_column;
        } else {
            f.next_prefix_indent = f.in_column;
            for (f.prefix) |pc| {
                if (c != pc) return c;
                f.in_column += 1;
                c = f.getc();
            }
            c = f.getSpace(c);
        }
        return c;
    }

    fn getSpace(f: *Fmt, c0: i32) i32 {
        var c = c0;
        while (true) {
            if (c == ' ') {
                f.in_column += 1;
            } else if (c == '\t') {
                f.tabs = true;
                f.in_column = @divTrunc(f.in_column, tab_width) * tab_width + tab_width;
            } else return c;
            c = f.getc();
        }
    }

    fn checkPunctuation(f: *Fmt, wi: usize) void {
        const w = &f.word[wi];
        const text = f.parabuf[w.text .. w.text + @as(usize, @intCast(w.length))];
        const first = text[0];
        var last_i: usize = text.len - 1;
        const fin = text[last_i];
        w.paren = std.mem.indexOfScalar(u8, "(['`\"", first) != null;
        w.punct = std.ascii.isPrint(fin) and !std.ascii.isAlphanumeric(fin) and fin != ' ';
        while (last_i > 0 and std.mem.indexOfScalar(u8, ")]'\"", text[last_i]) != null) last_i -= 1;
        w.period = std.mem.indexOfScalar(u8, ".?!", text[last_i]) != null;
    }

    fn flushParagraph(f: *Fmt) void {
        if (f.word_limit == 0) {
            f.out.write(f.parabuf[0..f.wptr]);
            f.wptr = 0;
            return;
        }
        f.fmtParagraph();
        var split_point = f.word_limit;
        var best_break: Cost = max_cost;
        var w = f.word[0].next_break;
        while (w != f.word_limit) : (w = f.word[w].next_break) {
            const d = f.word[w].best_cost - f.word[f.word[w].next_break].best_cost;
            if (d < best_break) {
                split_point = w;
                best_break = d;
            }
            if (best_break <= max_cost - line_credit) best_break += line_credit;
        }
        f.putParagraph(split_point);
        const src = f.word[split_point].text;
        std.mem.copyForwards(u8, f.parabuf[0 .. f.wptr - src], f.parabuf[src..f.wptr]);
        const shift = src;
        f.wptr -= shift;
        var i = split_point;
        while (i <= f.word_limit) : (i += 1) f.word[i].text -= shift;
        const n = f.word_limit - split_point + 1;
        std.mem.copyForwards(Word, f.word[0..n], f.word[split_point .. split_point + n]);
        f.word_limit -= split_point;
        // next_break indexes are relative to the old array: rebased by fmtParagraph on next use.
    }

    fn baseCost(f: *const Fmt, this: usize) Cost {
        var cost: Cost = line_cost_const;
        if (this > 0) {
            const prev = f.word[this - 1];
            if (prev.period) {
                if (prev.final) cost -= sentence_bonus else cost += nobreak_cost;
            } else if (prev.punct) {
                cost -= punct_bonus;
            } else if (this > 1 and f.word[this - 2].final) {
                cost += widowCost(prev.length);
            }
        }
        if (f.word[this].paren) {
            cost -= paren_bonus;
        } else if (f.word[this].final) {
            cost += orphanCost(f.word[this].length);
        }
        return cost;
    }

    fn lineCost(f: *const Fmt, next: usize, len: i64) Cost {
        if (next == f.word_limit) return 0;
        var n = f.goal_width - len;
        var cost = shortCost(n);
        if (f.word[next].next_break != f.word_limit) {
            n = len - f.word[next].line_length;
            cost += raggedCost(n);
        }
        return cost;
    }

    fn fmtParagraph(f: *Fmt) void {
        f.word[f.word_limit].best_cost = 0;
        const saved_length = f.word[f.word_limit].length;
        f.word[f.word_limit].length = f.max_width; // sentinel
        var start = f.word_limit;
        while (start > 0) {
            start -= 1;
            var best: Cost = max_cost;
            var len: i64 = if (start == 0) f.first_indent else f.other_indent;
            var w = start;
            len += f.word[w].length;
            while (true) {
                w += 1;
                var wcost = f.lineCost(w, len) + f.word[w].best_cost;
                if (start == 0 and f.last_line_length > 0) wcost += raggedCost(len - f.last_line_length);
                if (wcost < best) {
                    best = wcost;
                    f.word[start].next_break = w;
                    f.word[start].line_length = len;
                }
                if (w == f.word_limit) break;
                len += f.word[w - 1].space + f.word[w].length;
                if (len >= f.max_width) break;
            }
            f.word[start].best_cost = best + f.baseCost(start);
        }
        f.word[f.word_limit].length = saved_length;
    }

    fn putParagraph(f: *Fmt, finish: usize) void {
        f.putLine(0, f.first_indent);
        var w = f.word[0].next_break;
        while (w != finish) : (w = f.word[w].next_break) f.putLine(w, f.other_indent);
    }

    fn putLine(f: *Fmt, w0: usize, indent: i64) void {
        f.out_column = 0;
        f.putSpace(f.prefix_indent);
        f.out.write(f.prefix);
        f.out_column += f.prefix_length;
        f.putSpace(indent - f.out_column);
        const endline = f.word[w0].next_break - 1;
        var w = w0;
        while (w != endline) : (w += 1) {
            f.putWord(w);
            f.putSpace(f.word[w].space);
        }
        f.putWord(w);
        f.last_line_length = f.out_column;
        f.putchar('\n');
    }

    fn putWord(f: *Fmt, w: usize) void {
        const wd = f.word[w];
        f.out.write(f.parabuf[wd.text .. wd.text + @as(usize, @intCast(wd.length))]);
        f.out_column += wd.length;
    }

    fn putSpace(f: *Fmt, space: i64) void {
        const space_target = f.out_column + space;
        if (f.tabs) {
            const tab_target = @divTrunc(space_target, tab_width) * tab_width;
            if (f.out_column + 1 < tab_target) {
                while (f.out_column < tab_target) {
                    f.putchar('\t');
                    f.out_column = @divTrunc(f.out_column, tab_width) * tab_width + tab_width;
                }
            }
        }
        while (f.out_column < space_target) {
            f.putchar(' ');
            f.out_column += 1;
        }
    }
};

const WidthError = error{ invalid, range };

fn parseWidth(text: []const u8, max: u64) WidthError!u64 {
    if (text.len > 0 and text[0] == '-') return error.invalid;
    const v = std.fmt.parseInt(u64, text, 10) catch |e| return if (e == error.Overflow) error.range else error.invalid;
    if (v > max) return error.range;
    return v;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var width_opt: ?[]const u8 = null;
    var goal_opt: ?[]const u8 = null;
    var args = ctx.args;
    if (args.len > 0 and args[0].len >= 2 and args[0][0] == '-' and std.ascii.isDigit(args[0][1])) {
        width_opt = args[0][1..];
        args = args[1..];
    }
    var c2 = ctx;
    c2.args = args;

    const f = gpa.create(Fmt) catch return 1;
    defer gpa.destroy(f);
    f.* = .{ .ctx = ctx, .out = cli.Out.init(ctx.io) };
    var prefix_arg: ?[]const u8 = null;

    var p = getopt.Parser.init(c2, "0123456789cstuw:p:g:", &.{
        .{ .name = "crown-margin", .id = 'c' },
        .{ .name = "prefix", .arg = .required, .id = 'p' },
        .{ .name = "split-only", .id = 's' },
        .{ .name = "tagged-paragraph", .id = 't' },
        .{ .name = "uniform-spacing", .id = 'u' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "goal", .arg = .required, .id = 'g' },
    });
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'c' => f.crown = true,
            's' => f.split = true,
            't' => f.tagged = true,
            'u' => f.uniform = true,
            'w' => width_opt = o.arg,
            'g' => goal_opt = o.arg,
            'p' => prefix_arg = o.arg,
            '0'...'9' => {
                cli.warn(ctx, "invalid option -- {c}; -WIDTH is recognized only when it is the first\noption; use -w N instead\nTry '{s} --help' for more information.", .{ @as(u8, @intCast(o.id)), ctx.name });
                return 1;
            },
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };
    if (prefix_arg) |pa| f.setPrefix(pa);
    if (width_opt) |w| {
        f.max_width = @intCast(parseWidth(w, max_chars / 2) catch |e| {
            cli.warn(ctx, "invalid width: {f}{s}", .{ cli.quoteC(w), if (e == error.range) ": Numerical result out of range" else "" });
            return 1;
        });
    }
    if (goal_opt) |g| {
        f.goal_width = @intCast(parseWidth(g, @intCast(f.max_width)) catch |e| {
            cli.warn(ctx, "invalid width: {f}{s}", .{ cli.quoteC(g), if (e == error.range) ": Value too large for defined data type" else "" });
            return 1;
        });
        if (width_opt == null) f.max_width = f.goal_width + 10;
    } else {
        f.goal_width = @divTrunc(f.max_width * (2 * (100 - leeway) + 1), 200);
    }

    var names: []const []const u8 = p.operands.items;
    const dash = [_][]const u8{"-"};
    if (names.len == 0) names = &dash;
    var status: u8 = 0;
    for (names) |name| {
        const file = cli.openInput(ctx.io, name) catch |e| {
            cli.warn(ctx, "cannot open {f} for reading: {s}", .{ cli.quoteA(name), cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var chunk: [65536]u8 = undefined;
        var failed = false;
        while (true) {
            const n = cli.readChunk(ctx.io, file, &chunk) catch |e| {
                cli.warn(ctx, "{f}: {s}", .{ cli.quote(name), cli.errText(e) });
                failed = true;
                break;
            };
            if (n == 0) break;
            buf.appendSlice(gpa, chunk[0..n]) catch return 1;
        }
        if (failed) {
            status = 1;
            continue;
        }
        f.run(buf.items);
    }
    f.out.flush();
    if (f.out.failed) return 1;
    return status;
}
