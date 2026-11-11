// SPDX-License-Identifier: GPL-2.0-or-later
//! grep — print lines that match patterns. Reference: GNU grep 3.12 (grep.c).
//! Patterns are compiled to the Perl dialect of regex-zig through
//! src/posixre.zig (BRE, ERE, fixed strings) or passed as is (-P).

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const posixre = @import("../posixre.zig");
const regex = @import("regex");
const sys = @import("../sys.zig");
const unicode = @import("../unicode.zig");
const fnmatch = @import("../fnmatch.zig");
const argmatch = @import("../argmatch.zig");
const LX = std.os.linux;
const Io = std.Io;

const help_text = @embedFile("../help/grep.txt");

const Matcher = enum { g, e, f, p };
const Binary = enum { binary, text, without_match };
const Dirs = enum { read, recurse, skip };
const Devs = enum { read_cmdline, read, skip };
const ListFiles = enum { none, matching, nonmatching };

const Pat = struct {
    re: regex.Regex,
    fin: posixre.Finder,
    mb: bool,
};

const Span = struct { start: usize, end: usize };

const Colors = struct {
    ms: []const u8 = "01;31",
    mc: []const u8 = "01;31",
    sl: []const u8 = "",
    cx: []const u8 = "",
    fn_: []const u8 = "35",
    ln: []const u8 = "32",
    bn: []const u8 = "32",
    se: []const u8 = "36",
    rv: bool = false,
    ne: bool = false,
};

const Opts = struct {
    matcher: Matcher = .g,
    icase: bool = false,
    invert: bool = false,
    word: bool = false,
    line: bool = false,
    count: bool = false,
    list: ListFiles = .none,
    quiet: bool = false,
    no_messages: bool = false,
    only: bool = false,
    byte_offset: bool = false,
    line_number: bool = false,
    filename_opt: i8 = -1, // -1 unset, 0 -h, 1 -H
    null_after_name: bool = false,
    null_data: bool = false,
    initial_tab: bool = false,
    max_count: i64 = std.math.maxInt(i64),
    before: i64 = -1,
    after: i64 = -1,
    binary_files: Binary = .binary,
    directories: Dirs = .read,
    devices: Devs = .read_cmdline,
    deref_recursive: bool = false,
    color: bool = false,
    line_buffered: bool = false,
    label: []const u8 = "(standard input)",
    group_sep: ?[]const u8 = "--",
    utf8: bool = false,
    unix_byte_offsets: bool = false,
};

const Glob = struct { pat: []const u8, include: bool };

const G = struct {
    ctx: cli.Context,
    gpa: std.mem.Allocator,
    o: Opts = .{},
    pats: std.ArrayList(*Pat) = .empty,
    no_patterns: bool = false,
    eol: u8 = '\n',
    globs: std.ArrayList(Glob) = .empty,
    excl_dirs: std.ArrayList([]const u8) = .empty,
    colors: Colors = .{},
    out: std.ArrayList(u8) = .empty,
    errseen: bool = false,
    out_file: i8 = 0, // 0 no, 1 yes, -1 only when recursing into a directory
    out_quiet: bool = false,
    done_on_match: bool = false,
    exit_on_match: bool = false,
    stdout_st: ?sys.FileStat = null,
    // per file
    fname: []const u8 = "",
    show_name: bool = false,
    totalnl: u64 = 0,
    lastout_line: i64 = -1, // line number of the last printed line (-1 none)
    pending: i64 = 0,
    used: bool = false,
    outleft: i64 = 0,
    before_q: std.ArrayList(CtxLine) = .empty,
    line_no: u64 = 0,
    offset: u64 = 0, // byte offset of the current line start
    last_printed_end: ?u64 = null, // offset just after the last printed line
    binary: bool = false,
    nlines_first_null: i64 = -1,
    nlines: u64 = 0,
    enc_error_suppressed: bool = false,
    implicit_dot: bool = false,
    offset_width: usize = 0,
};

const CtxLine = struct { text: []u8, no: u64, off: u64 };

fn oom(ctx: cli.Context) noreturn {
    cli.warn(ctx, "memory exhausted", .{});
    std.process.exit(2);
}

// ----------------------------------------------------------------- output

fn flushOut(g: *G) void {
    if (g.out.items.len == 0) return;
    if (sys.writeAllFd(1, g.out.items)) |err| {
        cli.noteStdoutFailure(sys.errnoText(err));
        cli.writeErrorWarn(g.ctx);
        std.process.exit(2);
    }
    g.out.clearRetainingCapacity();
}

fn emit(g: *G, bytes: []const u8) void {
    g.out.appendSlice(g.gpa, bytes) catch oom(g.ctx);
    if (g.out.items.len > 65536) flushOut(g);
}

fn emitByte(g: *G, b: u8) void {
    g.out.append(g.gpa, b) catch oom(g.ctx);
}

fn sgrStart(g: *G, color: []const u8) void {
    if (color.len == 0) return;
    emit(g, "\x1b[");
    emit(g, color);
    emit(g, if (g.colors.ne) "m" else "m\x1b[K");
}

fn sgrEnd(g: *G, color: []const u8) void {
    if (color.len == 0) return;
    emit(g, if (g.colors.ne) "\x1b[m" else "\x1b[m\x1b[K");
}

fn printSep(g: *G, sep: u8) void {
    if (g.o.color) sgrStart(g, g.colors.se);
    emitByte(g, sep);
    if (g.o.color) sgrEnd(g, g.colors.se);
}

fn printFilename(g: *G) void {
    if (g.o.color) sgrStart(g, g.colors.fn_);
    emit(g, g.fname);
    if (g.o.color) sgrEnd(g, g.colors.fn_);
}

fn printOffset(g: *G, n: u64, _: usize, color: []const u8) void {
    const min_width = g.offset_width;
    var buf: [32]u8 = undefined;
    var s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
    var pad: [32]u8 = undefined;
    if (g.o.initial_tab and s.len < min_width) {
        const k = min_width - s.len;
        @memset(pad[0..k], ' ');
        @memcpy(pad[k .. k + s.len], s);
        s = pad[0 .. k + s.len];
    }
    if (g.o.color) sgrStart(g, color);
    emit(g, s);
    if (g.o.color) sgrEnd(g, color);
}

fn printLineHead(g: *G, line_no: u64, off: u64, len: usize, sep: u8) void {
    if (g.show_name) {
        printFilename(g);
        if (g.o.null_after_name) emitByte(g, 0) else printSep(g, sep);
    }
    if (g.o.line_number) {
        printOffset(g, line_no, 4, g.colors.ln);
        printSep(g, sep);
    }
    if (g.o.byte_offset) {
        printOffset(g, off, 6, g.colors.bn);
        printSep(g, sep);
    }
    if (g.o.initial_tab and (g.show_name or g.o.line_number or g.o.byte_offset) and len > 0) emitByte(g, '\t');
}

// --------------------------------------------------------------- matching

fn findIn(g: *G, line: []const u8, from: usize) ?Span {
    var best: ?Span = null;
    for (g.pats.items) |p| {
        const m = (p.fin.find(line, from) catch null) orelse continue;
        const sp = Span{ .start = m.start(), .end = m.end() };
        if (best == null or sp.start < best.?.start or (sp.start == best.?.start and sp.end > best.?.end)) best = sp;
    }
    return best;
}

fn lineMatches(g: *G, line: []const u8) bool {
    if (g.no_patterns) return false;
    for (g.pats.items) |p| {
        if ((p.fin.find(line, 0) catch null) != null) return true;
    }
    return false;
}

// ----------------------------------------------------------------- lines

fn writeRaw(g: *G, bytes: []const u8) void {
    emit(g, bytes);
}

/// Print one line (without its terminator) as selected (':') or context ('-').
fn encFail(g: *G, text: []const u8) bool {
    if (g.o.utf8 and g.o.binary_files == .binary and !validUtf8(text)) {
        g.enc_error_suppressed = true;
        return true;
    }
    return false;
}

fn prline(g: *G, text: []const u8, no: u64, off: u64, sep: u8) bool {
    const o = &g.o;
    if (!o.only and encFail(g, text)) return false;
    if (!o.only) printLineHead(g, no, off, text.len, sep);
    const matching = (sep == ':') != o.invert;
    var line_color: []const u8 = "";
    var match_color: []const u8 = "";
    if (o.color) {
        const sel_line = ((sep == ':') != (o.invert and g.colors.rv));
        line_color = if (sel_line) g.colors.sl else g.colors.cx;
        match_color = if (sep == ':') g.colors.ms else g.colors.mc;
    }
    var beg: usize = 0;
    if ((o.only and matching) or (o.color and (line_color.len > 0 or match_color.len > 0))) {
        if (matching and (o.only or match_color.len > 0)) {
            beg = printLineMiddle(g, text, no, off, line_color, match_color);
        }
        if (!o.only and line_color.len > 0) {
            // tail: the rest of the line (minus a trailing CR) in the line colour
            var tail = text.len - beg;
            if (tail > 0 and text[text.len - 1] == '\r') tail -= 1;
            if (tail > 0) {
                sgrStart(g, line_color);
                emit(g, text[beg .. beg + tail]);
                sgrEnd(g, line_color);
                beg += tail;
            }
        }
    }
    if (!o.only) {
        emit(g, text[beg..]);
        emitByte(g, g.eol);
    }
    if (o.line_buffered) flushOut(g);
    return true;
}

fn printLineMiddle(g: *G, text: []const u8, no: u64, off: u64, line_color: []const u8, match_color: []const u8) usize {
    var cur: usize = 0;
    var mid: ?usize = null;
    while (cur < text.len) {
        const m = findIn(g, text, cur) orelse break;
        const b = m.start;
        var size = m.end - m.start;
        if (b == text.len) break;
        if (size == 0) {
            size = 1;
            if (mid == null) mid = cur;
            // skip a whole character in UTF-8
            if (g.o.utf8) size = unicode.decode(text, b).len;
            cur = b + size;
            continue;
        }
        if (encFail(g, text[b .. b + size])) {
            cur = b + size;
            continue;
        }
        if (g.o.only) {
            const sep: u8 = if (g.o.invert) '-' else ':';
            printLineHead(g, no, off + b, size, sep);
        } else {
            sgrStart(g, line_color);
            if (mid) |md| {
                cur = md;
                mid = null;
            }
            emit(g, text[cur..b]);
        }
        sgrStart(g, match_color);
        emit(g, text[b .. b + size]);
        sgrEnd(g, match_color);
        if (g.o.only) emitByte(g, g.eol);
        cur = b + size;
    }
    if (g.o.only) return text.len;
    if (mid) |md| return md;
    return cur;
}

fn flushBefore(g: *G) void {
    for (g.before_q.items) |c| g.gpa.free(c.text);
    g.before_q.clearRetainingCapacity();
}

// --------------------------------------------------------------- scanning

const Stop = enum { cont, stop };

/// Process one input line. Returns .stop when scanning of this file ends.
fn doLine(g: *G, text: []const u8) Stop {
    g.line_no += 1;
    const no = g.line_no;
    const off = g.offset;
    g.offset += text.len + 1;
    const o = &g.o;
    const matched = lineMatches(g, text);
    const selected = matched != o.invert;

    if (g.outleft == 0) {
        // -m reached: only trailing context remains
        if (g.pending > 0 and !g.out_quiet) {
            if (prline(g, text, no, off, '-')) g.lastout_line = @intCast(no);
            g.pending -= 1;
            if (g.pending == 0) return .stop;
            return .cont;
        }
        return .stop;
    }

    if (selected) {
        g.nlines += 1;
        if (!g.out_quiet) {
            if (g.binary and o.binary_files == .binary) {
                // matches in a binary file are not printed
                if (g.nlines_first_null < 0) g.nlines_first_null = 0;
            }
        }
        if (g.binary and o.binary_files == .binary and !g.out_quiet) {
            // first match in binary data: stop here, a message follows
            g.outleft -= 1;
            g.done_on_match = true;
            return .stop;
        }
        if (!g.out_quiet) {
            // leading context
            if (g.pending > 0) {
                // (pending trailing context was already printed line by line)
                g.pending = 0;
            }
            var first_ctx_no: u64 = no;
            if (g.before_q.items.len > 0) first_ctx_no = g.before_q.items[0].no;
            if ((o.before >= 0 or o.after >= 0) and g.used and (g.lastout_line < 0 or g.lastout_line + 1 != @as(i64, @intCast(first_ctx_no)))) {
                if (o.group_sep) |gs| {
                    if (o.color) sgrStart(g, g.colors.se);
                    emit(g, gs);
                    if (o.color) sgrEnd(g, g.colors.se);
                    emitByte(g, '\n');
                }
            }
            for (g.before_q.items) |c| {
                if (prline(g, c.text, c.no, c.off, '-')) g.lastout_line = @intCast(c.no);
            }
            flushBefore(g);
            if (prline(g, text, no, off, ':')) g.lastout_line = @intCast(no);
            g.pending = @max(0, o.after);
            g.used = true;
        }
        g.outleft -= 1;
        if (g.exit_on_match) {
            flushOut(g);
            std.process.exit(0);
        }
        if (g.done_on_match) return .stop;
        if (g.outleft == 0 and g.pending <= 0) return .stop;
        return .cont;
    }

    // not selected
    if (!g.out_quiet) {
        if (g.pending > 0) {
            if (prline(g, text, no, off, '-')) g.lastout_line = @intCast(no);
            g.pending -= 1;
        } else if (o.before > 0) {
            const copy = g.gpa.dupe(u8, text) catch oom(g.ctx);
            if (g.before_q.items.len >= @as(usize, @intCast(o.before))) {
                g.gpa.free(g.before_q.items[0].text);
                _ = g.before_q.orderedRemove(0);
            }
            g.before_q.append(g.gpa, .{ .text = copy, .no = no, .off = off }) catch oom(g.ctx);
        }
    }
    return .cont;
}

fn validUtf8(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] < 0x80) {
            i += 1;
            continue;
        }
        const d = unicode.decode(s, i);
        if (!d.valid) return false;
        i += d.len;
    }
    return true;
}

/// Search one open descriptor. Returns the number of selected lines.
fn grepFd(g: *G, fd: i32, seekable_stdin: bool) u64 {
    const o = &g.o;
    g.totalnl = 0;
    g.lastout_line = -1;
    g.pending = 0;
    g.line_no = 0;
    g.offset = 0;
    g.binary = false;
    g.nlines = 0;
    g.nlines_first_null = -1;
    g.enc_error_suppressed = false;
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    g.outleft = o.max_count;
    flushBefore(g);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(g.gpa);
    var pos: usize = 0;
    var eof = false;
    var chunk: [98304]u8 = undefined;
    var stopped = false;
    var consumed_total: u64 = 0;
    const base_quiet = g.out_quiet;
    var extra_nul_split = false;

    while (!stopped) {
        // find next line
        var term: ?usize = null;
        if (pos < buf.items.len) {
            const rest = buf.items[pos..];
            if (extra_nul_split) {
                term = std.mem.indexOfAny(u8, rest, "\n\x00");
            } else term = std.mem.indexOfScalar(u8, rest, g.eol);
        }
        if (term == null) {
            if (eof) {
                if (pos < buf.items.len) {
                    // final line without terminator
                    const text = buf.items[pos..];
                    consumed_total += text.len;
                    pos = buf.items.len;
                    if (doLine(g, text) == .stop) stopped = true;
                }
                break;
            }
            // read more
            if (pos > 0 and pos == buf.items.len) {
                buf.clearRetainingCapacity();
                pos = 0;
            } else if (pos > (1 << 20)) {
                buf.replaceRange(g.gpa, 0, pos, &.{}) catch oom(g.ctx);
                pos = 0;
            }
            var err: LX.E = .SUCCESS;
            const n = sys.readFd(fd, &chunk, &err) orelse {
                if (!o.no_messages) cli.warn(g.ctx, "{s}: {s}", .{ g.fname, sys.errnoText(err) });
                g.errseen = true;
                break;
            };
            if (n == 0) {
                eof = true;
                continue;
            }
            if (!g.binary and o.binary_files != .text and !o.null_data) {
                if (std.mem.indexOfScalar(u8, chunk[0..n], 0) != null) {
                    g.binary = true;
                    if (o.binary_files == .without_match) {
                        return 0;
                    }
                    extra_nul_split = true;
                    g.nlines_first_null = @intCast(g.nlines);
                    if (!g.out_quiet) {
                        // binary: stop at the first match, no output
                        g.done_on_match = true;
                    }
                }
            }
            buf.appendSlice(g.gpa, chunk[0..n]) catch oom(g.ctx);
            continue;
        }
        const text = buf.items[pos .. pos + term.?];
        consumed_total += term.? + 1;
        pos += term.? + 1;
        if (doLine(g, text) == .stop) stopped = true;
    }
    _ = base_quiet;
    // restore stdin position when stopped early on a seekable stdin
    if (seekable_stdin and stopped and pos < buf.items.len + 0) {
        const unread: i64 = @intCast(buf.items.len - pos);
        var serr: LX.E = .SUCCESS;
        _ = sys.seekFd(fd, -unread, 1, &serr);
    } else if (seekable_stdin and stopped and !eof) {
        // data not yet read stays in the file
    }
    return g.nlines;
}

// ------------------------------------------------------------------ files

fn matchGlobs(g: *G, name: []const u8, base: []const u8, cmdline: bool) bool {
    // returns true when the file is to be skipped
    var has_include = false;
    var included = false;
    for (g.globs.items) |gl| {
        const hit = globHit(gl.pat, name, base, cmdline);
        if (gl.include) {
            has_include = true;
            if (hit) included = true;
        } else if (hit) return true;
    }
    if (has_include and !included) return true;
    return false;
}

fn globHit(pat: []const u8, name: []const u8, base: []const u8, cmdline: bool) bool {
    if (fnmatch.match(pat, base, .{})) return true;
    if (cmdline) {
        if (fnmatch.match(pat, name, .{})) return true;
        // match any trailing sequence of components
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, name, i, '/')) |k| {
            if (fnmatch.match(pat, name[k + 1 ..], .{})) return true;
            i = k + 1;
        }
    }
    return false;
}

fn dirExcluded(g: *G, name: []const u8, base: []const u8, cmdline: bool) bool {
    for (g.excl_dirs.items) |p| {
        var pp = p;
        while (pp.len > 1 and pp[pp.len - 1] == '/') pp = pp[0 .. pp.len - 1];
        var nm = name;
        while (nm.len > 1 and nm[nm.len - 1] == '/') nm = nm[0 .. nm.len - 1];
        var bs = base;
        while (bs.len > 1 and bs[bs.len - 1] == '/') bs = bs[0 .. bs.len - 1];
        if (globHit(pp, nm, bs, cmdline)) return true;
    }
    return false;
}

fn finishFile(g: *G, count: u64) bool {
    // returns true when the file had a selected line
    const o = &g.o;
    if (o.count) {
        if (g.show_name) {
            printFilename(g);
            if (o.null_after_name) emitByte(g, 0) else printSep(g, ':');
        }
        var b: [24]u8 = undefined;
        emit(g, std.fmt.bufPrint(&b, "{d}\n", .{count}) catch unreachable);
        if (o.line_buffered) flushOut(g);
    }
    const status_matched = count > 0;
    const want = (o.list == .matching and status_matched) or (o.list == .nonmatching and !status_matched);
    if (want) {
        printFilename(g);
        emitByte(g, if (o.null_after_name) 0 else '\n');
        if (o.line_buffered) flushOut(g);
    }
    if (g.binary and o.binary_files == .binary and !g.out_quiet and g.nlines > 0 and g.nlines_first_null >= 0 and @as(i64, @intCast(g.nlines)) > g.nlines_first_null) {
        flushOut(g);
        cli.warn(g.ctx, "{s}: binary file matches", .{g.fname});
    } else if (g.enc_error_suppressed) {
        flushOut(g);
        cli.warn(g.ctx, "{s}: binary file matches", .{g.fname});
    }
    return status_matched;
}

fn grepOpened(g: *G, fd: i32, name: []const u8, is_stdin: bool, seekable_stdin: bool) bool {
    _ = is_stdin;
    g.fname = name;
    {
        var serr: LX.E = .SUCCESS;
        g.offset_width = 20;
        if (sys.fstatFd(fd, &serr)) |fst| {
            if (fst.isReg()) {
                var w: usize = 1;
                var sz = fst.size;
                while (sz >= 10) : (sz /= 10) w += 1;
                g.offset_width = w;
            }
        }
    }
    const count = grepFd(g, fd, seekable_stdin);
    const matched = finishFile(g, count);
    flushBefore(g);
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    return matched;
}

fn grepFile(g: *G, path: []const u8, display: []const u8, cmdline: bool, in_dir: bool) bool {
    const o = &g.o;
    // status of the file: true = matched
    var err: LX.E = .SUCCESS;
    var st_opt = sys.fileStat(path, cmdline or o.deref_recursive, &err);
    if (st_opt == null) {
        if (!(cmdline and false)) {
            if (!o.no_messages) cli.warn(g.ctx, "{s}: {s}", .{ display, sys.errnoText(err) });
            g.errseen = true;
        }
        return false;
    }
    const st = st_opt.?;
    st_opt = null;
    if (st.isDir()) {
        if (o.directories == .skip) return false;
        if (o.directories == .recurse) return grepDir(g, path, display, cmdline);
        if (!o.no_messages) cli.warn(g.ctx, "{s}: Is a directory", .{display});
        g.errseen = true;
        return false;
    }
    const kind = st.mode & 0o170000;
    const is_dev = kind == 0o020000 or kind == 0o060000 or kind == 0o010000 or kind == 0o140000;
    if (is_dev and (o.devices == .skip or (o.devices == .read_cmdline and in_dir))) return false;
    if (!cmdline or true) {
        const base = if (std.mem.lastIndexOfScalar(u8, display, '/')) |k| display[k + 1 ..] else display;
        if (g.globs.items.len > 0 and matchGlobs(g, display, base, cmdline and !in_dir)) return false;
    }
    var oerr: LX.E = .SUCCESS;
    const fd = sys.openFd(path, sys.O.RDONLY | 0o4000, 0, &oerr) orelse {
        if (!o.no_messages) cli.warn(g.ctx, "{s}: {s}", .{ display, sys.errnoText(oerr) });
        g.errseen = true;
        return false;
    };
    defer _ = sys.closeFd(fd);
    // refuse to read the output file
    if (g.stdout_st) |so| {
        if (!g.out_quiet and o.list == .none and so.isReg() and so.ino == st.ino and so.dev_major == st.dev_major and so.dev_minor == st.dev_minor and o.max_count > 1 and !o.count) {
            if (!o.no_messages) cli.warn(g.ctx, "{s}: input file is also the output", .{display});
            g.errseen = true;
            return false;
        }
    }
    g.show_name = switch (g.out_file) {
        1 => true,
        0 => false,
        else => in_dir,
    };
    return grepOpened(g, fd, display, false, false);
}

fn grepDir(g: *G, path: []const u8, display: []const u8, cmdline: bool) bool {
    const o = &g.o;
    if (dirExcluded(g, display, if (std.mem.lastIndexOfScalar(u8, display, '/')) |k| display[k + 1 ..] else display, cmdline)) return false;
    var any = false;
    const dir_h = Io.Dir.cwd().openDir(g.ctx.io, path, .{ .iterate = true }) catch |e| {
        const emap: LX.E = switch (e) {
            error.AccessDenied => .ACCES,
            error.FileNotFound => .NOENT,
            error.NotDir => .NOTDIR,
            else => .IO,
        };
        if (!o.no_messages) cli.warn(g.ctx, "{s}: {s}", .{ display, sys.errnoText(emap) });
        g.errseen = true;
        return false;
    };
    var dir = dir_h;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| g.gpa.free(n);
        names.deinit(g.gpa);
    }
    var it = dir.iterate();
    while (it.next(g.ctx.io) catch null) |entry| {
        const dup = g.gpa.dupe(u8, entry.name) catch oom(g.ctx);
        names.append(g.gpa, dup) catch oom(g.ctx);
    }
    dir.close(g.ctx.io);
    var pbase = path;
    while (pbase.len > 1 and pbase[pbase.len - 1] == '/') pbase = pbase[0 .. pbase.len - 1];
    var dbase = display;
    while (dbase.len > 1 and dbase[dbase.len - 1] == '/') dbase = dbase[0 .. dbase.len - 1];
    for (names.items) |n| {
        const child = if (std.mem.eql(u8, path, ".") and g.implicit_dot)
            std.fmt.allocPrint(g.gpa, "{s}", .{n}) catch oom(g.ctx)
        else
            std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ pbase, n }) catch oom(g.ctx);
        defer g.gpa.free(child);
        const disp = if (g.implicit_dot and std.mem.eql(u8, display, "."))
            std.fmt.allocPrint(g.gpa, "{s}", .{n}) catch oom(g.ctx)
        else
            std.fmt.allocPrint(g.gpa, "{s}/{s}", .{ dbase, n }) catch oom(g.ctx);
        defer g.gpa.free(disp);
        var err: LX.E = .SUCCESS;
        const lst = sys.fileStat(child, false, &err);
        if (lst) |l| {
            if (l.isLink() and !o.deref_recursive) continue;
        }
        if (grepFile(g, child, disp, false, true)) any = true;
    }
    return any;
}

// ---------------------------------------------------------------- patterns

fn wordSet(g: *G, flat: bool) []const u8 {
    _ = flat;
    _ = g;
    return "[A-Za-z0-9_]";
}

fn compilePattern(g: *G, pat: []const u8, flags_out: *posixre.Flags) ?[]u8 {
    const o = &g.o;
    const opts = posixre.Opts{ .utf8 = o.utf8, .icase = o.icase, .lenient_brace = true };
    switch (o.matcher) {
        .g, .e => {
            const body = posixre.translateFlags(g.gpa, pat, o.matcher == .e, opts, flags_out) catch |e| switch (e) {
                error.OutOfMemory => oom(g.ctx),
                error.BadPattern => {
                    cli.warn(g.ctx, "{s}", .{posixre.diagnoseGrep(pat, o.matcher == .e)});
                    return null;
                },
            };
            if (posixre.bareClass(pat)) {
                cli.warn(g.ctx, "character class syntax is [[:space:]], not [:space:]", .{});
                g.gpa.free(body);
                return null;
            }
            switch (flags_out.leading_op) {
                0 => {},
                '{' => cli.warn(g.ctx, "warning: {{...}} at start of expression", .{}),
                else => |ch| cli.warn(g.ctx, "warning: {c} at start of expression", .{ch}),
            }
            return body;
        },
        .f => {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < pat.len) {
                const c = pat[i];
                if (o.utf8 and c >= 0x80) {
                    const d = unicode.decode(pat, i);
                    if (d.valid) {
                        posixre.utf8Literal(g.gpa, &out, d.cp, o.icase) catch oom(g.ctx);
                        i += d.len;
                        continue;
                    }
                }
                if (c < 0x20 or c >= 0x7f) {
                    const hex = "0123456789abcdef";
                    out.appendSlice(g.gpa, &.{ '\\', 'x', hex[c >> 4], hex[c & 15] }) catch oom(g.ctx);
                } else {
                    if (std.mem.indexOfScalar(u8, "\\^$.|?*+()[]{}/#", c) != null) out.append(g.gpa, '\\') catch oom(g.ctx);
                    out.append(g.gpa, c) catch oom(g.ctx);
                }
                i += 1;
            }
            return out.toOwnedSlice(g.gpa) catch oom(g.ctx);
        },
        .p => {
            if (!o.utf8) return g.gpa.dupe(u8, pat) catch oom(g.ctx);
            return perlUtf8(g, pat);
        },
    }
}

/// PCRE2 in UTF mode: `.` and negated bracket expressions match characters.
fn perlUtf8(g: *G, pat: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    const mb = "[\\xc2-\\xdf][\\x80-\\xbf]|[\\xe0-\\xef][\\x80-\\xbf][\\x80-\\xbf]|[\\xf0-\\xf4][\\x80-\\xbf][\\x80-\\xbf][\\x80-\\xbf]";
    var i: usize = 0;
    while (i < pat.len) {
        const c = pat[i];
        if (c == '\\' and i + 1 < pat.len) {
            out.appendSlice(g.gpa, pat[i .. i + 2]) catch oom(g.ctx);
            i += 2;
            continue;
        }
        if (c == '.') {
            out.appendSlice(g.gpa, unicode.any_char) catch oom(g.ctx);
            i += 1;
            continue;
        }
        if (c == '[') {
            var j = i + 1;
            const neg = j < pat.len and pat[j] == '^';
            if (neg) j += 1;
            if (j < pat.len and pat[j] == ']') j += 1;
            while (j < pat.len and pat[j] != ']') : (j += 1) {
                if (pat[j] == '\\') j += 1;
                if (j < pat.len and pat[j] == '[' and j + 1 < pat.len and pat[j + 1] == ':') {
                    j = (std.mem.indexOfPos(u8, pat, j + 2, ":]") orelse pat.len - 1) + 1;
                }
            }
            if (j >= pat.len) {
                out.appendSlice(g.gpa, pat[i..]) catch oom(g.ctx);
                break;
            }
            if (neg) {
                out.appendSlice(g.gpa, "(?:") catch oom(g.ctx);
                out.appendSlice(g.gpa, pat[i..j]) catch oom(g.ctx);
                out.appendSlice(g.gpa, "\\x80-\\xff]|") catch oom(g.ctx);
                out.appendSlice(g.gpa, mb) catch oom(g.ctx);
                out.append(g.gpa, ')') catch oom(g.ctx);
            } else out.appendSlice(g.gpa, pat[i .. j + 1]) catch oom(g.ctx);
            i = j + 1;
            continue;
        }
        out.append(g.gpa, c) catch oom(g.ctx);
        i += 1;
    }
    return out.toOwnedSlice(g.gpa) catch oom(g.ctx);
}

fn addPattern(g: *G, pat: []const u8) bool {
    const o = &g.o;
    var flags: posixre.Flags = .{};
    const body = compilePattern(g, pat, &flags) orelse return false;
    defer g.gpa.free(body);
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(g.gpa);
    src.appendSlice(g.gpa, "(?s)") catch oom(g.ctx);
    if (o.line) {
        src.print(g.gpa, "\\A(?:{s})\\z", .{body}) catch oom(g.ctx);
    } else if (o.word and o.utf8) {
        var set: unicode.Set = .{};
        defer set.deinit(g.gpa);
        set.addAll(g.gpa, unicode.classRanges(.alnum)) catch oom(g.ctx);
        set.add(g.gpa, '_', '_') catch oom(g.ctx);
        var wg: std.ArrayList(u8) = .empty;
        defer wg.deinit(g.gpa);
        unicode.appendSetRegex(g.gpa, &wg, &set) catch oom(g.ctx);
        var wf: std.ArrayList(u8) = .empty;
        defer wf.deinit(g.gpa);
        unicode.appendSetFlat(g.gpa, &wf, &set) catch oom(g.ctx);
        src.print(g.gpa, "(?<!{s})(?:{s})(?!{s})", .{ wf.items, body, wg.items }) catch oom(g.ctx);
    } else if (o.word) {
        src.print(g.gpa, "(?<![A-Za-z0-9_])(?:{s})(?![A-Za-z0-9_])", .{body}) catch oom(g.ctx);
    } else src.appendSlice(g.gpa, body) catch oom(g.ctx);
    var re = regex.Regex.compile(g.gpa, src.items, .{ .dialect = .perl, .ignore_case = o.icase, .limits = posixre.big_limits }, null) catch {
        cli.warn(g.ctx, "{s}", .{if (o.matcher == .p) "invalid Perl regular expression" else posixre.diagnoseGrep(pat, o.matcher == .e)});
        return false;
    };
    var longest: ?regex.Regex = null;
    if (o.matcher != .p and !o.line and !o.word) {
        if (posixre.longestSource(g.gpa, body, "(?s)", flags) catch null) |ls| {
            defer g.gpa.free(ls);
            longest = regex.Regex.compile(g.gpa, ls, .{ .dialect = .perl, .ignore_case = o.icase, .limits = posixre.big_limits }, null) catch null;
        }
    }
    const p = g.gpa.create(Pat) catch oom(g.ctx);
    p.re = re;
    const fin = posixre.Finder.initParts(g.gpa, &p.re, if (longest) |*l| blk: {
        const keep = g.gpa.create(regex.Regex) catch oom(g.ctx);
        keep.* = l.*;
        break :blk keep;
    } else null) catch oom(g.ctx);
    p.fin = fin;
    p.mb = flags.mb;
    _ = &re;
    g.pats.append(g.gpa, p) catch oom(g.ctx);
    return true;
}

fn localeIsUtf8(ctx: cli.Context) bool {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |k| {
        const v = cli.getenv(ctx, k) orelse continue;
        if (v.len == 0) continue;
        return std.ascii.findIgnoreCase(v, "utf-8") != null or std.ascii.findIgnoreCase(v, "utf8") != null;
    }
    return false;
}

// ------------------------------------------------------------------ colors

fn parseColors(g: *G) void {
    if (cli.getenv(g.ctx, "GREP_COLOR")) |gc| {
        if (gc.len > 0) {
            cli.warn(g.ctx, "warning: GREP_COLOR='{s}' is deprecated; use GREP_COLORS='mt={s}'", .{ gc, gc });
            g.colors.ms = gc;
            g.colors.mc = gc;
        }
    }
    const env = cli.getenv(g.ctx, "GREP_COLORS") orelse return;
    var it = std.mem.splitScalar(u8, env, ':');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        var name = item;
        var val: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, item, '=')) |k| {
            name = item[0..k];
            val = item[k + 1 ..];
        }
        if (std.mem.eql(u8, name, "mt")) {
            if (val) |v| {
                g.colors.ms = v;
                g.colors.mc = v;
            }
        } else if (std.mem.eql(u8, name, "ms")) {
            if (val) |v| g.colors.ms = v;
        } else if (std.mem.eql(u8, name, "mc")) {
            if (val) |v| g.colors.mc = v;
        } else if (std.mem.eql(u8, name, "sl")) {
            if (val) |v| g.colors.sl = v;
        } else if (std.mem.eql(u8, name, "cx")) {
            if (val) |v| g.colors.cx = v;
        } else if (std.mem.eql(u8, name, "fn")) {
            if (val) |v| g.colors.fn_ = v;
        } else if (std.mem.eql(u8, name, "ln")) {
            if (val) |v| g.colors.ln = v;
        } else if (std.mem.eql(u8, name, "bn")) {
            if (val) |v| g.colors.bn = v;
        } else if (std.mem.eql(u8, name, "se")) {
            if (val) |v| g.colors.se = v;
        } else if (std.mem.eql(u8, name, "rv")) {
            g.colors.rv = true;
        } else if (std.mem.eql(u8, name, "ne")) {
            g.colors.ne = true;
        }
    }
}

// -------------------------------------------------------------------- main

fn usage(ctx: cli.Context) u8 {
    cli.writeStderr(ctx, "Usage: {s} [OPTION]... PATTERNS [FILE]...\nTry '{s} --help' for more information.", .{ ctx.name, ctx.name });
    return 2;
}

fn contextArg(g: *G, arg: []const u8) ?i64 {
    var v: i64 = 0;
    if (arg.len == 0) {
        cli.warn(g.ctx, "{s}: invalid context length argument", .{arg});
        return null;
    }
    for (arg) |ch| {
        if (!std.ascii.isDigit(ch)) {
            cli.warn(g.ctx, "{s}: invalid context length argument", .{arg});
            return null;
        }
        v = v *| 10 +| (ch - '0');
    }
    return v;
}

pub fn main(ctx: cli.Context) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g = G{ .ctx = ctx, .gpa = std.heap.smp_allocator };
    g.o.utf8 = localeIsUtf8(ctx);

    var p = getopt.Parser.init(ctx, "0123456789A:B:C:D:EFGHIPTUVX:abcd:e:f:hiLlm:noqRrsuvwxyZz", &.{
        .{ .name = "basic-regexp", .id = 'G' },
        .{ .name = "extended-regexp", .id = 'E' },
        .{ .name = "fixed-regexp", .id = 'F' },
        .{ .name = "fixed-strings", .id = 'F' },
        .{ .name = "perl-regexp", .id = 'P' },
        .{ .name = "after-context", .arg = .required, .id = 'A' },
        .{ .name = "before-context", .arg = .required, .id = 'B' },
        .{ .name = "binary-files", .arg = .required, .id = 1100 },
        .{ .name = "byte-offset", .id = 'b' },
        .{ .name = "context", .arg = .required, .id = 'C' },
        .{ .name = "color", .arg = .optional, .id = 1101 },
        .{ .name = "colour", .arg = .optional, .id = 1101 },
        .{ .name = "count", .id = 'c' },
        .{ .name = "dereference-recursive", .id = 'R' },
        .{ .name = "devices", .arg = .required, .id = 'D' },
        .{ .name = "directories", .arg = .required, .id = 'd' },
        .{ .name = "exclude", .arg = .required, .id = 1102 },
        .{ .name = "exclude-from", .arg = .required, .id = 1103 },
        .{ .name = "exclude-dir", .arg = .required, .id = 1104 },
        .{ .name = "file", .arg = .required, .id = 'f' },
        .{ .name = "files-with-matches", .id = 'l' },
        .{ .name = "files-without-match", .id = 'L' },
        .{ .name = "group-separator", .arg = .required, .id = 1105 },
        .{ .name = "include", .arg = .required, .id = 1106 },
        .{ .name = "ignore-case", .id = 'i' },
        .{ .name = "no-ignore-case", .id = 1107 },
        .{ .name = "initial-tab", .id = 'T' },
        .{ .name = "label", .arg = .required, .id = 1108 },
        .{ .name = "line-buffered", .id = 1109 },
        .{ .name = "line-number", .id = 'n' },
        .{ .name = "line-regexp", .id = 'x' },
        .{ .name = "max-count", .arg = .required, .id = 'm' },
        .{ .name = "no-filename", .id = 'h' },
        .{ .name = "no-group-separator", .id = 1110 },
        .{ .name = "no-messages", .id = 's' },
        .{ .name = "null", .id = 'Z' },
        .{ .name = "null-data", .id = 'z' },
        .{ .name = "only-matching", .id = 'o' },
        .{ .name = "quiet", .id = 'q' },
        .{ .name = "recursive", .id = 'r' },
        .{ .name = "regexp", .arg = .required, .id = 'e' },
        .{ .name = "invert-match", .id = 'v' },
        .{ .name = "silent", .id = 'q' },
        .{ .name = "text", .id = 'a' },
        .{ .name = "binary", .id = 'U' },
        .{ .name = "with-filename", .id = 'H' },
        .{ .name = "word-regexp", .id = 'w' },
    });
    defer p.deinit();
    p.no_try = true;

    var matcher_set = false;
    var keys: std.ArrayList(u8) = .empty;
    var have_keys = false;
    var digit_val: i64 = 0;
    var last_digit_idx: usize = std.math.maxInt(usize);
    var default_ctx: i64 = -1;
    while (true) {
        const idx_before = p.index;
        switch (p.next()) {
            .done => break,
            .bad => return usage(ctx),
            .opt => |opt| switch (opt.id) {
                '0'...'9' => {
                    if (last_digit_idx == idx_before and p.sub != 0 or last_digit_idx == idx_before) {
                        digit_val = digit_val *| 10 +| (opt.id - '0');
                    } else digit_val = opt.id - '0';
                    last_digit_idx = idx_before;
                    default_ctx = digit_val;
                },
                'A' => g.o.after = contextArg(&g, opt.arg.?) orelse return 2,
                'B' => g.o.before = contextArg(&g, opt.arg.?) orelse return 2,
                'C' => default_ctx = contextArg(&g, opt.arg.?) orelse return 2,
                'D' => {
                    const t = [_]argmatch.Entry{};
                    _ = t;
                    if (std.mem.eql(u8, opt.arg.?, "read")) g.o.devices = .read else if (std.mem.eql(u8, opt.arg.?, "skip")) g.o.devices = .skip else {
                        cli.warn(ctx, "unknown devices method", .{});
                        return 2;
                    }
                },
                'E' => {
                    if (matcher_set and g.o.matcher != .e) {
                        cli.warn(ctx, "conflicting matchers specified", .{});
                        return 2;
                    }
                    matcher_set = true;
                    g.o.matcher = .e;
                },
                'F' => {
                    if (matcher_set and g.o.matcher != .f) {
                        cli.warn(ctx, "conflicting matchers specified", .{});
                        return 2;
                    }
                    matcher_set = true;
                    g.o.matcher = .f;
                },
                'G' => {
                    if (matcher_set and g.o.matcher != .g) {
                        cli.warn(ctx, "conflicting matchers specified", .{});
                        return 2;
                    }
                    matcher_set = true;
                    g.o.matcher = .g;
                },
                'P' => {
                    if (matcher_set and g.o.matcher != .p) {
                        cli.warn(ctx, "conflicting matchers specified", .{});
                        return 2;
                    }
                    matcher_set = true;
                    g.o.matcher = .p;
                },
                'X' => {
                    const a = opt.arg.?;
                    if (std.mem.eql(u8, a, "grep")) g.o.matcher = .g else if (std.mem.eql(u8, a, "egrep")) g.o.matcher = .e else if (std.mem.eql(u8, a, "fgrep")) g.o.matcher = .f else if (std.mem.eql(u8, a, "perl")) g.o.matcher = .p else {
                        cli.warn(ctx, "invalid matcher {s}", .{a});
                        return 2;
                    }
                },
                'H' => g.o.filename_opt = 1,
                'I' => g.o.binary_files = .without_match,
                'T' => g.o.initial_tab = true,
                'U' => {},
                'u' => return usage(ctx),
                'V' => return version(ctx),
                'a' => g.o.binary_files = .text,
                'b' => g.o.byte_offset = true,
                'c' => g.o.count = true,
                'd' => {
                    const a = opt.arg.?;
                    const tbl = [_]argmatch.Entry{ .{ .name = "read", .value = 0 }, .{ .name = "recurse", .value = 1 }, .{ .name = "skip", .value = 2 } };
                    switch (argmatch.match(a, &tbl)) {
                        .ok => |v| g.o.directories = switch (v) {
                            0 => .read,
                            1 => .recurse,
                            else => .skip,
                        },
                        else => |r| {
                            argmatch.dieEx(ctx, a, "--directories", &tbl, r, "Usage: grep [OPTION]... PATTERNS [FILE]...");
                            return 1;
                        },
                    }
                },
                'e' => {
                    keys.appendSlice(g.gpa, opt.arg.?) catch oom(ctx);
                    keys.append(g.gpa, '\n') catch oom(ctx);
                    have_keys = true;
                },
                'f' => {
                    const name = opt.arg.?;
                    var err: LX.E = .SUCCESS;
                    const fd: i32 = if (std.mem.eql(u8, name, "-")) 0 else sys.openFd(name, sys.O.RDONLY, 0, &err) orelse {
                        cli.warn(ctx, "{s}: {s}", .{ name, sys.errnoText(err) });
                        return 2;
                    };
                    var data: std.ArrayList(u8) = .empty;
                    var buf: [65536]u8 = undefined;
                    while (true) {
                        const n = sys.readFd(fd, &buf, &err) orelse {
                            cli.warn(ctx, "{s}: {s}", .{ name, sys.errnoText(err) });
                            return 2;
                        };
                        if (n == 0) break;
                        data.appendSlice(g.gpa, buf[0..n]) catch oom(ctx);
                    }
                    if (fd != 0) _ = sys.closeFd(fd);
                    have_keys = true;
                    if (data.items.len > 0) {
                        keys.appendSlice(g.gpa, data.items) catch oom(ctx);
                        if (data.items[data.items.len - 1] != '\n') keys.append(g.gpa, '\n') catch oom(ctx);
                    }
                },
                'h' => g.o.filename_opt = 0,
                'i', 'y' => g.o.icase = true,
                'L' => g.o.list = .nonmatching,
                'l' => g.o.list = .matching,
                'm' => {
                    const a = opt.arg.?;
                    var v: i64 = 0;
                    var neg = false;
                    var s = a;
                    if (s.len > 0 and s[0] == '-') {
                        neg = true;
                        s = s[1..];
                    }
                    if (s.len == 0) {
                        cli.warn(ctx, "invalid max count", .{});
                        return 2;
                    }
                    for (s) |ch| {
                        if (!std.ascii.isDigit(ch)) {
                            cli.warn(ctx, "invalid max count", .{});
                            return 2;
                        }
                        v = v *| 10 +| (ch - '0');
                    }
                    g.o.max_count = if (neg) std.math.maxInt(i64) else v;
                },
                'n' => g.o.line_number = true,
                'o' => g.o.only = true,
                'q' => g.exit_on_match = true,
                'R' => {
                    g.o.deref_recursive = true;
                    g.o.directories = .recurse;
                },
                'r' => {
                    g.o.directories = .recurse;
                    g.o.deref_recursive = false;
                },
                's' => g.o.no_messages = true,
                'v' => g.o.invert = true,
                'w' => g.o.word = true,
                'x' => g.o.line = true,
                'Z' => g.o.null_after_name = true,
                'z' => {
                    g.o.null_data = true;
                    g.eol = 0;
                },
                1100 => {
                    const a = opt.arg.?;
                    if (std.mem.eql(u8, a, "binary")) g.o.binary_files = .binary else if (std.mem.eql(u8, a, "text")) g.o.binary_files = .text else if (std.mem.eql(u8, a, "without-match")) g.o.binary_files = .without_match else {
                        cli.warn(ctx, "unknown binary-files type", .{});
                        return 2;
                    }
                },
                1101 => {
                    const a = opt.arg;
                    if (a == null) g.o.color = colorAuto(ctx) else if (std.mem.eql(u8, a.?, "always") or std.mem.eql(u8, a.?, "yes") or std.mem.eql(u8, a.?, "force")) g.o.color = true else if (std.mem.eql(u8, a.?, "never") or std.mem.eql(u8, a.?, "no") or std.mem.eql(u8, a.?, "none")) g.o.color = false else if (std.mem.eql(u8, a.?, "auto") or std.mem.eql(u8, a.?, "tty") or std.mem.eql(u8, a.?, "if-tty")) g.o.color = colorAuto(ctx) else {
                        return if (cli.writeStdout(ctx.io, help_text)) 0 else 2;
                    }
                },
                1102 => g.globs.append(g.gpa, .{ .pat = opt.arg.?, .include = false }) catch oom(ctx),
                1103 => {
                    const name = opt.arg.?;
                    var err: LX.E = .SUCCESS;
                    const fd = sys.openFd(name, sys.O.RDONLY, 0, &err) orelse {
                        cli.warn(ctx, "{s}: {s}", .{ name, sys.errnoText(err) });
                        return 2;
                    };
                    var data: std.ArrayList(u8) = .empty;
                    var buf: [65536]u8 = undefined;
                    while (true) {
                        const n = sys.readFd(fd, &buf, &err) orelse break;
                        if (n == 0) break;
                        data.appendSlice(arena, buf[0..n]) catch oom(ctx);
                    }
                    _ = sys.closeFd(fd);
                    var lines = std.mem.splitScalar(u8, data.items, '\n');
                    while (lines.next()) |ln| {
                        if (ln.len == 0) continue;
                        g.globs.append(g.gpa, .{ .pat = ln, .include = false }) catch oom(ctx);
                    }
                },
                1104 => g.excl_dirs.append(g.gpa, opt.arg.?) catch oom(ctx),
                1105 => g.o.group_sep = opt.arg.?,
                1106 => g.globs.append(g.gpa, .{ .pat = opt.arg.?, .include = true }) catch oom(ctx),
                1107 => g.o.icase = false,
                1108 => g.o.label = opt.arg.?,
                1109 => g.o.line_buffered = true,
                1110 => g.o.group_sep = null,
                getopt.help_id => return if (cli.writeStdout(ctx.io, help_text)) 0 else 2,
                getopt.version_id => return version(ctx),
                else => return usage(ctx),
            },
        }
    }

    var operands = p.operands.items;
    if (!have_keys) {
        if (operands.len == 0) return usage(ctx);
        keys.appendSlice(g.gpa, operands[0]) catch oom(ctx);
        keys.append(g.gpa, '\n') catch oom(ctx);
        operands = operands[1..];
    }
    if (default_ctx >= 0) {
        if (g.o.after < 0) g.o.after = default_ctx;
        if (g.o.before < 0) g.o.before = default_ctx;
    }
    // patterns
    var keycc: usize = 0;
    if (have_keys and keys.items.len == 0) {
        // no keys at all (-f /dev/null): match nothing
        g.o.invert = !g.o.invert;
        g.o.line = false;
        g.o.word = false;
        keycc = 0;
    } else {
        _ = keys.pop();
        keycc = keys.items.len;
    }
    if ((g.o.max_count == 0 or (keycc == 0 and g.o.invert and !g.o.line and !g.o.word)) and g.o.list != .nonmatching) return 1;
    {
        var it = std.mem.splitScalar(u8, keys.items, '\n');
        while (it.next()) |pt| {
            if (!addPattern(&g, pt)) return 2;
        }
    }

    if (g.o.color) parseColors(&g);
    g.exit_on_match = g.exit_on_match;
    g.done_on_match = g.exit_on_match or g.o.list != .none;
    g.out_quiet = g.o.count or g.done_on_match;
    if (g.exit_on_match) g.out_quiet = true;
    if (g.o.list != .none) g.out_quiet = true;
    // -q with -c / -l: quiet output wins
    if (g.exit_on_match) {
        g.o.count = false;
        g.o.list = .none;
    }
    if (g.o.max_count < 0) g.o.max_count = std.math.maxInt(i64);

    // stdout identity for the "input file is also the output" check
    {
        var serr: LX.E = .SUCCESS;
        g.stdout_st = sys.fstatFd(1, &serr);
    }
    if (g.o.before < 0 and g.o.after < 0) {}

    g.out_file = if (g.o.filename_opt >= 0)
        g.o.filename_opt
    else if (operands.len > 1)
        1
    else if (g.o.directories == .recurse)
        -1
    else
        0;

    var any = false;
    var implicit = false;
    const dot = [_][]const u8{"."};
    const dash = [_][]const u8{"-"};
    var files: []const []const u8 = operands;
    if (files.len == 0) {
        if (g.o.directories == .recurse) {
            files = &dot;
            implicit = true;
        } else files = &dash;
    }
    g.implicit_dot = implicit;
    for (files) |f| {
        if (std.mem.eql(u8, f, "-") and !implicit) {
            g.show_name = g.out_file == 1;
            var serr: LX.E = .SUCCESS;
            const seekable = blk: {
                const r = sys.seekFd(0, 0, 1, &serr);
                break :blk r != null;
            };
            if (grepOpened(&g, 0, g.o.label, true, seekable)) any = true;
        } else {
            if (grepFile(&g, f, f, true, false)) any = true;
        }
    }
    flushOut(&g);
    if (g.errseen) return 2;
    return if (any) 0 else 1;
}

fn colorAuto(ctx: cli.Context) bool {
    const term = cli.getenv(ctx, "TERM") orelse return false;
    if (std.mem.eql(u8, term, "dumb")) return false;
    return Io.File.stdout().isTty(ctx.io) catch false;
}

fn version(ctx: cli.Context) u8 {
    const v =
        \\grep (GNU grep) 3.12
        \\Copyright (C) 2025 Free Software Foundation, Inc.
        \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
        \\This is free software: you are free to change and redistribute it.
        \\There is NO WARRANTY, to the extent permitted by law.
        \\
        \\Written by Mike Haertel and others; see
        \\<https://git.savannah.gnu.org/cgit/grep.git/tree/AUTHORS>.
        \\
    ;
    return if (cli.writeStdout(ctx.io, v)) 0 else 2;
}
