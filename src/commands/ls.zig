//! ls, dir and vdir — list directory contents.
//!
//! References, consulted 2026-11-07: GNU coreutils manual "ls invocation"
//! (9.7), POSIX.1-2024 ls, and GNU coreutils 9.6 src/ls.c (algorithms for
//! column layout, sorting, quoting and the long format were studied there and
//! rewritten). Behaviour is the C locale only: byte-wise name order, ASCII
//! printability, `Mon DD HH:MM` dates. Not implemented: ACL/xattr details
//! beyond detecting their presence, SELinux contexts other than reading
//! security.selinux, and capability colouring.

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const userdb = @import("../userdb.zig");
const quotearg = @import("../quotearg.zig");
const human = @import("../human.zig");
const argmatch = @import("../argmatch.zig");
const filevercmp = @import("../filevercmp.zig");
const fnmatch = @import("../fnmatch.zig");
const paths = @import("../paths.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const help_ls = @embedFile("../help/ls.txt");
const help_dir = @embedFile("../help/dir.txt");
const help_vdir = @embedFile("../help/vdir.txt");

pub const Mode = enum { ls, multi_col, long };

const Format = enum { long, one_per_line, many_per_line, horizontal, with_commas };
const IndicatorStyle = enum(u8) { none, slash, file_type, classify };
const SortType = enum(u8) { name, extension, width, size, version, time, none };
const TimeType = enum(u8) { mtime, ctime, atime, btime };
const Deref = enum { undefined, never, command_line_args, command_line_symlink_to_dir, always };
const IgnoreMode = enum { default, dot_and_dotdot, minimal };
const FileType = enum { unknown, fifo, chardev, directory, blockdev, normal, symbolic_link, sock, whiteout, arg_directory };
const AclType = enum { none, unknown, lsm_context_only, yes };

const filetype_letter = [_]u8{ '?', 'p', 'c', 'd', 'b', '-', 'l', 's', 'w', 'd' };

const NOT_AN_INODE: u64 = std.math.maxInt(u64);

// Indicator numbers (LS_COLORS two-letter codes).
const C_LEFT = 0;
const C_RIGHT = 1;
const C_END = 2;
const C_RESET = 3;
const C_NORM = 4;
const C_FILE = 5;
const C_DIR = 6;
const C_LINK = 7;
const C_FIFO = 8;
const C_SOCK = 9;
const C_BLK = 10;
const C_CHR = 11;
const C_MISSING = 12;
const C_ORPHAN = 13;
const C_EXEC = 14;
const C_DOOR = 15;
const C_SETUID = 16;
const C_SETGID = 17;
const C_STICKY = 18;
const C_OTHER_WRITABLE = 19;
const C_STICKY_OTHER_WRITABLE = 20;
const C_CAP = 21;
const C_MULTIHARDLINK = 22;
const C_CLR_TO_EOL = 23;
const indicator_count = 24;

const indicator_name = [indicator_count][2]u8{
    .{ 'l', 'c' }, .{ 'r', 'c' }, .{ 'e', 'c' }, .{ 'r', 's' }, .{ 'n', 'o' },
    .{ 'f', 'i' }, .{ 'd', 'i' }, .{ 'l', 'n' }, .{ 'p', 'i' }, .{ 's', 'o' },
    .{ 'b', 'd' }, .{ 'c', 'd' }, .{ 'm', 'i' }, .{ 'o', 'r' }, .{ 'e', 'x' },
    .{ 'd', 'o' }, .{ 's', 'u' }, .{ 's', 'g' }, .{ 's', 't' }, .{ 'o', 'w' },
    .{ 't', 'w' }, .{ 'c', 'a' }, .{ 'm', 'h' }, .{ 'c', 'l' },
};

const default_indicators = [indicator_count]?[]const u8{
    "\x1b[", "m", null, "0", null, null, "01;34", "01;36", "33", "01;35",
    "01;33", "01;33", null, null, "01;32", "01;35", "37;41", "30;43", "37;44", "34;42",
    "30;42", null, null, "\x1b[K",
};

const ColorExt = struct {
    ext: []const u8,
    seq: []const u8 = "",
    exact: bool = false,
    ignored: bool = false,
};

const FileInfo = struct {
    name: []const u8,
    linkname: ?[]const u8 = null,
    absolute_name: ?[]const u8 = null,
    st: sys.FileStat = undefined,
    filetype: FileType = .unknown,
    linkmode: u32 = 0,
    scontext: []const u8 = "?",
    stat_ok: bool = false,
    linkok: bool = false,
    acl_type: AclType = .none,
    has_capability: bool = false,
    quoted: i8 = -1,
    width: usize = 0,
};

const Pending = struct {
    name: ?[]u8,
    realname: ?[]u8,
    command_line_arg: bool,
};

const DevIno = struct { dev: u64, ino: u64 };

const ColumnInfo = struct {
    valid_len: bool,
    line_len: usize,
    col_arr: []usize,
};

const MIN_COLUMN_WIDTH = 3;

const Ts = struct { sec: i64, nsec: i64 };

fn decLen(v: u64) usize {
    var tmp: [24]u8 = undefined;
    const t: []const u8 = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "";
    return t.len;
}

const Ls = struct {
    ctx: cli.Context,
    mode: Mode,
    out: cli.Out,
    /// Per-directory storage (file names, link targets); reset by clearFiles.
    arena: std.heap.ArenaAllocator,
    /// Storage that lives for the whole run (LS_COLORS strings).
    cfg: std.heap.ArenaAllocator,
    gpa: Allocator,

    // Options.
    format: Format = .one_per_line,
    time_type: TimeType = .mtime,
    explicit_time: bool = false,
    sort_type: SortType = .name,
    sort_reverse: bool = false,
    print_owner: bool = true,
    print_author: bool = false,
    print_group: bool = true,
    numeric_ids: bool = false,
    print_block_size: bool = false,
    human_output_opts: u32 = 0,
    output_block_size: u64 = 0,
    file_human_output_opts: u32 = 0,
    file_output_block_size: u64 = 1,
    dired: bool = false,
    indicator_style: IndicatorStyle = .none,
    print_with_color: bool = false,
    print_hyperlink: bool = false,
    used_color: bool = false,
    check_symlink_mode: bool = false,
    print_inode: bool = false,
    dereference: Deref = .undefined,
    recursive: bool = false,
    immediate_dirs: bool = false,
    directories_first: bool = false,
    ignore_mode: IgnoreMode = .default,
    ignore_patterns: std.ArrayList([]const u8) = .empty,
    hide_patterns: std.ArrayList([]const u8) = .empty,
    qmark_funny_chars: bool = false,
    filename_style: quotearg.Style = .literal,
    filename_extra: quotearg.ExtraSet = .{},
    dirname_extra: quotearg.ExtraSet = .{},
    tabsize: usize = 8,
    print_dir_name: bool = true,
    line_length: usize = 80,
    max_idx: usize = 0,
    print_scontext: bool = false,
    eolbyte: u8 = '\n',
    long_time_format: [2][]const u8 = .{ "%b %e  %Y", "%b %e %H:%M" },
    align_variable_outer_quotes: bool = false,
    format_needs_stat: bool = false,
    format_needs_type: bool = false,
    format_needs_capability: bool = false,

    // Colors.
    indicators: [indicator_count]?[]const u8 = default_indicators,
    ext_list: std.ArrayList(ColorExt) = .empty,
    color_symlink_as_referent: bool = false,

    // State.
    exit_status: u8 = 0,
    zone: tzmod.Zone = undefined,
    zone_loaded: bool = false,
    current_time_sec: i64 = std.math.minInt(i64),
    current_time_nsec: i64 = -1,
    db: ?userdb.Db = null,
    user_cache: std.AutoHashMap(u32, ?[]const u8),
    group_cache: std.AutoHashMap(u32, ?[]const u8),
    hostname: []const u8 = "",
    rfc3986: [256]bool = @splat(false),

    files: std.ArrayList(*FileInfo) = .empty,
    cwd_some_quoted: bool = false,
    any_has_acl: bool = false,
    inode_number_width: usize = 0,
    block_size_width: usize = 0,
    nlink_width: usize = 0,
    scontext_width: usize = 0,
    owner_width: usize = 0,
    group_width: usize = 0,
    author_width: usize = 0,
    major_device_number_width: usize = 0,
    minor_device_number_width: usize = 0,
    file_size_width: usize = 0,

    pending: std.ArrayList(Pending) = .empty,
    active: std.ArrayList(DevIno) = .empty,
    loop_detect: bool = false,
    first_dir: bool = true,

    dired_pos: i64 = 0,
    dired_offsets: std.ArrayList(i64) = .empty,
    subdired_offsets: std.ArrayList(i64) = .empty,

    fn alloc(s: *Ls) Allocator {
        return s.arena.allocator();
    }

    // ------------------------------------------------------------ output

    fn put(s: *Ls, bytes: []const u8) void {
        s.out.write(bytes);
        s.dired_pos += @intCast(bytes.len);
    }

    fn putByte(s: *Ls, b: u8) void {
        s.out.writeByte(b);
        s.dired_pos += 1;
    }

    fn pad(s: *Ls, n: usize) void {
        var k = n;
        while (k > 0) : (k -= 1) s.putByte(' ');
    }

    fn putRight(s: *Ls, text: []const u8, width: usize) void {
        if (text.len < width) s.pad(width - text.len);
        s.put(text);
    }

    fn fmt(s: *Ls, comptime f: []const u8, args: anytype) void {
        var tmp: [1024]u8 = undefined;
        const t = std.fmt.bufPrint(&tmp, f, args) catch return;
        s.put(t);
    }

    fn diredIndent(s: *Ls) void {
        if (s.dired) s.put("  ");
    }

    fn pushDiredPos(s: *Ls, list: *std.ArrayList(i64)) void {
        if (s.dired) list.append(s.gpa, s.dired_pos) catch {};
    }

    // ----------------------------------------------------------- failures

    fn setExitStatus(s: *Ls, serious: bool) void {
        if (serious) {
            s.exit_status = 2;
        } else if (s.exit_status == 0) s.exit_status = 1;
    }

    fn fileFailureErrno(s: *Ls, serious: bool, comptime msg: []const u8, file: []const u8, e: std.os.linux.E) void {
        cli.warn(s.ctx, msg ++ ": {s}", .{ cli.quoteA(file), sys.errnoText(e) });
        s.setExitStatus(serious);
    }

    fn fileFailureText(s: *Ls, serious: bool, comptime msg: []const u8, file: []const u8, text: []const u8) void {
        cli.warn(s.ctx, msg ++ ": {s}", .{ cli.quoteA(file), text });
        s.setExitStatus(serious);
    }

    // -------------------------------------------------------------- colors

    fn isColored(s: *const Ls, t: usize) bool {
        const str = s.indicators[t] orelse return false;
        if (str.len == 0) return false;
        if (str.len > 2) return true;
        return str[0] != '0' or str[str.len - 1] != '0';
    }

    fn indicatorStr(s: *const Ls, t: usize) []const u8 {
        return s.indicators[t] orelse "";
    }

    fn putIndicator(s: *Ls, ind: []const u8) void {
        if (!s.used_color) {
            s.used_color = true;
            s.prepNonFilenameText();
        }
        s.out.write(ind);
    }

    fn prepNonFilenameText(s: *Ls) void {
        if (s.indicators[C_END]) |e| {
            s.putIndicator(e);
        } else {
            s.putIndicator(s.indicatorStr(C_LEFT));
            s.putIndicator(s.indicatorStr(C_RESET));
            s.putIndicator(s.indicatorStr(C_RIGHT));
        }
    }

    fn restoreDefaultColor(s: *Ls) void {
        s.putIndicator(s.indicatorStr(C_LEFT));
        s.putIndicator(s.indicatorStr(C_RIGHT));
    }

    fn setNormalColor(s: *Ls) void {
        if (s.print_with_color and s.isColored(C_NORM)) {
            s.putIndicator(s.indicatorStr(C_LEFT));
            s.putIndicator(s.indicatorStr(C_NORM));
            s.putIndicator(s.indicatorStr(C_RIGHT));
        }
    }

    fn printColorIndicator(s: *Ls, ind: ?[]const u8) bool {
        if (ind) |i| {
            if (s.isColored(C_NORM)) s.restoreDefaultColor();
            s.putIndicator(s.indicatorStr(C_LEFT));
            s.putIndicator(i);
            s.putIndicator(s.indicatorStr(C_RIGHT));
            return true;
        }
        return false;
    }

    fn knownTermType(s: *Ls) bool {
        const term = cli.getenv(s.ctx, "TERM") orelse return false;
        if (term.len == 0) return false;
        const patterns = [_][]const u8{
            "Eterm",   "ansi",   "*color*",    "con[0-9]*x[0-9]*", "cons25", "console", "cygwin", "*direct*",
            "dtterm",  "gnome",  "hurd",       "jfbterm",          "konsole", "kterm",  "linux",  "linux-c",
            "mlterm",  "putty",  "rxvt*",      "screen*",          "st",      "terminator", "tmux*", "vt100",
            "vt220",   "xterm*",
        };
        for (patterns) |p| if (fnmatch.match(p, term, .{})) return true;
        return false;
    }

    /// Decode one LS_COLORS string; returns the decoded bytes and advances
    /// `pos`. null when the text is malformed.
    fn getFunnyString(s: *Ls, text: []const u8, pos: *usize, equals_end: bool) ?[]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        var p = pos.*;
        const State = enum { gnd, backslash, octal, hex, caret, end, err };
        var state: State = .gnd;
        var num: u8 = 0;
        const a = s.cfg.allocator();
        while (state != .end and state != .err) {
            const c: u8 = if (p < text.len) text[p] else 0;
            switch (state) {
                .gnd => switch (c) {
                    ':', 0 => state = .end,
                    '\\' => {
                        state = .backslash;
                        p += 1;
                    },
                    '^' => {
                        state = .caret;
                        p += 1;
                    },
                    '=' => if (equals_end) {
                        state = .end;
                    } else {
                        buf.append(a, c) catch return null;
                        p += 1;
                    },
                    else => {
                        buf.append(a, c) catch return null;
                        p += 1;
                    },
                },
                .backslash => {
                    switch (c) {
                        '0'...'7' => {
                            state = .octal;
                            num = c - '0';
                        },
                        'x', 'X' => {
                            state = .hex;
                            num = 0;
                        },
                        'a' => num = 7,
                        'b' => num = 8,
                        'e' => num = 27,
                        'f' => num = 12,
                        'n' => num = '\n',
                        'r' => num = '\r',
                        't' => num = '\t',
                        'v' => num = 11,
                        '?' => num = 127,
                        '_' => num = ' ',
                        0 => state = .err,
                        else => num = c,
                    }
                    if (state == .backslash) {
                        buf.append(a, num) catch return null;
                        state = .gnd;
                    }
                    p += 1;
                },
                .octal => {
                    if (c < '0' or c > '7') {
                        buf.append(a, num) catch return null;
                        state = .gnd;
                    } else {
                        num = (num << 3) +% (c - '0');
                        p += 1;
                    }
                },
                .hex => {
                    switch (c) {
                        '0'...'9' => {
                            num = (num << 4) +% (c - '0');
                            p += 1;
                        },
                        'a'...'f' => {
                            num = (num << 4) +% (c - 'a') +% 10;
                            p += 1;
                        },
                        'A'...'F' => {
                            num = (num << 4) +% (c - 'A') +% 10;
                            p += 1;
                        },
                        else => {
                            buf.append(a, num) catch return null;
                            state = .gnd;
                        },
                    }
                },
                .caret => {
                    state = .gnd;
                    if (c >= '@' and c <= '~') {
                        buf.append(a, c & 0o37) catch return null;
                        p += 1;
                    } else if (c == '?') {
                        // GNU does not consume the '?' here, so it is then
                        // read again as a literal character.
                        buf.append(a, 127) catch return null;
                    } else state = .err;
                },
                .end, .err => unreachable,
            }
        }
        pos.* = p;
        if (state == .err) return null;
        return buf.items;
    }

    fn parseLsColor(s: *Ls) void {
        const lsc = cli.getenv(s.ctx, "LS_COLORS");
        if (lsc == null or lsc.?.len == 0) {
            const ct = cli.getenv(s.ctx, "COLORTERM");
            if (!(ct != null and ct.?.len > 0) and !s.knownTermType()) s.print_with_color = false;
            return;
        }
        const text = lsc.?;
        var p: usize = 0;
        const St = enum { start, p2, p3, p4, done, fail };
        var state: St = .start;
        var label0: u8 = 0;
        var label1: u8 = 0;
        var cur_ext: usize = 0;
        while (true) {
            switch (state) {
                .start => {
                    const c: u8 = if (p < text.len) text[p] else 0;
                    switch (c) {
                        ':' => p += 1,
                        '*' => {
                            p += 1;
                            cur_ext = s.ext_list.items.len;
                            const e = s.getFunnyString(text, &p, true);
                            if (e) |ee| {
                                s.ext_list.append(s.gpa, .{ .ext = ee }) catch {};
                                state = .p4;
                            } else state = .fail;
                        },
                        0 => {
                            state = .done;
                        },
                        else => {
                            label0 = c;
                            p += 1;
                            state = .p2;
                        },
                    }
                },
                .p2 => {
                    if (p < text.len) {
                        label1 = text[p];
                        p += 1;
                        state = .p3;
                    } else state = .fail;
                },
                .p3 => {
                    state = .fail;
                    const c: u8 = if (p < text.len) text[p] else 0;
                    p += 1;
                    if (c == '=') {
                        for (indicator_name, 0..) |nm, i| {
                            if (label0 == nm[0] and label1 == nm[1]) {
                                if (s.getFunnyString(text, &p, false)) |v| {
                                    s.indicators[i] = v;
                                    state = .start;
                                }
                                break;
                            }
                        }
                        if (state == .fail) {
                            const lab = [_]u8{ label0, label1 };
                            cli.warn(s.ctx, "unrecognized prefix: {f}", .{cli.quoteC(&lab)});
                        }
                    }
                },
                .p4 => {
                    const c: u8 = if (p < text.len) text[p] else 0;
                    p += 1;
                    if (c == '=') {
                        if (s.getFunnyString(text, &p, false)) |v| {
                            s.ext_list.items[cur_ext].seq = v;
                            state = .start;
                        } else state = .fail;
                    } else state = .fail;
                },
                .fail, .done => break,
            }
            if (state == .done) break;
        }
        if (state == .fail) {
            cli.warn(s.ctx, "unparsable value for LS_COLORS environment variable", .{});
            s.ext_list.clearRetainingCapacity();
            s.print_with_color = false;
        } else {
            // Later definitions override earlier ones: GNU's list is
            // head-first, i.e. our list read from the end.
            const items = s.ext_list.items;
            var ii = items.len;
            while (ii > 0) {
                ii -= 1;
                const e1 = &items[ii];
                var case_ignored = false;
                var jj = ii;
                while (jj > 0) {
                    jj -= 1;
                    const e2 = &items[jj];
                    if (!e2.ignored and e1.ext.len == e2.ext.len) {
                        if (std.mem.eql(u8, e1.ext, e2.ext)) {
                            e2.ignored = true;
                        } else if (std.ascii.eqlIgnoreCase(e1.ext, e2.ext)) {
                            if (case_ignored) {
                                e2.ignored = true;
                            } else if (std.mem.eql(u8, e1.seq, e2.seq)) {
                                e2.ignored = true;
                                case_ignored = true;
                            } else {
                                e1.exact = true;
                                e2.exact = true;
                            }
                        }
                    }
                }
            }
        }
        if (s.indicators[C_LINK]) |l| if (std.mem.eql(u8, l, "target")) {
            s.color_symlink_as_referent = true;
        };
    }

    // ------------------------------------------------------------- quoting

    fn needsQuoting(s: *Ls, name: []const u8) bool {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(s.gpa);
        quotearg.quote(&buf, s.gpa, name, s.filename_style, &s.filename_extra) catch return false;
        return !std.mem.eql(u8, buf.items, name);
    }

    const QName = struct { text: std.ArrayList(u8) = .empty, width: usize = 0, pad: bool = false, quoted: bool = false };

    /// GNU quote_name_buf in the C locale.
    fn quoteNameBuf(s: *Ls, name: []const u8, style: quotearg.Style, extra: *const quotearg.ExtraSet, needs_general: i8, q: *QName) void {
        const needs_further = s.qmark_funny_chars and (style == .shell or style == .shell_always or style == .literal);
        var quoted = false;
        if (needs_general != 0) {
            quotearg.quote(&q.text, s.gpa, name, style, extra) catch {};
            quoted = !std.mem.eql(u8, q.text.items, name);
        } else {
            q.text.appendSlice(s.gpa, name) catch {};
        }
        if (needs_further) {
            for (q.text.items) |*c| {
                if (!(c.* >= 0x20 and c.* <= 0x7e)) c.* = '?';
            }
            q.width = q.text.items.len;
        } else {
            var w: usize = 0;
            for (q.text.items) |c| {
                if (c >= 0x20 and c <= 0x7e) w += 1;
            }
            q.width = w;
        }
        q.quoted = quoted;
        q.pad = s.align_variable_outer_quotes and s.cwd_some_quoted and !quoted;
    }

    fn quoteNameWidth(s: *Ls, name: []const u8, needs_general: i8) usize {
        var q: QName = .{};
        defer q.text.deinit(s.gpa);
        s.quoteNameBuf(name, s.filename_style, &s.filename_extra, needs_general, &q);
        return q.width + @intFromBool(q.pad);
    }

    fn fileEscape(s: *Ls, str: []const u8, is_path: bool, out: *std.ArrayList(u8)) void {
        for (str) |c| {
            if (is_path and c == '/') {
                out.append(s.gpa, '/') catch {};
            } else if (s.rfc3986[c]) {
                out.append(s.gpa, c) catch {};
            } else {
                var b: [3]u8 = undefined;
                _ = std.fmt.bufPrint(&b, "%{x:0>2}", .{c}) catch {};
                out.appendSlice(s.gpa, &b) catch {};
            }
        }
    }

    /// GNU quote_name. Returns the byte length printed (plus padding).
    fn quoteName(s: *Ls, name: []const u8, style: quotearg.Style, extra: *const quotearg.ExtraSet, needs_general: i8, color: ?[]const u8, allow_pad: bool, stack: ?*std.ArrayList(i64), absolute_name: ?[]const u8) usize {
        var q: QName = .{};
        defer q.text.deinit(s.gpa);
        s.quoteNameBuf(name, style, extra, needs_general, &q);
        const buf = q.text.items;
        if (q.pad and allow_pad) s.putByte(' ');
        if (color != null) _ = s.printColorIndicator(color);
        var skip_quotes = false;
        if (absolute_name) |an| {
            if (s.align_variable_outer_quotes and s.cwd_some_quoted and !q.pad and buf.len > 0) {
                skip_quotes = true;
                s.putByte(buf[0]);
            }
            var h: std.ArrayList(u8) = .empty;
            defer h.deinit(s.gpa);
            var n: std.ArrayList(u8) = .empty;
            defer n.deinit(s.gpa);
            s.fileEscape(s.hostname, false, &h);
            s.fileEscape(an, true, &n);
            s.out.write("\x1b]8;;file://");
            s.out.write(h.items);
            if (n.items.len == 0 or n.items[0] != '/') s.out.write("/");
            s.out.write(n.items);
            s.out.write("\x07");
        }
        if (stack) |st| s.pushDiredPos(st);
        const body = if (skip_quotes) buf[1 .. buf.len - 1] else buf;
        s.out.write(body);
        s.dired_pos += @intCast(buf.len);
        if (stack) |st| s.pushDiredPos(st);
        if (absolute_name != null) {
            s.out.write("\x1b]8;;\x07");
            if (skip_quotes) s.out.writeByte(buf[buf.len - 1]);
        }
        return buf.len + @intFromBool(q.pad);
    }

    // ------------------------------------------------------------ user/group

    fn getUser(s: *Ls, uid: u32) ?[]const u8 {
        if (s.numeric_ids) return null;
        if (s.user_cache.get(uid)) |v| return v;
        if (s.db == null) s.db = userdb.Db.load(s.gpa, s.ctx.io);
        const r: ?[]const u8 = if (s.db.?.userByUid(uid)) |u| u.name else null;
        s.user_cache.put(uid, r) catch {};
        return r;
    }

    fn getGroup(s: *Ls, gid: u32) ?[]const u8 {
        if (s.numeric_ids) return null;
        if (s.group_cache.get(gid)) |v| return v;
        if (s.db == null) s.db = userdb.Db.load(s.gpa, s.ctx.io);
        const r: ?[]const u8 = if (s.db.?.groupByGid(gid)) |g| g.name else null;
        s.group_cache.put(gid, r) catch {};
        return r;
    }

    fn idWidth(name: ?[]const u8, id: u64) usize {
        if (name) |n| return n.len;
        return decLen(id);
    }

    fn formatUserOrGroup(s: *Ls, name: ?[]const u8, id: u64, width: usize) void {
        if (name) |n| {
            const gap = if (n.len < width) width - n.len else 0;
            s.put(n);
            s.pad(gap + 1);
        } else {
            var tmp: [24]u8 = undefined;
            const t = std.fmt.bufPrint(&tmp, "{d}", .{id}) catch "";
            s.putRight(t, width);
            s.putByte(' ');
        }
    }

    // ---------------------------------------------------------------- stat

    fn doStat(path: []const u8, follow: bool, st: *sys.FileStat, e: *std.os.linux.E) bool {
        if (sys.fileStat(path, follow, e)) |v| {
            st.* = v;
            return true;
        }
        return false;
    }

    fn ensureZone(s: *Ls) void {
        if (!s.zone_loaded) {
            s.zone = tzmod.load(s.gpa, s.ctx.io, cli.getenv(s.ctx, "TZ"));
            s.zone_loaded = true;
        }
    }

    fn gettime(s: *Ls) void {
        const ts = Io.Timestamp.now(s.ctx.io, .real);
        const ns = ts.toNanoseconds();
        s.current_time_sec = @intCast(@divFloor(ns, std.time.ns_per_s));
        s.current_time_nsec = @intCast(@mod(ns, std.time.ns_per_s));
    }

    fn typeFromKind(k: Io.File.Kind) FileType {
        return switch (k) {
            .file => .normal,
            .directory => .directory,
            .sym_link => .symbolic_link,
            .named_pipe => .fifo,
            .unix_domain_socket => .sock,
            .block_device => .blockdev,
            .character_device => .chardev,
            .whiteout => .whiteout,
            else => .unknown,
        };
    }

    fn typeFromMode(mode: u32) FileType {
        return switch (mode & 0o170000) {
            0o100000 => .normal,
            0o040000 => .directory,
            0o120000 => .symbolic_link,
            0o010000 => .fifo,
            0o140000 => .sock,
            0o060000 => .blockdev,
            0o020000 => .chardev,
            else => .unknown,
        };
    }

    fn attach(a: Allocator, dirname: []const u8, name: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        if (!(dirname.len == 1 and dirname[0] == '.')) {
            try out.appendSlice(a, dirname);
            if (dirname.len > 0 and dirname[dirname.len - 1] != '/') try out.append(a, '/');
        }
        try out.appendSlice(a, name);
        return out.items;
    }

    /// GNU gobble_file: add `name` to the table; returns its block count.
    fn gobbleFile(s: *Ls, name: []const u8, type_in: FileType, command_line_arg: bool, dirname: ?[]const u8) u64 {
        const a = s.alloc();
        var ftype = type_in;
        const f = a.create(FileInfo) catch return 0;
        f.* = .{ .name = "" };
        f.filetype = ftype;
        f.quoted = -1;
        if (!s.cwd_some_quoted and s.align_variable_outer_quotes) {
            f.quoted = @intFromBool(s.needsQuoting(name));
            if (f.quoted != 0) s.cwd_some_quoted = true;
        }

        const check_stat = command_line_arg or s.print_hyperlink or s.format_needs_stat or
            (s.format_needs_type and ftype == .unknown) or
            ((ftype == .directory or ftype == .unknown) and s.print_with_color and
                (s.isColored(C_OTHER_WRITABLE) or s.isColored(C_STICKY) or s.isColored(C_STICKY_OTHER_WRITABLE))) or
            ((s.print_inode or s.format_needs_type) and (ftype == .symbolic_link or ftype == .unknown) and
                (s.dereference == .always or s.color_symlink_as_referent or s.check_symlink_mode)) or
            s.print_inode or
            ((ftype == .normal or ftype == .unknown) and
                (s.indicator_style == .classify or
                    (s.print_with_color and (s.isColored(C_EXEC) or s.isColored(C_SETUID) or s.isColored(C_SETGID)))));

        var full_name: []const u8 = name;
        if ((check_stat or s.print_scontext or s.format_needs_capability) and name.len > 0 and name[0] != '/' and dirname != null) {
            full_name = attach(a, dirname.?, name) catch name;
        }

        var do_deref: bool = undefined;
        if (!check_stat) {
            do_deref = s.dereference == .always;
        } else {
            var err: std.os.linux.E = .SUCCESS;
            var ok = false;
            if (s.print_hyperlink) {
                if (paths.resolve(s.ctx, full_name, .missing)) |abs| {
                    defer s.gpa.free(abs);
                    f.absolute_name = a.dupe(u8, abs) catch null;
                } else |_| {}
                if (f.absolute_name == null) s.fileFailureErrno(command_line_arg, "error canonicalizing {f}", full_name, .NOENT);
            }
            var lstat_needed = false;
            switch (s.dereference) {
                .always => {
                    ok = doStat(full_name, true, &f.st, &err);
                    do_deref = true;
                },
                .command_line_args, .command_line_symlink_to_dir => {
                    if (command_line_arg) {
                        ok = doStat(full_name, true, &f.st, &err);
                        do_deref = true;
                        if (s.dereference == .command_line_args) {} else {
                            const need_lstat = if (!ok) (err == .NOENT or err == .LOOP) else !f.st.isDir();
                            if (need_lstat) lstat_needed = true;
                        }
                    } else lstat_needed = true;
                },
                else => lstat_needed = true,
            }
            if (lstat_needed) {
                ok = doStat(full_name, false, &f.st, &err);
                do_deref = false;
            }
            if (!ok) {
                s.fileFailureErrno(command_line_arg, "cannot access {f}", full_name, err);
                if (command_line_arg) return 0;
                f.name = a.dupe(u8, name) catch name;
                s.files.append(s.gpa, f) catch {};
                return 0;
            }
            f.stat_ok = true;
            f.filetype = typeFromMode(f.st.mode);
            ftype = f.filetype;
        }

        if (ftype == .directory and command_line_arg and !s.immediate_dirs) {
            f.filetype = .arg_directory;
            ftype = .arg_directory;
        }

        const get_scontext = (s.format == .long) or s.print_scontext;
        if (get_scontext) {
            // ACLs show as '+', a security context as '.'; both are detected
            // through extended attributes.
            var xerr: std.os.linux.E = .SUCCESS;
            var tmp: [256]u8 = undefined;
            const follow = do_deref;
            var have_acl = false;
            if (sys.getXattr(full_name, "system.posix_acl_access", follow, &tmp, &xerr) != null) have_acl = true;
            if (!have_acl and f.stat_ok and f.st.isDir()) {
                if (sys.getXattr(full_name, "system.posix_acl_default", follow, &tmp, &xerr) != null) have_acl = true;
            }
            var have_ctx = false;
            if (sys.getXattr(full_name, "security.selinux", follow, &tmp, &xerr)) |n| {
                var len = n;
                while (len > 0 and tmp[len - 1] == 0) len -= 1;
                f.scontext = a.dupe(u8, tmp[0..len]) catch "?";
                have_ctx = true;
            }
            f.acl_type = if (!have_ctx and !have_acl) .none else if (have_ctx and !have_acl) .lsm_context_only else .yes;
            if (f.acl_type != .none) s.any_has_acl = true;
        }

        if (ftype == .symbolic_link and (s.format == .long or s.check_symlink_mode)) {
            var lbuf: [4096]u8 = undefined;
            if (Io.Dir.cwd().readLink(s.ctx.io, full_name, &lbuf)) |n| {
                f.linkname = a.dupe(u8, lbuf[0..n]) catch null;
            } else |e| {
                s.fileFailureText(command_line_arg, "cannot read symbolic link {f}", full_name, cli.errText(e));
            }
            if (f.linkname != null and f.quoted == 0 and s.needsQuoting(f.linkname.?)) f.quoted = -1;
            if (f.linkname != null and (@intFromEnum(s.indicator_style) >= @intFromEnum(IndicatorStyle.file_type) or s.check_symlink_mode)) {
                var lst: sys.FileStat = undefined;
                var e2: std.os.linux.E = .SUCCESS;
                if (doStat(full_name, true, &lst, &e2)) {
                    f.linkok = true;
                    f.linkmode = lst.mode;
                }
            }
        }

        const blocks: u64 = if (f.stat_ok) f.st.blocks else 0;
        if (s.format == .long or s.print_block_size) {
            var hb: [human.longest]u8 = undefined;
            const t = human.readable(blocks, &hb, s.human_output_opts, 512, s.output_block_size);
            if (s.block_size_width < t.len) s.block_size_width = t.len;
        }
        if (s.format == .long) {
            if (s.print_owner) {
                const w = idWidth(s.getUser(f.st.uid), f.st.uid);
                if (s.owner_width < w) s.owner_width = w;
            }
            if (s.print_group) {
                const w = idWidth(s.getGroup(f.st.gid), f.st.gid);
                if (s.group_width < w) s.group_width = w;
            }
            if (s.print_author) {
                const w = idWidth(s.getUser(f.st.uid), f.st.uid);
                if (s.author_width < w) s.author_width = w;
            }
        }
        if (s.print_scontext) {
            if (s.scontext_width < f.scontext.len) s.scontext_width = f.scontext.len;
        }
        if (s.format == .long) {
            const nl = decLen(f.st.nlink);
            if (s.nlink_width < nl) s.nlink_width = nl;
            if (ftype == .chardev or ftype == .blockdev) {
                const mj = decLen(f.st.rdev_major);
                if (s.major_device_number_width < mj) s.major_device_number_width = mj;
                const mn = decLen(f.st.rdev_minor);
                if (s.minor_device_number_width < mn) s.minor_device_number_width = mn;
                const len = s.major_device_number_width + 2 + s.minor_device_number_width;
                if (s.file_size_width < len) s.file_size_width = len;
            } else {
                var hb: [human.longest]u8 = undefined;
                const t = human.readable(f.st.size, &hb, s.file_human_output_opts, 1, s.file_output_block_size);
                if (s.file_size_width < t.len) s.file_size_width = t.len;
            }
        }
        if (s.print_inode) {
            const il = decLen(f.st.ino);
            if (s.inode_number_width < il) s.inode_number_width = il;
        }
        f.name = a.dupe(u8, name) catch name;
        s.files.append(s.gpa, f) catch {};
        return blocks;
    }

    fn clearFiles(s: *Ls) void {
        s.files.clearRetainingCapacity();
        _ = s.arena.reset(.retain_capacity);
        s.cwd_some_quoted = false;
        s.any_has_acl = false;
        s.inode_number_width = 0;
        s.block_size_width = 0;
        s.nlink_width = 0;
        s.owner_width = 0;
        s.group_width = 0;
        s.author_width = 0;
        s.scontext_width = 0;
        s.major_device_number_width = 0;
        s.minor_device_number_width = 0;
        s.file_size_width = 0;
    }

    // ------------------------------------------------------------ ignoring

    fn fileIgnored(s: *Ls, name: []const u8) bool {
        if (s.ignore_mode != .minimal and name.len > 0 and name[0] == '.' and
            (s.ignore_mode == .default or name.len == 1 or (name.len == 2 and name[1] == '.')))
            return true;
        if (s.ignore_mode == .default) {
            for (s.hide_patterns.items) |p| if (fnmatch.match(p, name, .{ .period = true })) return true;
        }
        for (s.ignore_patterns.items) |p| if (fnmatch.match(p, name, .{ .period = true })) return true;
        return false;
    }

    // -------------------------------------------------------------- sorting

    fn isLinkedDirectory(f: *const FileInfo) bool {
        return f.filetype == .directory or f.filetype == .arg_directory or (f.linkmode & 0o170000) == 0o040000;
    }

    fn isDirectory(f: *const FileInfo) bool {
        return f.filetype == .directory or f.filetype == .arg_directory;
    }

    fn timeOf(f: *const FileInfo, t: TimeType) Ts {
        return switch (t) {
            .mtime => .{ .sec = f.st.mtime_s, .nsec = f.st.mtime_ns },
            .ctime => .{ .sec = f.st.ctime_s, .nsec = f.st.ctime_ns },
            .atime => .{ .sec = f.st.atime_s, .nsec = f.st.atime_ns },
            .btime => if (f.st.has_btime) .{ .sec = f.st.btime_s, .nsec = f.st.btime_ns } else .{ .sec = -1, .nsec = -1 },
        };
    }

    fn nameWidth(s: *Ls, f: *FileInfo) usize {
        if (f.width != 0) return f.width;
        return s.quoteNameWidth(f.name, f.quoted);
    }

    fn cmpBytes(a: []const u8, b: []const u8) i32 {
        return switch (std.mem.order(u8, a, b)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    fn cmpKey(s: *Ls, a: *FileInfo, b: *FileInfo) i32 {
        switch (s.sort_type) {
            .name => return cmpBytes(a.name, b.name),
            .extension => {
                const ea = if (std.mem.lastIndexOfScalar(u8, a.name, '.')) |i| a.name[i..] else "";
                const eb = if (std.mem.lastIndexOfScalar(u8, b.name, '.')) |i| b.name[i..] else "";
                const d = cmpBytes(ea, eb);
                return if (d != 0) d else cmpBytes(a.name, b.name);
            },
            .width => {
                const wa: i64 = @intCast(s.nameWidth(a));
                const wb: i64 = @intCast(s.nameWidth(b));
                const d: i64 = wa - wb;
                if (d != 0) return if (d < 0) -1 else 1;
                return cmpBytes(a.name, b.name);
            },
            .size => {
                const sa: i64 = @bitCast(a.st.size);
                const sb: i64 = @bitCast(b.st.size);
                if (sb != sa) return if (sb > sa) 1 else -1;
                return cmpBytes(a.name, b.name);
            },
            .version => {
                const d = filevercmp.cmp(a.name, b.name);
                if (d != 0) return d;
                return cmpBytes(a.name, b.name);
            },
            .time => {
                const ta = timeOf(a, s.time_type);
                const tb = timeOf(b, s.time_type);
                // newest first: compare b to a
                var d: i32 = 0;
                if (tb.sec != ta.sec) {
                    d = if (tb.sec > ta.sec) 1 else -1;
                } else if (tb.nsec != ta.nsec) d = if (tb.nsec > ta.nsec) 1 else -1;
                if (d != 0) return d;
                return cmpBytes(a.name, b.name);
            },
            .none => return 0,
        }
    }

    fn lessThan(s: *Ls, a: *FileInfo, b: *FileInfo) bool {
        if (s.directories_first) {
            const da: i32 = @intFromBool(isLinkedDirectory(a));
            const db_: i32 = @intFromBool(isLinkedDirectory(b));
            // GNU: is_linked_directory(b) - is_linked_directory(a), ahead of
            // the (possibly reversed) key comparison.
            const diff = db_ - da;
            if (diff != 0) return diff < 0;
        }
        return if (s.sort_reverse) s.cmpKey(b, a) < 0 else s.cmpKey(a, b) < 0;
    }

    fn updateCurrentFilesInfo(s: *Ls) void {
        if (s.sort_type == .width or (s.line_length != 0 and (s.format == .many_per_line or s.format == .horizontal))) {
            for (s.files.items) |f| f.width = s.nameWidth(f);
        }
    }

    fn sortFiles(s: *Ls) void {
        s.updateCurrentFilesInfo();
        if (s.sort_type == .none) return;
        const Ctx = struct {
            s: *Ls,
            fn less(c: @This(), a: *FileInfo, b: *FileInfo) bool {
                return c.s.lessThan(a, b);
            }
        };
        std.sort.block(*FileInfo, s.files.items, Ctx{ .s = s }, Ctx.less);
    }

    // --------------------------------------------------- queue / directories

    fn queueDirectory(s: *Ls, name: ?[]const u8, realname: ?[]const u8, command_line_arg: bool) void {
        const n = if (name) |x| s.gpa.dupe(u8, x) catch return else null;
        const r = if (realname) |x| s.gpa.dupe(u8, x) catch return else null;
        s.pending.append(s.gpa, .{ .name = n, .realname = r, .command_line_arg = command_line_arg }) catch {};
    }

    fn baseIsDotOrDotDot(name: []const u8) bool {
        var end = name.len;
        while (end > 1 and name[end - 1] == '/') end -= 1;
        const trimmed = name[0..end];
        const base = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
        return std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..");
    }

    fn extractDirsFromFiles(s: *Ls, dirname: ?[]const u8, command_line_arg: bool) void {
        const ignore_dot_and_dotdot = dirname != null;
        if (dirname != null and s.loop_detect) s.queueDirectory(null, dirname, false);
        var i = s.files.items.len;
        while (i > 0) {
            i -= 1;
            const f = s.files.items[i];
            if (isDirectory(f) and (!ignore_dot_and_dotdot or !baseIsDotOrDotDot(f.name))) {
                if (dirname == null or (f.name.len > 0 and f.name[0] == '/')) {
                    s.queueDirectory(f.name, f.linkname, command_line_arg);
                } else {
                    const d = dirname.?;
                    var full: std.ArrayList(u8) = .empty;
                    defer full.deinit(s.gpa);
                    full.appendSlice(s.gpa, d) catch {};
                    if (d.len == 0 or d[d.len - 1] != '/') full.append(s.gpa, '/') catch {};
                    full.appendSlice(s.gpa, f.name) catch {};
                    s.queueDirectory(full.items, f.linkname, command_line_arg);
                }
            }
        }
        // Remove the arg_directory entries (they are listed as directories).
        var j: usize = 0;
        for (s.files.items) |f| {
            s.files.items[j] = f;
            if (f.filetype != .arg_directory) j += 1;
        }
        s.files.items.len = j;
    }

    fn visitDir(s: *Ls, dev: u64, ino: u64) bool {
        for (s.active.items) |d| if (d.dev == dev and d.ino == ino) return true;
        return false;
    }

    fn printDir(s: *Ls, name: []const u8, realname: ?[]const u8, command_line_arg: bool) void {
        var dir = Io.Dir.cwd().openDir(s.ctx.io, name, .{ .iterate = true }) catch |e| {
            s.fileFailureText(command_line_arg, "cannot open directory {f}", name, cli.errText(e));
            return;
        };
        defer dir.close(s.ctx.io);

        if (s.loop_detect) {
            var st: sys.FileStat = undefined;
            var err: std.os.linux.E = .SUCCESS;
            if (!doStat(name, true, &st, &err)) {
                s.fileFailureErrno(command_line_arg, "cannot determine device and inode of {f}", name, err);
                return;
            }
            const dev = (@as(u64, st.dev_major) << 32) | st.dev_minor;
            if (s.visitDir(dev, st.ino)) {
                cli.warn(s.ctx, "{f}: not listing already-listed directory", .{cli.quote(name)});
                s.setExitStatus(true);
                return;
            }
            s.active.append(s.gpa, .{ .dev = dev, .ino = st.ino }) catch {};
        }

        s.clearFiles();

        if (s.recursive or s.print_dir_name) {
            if (!s.first_dir) s.putByte('\n');
            s.first_dir = false;
            s.diredIndent();
            var absolute: ?[]u8 = null;
            defer if (absolute) |x| s.gpa.free(x);
            if (s.print_hyperlink) {
                absolute = paths.resolve(s.ctx, name, .missing) catch null;
                if (absolute == null) s.fileFailureErrno(command_line_arg, "error canonicalizing {f}", name, .NOENT);
            }
            _ = s.quoteName(realname orelse name, s.filename_style, &s.dirname_extra, -1, null, true, &s.subdired_offsets, absolute);
            s.put(":\n");
        }

        var total_blocks: u64 = 0;
        // std.Io hides "." and ".."; readdir lists them first.
        for ([_][]const u8{ ".", ".." }) |dots| {
            if (s.fileIgnored(dots)) continue;
            total_blocks += s.gobbleFile(dots, .directory, false, name);
            if (s.format == .one_per_line and s.sort_type == .none and !s.print_block_size and !s.recursive) {
                s.sortFiles();
                s.printCurrentFiles();
                s.clearFiles();
            }
        }
        var it = dir.iterate();
        while (true) {
            const entry = it.next(s.ctx.io) catch |e| {
                s.fileFailureText(command_line_arg, "reading directory {f}", name, cli.errText(e));
                break;
            } orelse break;
            if (s.fileIgnored(entry.name)) continue;
            total_blocks += s.gobbleFile(entry.name, typeFromKind(entry.kind), false, name);
            if (s.format == .one_per_line and s.sort_type == .none and !s.print_block_size and !s.recursive) {
                s.sortFiles();
                s.printCurrentFiles();
                s.clearFiles();
            }
        }

        s.sortFiles();
        if (s.recursive) s.extractDirsFromFiles(name, false);

        if (s.format == .long or s.print_block_size) {
            var hb: [human.longest]u8 = undefined;
            const t = human.readable(total_blocks, &hb, s.human_output_opts, 512, s.output_block_size);
            s.diredIndent();
            s.put("total ");
            s.put(t);
            s.putByte(s.eolbyte);
        }
        if (s.files.items.len > 0) s.printCurrentFiles();
    }

    // ------------------------------------------------------------- printing

    fn getTypeIndicator(s: *const Ls, stat_ok: bool, mode: u32, ftype: FileType) u8 {
        const fmt_ = mode & 0o170000;
        if (if (stat_ok) fmt_ == 0o100000 else ftype == .normal) {
            if (stat_ok and s.indicator_style == .classify and (mode & 0o111) != 0) return '*';
            return 0;
        }
        if (if (stat_ok) fmt_ == 0o040000 else (ftype == .directory or ftype == .arg_directory)) return '/';
        if (s.indicator_style == .slash) return 0;
        if (if (stat_ok) fmt_ == 0o120000 else ftype == .symbolic_link) return '@';
        if (if (stat_ok) fmt_ == 0o010000 else ftype == .fifo) return '|';
        if (if (stat_ok) fmt_ == 0o140000 else ftype == .sock) return '=';
        return 0;
    }

    fn printTypeIndicator(s: *Ls, stat_ok: bool, mode: u32, ftype: FileType) bool {
        const c = s.getTypeIndicator(stat_ok, mode, ftype);
        if (c != 0) s.putByte(c);
        return c != 0;
    }

    fn fileOrLinkMode(s: *const Ls, f: *const FileInfo) u32 {
        return if (s.color_symlink_as_referent and f.linkok) f.linkmode else f.st.mode;
    }

    fn getColorIndicator(s: *Ls, f: *const FileInfo, symlink_target: bool) ?[]const u8 {
        var name: []const u8 = undefined;
        var mode: u32 = undefined;
        var linkok: i32 = undefined;
        if (symlink_target) {
            name = f.linkname.?;
            mode = f.linkmode;
            linkok = if (f.linkok) 0 else -1;
        } else {
            name = f.name;
            mode = s.fileOrLinkMode(f);
            linkok = @intFromBool(f.linkok);
        }
        var t: usize = undefined;
        if (linkok == -1 and s.isColored(C_MISSING)) {
            t = C_MISSING;
        } else if (!f.stat_ok) {
            const fi = [_]usize{ C_ORPHAN, C_FIFO, C_CHR, C_DIR, C_BLK, C_FILE, C_LINK, C_SOCK, C_FILE, C_DIR };
            t = fi[@intFromEnum(f.filetype)];
        } else {
            switch (mode & 0o170000) {
                0o100000 => {
                    t = C_FILE;
                    if ((mode & 0o4000) != 0 and s.isColored(C_SETUID)) {
                        t = C_SETUID;
                    } else if ((mode & 0o2000) != 0 and s.isColored(C_SETGID)) {
                        t = C_SETGID;
                    } else if (f.has_capability) {
                        t = C_CAP;
                    } else if ((mode & 0o111) != 0 and s.isColored(C_EXEC)) {
                        t = C_EXEC;
                    } else if (f.st.nlink > 1 and s.isColored(C_MULTIHARDLINK)) {
                        t = C_MULTIHARDLINK;
                    }
                },
                0o040000 => {
                    t = C_DIR;
                    if ((mode & 0o1000) != 0 and (mode & 0o002) != 0 and s.isColored(C_STICKY_OTHER_WRITABLE)) {
                        t = C_STICKY_OTHER_WRITABLE;
                    } else if ((mode & 0o002) != 0 and s.isColored(C_OTHER_WRITABLE)) {
                        t = C_OTHER_WRITABLE;
                    } else if ((mode & 0o1000) != 0 and s.isColored(C_STICKY)) {
                        t = C_STICKY;
                    }
                },
                0o120000 => t = C_LINK,
                0o010000 => t = C_FIFO,
                0o140000 => t = C_SOCK,
                0o060000 => t = C_BLK,
                0o020000 => t = C_CHR,
                else => t = C_ORPHAN,
            }
        }
        var ext_seq: ?[]const u8 = null;
        var have_ext = false;
        if (t == C_FILE) {
            var i = s.ext_list.items.len;
            while (i > 0) {
                i -= 1;
                const e = s.ext_list.items[i];
                if (e.ignored) continue;
                if (e.ext.len <= name.len) {
                    const tail = name[name.len - e.ext.len ..];
                    const hit = if (e.exact) std.mem.eql(u8, tail, e.ext) else std.ascii.eqlIgnoreCase(tail, e.ext);
                    if (hit) {
                        have_ext = true;
                        ext_seq = e.seq;
                        break;
                    }
                }
            }
        }
        if (t == C_LINK and linkok == 0) {
            if (s.color_symlink_as_referent or s.isColored(C_ORPHAN)) t = C_ORPHAN;
        }
        if (have_ext) return ext_seq;
        return s.indicators[t];
    }

    fn printNameWithQuoting(s: *Ls, f: *const FileInfo, symlink_target: bool, stack: ?*std.ArrayList(i64), start_col: usize) usize {
        const name = if (symlink_target) f.linkname.? else f.name;
        const color: ?[]const u8 = if (s.print_with_color) s.getColorIndicator(f, symlink_target) else null;
        const used_color_this_time = s.print_with_color and (color != null or s.isColored(C_NORM));
        const len = s.quoteName(name, s.filename_style, &s.filename_extra, f.quoted, color, !symlink_target, stack, f.absolute_name);
        if (used_color_this_time) {
            s.prepNonFilenameText();
            if (s.line_length != 0 and len > 0 and (start_col / s.line_length != (start_col + len - 1) / s.line_length)) {
                s.putIndicator(s.indicatorStr(C_CLR_TO_EOL));
            }
        }
        return len;
    }

    fn formatInode(f: *const FileInfo, buf: *[24]u8) []const u8 {
        if (f.stat_ok and f.st.ino != NOT_AN_INODE) return std.fmt.bufPrint(buf, "{d}", .{f.st.ino}) catch "?";
        return "?";
    }

    fn printFileNameAndFrills(s: *Ls, f: *FileInfo, start_col: usize) usize {
        s.setNormalColor();
        var nb: [24]u8 = undefined;
        if (s.print_inode) {
            const t = formatInode(f, &nb);
            s.putRight(t, if (s.format == .with_commas) 0 else s.inode_number_width);
            s.putByte(' ');
        }
        if (s.print_block_size) {
            var hb: [human.longest]u8 = undefined;
            const t = if (!f.stat_ok) "?" else human.readable(f.st.blocks, &hb, s.human_output_opts, 512, s.output_block_size);
            s.putRight(t, if (s.format == .with_commas) 0 else s.block_size_width);
            s.putByte(' ');
        }
        if (s.print_scontext) {
            s.putRight(f.scontext, if (s.format == .with_commas) 0 else s.scontext_width);
            s.putByte(' ');
        }
        var width = s.printNameWithQuoting(f, false, null, start_col);
        if (s.indicator_style != .none) {
            width += @intFromBool(s.printTypeIndicator(f.stat_ok, f.st.mode, f.filetype));
        }
        return width;
    }

    fn lengthOfFileNameAndFrills(s: *Ls, f: *FileInfo) usize {
        var len: usize = 0;
        if (s.print_inode) {
            len += 1 + (if (s.format == .with_commas) decLen(f.st.ino) else s.inode_number_width);
        }
        if (s.print_block_size) {
            var hb: [human.longest]u8 = undefined;
            len += 1 + (if (s.format == .with_commas)
                blk: {
                const t: []const u8 = if (!f.stat_ok) "?" else human.readable(f.st.blocks, &hb, s.human_output_opts, 512, s.output_block_size);
                break :blk t.len;
            }
            else
                s.block_size_width);
        }
        if (s.print_scontext) len += 1 + (if (s.format == .with_commas) f.scontext.len else s.scontext_width);
        len += s.nameWidth(f);
        if (s.indicator_style != .none) {
            if (s.getTypeIndicator(f.stat_ok, f.st.mode, f.filetype) != 0) len += 1;
        }
        return len;
    }

    fn indent(s: *Ls, from_in: usize, to: usize) void {
        var from = from_in;
        while (from < to) {
            if (s.tabsize != 0 and to / s.tabsize > (from + 1) / s.tabsize) {
                s.putByte('\t');
                from += s.tabsize - from % s.tabsize;
            } else {
                s.putByte(' ');
                from += 1;
            }
        }
    }

    fn calculateColumns(s: *Ls, by_columns: bool, infos: *std.ArrayList(ColumnInfo)) usize {
        const n = s.files.items.len;
        const max_cols = if (s.max_idx > 0 and s.max_idx < n) s.max_idx else n;
        var i: usize = 0;
        while (i < max_cols) : (i += 1) {
            const arr = s.gpa.alloc(usize, i + 1) catch return 1;
            @memset(arr, MIN_COLUMN_WIDTH);
            infos.append(s.gpa, .{ .valid_len = true, .line_len = (i + 1) * MIN_COLUMN_WIDTH, .col_arr = arr }) catch return 1;
        }
        for (s.files.items, 0..) |f, filesno| {
            const name_length = s.lengthOfFileNameAndFrills(f);
            var k: usize = 0;
            while (k < max_cols) : (k += 1) {
                const ci = &infos.items[k];
                if (ci.valid_len) {
                    const idx = if (by_columns) filesno / ((n + k) / (k + 1)) else filesno % (k + 1);
                    const real_length = name_length + (if (idx == k) @as(usize, 0) else 2);
                    if (ci.col_arr[idx] < real_length) {
                        ci.line_len += real_length - ci.col_arr[idx];
                        ci.col_arr[idx] = real_length;
                        ci.valid_len = ci.line_len < s.line_length;
                    }
                }
            }
        }
        var cols = max_cols;
        while (cols > 1) : (cols -= 1) {
            if (infos.items[cols - 1].valid_len) break;
        }
        return cols;
    }

    fn freeColumns(s: *Ls, infos: *std.ArrayList(ColumnInfo)) void {
        for (infos.items) |ci| s.gpa.free(ci.col_arr);
        infos.deinit(s.gpa);
    }

    fn printManyPerLine(s: *Ls) void {
        var infos: std.ArrayList(ColumnInfo) = .empty;
        defer s.freeColumns(&infos);
        const cols = s.calculateColumns(true, &infos);
        const line_fmt = infos.items[cols - 1];
        const n = s.files.items.len;
        const rows = n / cols + @intFromBool(n % cols != 0);
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            var col: usize = 0;
            var filesno = row;
            var pos: usize = 0;
            while (true) {
                const f = s.files.items[filesno];
                const name_length = s.lengthOfFileNameAndFrills(f);
                const max_name_length = line_fmt.col_arr[col];
                col += 1;
                _ = s.printFileNameAndFrills(f, pos);
                if (n - rows <= filesno) break;
                filesno += rows;
                s.indent(pos + name_length, pos + max_name_length);
                pos += max_name_length;
            }
            s.putByte(s.eolbyte);
        }
    }

    fn printHorizontal(s: *Ls) void {
        var infos: std.ArrayList(ColumnInfo) = .empty;
        defer s.freeColumns(&infos);
        const cols = s.calculateColumns(false, &infos);
        const line_fmt = infos.items[cols - 1];
        var pos: usize = 0;
        var f = s.files.items[0];
        var name_length = s.lengthOfFileNameAndFrills(f);
        var max_name_length = line_fmt.col_arr[0];
        _ = s.printFileNameAndFrills(f, 0);
        var filesno: usize = 1;
        while (filesno < s.files.items.len) : (filesno += 1) {
            const col = filesno % cols;
            if (col == 0) {
                s.putByte(s.eolbyte);
                pos = 0;
            } else {
                s.indent(pos + name_length, pos + max_name_length);
                pos += max_name_length;
            }
            f = s.files.items[filesno];
            _ = s.printFileNameAndFrills(f, pos);
            name_length = s.lengthOfFileNameAndFrills(f);
            max_name_length = line_fmt.col_arr[col];
        }
        s.putByte(s.eolbyte);
    }

    fn printWithSeparator(s: *Ls, sep: u8) void {
        var pos: usize = 0;
        for (s.files.items, 0..) |f, filesno| {
            const len: usize = if (s.line_length != 0) s.lengthOfFileNameAndFrills(f) else 0;
            if (filesno != 0) {
                var separator: u8 = undefined;
                if (s.line_length == 0 or (pos + len + 2 < s.line_length)) {
                    pos += 2;
                    separator = ' ';
                } else {
                    pos = 0;
                    separator = s.eolbyte;
                }
                s.putByte(sep);
                s.putByte(separator);
            }
            _ = s.printFileNameAndFrills(f, pos);
            pos += len;
        }
        s.putByte(s.eolbyte);
    }

    fn modeString(mode: u32, buf: *[12]u8) void {
        buf[0] = switch (mode & 0o170000) {
            0o100000 => '-',
            0o040000 => 'd',
            0o060000 => 'b',
            0o020000 => 'c',
            0o120000 => 'l',
            0o010000 => 'p',
            0o140000 => 's',
            else => '?',
        };
        buf[1] = if (mode & 0o400 != 0) 'r' else '-';
        buf[2] = if (mode & 0o200 != 0) 'w' else '-';
        buf[3] = if (mode & 0o4000 != 0) (if (mode & 0o100 != 0) @as(u8, 's') else 'S') else if (mode & 0o100 != 0) 'x' else '-';
        buf[4] = if (mode & 0o040 != 0) 'r' else '-';
        buf[5] = if (mode & 0o020 != 0) 'w' else '-';
        buf[6] = if (mode & 0o2000 != 0) (if (mode & 0o010 != 0) @as(u8, 's') else 'S') else if (mode & 0o010 != 0) 'x' else '-';
        buf[7] = if (mode & 0o004 != 0) 'r' else '-';
        buf[8] = if (mode & 0o002 != 0) 'w' else '-';
        buf[9] = if (mode & 0o1000 != 0) (if (mode & 0o001 != 0) @as(u8, 't') else 'T') else if (mode & 0o001 != 0) 'x' else '-';
        buf[10] = ' ';
        buf[11] = 0;
    }

    /// strftime into `out`; false when the year does not fit a struct tm.
    fn formatTime(s: *Ls, out: *std.ArrayList(u8), format: []const u8, sec: i64, nsec: u32) bool {
        s.ensureZone();
        const tm = tzmod.localtime(&s.zone, sec);
        if (tm.year - 1900 > std.math.maxInt(i32) or tm.year - 1900 < std.math.minInt(i32)) return false;
        strftime.format(out, s.gpa, format, &tm, sec, nsec) catch return false;
        return true;
    }

    fn longTimeExpectedWidth(s: *Ls) usize {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(s.gpa);
        if (!s.formatTime(&out, s.long_time_format[0], 0, 0)) return 0;
        var w: usize = 0;
        for (out.items) |c| {
            if (c >= 0x20 and c <= 0x7e) w += 1;
        }
        return w;
    }

    fn printLongFormat(s: *Ls, f: *FileInfo) void {
        var modebuf: [12]u8 = undefined;
        if (f.stat_ok) {
            modeString(f.st.mode, &modebuf);
        } else {
            modebuf[0] = filetype_letter[@intFromEnum(f.filetype)];
            @memset(modebuf[1..11], '?');
            modebuf[11] = 0;
        }
        var mode_len: usize = 11;
        if (!s.any_has_acl) {
            mode_len = 10;
        } else switch (f.acl_type) {
            .lsm_context_only => modebuf[10] = '.',
            .yes => modebuf[10] = '+',
            .unknown => modebuf[10] = '?',
            .none => {},
        }
        mode_len = if (!s.any_has_acl) 10 else 11;

        const when: Ts = timeOf(f, s.time_type);
        var btime_ok = true;
        if (s.time_type == .btime and when.sec == -1 and when.nsec == -1) btime_ok = false;

        var nb: [24]u8 = undefined;
        s.diredIndent();
        var mark: i64 = s.dired_pos;
        if (s.print_inode) {
            const t = formatInode(f, &nb);
            s.putRight(t, s.inode_number_width);
            s.putByte(' ');
        }

        if (s.print_block_size) {
            var hb: [human.longest]u8 = undefined;
            const t = if (!f.stat_ok) "?" else human.readable(f.st.blocks, &hb, s.human_output_opts, 512, s.output_block_size);
            s.putRight(t, s.block_size_width);
            s.putByte(' ');
        }

        s.put(modebuf[0..mode_len]);
        s.putByte(' ');
        {
            const t = if (!f.stat_ok) "?" else (std.fmt.bufPrint(&nb, "{d}", .{f.st.nlink}) catch "?");
            s.putRight(t, s.nlink_width);
            s.putByte(' ');
        }

        const had_ids = s.print_owner or s.print_group or s.print_author or s.print_scontext;
        if (s.print_owner) s.formatUserOrGroup(if (!f.stat_ok) "?" else s.getUser(f.st.uid), f.st.uid, s.owner_width);
        if (s.print_group) s.formatUserOrGroup(if (!f.stat_ok) "?" else s.getGroup(f.st.gid), f.st.gid, s.group_width);
        if (s.print_author) s.formatUserOrGroup(if (!f.stat_ok) "?" else s.getUser(f.st.uid), f.st.uid, s.author_width);
        if (s.print_scontext) s.formatUserOrGroup(f.scontext, 0, s.scontext_width);
        if (had_ids) mark = s.dired_pos;

        if (f.stat_ok and ((f.st.mode & 0o170000) == 0o020000 or (f.st.mode & 0o170000) == 0o060000)) {
            var mb: [24]u8 = undefined;
            var nb2: [24]u8 = undefined;
            const mj = std.fmt.bufPrint(&mb, "{d}", .{f.st.rdev_major}) catch "";
            const mn = std.fmt.bufPrint(&nb2, "{d}", .{f.st.rdev_minor}) catch "";
            const blanks = @as(isize, @intCast(s.file_size_width)) - @as(isize, @intCast(s.major_device_number_width + 2 + s.minor_device_number_width));
            const mjw = s.major_device_number_width + @as(usize, @intCast(@max(0, blanks)));
            s.putRight(mj, mjw);
            s.put(", ");
            s.putRight(mn, s.minor_device_number_width);
            s.putByte(' ');
        } else {
            var hb: [human.longest]u8 = undefined;
            const t = if (!f.stat_ok) "?" else human.readable(f.st.size, &hb, s.file_human_output_opts, 1, s.file_output_block_size);
            s.putRight(t, s.file_size_width);
            s.putByte(' ');
        }

        var time_text: std.ArrayList(u8) = .empty;
        defer time_text.deinit(s.gpa);
        var formatted = false;
        if (f.stat_ok and btime_ok) {
            if (s.current_time_sec == std.math.minInt(i64) or tsCmp(s.current_time_sec, s.current_time_nsec, when.sec, when.nsec) < 0) s.gettime();
            const six_months_ago_sec = s.current_time_sec - 31556952 / 2;
            const recent = tsCmp(six_months_ago_sec, s.current_time_nsec, when.sec, when.nsec) < 0 and
                tsCmp(when.sec, when.nsec, s.current_time_sec, s.current_time_nsec) < 0;
            const fmt_str = s.long_time_format[@intFromBool(recent)];
            formatted = s.formatTime(&time_text, fmt_str, when.sec, @intCast(@max(0, when.nsec)));
        }
        if (formatted) {
            s.put(time_text.items);
            s.putByte(' ');
        } else {
            var tb: [32]u8 = undefined;
            const t = if (!f.stat_ok or !btime_ok) "?" else (std.fmt.bufPrint(&tb, "{d}", .{when.sec}) catch "?");
            s.putRight(t, s.longTimeExpectedWidth());
            s.putByte(' ');
        }

        const start_col: usize = @intCast(s.dired_pos - mark);
        const w = s.printNameWithQuoting(f, false, &s.dired_offsets, start_col);
        if (f.filetype == .symbolic_link) {
            if (f.linkname != null) {
                s.put(" -> ");
                _ = s.printNameWithQuoting(f, true, null, start_col + w + 4);
                if (s.indicator_style != .none) _ = s.printTypeIndicator(true, f.linkmode, .unknown);
            }
        } else if (s.indicator_style != .none) {
            _ = s.printTypeIndicator(f.stat_ok, f.st.mode, f.filetype);
        }
    }

    fn tsCmp(as: i64, an: i64, bs: i64, bn: i64) i32 {
        if (as != bs) return if (as < bs) -1 else 1;
        if (an != bn) return if (an < bn) -1 else 1;
        return 0;
    }

    fn dumpOffsets(s: *Ls, prefix: []const u8, list: *std.ArrayList(i64)) void {
        if (list.items.len == 0) return;
        s.out.write(prefix);
        for (list.items) |v| s.out.print(" {d}", .{v});
        s.out.writeByte('\n');
    }

    fn printCurrentFiles(s: *Ls) void {
        switch (s.format) {
            .one_per_line => for (s.files.items) |f| {
                _ = s.printFileNameAndFrills(f, 0);
                s.putByte(s.eolbyte);
            },
            .many_per_line => if (s.line_length == 0) s.printWithSeparator(' ') else s.printManyPerLine(),
            .horizontal => if (s.line_length == 0) s.printWithSeparator(' ') else s.printHorizontal(),
            .with_commas => s.printWithSeparator(','),
            .long => for (s.files.items) |f| {
                s.setNormalColor();
                s.printLongFormat(f);
                s.putByte(s.eolbyte);
            },
        }
    }
};

// ---------------------------------------------------------------- options

const Opt = struct {
    const author = 1100;
    const block_size = 1101;
    const color = 1102;
    const deref_cl_symlink_to_dir = 1103;
    const file_type = 1104;
    const format = 1105;
    const full_time = 1106;
    const group_dirs_first = 1107;
    const hide = 1108;
    const hyperlink = 1109;
    const indicator_style = 1110;
    const quoting_style = 1111;
    const show_control_chars = 1112;
    const si = 1113;
    const sort = 1114;
    const time = 1115;
    const time_style = 1116;
    const zero = 1117;
    const classify = 'F';
};

const when_table = [_]argmatch.Entry{
    .{ .name = "always", .value = 1 }, .{ .name = "yes", .value = 1 },    .{ .name = "force", .value = 1 },
    .{ .name = "never", .value = 0 },  .{ .name = "no", .value = 0 },     .{ .name = "none", .value = 0 },
    .{ .name = "auto", .value = 2 },   .{ .name = "tty", .value = 2 },    .{ .name = "if-tty", .value = 2 },
};

const format_table = [_]argmatch.Entry{
    .{ .name = "verbose", .value = 0 },       .{ .name = "long", .value = 0 },
    .{ .name = "commas", .value = 4 },        .{ .name = "horizontal", .value = 3 },
    .{ .name = "across", .value = 3 },        .{ .name = "vertical", .value = 2 },
    .{ .name = "single-column", .value = 1 },
};

const sort_table = [_]argmatch.Entry{
    .{ .name = "none", .value = 6 },      .{ .name = "size", .value = 3 },    .{ .name = "time", .value = 5 },
    .{ .name = "version", .value = 4 },   .{ .name = "extension", .value = 1 }, .{ .name = "name", .value = 0 },
    .{ .name = "width", .value = 2 },
};

const time_table = [_]argmatch.Entry{
    .{ .name = "atime", .value = 2 },        .{ .name = "access", .value = 2 },       .{ .name = "use", .value = 2 },
    .{ .name = "ctime", .value = 1 },        .{ .name = "status", .value = 1 },
    .{ .name = "mtime", .value = 0 },        .{ .name = "modification", .value = 0 },
    .{ .name = "birth", .value = 3 },        .{ .name = "creation", .value = 3 },
};

const indicator_table = [_]argmatch.Entry{
    .{ .name = "none", .value = 0 },      .{ .name = "slash", .value = 1 },
    .{ .name = "file-type", .value = 2 }, .{ .name = "classify", .value = 3 },
};

const quoting_table = blk: {
    var t: [quotearg.style_names.len]argmatch.Entry = undefined;
    for (quotearg.style_names, 0..) |n, i| t[i] = .{ .name = n, .value = i };
    break :blk t;
};

const time_style_table = [_]argmatch.Entry{
    .{ .name = "full-iso", .value = 0 }, .{ .name = "long-iso", .value = 1 },
    .{ .name = "iso", .value = 2 },      .{ .name = "locale", .value = 3 },
};

fn xargmatch(ctx: cli.Context, arg: []const u8, context: []const u8, table: []const argmatch.Entry) ?u32 {
    const r = argmatch.match(arg, table);
    switch (r) {
        .ok => |v| return v,
        else => {
            argmatch.die(ctx, arg, context, table, r);
            return null;
        },
    }
}

fn decodeLineLength(spec: []const u8) ?usize {
    const p = human.strtoumax(spec, "");
    switch (p.err) {
        .ok => return if (p.value <= std.math.maxInt(isize)) @intCast(p.value) else 0,
        .overflow => return 0,
        else => return null,
    }
}

fn xstrtolFatal(ctx: cli.Context, e: human.StrtolError, option: []const u8, arg: []const u8) void {
    switch (e) {
        .invalid => cli.warn(ctx, "invalid {s} argument {f}", .{ option, cli.quoteC(arg) }),
        .invalid_suffix_char, .invalid_suffix_char_with_overflow => cli.warn(ctx, "invalid suffix in {s} argument {f}", .{ option, cli.quoteC(arg) }),
        .overflow => cli.warn(ctx, "{s} argument {f} too large", .{ option, cli.quoteC(arg) }),
        .ok => {},
    }
}

pub fn run(ctx: cli.Context, mode: Mode) u8 {
    var s: Ls = .{
        .ctx = ctx,
        .mode = mode,
        .out = cli.Out.init(ctx.io),
        .arena = std.heap.ArenaAllocator.init(ctx.gpa),
        .cfg = std.heap.ArenaAllocator.init(ctx.gpa),
        .gpa = ctx.gpa,
        .user_cache = std.AutoHashMap(u32, ?[]const u8).init(ctx.gpa),
        .group_cache = std.AutoHashMap(u32, ?[]const u8).init(ctx.gpa),
    };
    defer {
        s.arena.deinit();
        s.cfg.deinit();
        s.ext_list.deinit(ctx.gpa);
        s.files.deinit(ctx.gpa);
        s.ignore_patterns.deinit(ctx.gpa);
        s.hide_patterns.deinit(ctx.gpa);
        for (s.pending.items) |p| {
            if (p.name) |n| ctx.gpa.free(n);
            if (p.realname) |n| ctx.gpa.free(n);
        }
        s.pending.deinit(ctx.gpa);
        s.active.deinit(ctx.gpa);
        s.dired_offsets.deinit(ctx.gpa);
        s.subdired_offsets.deinit(ctx.gpa);
        s.user_cache.deinit();
        s.group_cache.deinit();
        if (s.db) |*d| d.deinit();
        if (s.zone_loaded) s.zone.deinit();
    }
    const rc = realMain(&s);
    s.out.flush();
    if (s.out.failed and rc == 0) {
        cli.warn(ctx, "write error", .{});
        return 2;
    }
    return rc;
}

fn realMain(s: *Ls) u8 {
    const ctx = s.ctx;
    const stdout_tty = Io.File.stdout().isTty(ctx.io) catch false;

    var time_style_option: ?[]const u8 = null;
    var kibibytes_specified = false;
    var format_opt: i32 = -1;
    var hide_control_chars_opt: i32 = -1;
    var quoting_style_opt: i32 = -1;
    var sort_opt: i32 = -1;
    var tabsize_opt: i64 = -1;
    var width_opt: i64 = -1;

    var p = getopt.Parser.init(ctx, "abcdfghiklmnopqrstuvw:xABCDFGHI:LNQRST:UXZ1", &.{
        .{ .name = "all", .id = 'a' },
        .{ .name = "escape", .id = 'b' },
        .{ .name = "directory", .id = 'd' },
        .{ .name = "dired", .id = 'D' },
        .{ .name = "full-time", .id = Opt.full_time },
        .{ .name = "group-directories-first", .id = Opt.group_dirs_first },
        .{ .name = "human-readable", .id = 'h' },
        .{ .name = "inode", .id = 'i' },
        .{ .name = "kibibytes", .id = 'k' },
        .{ .name = "numeric-uid-gid", .id = 'n' },
        .{ .name = "no-group", .id = 'G' },
        .{ .name = "hide-control-chars", .id = 'q' },
        .{ .name = "reverse", .id = 'r' },
        .{ .name = "size", .id = 's' },
        .{ .name = "width", .arg = .required, .id = 'w' },
        .{ .name = "almost-all", .id = 'A' },
        .{ .name = "ignore-backups", .id = 'B' },
        .{ .name = "classify", .arg = .optional, .id = 'F' },
        .{ .name = "file-type", .id = Opt.file_type },
        .{ .name = "si", .id = Opt.si },
        .{ .name = "dereference-command-line", .id = 'H' },
        .{ .name = "dereference-command-line-symlink-to-dir", .id = Opt.deref_cl_symlink_to_dir },
        .{ .name = "hide", .arg = .required, .id = Opt.hide },
        .{ .name = "ignore", .arg = .required, .id = 'I' },
        .{ .name = "indicator-style", .arg = .required, .id = Opt.indicator_style },
        .{ .name = "dereference", .id = 'L' },
        .{ .name = "literal", .id = 'N' },
        .{ .name = "quote-name", .id = 'Q' },
        .{ .name = "quoting-style", .arg = .required, .id = Opt.quoting_style },
        .{ .name = "recursive", .id = 'R' },
        .{ .name = "format", .arg = .required, .id = Opt.format },
        .{ .name = "show-control-chars", .id = Opt.show_control_chars },
        .{ .name = "sort", .arg = .required, .id = Opt.sort },
        .{ .name = "tabsize", .arg = .required, .id = 'T' },
        .{ .name = "time", .arg = .required, .id = Opt.time },
        .{ .name = "time-style", .arg = .required, .id = Opt.time_style },
        .{ .name = "zero", .id = Opt.zero },
        .{ .name = "color", .arg = .optional, .id = Opt.color },
        .{ .name = "hyperlink", .arg = .optional, .id = Opt.hyperlink },
        .{ .name = "block-size", .arg = .required, .id = Opt.block_size },
        .{ .name = "context", .id = 'Z' },
        .{ .name = "author", .id = Opt.author },
    });
    defer p.deinit();

    while (true) switch (p.next()) {
        .done => break,
        .bad => return 2,
        .opt => |o| switch (o.id) {
            'a' => s.ignore_mode = .minimal,
            'b' => quoting_style_opt = @intFromEnum(quotearg.Style.escape),
            'c' => {
                s.time_type = .ctime;
                s.explicit_time = true;
            },
            'd' => s.immediate_dirs = true,
            'f' => {
                s.ignore_mode = .minimal;
                sort_opt = @intFromEnum(SortType.none);
            },
            Opt.file_type => s.indicator_style = .file_type,
            'g' => {
                format_opt = @intFromEnum(Format.long);
                s.print_owner = false;
            },
            'h' => {
                s.file_human_output_opts = human.autoscale | human.si | human.base_1024;
                s.human_output_opts = s.file_human_output_opts;
                s.file_output_block_size = 1;
                s.output_block_size = 1;
            },
            'i' => s.print_inode = true,
            'k' => kibibytes_specified = true,
            'l' => format_opt = @intFromEnum(Format.long),
            'm' => format_opt = @intFromEnum(Format.with_commas),
            'n' => {
                s.numeric_ids = true;
                format_opt = @intFromEnum(Format.long);
            },
            'o' => {
                format_opt = @intFromEnum(Format.long);
                s.print_group = false;
            },
            'p' => s.indicator_style = .slash,
            'q' => hide_control_chars_opt = 1,
            'r' => s.sort_reverse = true,
            's' => s.print_block_size = true,
            't' => sort_opt = @intFromEnum(SortType.time),
            'u' => {
                s.time_type = .atime;
                s.explicit_time = true;
            },
            'v' => sort_opt = @intFromEnum(SortType.version),
            'w' => {
                const v = decodeLineLength(o.arg.?) orelse {
                    cli.warn(ctx, "invalid line width: {f}", .{cli.quoteC(o.arg.?)});
                    return 2;
                };
                width_opt = @intCast(v);
            },
            'x' => format_opt = @intFromEnum(Format.horizontal),
            'A' => s.ignore_mode = .dot_and_dotdot,
            'B' => {
                s.ignore_patterns.append(ctx.gpa, "*~") catch {};
                s.ignore_patterns.append(ctx.gpa, ".*~") catch {};
            },
            'C' => format_opt = @intFromEnum(Format.many_per_line),
            'D' => {
                format_opt = @intFromEnum(Format.long);
                s.print_hyperlink = false;
                s.dired = true;
            },
            'F' => {
                const v: u32 = if (o.arg) |a| (xargmatch(ctx, a, "--classify", &when_table) orelse return 1) else 1;
                if (v == 1 or (v == 2 and stdout_tty)) s.indicator_style = .classify;
            },
            'G' => s.print_group = false,
            'H' => s.dereference = .command_line_args,
            Opt.deref_cl_symlink_to_dir => s.dereference = .command_line_symlink_to_dir,
            'I' => s.ignore_patterns.append(ctx.gpa, o.arg.?) catch {},
            'L' => s.dereference = .always,
            'N' => quoting_style_opt = @intFromEnum(quotearg.Style.literal),
            'Q' => quoting_style_opt = @intFromEnum(quotearg.Style.c),
            'R' => s.recursive = true,
            'S' => sort_opt = @intFromEnum(SortType.size),
            'T' => {
                const arg = o.arg.?;
                const r = human.strtoumax(arg, "");
                switch (r.err) {
                    .ok => tabsize_opt = @intCast(@min(r.value, std.math.maxInt(i64))),
                    .overflow => {
                        cli.warn(ctx, "invalid tab size: {f}: Value too large for defined data type", .{cli.quoteC(arg)});
                        return 2;
                    },
                    else => {
                        cli.warn(ctx, "invalid tab size: {f}", .{cli.quoteC(arg)});
                        return 2;
                    },
                }
            },
            'U' => sort_opt = @intFromEnum(SortType.none),
            'X' => sort_opt = @intFromEnum(SortType.extension),
            '1' => if (format_opt != @intFromEnum(Format.long)) {
                format_opt = @intFromEnum(Format.one_per_line);
            },
            Opt.author => s.print_author = true,
            Opt.hide => s.hide_patterns.append(ctx.gpa, o.arg.?) catch {},
            Opt.sort => sort_opt = @intCast(xargmatch(ctx, o.arg.?, "--sort", &sort_table) orelse return 1),
            Opt.group_dirs_first => s.directories_first = true,
            Opt.time => {
                s.time_type = @enumFromInt(xargmatch(ctx, o.arg.?, "--time", &time_table) orelse return 1);
                s.explicit_time = true;
            },
            Opt.format => format_opt = @intCast(xargmatch(ctx, o.arg.?, "--format", &format_table) orelse return 1),
            Opt.full_time => {
                format_opt = @intFromEnum(Format.long);
                time_style_option = "full-iso";
            },
            Opt.color => {
                const v: u32 = if (o.arg) |a| (xargmatch(ctx, a, "--color", &when_table) orelse return 1) else 1;
                s.print_with_color = v == 1 or (v == 2 and stdout_tty);
            },
            Opt.hyperlink => {
                const v: u32 = if (o.arg) |a| (xargmatch(ctx, a, "--hyperlink", &when_table) orelse return 1) else 1;
                s.print_hyperlink = v == 1 or (v == 2 and stdout_tty);
            },
            Opt.indicator_style => s.indicator_style = @enumFromInt(xargmatch(ctx, o.arg.?, "--indicator-style", &indicator_table) orelse return 1),
            Opt.quoting_style => quoting_style_opt = @intCast(xargmatch(ctx, o.arg.?, "--quoting-style", &quoting_table) orelse return 1),
            Opt.time_style => time_style_option = o.arg.?,
            Opt.show_control_chars => hide_control_chars_opt = 0,
            Opt.block_size => {
                const arg = o.arg.?;
                const bs = human.options(arg, null, false);
                if (bs.err != .ok) {
                    xstrtolFatal(ctx, bs.err, "--block-size", arg);
                    return 2;
                }
                s.human_output_opts = bs.opts;
                s.output_block_size = bs.size;
                s.file_human_output_opts = bs.opts;
                s.file_output_block_size = bs.size;
            },
            Opt.si => {
                s.file_human_output_opts = human.autoscale | human.si;
                s.human_output_opts = s.file_human_output_opts;
                s.file_output_block_size = 1;
                s.output_block_size = 1;
            },
            'Z' => s.print_scontext = true,
            Opt.zero => {
                s.eolbyte = 0;
                hide_control_chars_opt = 0;
                if (format_opt != @intFromEnum(Format.long)) format_opt = @intFromEnum(Format.one_per_line);
                s.print_with_color = false;
                quoting_style_opt = @intFromEnum(quotearg.Style.literal);
            },
            getopt.help_id => {
                const ok = switch (s.mode) {
                    .ls => cli.writeStdout(ctx.io, help_ls ++ "\n"),
                    .multi_col => cli.writeStdout(ctx.io, help_dir ++ "\n"),
                    .long => cli.writeStdout(ctx.io, help_vdir ++ "\n"),
                };
                return if (ok) 0 else 2;
            },
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 2,
            else => unreachable,
        },
    };

    if (s.output_block_size == 0) {
        const ls_bs = cli.getenv(ctx, "LS_BLOCK_SIZE");
        const env_bs = ls_bs orelse (cli.getenv(ctx, "BLOCK_SIZE") orelse cli.getenv(ctx, "BLOCKSIZE"));
        const posix = cli.getenv(ctx, "POSIXLY_CORRECT") != null;
        const bs = human.options(ls_bs, env_bs, posix);
        s.human_output_opts = bs.opts;
        s.output_block_size = bs.size;
        if (ls_bs != null or cli.getenv(ctx, "BLOCK_SIZE") != null) {
            s.file_human_output_opts = s.human_output_opts;
            s.file_output_block_size = s.output_block_size;
        }
        if (kibibytes_specified) {
            s.human_output_opts = 0;
            s.output_block_size = 1024;
        }
    }

    s.format = if (format_opt >= 0) @enumFromInt(format_opt) else switch (s.mode) {
        .ls => if (stdout_tty) Format.many_per_line else Format.one_per_line,
        .multi_col => Format.many_per_line,
        .long => Format.long,
    };

    var linelen: i64 = width_opt;
    if (s.format == .many_per_line or s.format == .horizontal or s.format == .with_commas or s.print_with_color) {
        if (linelen < 0) {
            if (stdout_tty) {
                if (sys.terminalColumns()) |c| {
                    if (c > 0) linelen = @intCast(c);
                }
            }
        }
        if (linelen < 0) {
            if (cli.getenv(ctx, "COLUMNS")) |c| {
                if (c.len > 0) {
                    if (decodeLineLength(c)) |v| {
                        linelen = @intCast(v);
                    } else {
                        cli.warn(ctx, "ignoring invalid width in environment variable COLUMNS: {f}", .{cli.quoteC(c)});
                    }
                }
            }
        }
    }
    s.line_length = if (linelen < 0) 80 else @intCast(linelen);
    s.max_idx = s.line_length / MIN_COLUMN_WIDTH;
    if (s.line_length % MIN_COLUMN_WIDTH != 0) s.max_idx += 1;

    if (s.format == .many_per_line or s.format == .horizontal or s.format == .with_commas) {
        if (tabsize_opt >= 0) {
            s.tabsize = @intCast(tabsize_opt);
        } else {
            s.tabsize = 8;
            if (cli.getenv(ctx, "TABSIZE")) |t| {
                const r = human.strtoumax(t, "");
                if (r.err == .ok) {
                    s.tabsize = @intCast(r.value);
                } else {
                    cli.warn(ctx, "ignoring invalid tab size in environment variable TABSIZE: {f}", .{cli.quoteC(t)});
                }
            }
        }
    }

    s.qmark_funny_chars = if (hide_control_chars_opt < 0) (s.mode == .ls and stdout_tty) else hide_control_chars_opt != 0;

    var qs: i32 = quoting_style_opt;
    if (qs < 0) {
        if (cli.getenv(ctx, "QUOTING_STYLE")) |q| {
            switch (argmatch.match(q, &quoting_table)) {
                .ok => |v| qs = @intCast(v),
                else => cli.warn(ctx, "ignoring invalid value of environment variable QUOTING_STYLE: {f}", .{cli.quoteC(q)}),
            }
        }
    }
    if (qs < 0) {
        qs = if (s.mode == .ls)
            (if (stdout_tty) @intFromEnum(quotearg.Style.shell_escape) else -1)
        else
            @intFromEnum(quotearg.Style.escape);
    }
    if (qs >= 0) s.filename_style = quotearg.style_values[@intCast(qs)];
    s.align_variable_outer_quotes = (s.format == .long or ((s.format == .many_per_line or s.format == .horizontal) and s.line_length != 0)) and
        (s.filename_style == .shell or s.filename_style == .shell_escape or s.filename_style == .c_maybe);
    if (s.filename_style == .escape) s.filename_extra.add(' ');
    if (@intFromEnum(s.indicator_style) >= @intFromEnum(IndicatorStyle.file_type)) {
        const chars = "*=>@|";
        for (chars[@intFromEnum(s.indicator_style) - @intFromEnum(IndicatorStyle.file_type) ..]) |c| s.filename_extra.add(c);
    }
    s.dirname_extra.add(':');

    s.dired = s.dired and s.format == .long and !s.print_hyperlink;
    if (s.eolbyte < @intFromBool(s.dired)) {
        cli.warn(ctx, "--dired and --zero are incompatible", .{});
        return 2;
    }

    s.sort_type = if (sort_opt >= 0) @enumFromInt(sort_opt) else if (s.format != .long and s.explicit_time) .time else .name;

    if (s.format == .long) {
        var style: []const u8 = time_style_option orelse (cli.getenv(ctx, "TIME_STYLE") orelse "locale");
        var posix_skipped = false;
        while (std.mem.startsWith(u8, style, "posix-")) {
            // hard_locale is false in the C locale: the style is ignored.
            posix_skipped = true;
            break;
        }
        if (!posix_skipped) {
            if (style.len > 0 and style[0] == '+') {
                const p0 = style[1..];
                if (std.mem.indexOfScalar(u8, p0, '\n')) |nl| {
                    const rest = p0[nl + 1 ..];
                    if (std.mem.indexOfScalar(u8, rest, '\n') != null) {
                        cli.warn(ctx, "invalid time style format {f}", .{cli.quoteC(p0)});
                        return 2;
                    }
                    s.long_time_format = .{ p0[0..nl], rest };
                } else s.long_time_format = .{ p0, p0 };
            } else {
                const r = argmatch.match(style, &time_style_table);
                switch (r) {
                    .ok => |v| switch (v) {
                        0 => s.long_time_format = .{ "%Y-%m-%d %H:%M:%S.%N %z", "%Y-%m-%d %H:%M:%S.%N %z" },
                        1 => s.long_time_format = .{ "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M" },
                        2 => s.long_time_format = .{ "%Y-%m-%d ", "%m-%d %H:%M" },
                        else => {},
                    },
                    else => {
                        const q = quotearg.quoteAlloc(ctx.gpa, style, .locale, null) catch return 2;
                        defer ctx.gpa.free(q);
                        cli.warn(ctx, "{s} argument {s} for 'time style'\nValid arguments are:\n  - [posix-]full-iso\n  - [posix-]long-iso\n  - [posix-]iso\n  - [posix-]locale\n  - +FORMAT (e.g., +%H:%M) for a 'date'-style format\nTry '{s} --help' for more information.", .{ if (r == .ambiguous) "ambiguous" else "invalid", q, ctx.name });
                        return 2;
                    },
                }
            }
        }
        style = style;
    }

    if (s.print_with_color) s.parseLsColor();
    if (s.print_with_color) s.tabsize = 0;

    if (s.directories_first) {
        s.check_symlink_mode = true;
    } else if (s.print_with_color) {
        if (s.isColored(C_ORPHAN) or (s.isColored(C_EXEC) and s.color_symlink_as_referent) or (s.isColored(C_MISSING) and s.format == .long))
            s.check_symlink_mode = true;
    }

    if (s.dereference == .undefined) {
        s.dereference = if (s.immediate_dirs or s.indicator_style == .classify or s.format == .long) .never else .command_line_symlink_to_dir;
    }
    if (s.recursive) s.loop_detect = true;

    s.format_needs_stat = s.sort_type == .time or s.sort_type == .size or s.format == .long or s.print_block_size or s.print_hyperlink;
    s.format_needs_type = !s.format_needs_stat and (s.recursive or s.print_with_color or s.print_scontext or s.directories_first or s.indicator_style != .none);
    s.format_needs_capability = false;

    if (s.print_hyperlink) {
        for (0..256) |i| {
            const c: u8 = @intCast(i);
            s.rfc3986[i] = std.ascii.isAlphanumeric(c) or c == '~' or c == '-' or c == '.' or c == '_';
        }
        s.hostname = s.cfg.allocator().dupe(u8, sys.uname().nodename) catch "";
    }

    s.clearFiles();

    const operands = p.operands.items;
    if (operands.len == 0) {
        if (s.immediate_dirs) {
            _ = s.gobbleFile(".", .directory, true, null);
        } else s.queueDirectory(".", null, true);
    } else {
        for (operands) |name| _ = s.gobbleFile(name, .unknown, true, null);
    }

    if (s.files.items.len > 0) {
        s.sortFiles();
        if (!s.immediate_dirs) s.extractDirsFromFiles(null, true);
    }

    if (s.files.items.len > 0) {
        s.printCurrentFiles();
        if (s.pending.items.len > 0) s.putByte('\n');
    } else if (operands.len <= 1 and s.pending.items.len == 1) {
        s.print_dir_name = false;
    }

    while (s.pending.pop()) |pd| {
        defer {
            if (pd.name) |n| ctx.gpa.free(n);
            if (pd.realname) |n| ctx.gpa.free(n);
        }
        if (s.loop_detect) {
            if (pd.name == null) {
                _ = s.active.pop();
                continue;
            }
        }
        s.printDir(pd.name.?, pd.realname, pd.command_line_arg);
        s.print_dir_name = true;
    }

    if (s.print_with_color and s.used_color) {
        const lc = s.indicators[C_LEFT] orelse "";
        const rc = s.indicators[C_RIGHT] orelse "";
        if (!(std.mem.eql(u8, lc, "\x1b[") and std.mem.eql(u8, rc, "m"))) s.restoreDefaultColor();
    }

    if (s.dired) {
        s.dumpOffsets("//DIRED//", &s.dired_offsets);
        s.dumpOffsets("//SUBDIRED//", &s.subdired_offsets);
        s.out.print("//DIRED-OPTIONS// --quoting-style={s}\n", .{quotearg.style_names[@intFromEnum(s.filename_style)]});
    }
    return s.exit_status;
}

pub fn main(ctx: cli.Context) u8 {
    return run(ctx, .ls);
}
