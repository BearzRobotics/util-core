// SPDX-License-Identifier: GPL-2.0-or-later
//! What the terminal can show: its color depth (from the environment) and
//! whether its background is dark or light (asked of the terminal with the
//! OSC 11 query, falling back to $COLORFGBG). Used by `cat` to pick a theme.

const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const cli = @import("cli.zig");
const theme = @import("syntax/theme.zig");

pub const Appearance = enum { dark, light };

/// Color depth from $COLORTERM, $TERM and a few terminals that are known to
/// support 24-bit color without saying so.
pub fn depth(ctx: cli.Context) theme.Depth {
    if (cli.getenv(ctx, "COLORTERM")) |c| {
        if (std.ascii.findIgnoreCase(c, "truecolor") != null or std.ascii.findIgnoreCase(c, "24bit") != null)
            return .truecolor;
    }
    if (cli.getenv(ctx, "WT_SESSION") != null) return .truecolor; // Windows Terminal
    if (cli.getenv(ctx, "TERM_PROGRAM")) |p| {
        for ([_][]const u8{ "iTerm.app", "vscode", "WezTerm", "ghostty" }) |known|
            if (std.mem.eql(u8, p, known)) return .truecolor;
    }
    if (cli.getenv(ctx, "KITTY_WINDOW_ID") != null or cli.getenv(ctx, "ALACRITTY_LOG") != null) return .truecolor;
    if (cli.getenv(ctx, "TERM")) |t| {
        if (std.mem.indexOf(u8, t, "direct") != null or std.mem.indexOf(u8, t, "truecolor") != null) return .truecolor;
        if (std.mem.indexOf(u8, t, "256color") != null) return .ansi256;
        if (std.mem.eql(u8, t, "dumb")) return .ansi16;
    }
    return .ansi16;
}

/// Whether the terminal background is dark or light: the terminal's own
/// answer when it gives one, else $COLORFGBG, else dark.
pub fn appearance(ctx: cli.Context, ask_terminal: bool) Appearance {
    if (ask_terminal) {
        if (queryBackground(ctx.io)) |rgb| return fromRgb(rgb);
    }
    if (cli.getenv(ctx, "COLORFGBG")) |v| {
        // "fg;bg" (sometimes "fg;default;bg"): the last field is the background.
        const idx = if (std.mem.lastIndexOfScalar(u8, v, ';')) |i| i + 1 else 0;
        if (std.fmt.parseInt(u8, v[idx..], 10)) |bg| {
            return if (bg == 7 or bg >= 9) .light else .dark;
        } else |_| {}
    }
    return .dark;
}

pub fn fromRgb(rgb: [3]u8) Appearance {
    const y = 0.2126 * @as(f32, @floatFromInt(rgb[0])) + 0.7152 * @as(f32, @floatFromInt(rgb[1])) + 0.0722 * @as(f32, @floatFromInt(rgb[2]));
    return if (y > 127.5) .light else .dark;
}

/// Ask the terminal for its background color: OSC 11 followed by a device
/// attributes request, which every terminal answers, so a terminal that does
/// not know OSC 11 is detected without waiting for a timeout.
pub fn queryBackground(io: Io) ?[3]u8 {
    var tty = sys.Tty.open(io) orelse return null;
    defer tty.close(io);
    var wbuf: [64]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &wbuf);
    w.interface.writeAll("\x1b]11;?\x1b\\\x1b[c") catch return null;
    w.interface.flush() catch return null;

    var reply: [128]u8 = undefined;
    var n: usize = 0;
    // Read until the device-attributes reply ("ESC [ ? ... c") or a pause.
    while (n < reply.len) {
        const b = tty.readByteTimeout(250) orelse break;
        reply[n] = b;
        n += 1;
        if (b == 'c' and std.mem.indexOf(u8, reply[0..n], "\x1b[?") != null) break;
    }
    return parseOsc11(reply[0..n]);
}

/// `ESC ] 11 ; rgb:RRRR/GGGG/BBBB` (1 to 4 hex digits per channel).
pub fn parseOsc11(reply: []const u8) ?[3]u8 {
    const at = std.mem.indexOf(u8, reply, "rgb:") orelse return null;
    var rest = reply[at + 4 ..];
    var out: [3]u8 = undefined;
    for (0..3) |k| {
        var len: usize = 0;
        while (len < rest.len and len < 4 and std.ascii.isHex(rest[len])) len += 1;
        if (len == 0) return null;
        const v = std.fmt.parseInt(u16, rest[0..len], 16) catch return null;
        const max: u32 = (@as(u32, 1) << @intCast(4 * len)) - 1;
        out[k] = @intCast((@as(u32, v) * 255 + max / 2) / max);
        rest = rest[len..];
        if (k < 2) {
            if (rest.len == 0 or rest[0] != '/') return null;
            rest = rest[1..];
        }
    }
    return out;
}

test "osc 11 reply" {
    const a = parseOsc11("\x1b]11;rgb:ffff/ffff/ffff\x1b\\\x1b[?62c").?;
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, a);
    try std.testing.expectEqual(Appearance.light, fromRgb(a));
    const b = parseOsc11("\x1b]11;rgb:1e/1e/2e\x07").?;
    try std.testing.expectEqual(Appearance.dark, fromRgb(b));
    try std.testing.expect(parseOsc11("\x1b[?62c") == null);
}
