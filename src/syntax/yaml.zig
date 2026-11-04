//! A small YAML reader: the subset used by Sublime `.sublime-syntax` files.
//!
//! Supported: block mappings and sequences (including a sequence at the same
//! indent as its key), plain / 'single' / "double" quoted scalars, block
//! scalars (| |- |+ > >-), flow sequences and mappings, comments, and the
//! `%YAML` / `---` header. Not supported, and reported as errors rather than
//! guessed at: anchors and aliases, tags, multi-line quoted scalars, complex
//! keys, multiple documents.
//!
//! All results live in the caller's arena.

const std = @import("std");

pub const Pair = struct { key: []const u8, value: Value };

pub const Value = union(enum) {
    scalar: []const u8,
    seq: []const Value,
    map: []const Pair,

    /// Value of `key` in a mapping (first match), or null.
    pub fn get(v: Value, key: []const u8) ?Value {
        if (v != .map) return null;
        for (v.map) |p| if (std.mem.eql(u8, p.key, key)) return p.value;
        return null;
    }

    pub fn str(v: Value) ?[]const u8 {
        return if (v == .scalar) v.scalar else null;
    }
};

pub const Error = error{ OutOfMemory, InvalidYaml, UnsupportedYaml };

pub const Diagnostic = struct {
    /// 1-based line number.
    line: usize = 0,
    message: []const u8 = "",
};

const Line = struct { indent: usize, text: []const u8 };

const Parser = struct {
    arena: std.mem.Allocator,
    lines: []Line,
    raw_numbers: []usize,
    i: usize = 0,
    diag: *Diagnostic,

    fn fail(p: *Parser, err: Error, msg: []const u8) Error {
        const idx = @min(p.i, p.lines.len -| 1);
        p.diag.* = .{ .line = if (p.lines.len == 0) 0 else p.raw_numbers[idx], .message = msg };
        return err;
    }

    fn isBlank(l: Line) bool {
        return l.text.len == 0 or l.text[0] == '#';
    }

    /// Advance to the next line with content.
    fn skip(p: *Parser) void {
        while (p.i < p.lines.len and isBlank(p.lines[p.i])) p.i += 1;
    }

    fn peekLine(p: *Parser) ?Line {
        p.skip();
        return if (p.i < p.lines.len) p.lines[p.i] else null;
    }

    fn isSeqItem(text: []const u8) bool {
        return text.len > 0 and text[0] == '-' and (text.len == 1 or text[1] == ' ');
    }

    fn emptyScalar() Value {
        return .{ .scalar = "" };
    }

    /// Parse the node starting at the next content line.
    fn parseNode(p: *Parser) Error!Value {
        const ln = p.peekLine() orelse return emptyScalar();
        if (isSeqItem(ln.text)) return p.parseSeq(ln.indent);
        if (keyEnd(ln.text) != null) return p.parseMap(ln.indent);
        const v = try p.parseInline(ln.text);
        return v;
    }

    fn parseSeq(p: *Parser, indent: usize) Error!Value {
        var items: std.ArrayList(Value) = .empty;
        while (p.peekLine()) |ln| {
            if (ln.indent < indent) break;
            if (ln.indent > indent) return p.fail(error.InvalidYaml, "bad indentation in sequence");
            if (!isSeqItem(ln.text)) break;
            var rest = ln.text[1..];
            const trimmed = std.mem.trimStart(u8, rest, " ");
            const consumed = 1 + (rest.len - trimmed.len);
            rest = trimmed;
            if (rest.len == 0 or rest[0] == '#') {
                p.i += 1;
                const next = p.peekLine();
                if (next != null and next.?.indent > indent) {
                    try items.append(p.arena, try p.parseNode());
                } else try items.append(p.arena, emptyScalar());
            } else {
                // Re-read the rest of the line as a node at its own column, so
                // "- key: v" followed by "  key2: v" forms one mapping.
                p.lines[p.i] = .{ .indent = indent + consumed, .text = rest };
                try items.append(p.arena, try p.parseNode());
            }
        }
        return .{ .seq = items.items };
    }

    fn parseMap(p: *Parser, indent: usize) Error!Value {
        var pairs: std.ArrayList(Pair) = .empty;
        while (p.peekLine()) |ln| {
            if (ln.indent < indent) break;
            if (ln.indent > indent) return p.fail(error.InvalidYaml, "bad indentation in mapping");
            if (isSeqItem(ln.text)) break;
            const ke = keyEnd(ln.text) orelse return p.fail(error.InvalidYaml, "expected 'key:'");
            const key = try p.unquoteKey(ln.text[0..ke]);
            const rest = std.mem.trim(u8, ln.text[ke + 1 ..], " ");

            var value: Value = undefined;
            if (rest.len == 0 or rest[0] == '#') {
                p.i += 1;
                const next = p.peekLine();
                if (next != null and (next.?.indent > indent or (next.?.indent == indent and isSeqItem(next.?.text)))) {
                    value = try p.parseNode();
                } else value = emptyScalar();
            } else if (rest[0] == '|' or rest[0] == '>') {
                value = .{ .scalar = try p.blockScalar(rest, indent) };
            } else {
                // Keep the value text but let parseInline see only it.
                p.lines[p.i] = .{ .indent = ln.indent, .text = rest };
                value = try p.parseInline(rest);
            }
            try pairs.append(p.arena, .{ .key = key, .value = value });
        }
        return .{ .map = pairs.items };
    }

    /// Index of the ':' ending a mapping key on this line, if it is one.
    fn keyEnd(text: []const u8) ?usize {
        if (text.len == 0) return null;
        switch (text[0]) {
            '"', '\'' => {
                const q = text[0];
                var i: usize = 1;
                while (i < text.len) : (i += 1) {
                    if (q == '"' and text[i] == '\\') {
                        i += 1;
                    } else if (text[i] == q) {
                        if (q == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                            i += 1;
                            continue;
                        }
                        break;
                    }
                }
                if (i + 1 < text.len and text[i + 1] == ':' and (i + 2 == text.len or text[i + 2] == ' '))
                    return i + 1;
                return null;
            },
            '[', '{', '|', '>', '#', '&', '*', '!' => return null,
            else => {},
        }
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')) return i;
            if (text[i] == ' ' and i + 1 < text.len and text[i + 1] == '#') return null;
        }
        return null;
    }

    fn unquoteKey(p: *Parser, k: []const u8) Error![]const u8 {
        if (k.len >= 2 and (k[0] == '"' or k[0] == '\'')) return p.quoted(k);
        return std.mem.trim(u8, k, " ");
    }

    /// Parse a value on one line (or a flow collection spanning lines) and
    /// move past it. `text` is the current line's text.
    fn parseInline(p: *Parser, text: []const u8) Error!Value {
        switch (text[0]) {
            '[', '{' => {
                const joined = try p.collectFlow(text);
                var fp: FlowParser = .{ .p = p, .s = joined };
                const v = try fp.value();
                fp.ws();
                if (fp.i < fp.s.len and fp.s[fp.i] != '#')
                    return p.fail(error.InvalidYaml, "unexpected text after flow collection");
                return v;
            },
            '&', '*', '!' => return p.fail(error.UnsupportedYaml, "anchors, aliases and tags are not supported"),
            '"', '\'' => {
                const end = try p.quotedEnd(text);
                p.i += 1;
                return .{ .scalar = try p.quoted(text[0..end]) };
            },
            else => {
                p.i += 1;
                return .{ .scalar = plain(text) };
            },
        }
    }

    fn plain(text: []const u8) []const u8 {
        var end = text.len;
        var i: usize = 0;
        while (i + 1 < text.len) : (i += 1) {
            if (text[i] == ' ' and text[i + 1] == '#') {
                end = i;
                break;
            }
        }
        return std.mem.trimEnd(u8, text[0..end], " ");
    }

    /// Length of the quoted scalar at the start of `text` (including quotes).
    fn quotedEnd(p: *Parser, text: []const u8) Error!usize {
        const q = text[0];
        var i: usize = 1;
        while (i < text.len) : (i += 1) {
            if (q == '"' and text[i] == '\\') {
                i += 1;
            } else if (text[i] == q) {
                if (q == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                return i + 1;
            }
        }
        return p.fail(error.UnsupportedYaml, "unterminated or multi-line quoted scalar");
    }

    /// Decode a complete quoted scalar (with its quotes).
    fn quoted(p: *Parser, q: []const u8) Error![]const u8 {
        const body = q[1 .. q.len - 1];
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        if (q[0] == '\'') {
            while (i < body.len) : (i += 1) {
                try out.append(p.arena, body[i]);
                if (body[i] == '\'') i += 1; // '' -> '
            }
            return out.items;
        }
        while (i < body.len) : (i += 1) {
            if (body[i] != '\\') {
                try out.append(p.arena, body[i]);
                continue;
            }
            i += 1;
            if (i >= body.len) return p.fail(error.InvalidYaml, "dangling backslash");
            switch (body[i]) {
                'n' => try out.append(p.arena, '\n'),
                't' => try out.append(p.arena, '\t'),
                'r' => try out.append(p.arena, '\r'),
                '0' => try out.append(p.arena, 0),
                'a' => try out.append(p.arena, 7),
                'b' => try out.append(p.arena, 8),
                'e' => try out.append(p.arena, 27),
                'f' => try out.append(p.arena, 12),
                'v' => try out.append(p.arena, 11),
                ' ', '"', '/', '\\' => |c| try out.append(p.arena, c),
                'x', 'u', 'U' => {
                    const n: usize = switch (body[i]) {
                        'x' => 2,
                        'u' => 4,
                        else => 8,
                    };
                    if (i + n >= body.len + 0 and i + n > body.len - 0) return p.fail(error.InvalidYaml, "short escape");
                    const cp = std.fmt.parseInt(u21, body[i + 1 ..][0..n], 16) catch
                        return p.fail(error.InvalidYaml, "bad numeric escape");
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch
                        return p.fail(error.InvalidYaml, "bad code point");
                    try out.appendSlice(p.arena, buf[0..len]);
                    i += n;
                },
                else => return p.fail(error.InvalidYaml, "unknown escape in double-quoted scalar"),
            }
        }
        return out.items;
    }

    /// Block scalar (| or >) whose key sits at `key_indent`. Consumes its lines.
    fn blockScalar(p: *Parser, header: []const u8, key_indent: usize) Error![]const u8 {
        const folded = header[0] == '>';
        var chomp: enum { clip, strip, keep } = .clip;
        for (header[1..]) |c| switch (c) {
            '-' => chomp = .strip,
            '+' => chomp = .keep,
            '0'...'9' => return p.fail(error.UnsupportedYaml, "explicit block indentation indicator"),
            ' ' => break,
            '#' => break,
            else => return p.fail(error.InvalidYaml, "bad block scalar header"),
        };
        p.i += 1;
        var block_indent: ?usize = null;
        var out: std.ArrayList(u8) = .empty;
        var first = true;
        while (p.i < p.lines.len) : (p.i += 1) {
            const ln = p.lines[p.i];
            const blank = ln.text.len == 0;
            if (!blank) {
                if (ln.indent <= key_indent) break;
                if (block_indent == null) block_indent = ln.indent;
                if (ln.indent < block_indent.?) break;
            }
            if (!first) try out.append(p.arena, '\n');
            first = false;
            if (!blank) {
                try out.appendNTimes(p.arena, ' ', ln.indent - block_indent.?);
                try out.appendSlice(p.arena, ln.text);
            }
        }
        // Trailing blank lines were joined as newlines; apply chomping.
        var end = out.items.len;
        while (end > 0 and out.items[end - 1] == '\n') end -= 1;
        var result: []const u8 = out.items[0..end];
        if (folded) result = try p.fold(result);
        switch (chomp) {
            .strip => {},
            .clip => if (!first) {
                result = try std.mem.concat(p.arena, u8, &.{ result, "\n" });
            },
            .keep => {
                const trailing = out.items.len - end;
                result = try std.mem.concat(p.arena, u8, &.{ result, "\n", out.items[end..][0..trailing] });
            },
        }
        return result;
    }

    fn fold(p: *Parser, s: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, s, '\n');
        var first = true;
        var prev_blank = false;
        while (it.next()) |l| {
            if (l.len == 0) {
                try out.append(p.arena, '\n');
                prev_blank = true;
                continue;
            }
            if (!first and !prev_blank) try out.append(p.arena, ' ');
            try out.appendSlice(p.arena, l);
            first = false;
            prev_blank = false;
        }
        return out.items;
    }

    /// Join lines of a flow collection until brackets balance; advances `i`.
    fn collectFlow(p: *Parser, first: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var text = first;
        var depth: i32 = 0;
        while (true) {
            var quote: u8 = 0;
            var k: usize = 0;
            while (k < text.len) : (k += 1) {
                const c = text[k];
                if (quote != 0) {
                    if (quote == '"' and c == '\\') k += 1 else if (c == quote) quote = 0;
                } else switch (c) {
                    '"', '\'' => quote = c,
                    '[', '{' => depth += 1,
                    ']', '}' => depth -= 1,
                    '#' => if (k == 0 or text[k - 1] == ' ') {
                        text = text[0..k];
                        break;
                    },
                    else => {},
                }
            }
            try out.appendSlice(p.arena, text);
            try out.append(p.arena, ' ');
            p.i += 1;
            if (depth <= 0) break;
            const next = p.peekLine() orelse return p.fail(error.InvalidYaml, "unterminated flow collection");
            text = next.text;
        }
        return out.items;
    }
};

const FlowParser = struct {
    p: *Parser,
    s: []const u8,
    i: usize = 0,

    fn ws(f: *FlowParser) void {
        while (f.i < f.s.len and (f.s[f.i] == ' ' or f.s[f.i] == '\t')) f.i += 1;
    }

    fn value(f: *FlowParser) Error!Value {
        f.ws();
        if (f.i >= f.s.len) return f.p.fail(error.InvalidYaml, "unexpected end of flow collection");
        switch (f.s[f.i]) {
            '[' => {
                f.i += 1;
                var items: std.ArrayList(Value) = .empty;
                while (true) {
                    f.ws();
                    if (f.i < f.s.len and f.s[f.i] == ']') {
                        f.i += 1;
                        break;
                    }
                    try items.append(f.p.arena, try f.value());
                    f.ws();
                    if (f.i < f.s.len and f.s[f.i] == ',') f.i += 1 else if (f.i < f.s.len and f.s[f.i] == ']') {
                        f.i += 1;
                        break;
                    } else return f.p.fail(error.InvalidYaml, "expected ',' or ']'");
                }
                return .{ .seq = items.items };
            },
            '{' => {
                f.i += 1;
                var pairs: std.ArrayList(Pair) = .empty;
                while (true) {
                    f.ws();
                    if (f.i < f.s.len and f.s[f.i] == '}') {
                        f.i += 1;
                        break;
                    }
                    const k = try f.scalar(true);
                    f.ws();
                    if (f.i >= f.s.len or f.s[f.i] != ':') return f.p.fail(error.InvalidYaml, "expected ':' in flow mapping");
                    f.i += 1;
                    const v = try f.value();
                    try pairs.append(f.p.arena, .{ .key = k, .value = v });
                    f.ws();
                    if (f.i < f.s.len and f.s[f.i] == ',') f.i += 1 else if (f.i < f.s.len and f.s[f.i] == '}') {
                        f.i += 1;
                        break;
                    } else return f.p.fail(error.InvalidYaml, "expected ',' or '}'");
                }
                return .{ .map = pairs.items };
            },
            else => return .{ .scalar = try f.scalar(false) },
        }
    }

    fn scalar(f: *FlowParser, is_key: bool) Error![]const u8 {
        f.ws();
        if (f.i < f.s.len and (f.s[f.i] == '"' or f.s[f.i] == '\'')) {
            const end = try f.p.quotedEnd(f.s[f.i..]);
            const out = try f.p.quoted(f.s[f.i..][0..end]);
            f.i += end;
            return out;
        }
        const start = f.i;
        while (f.i < f.s.len) : (f.i += 1) {
            const c = f.s[f.i];
            if (c == ',' or c == ']' or c == '}') break;
            if (is_key and c == ':') break;
            if (c == ':' and f.i + 1 < f.s.len and f.s[f.i + 1] == ' ') break;
        }
        return std.mem.trim(u8, f.s[start..f.i], " ");
    }
};

/// Parse one YAML document.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: *Diagnostic) Error!Value {
    diag.* = .{};
    var lines: std.ArrayList(Line) = .empty;
    var numbers: std.ArrayList(usize) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var no: usize = 0;
    var seen_doc_start = false;
    while (it.next()) |raw| {
        no += 1;
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, l, "%")) continue;
        if (std.mem.eql(u8, l, "---") or std.mem.startsWith(u8, l, "--- ")) {
            if (seen_doc_start and lines.items.len > 0) {
                diag.* = .{ .line = no, .message = "multiple documents" };
                return error.UnsupportedYaml;
            }
            seen_doc_start = true;
            continue;
        }
        const content = std.mem.trimStart(u8, l, " ");
        try lines.append(arena, .{ .indent = l.len - content.len, .text = content });
        try numbers.append(arena, no);
    }
    var p: Parser = .{ .arena = arena, .lines = lines.items, .raw_numbers = numbers.items, .diag = diag };
    return p.parseNode();
}

test "mappings, sequences, scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const v = try parse(arena.allocator(),
        \\%YAML 1.2
        \\---
        \\# comment
        \\name: C++ (fmt)   # trailing
        \\file_extensions:
        \\  - cpp
        \\  - 'h'
        \\same:
        \\- a
        \\- "b\tc"
        \\contexts:
        \\  main:
        \\    - match: '\b(it''s)\b'
        \\      scope: x.y
        \\      captures:
        \\        1: kw.a
        \\    - include: other
        \\
    , &d);
    try std.testing.expectEqualStrings("C++ (fmt)", v.get("name").?.str().?);
    const ext = v.get("file_extensions").?.seq;
    try std.testing.expectEqual(@as(usize, 2), ext.len);
    try std.testing.expectEqualStrings("h", ext[1].str().?);
    try std.testing.expectEqualStrings("b\tc", v.get("same").?.seq[1].str().?);
    const main = v.get("contexts").?.get("main").?.seq;
    try std.testing.expectEqual(@as(usize, 2), main.len);
    try std.testing.expectEqualStrings("\\b(it's)\\b", main[0].get("match").?.str().?);
    try std.testing.expectEqualStrings("kw.a", main[0].get("captures").?.get("1").?.str().?);
    try std.testing.expectEqualStrings("other", main[1].get("include").?.str().?);
}

test "block scalars keep # lines and indentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const v = try parse(arena.allocator(),
        \\a: |-
        \\    (?x:
        \\      \d*   # width
        \\    )
        \\b: |
        \\  one
        \\
        \\  two
        \\c: end
    , &d);
    try std.testing.expectEqualStrings("(?x:\n  \\d*   # width\n)", v.get("a").?.str().?);
    try std.testing.expectEqualStrings("one\n\ntwo\n", v.get("b").?.str().?);
    try std.testing.expectEqualStrings("end", v.get("c").?.str().?);
}

test "flow collections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const v = try parse(arena.allocator(),
        \\push: [a, b, 'c d']
        \\caps: {1: x.y, 2: "z"}
        \\multi: [
        \\  p, # note
        \\  q,
        \\]
        \\last: 1
    , &d);
    try std.testing.expectEqual(@as(usize, 3), v.get("push").?.seq.len);
    try std.testing.expectEqualStrings("c d", v.get("push").?.seq[2].str().?);
    try std.testing.expectEqualStrings("z", v.get("caps").?.get("2").?.str().?);
    try std.testing.expectEqual(@as(usize, 2), v.get("multi").?.seq.len);
    try std.testing.expectEqualStrings("1", v.get("last").?.str().?);
}

test "errors name the line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.UnsupportedYaml, parse(arena.allocator(), "a: &x 1\n", &d));
    try std.testing.expectEqual(@as(usize, 1), d.line);
    try std.testing.expectError(error.InvalidYaml, parse(arena.allocator(), "a:\n  b: 1\n   c: 2\n", &d));
}
