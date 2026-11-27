// SPDX-License-Identifier: GPL-2.0-or-later
//! less — page a file or a stream on the terminal. Reference: less(1) (GNU
//! less 668 on the development machine) for options and keys.
//!
//! The model and drawing are in src/lib/pager.zig, the terminal and threads in
//! src/pager_ui.zig. This wrapper reads the inputs and feeds them to the
//! pager as they arrive, so a pipe can be scrolled while it still fills. When
//! standard output is not a terminal it copies its input like cat.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const pager_ui = @import("../pager_ui.zig");
const pager = @import("../lib/pager.zig");

const help_text = @embedFile("../help/less.txt");

const longs = [_]getopt.Long{
    .{ .name = "quit-if-one-screen", .id = 'F' },
    .{ .name = "RAW-CONTROL-CHARS", .id = 'R' },
    .{ .name = "raw-control-chars", .id = 'r' },
    .{ .name = "chop-long-lines", .id = 'S' },
    .{ .name = "LINE-NUMBERS", .id = 'N' },
    .{ .name = "ignore-case", .id = 'i' },
    .{ .name = "IGNORE-CASE", .id = 'I' },
    .{ .name = "no-init", .id = 'X' },
    .{ .name = "quit-at-eof", .id = 'e' },
    .{ .name = "QUIT-AT-EOF", .id = 'E' },
    .{ .name = "quiet", .id = 'q' },
    .{ .name = "silent", .id = 'q' },
    .{ .name = "QUIET", .id = 'Q' },
    .{ .name = "SILENT", .id = 'Q' },
};

const Input = struct { name: []const u8, file: Io.File, owned: bool };

pub fn main(ctx: cli.Context) u8 {
    var opts: pager_ui.Options = .{};
    var quit_if_one = false;
    var p = getopt.Parser.init(ctx, "FRrSNiIXeEqQscdmMwLKn", &longs);
    defer p.deinit();
    while (true) switch (p.next()) {
        .done => break,
        .bad => return 1,
        .opt => |o| switch (o.id) {
            'F' => quit_if_one = true,
            'R', 'r' => opts.raw = true,
            'S' => opts.chop = true,
            'N' => opts.numbers = true,
            'i' => opts.case = .smart,
            'I' => opts.case = .ignore,
            // Accepted for compatibility, no effect here.
            'X', 'e', 'E', 'q', 'Q', 's', 'c', 'd', 'm', 'w', 'L', 'K', 'n' => {},
            'M' => {},
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text)) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        },
    };

    const tty_out = Io.File.stdout().isTty(ctx.io) catch false;
    var names = p.operands.items;
    const stdin_only = [_][]const u8{"-"};
    if (names.len == 0) {
        if (Io.File.stdin().isTty(ctx.io) catch false) {
            cli.writeStderr(ctx, "Missing filename (\"less --help\" for help)", .{});
            return 1;
        }
        names = @constCast(&stdin_only);
    }

    // Open every input first, so a missing file is reported before the screen
    // is taken over.
    var inputs: std.ArrayList(Input) = .empty;
    defer {
        for (inputs.items) |i| if (i.owned) i.file.close(ctx.io);
        inputs.deinit(ctx.gpa);
    }
    var status: u8 = 0;
    for (names) |name| {
        if (std.mem.eql(u8, name, "-")) {
            inputs.append(ctx.gpa, .{ .name = "stdin", .file = Io.File.stdin(), .owned = false }) catch return oom(ctx);
            continue;
        }
        const f = Io.Dir.cwd().openFile(ctx.io, name, .{}) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ name, cli.errText(e) });
            status = 1;
            continue;
        };
        inputs.append(ctx.gpa, .{ .name = name, .file = f, .owned = true }) catch return oom(ctx);
    }
    if (inputs.items.len == 0) return 1;

    const label = if (inputs.items.len == 1) inputs.items[0].name else "";
    const ui = if (tty_out) pager_ui.Ui.start(ctx.gpa, ctx.io, opts, label, quit_if_one) else null;
    if (ui == null) return copyAll(ctx, inputs.items, status, tty_out and !opts.raw);
    defer ui.?.deinit();

    var buf: [65536]u8 = undefined;
    feed: for (inputs.items) |in| {
        while (true) {
            const n = in.file.readStreaming(ctx.io, &.{&buf}) catch break;
            if (n == 0) break;
            ui.?.feed(buf[0..n]) catch break :feed;
        }
    }
    // A file can still grow (a log being written): F then reads what is
    // added to the last one.
    const last = inputs.items[inputs.items.len - 1].file;
    const regular = if (last.stat(ctx.io)) |st| st.kind == .file else |_| false;
    _ = ui.?.finishGrowing(quit_if_one, if (regular) last else null);
    return status;
}

/// No terminal to page on: behave like cat. With `visible` (the output is a
/// terminal all the same, and -R was not given) control characters are shown
/// as the pager shows them.
fn copyAll(ctx: cli.Context, inputs: []const Input, status: u8, visible: bool) u8 {
    var obuf: [8192]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(ctx.io, &obuf);
    var buf: [65536]u8 = undefined;
    for (inputs) |in| {
        while (true) {
            const n = in.file.readStreaming(ctx.io, &.{&buf}) catch break;
            if (n == 0) break;
            writeCopy(ctx.gpa, &out.interface, buf[0..n], visible) catch
                return copyFailed(out.err, status);
        }
    }
    out.interface.flush() catch return copyFailed(out.err, status);
    return status;
}

/// A reader that has gone has seen all it wanted: as with less itself, that
/// is no error (SIGPIPE only arrives here as one when it is ignored).
fn copyFailed(err: ?Io.File.Writer.Error, status: u8) u8 {
    if (err) |e| if (e == error.BrokenPipe) return status;
    cli.noteStdoutFailure(cli.errText(err orelse error.WriteFailed));
    return 1;
}

fn writeCopy(gpa: std.mem.Allocator, w: *Io.Writer, bytes: []const u8, visible: bool) !void {
    if (!visible) return w.writeAll(bytes);
    var part = pager.Pager.init(gpa, .{}, 24, 80);
    defer part.deinit();
    _ = try part.append(bytes);
    try part.print(w);
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}
