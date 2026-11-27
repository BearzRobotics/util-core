// SPDX-License-Identifier: GPL-2.0-or-later
//! sed: thin wrapper over `util_core.sed` (decision 0004). Parses arguments
//! the way GNU sed does, reads -f script files, words the diagnostics; the
//! script compiler and the executor are in src/lib/sed.zig.
//! Reference: GNU sed 4.9.

const std = @import("std");
const Io = std.Io;
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const sed = @import("../lib/sed.zig");
const LX = std.os.linux;

const help_text = @embedFile("../help/sed.txt");

fn usage(ctx: cli.Context, to_stderr: bool, status: u8) u8 {
    const text = std.mem.replaceOwned(u8, ctx.gpa, help_text, "@NAME@", ctx.name) catch return 4;
    defer ctx.gpa.free(text);
    if (to_stderr) {
        const mail = std.mem.indexOf(u8, text, "E-mail bug reports") orelse text.len;
        _ = sys.writeAllFd(std.Io.File.stderr().handle, text[0..mail]);
    } else if (!cli.writeStdout(ctx.io, text)) return 4;
    return status;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "couldn't allocate memory", .{});
    return 4;
}

pub fn main(ctx: cli.Context) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const env: sed.Env = .{ .io = ctx.io, .gpa = std.heap.smp_allocator, .environ = ctx.environ };
    var opts: sed.Options = .{};
    opts.utf8 = sed.localeIsUtf8(env);

    var p = getopt.Parser.init(ctx, "bsnrzuEe:f:l:i::V:", &.{
        .{ .name = "binary", .id = 'b' },
        .{ .name = "regexp-extended", .id = 'E' },
        .{ .name = "debug", .id = 1100 },
        .{ .name = "in-place", .arg = .optional, .id = 'i' },
        .{ .name = "expression", .arg = .required, .id = 'e' },
        .{ .name = "file", .arg = .required, .id = 'f' },
        .{ .name = "line-length", .arg = .required, .id = 'l' },
        .{ .name = "null-data", .id = 'z' },
        .{ .name = "zero-terminated", .id = 'z' },
        .{ .name = "quiet", .id = 'n' },
        .{ .name = "posix", .id = 1101 },
        .{ .name = "silent", .id = 'n' },
        .{ .name = "sandbox", .id = 1102 },
        .{ .name = "separate", .id = 's' },
        .{ .name = "unbuffered", .id = 'u' },
        .{ .name = "follow-symlinks", .id = 1103 },
    });
    defer p.deinit();
    p.no_try = true;
    var chunks: std.ArrayList(sed.Chunk) = .empty;
    var n_e: usize = 0;
    while (true) switch (p.next()) {
        .done => break,
        .bad => return usage(ctx, true, 1),
        .opt => |o| switch (o.id) {
            'n' => opts.quiet = true,
            'E', 'r' => opts.ere = true,
            's' => opts.separate = true,
            'z' => opts.null_data = true,
            'u' => opts.unbuffered = true,
            'b' => {},
            'i' => {
                opts.in_place = true;
                opts.separate = true;
                opts.suffix = o.arg;
            },
            'l' => {
                var v: i64 = 0;
                for (o.arg.?) |ch| {
                    if (!std.ascii.isDigit(ch)) break;
                    v = v *| 10 +| (ch - '0');
                }
                opts.line_len = v;
            },
            'e' => {
                n_e += 1;
                chunks.append(arena, .{ .text = o.arg.?, .is_file = false, .name = "", .index = n_e }) catch return 4;
            },
            'f' => {
                const name = o.arg.?;
                var data: std.ArrayList(u8) = .empty;
                var err: LX.E = .SUCCESS;
                const fd: sys.Handle = if (std.mem.eql(u8, name, "-")) std.Io.File.stdin().handle else sys.openFd(name, sys.O.RDONLY, 0, &err) orelse {
                    cli.warn(ctx, "couldn't open file {s}: {s}", .{ name, sys.errnoText(err) });
                    return 4;
                };
                var buf: [65536]u8 = undefined;
                while (true) {
                    const n = sys.readFd(fd, &buf, &err) orelse break;
                    if (n == 0) break;
                    data.appendSlice(arena, buf[0..n]) catch return 4;
                }
                if (fd != std.Io.File.stdin().handle) _ = sys.closeFd(fd);
                var text = data.items;
                if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
                n_e += 1;
                chunks.append(arena, .{ .text = text, .is_file = true, .name = name, .index = n_e }) catch return 4;
            },
            1100 => opts.debug = true,
            1101 => opts.posix = true,
            1102 => opts.sandbox = true,
            1103 => opts.follow = true,
            getopt.help_id => return usage(ctx, false, 0),
            getopt.version_id => {
                const v =
                    \\sed (GNU sed) 4.9
                    \\Copyright (C) 2022 Free Software Foundation, Inc.
                    \\License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
                    \\This is free software: you are free to change and redistribute it.
                    \\There is NO WARRANTY, to the extent permitted by law.
                    \\
                ;
                return if (cli.writeStdout(ctx.io, v)) 0 else 4;
            },
            else => return usage(ctx, true, 1),
        },
    };

    var operands = p.operands.items;
    if (chunks.items.len == 0) {
        if (operands.len == 0) return usage(ctx, true, 1);
        n_e += 1;
        chunks.append(arena, .{ .text = operands[0], .is_file = false, .name = "", .index = 1 }) catch return 4;
        operands = operands[1..];
    }
    var diag: sed.CompileError = .{};
    var program = sed.compile(env, opts, chunks.items, &diag) catch |e| switch (e) {
        error.OutOfMemory => return oom(ctx),
        error.BadProgram => return reportCompileError(ctx, &diag),
    };
    defer program.deinit();

    if (opts.in_place and operands.len == 0) {
        cli.warn(ctx, "no input files", .{});
        return 4;
    }
    var inputs: std.ArrayList(sed.Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    if (operands.len == 0) {
        inputs.append(ctx.gpa, .{ .name = "-", .source = .{ .file = Io.File.stdin() } }) catch return oom(ctx);
    }
    for (operands) |f| {
        const in: sed.Input = if (std.mem.eql(u8, f, "-") and !opts.in_place)
            .{ .name = "-", .source = .{ .file = Io.File.stdin() } }
        else
            .{ .name = f, .source = .{ .path = f } };
        inputs.append(ctx.gpa, in) catch return oom(ctx);
    }

    var buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(ctx.io, &buf);
    var ebuf: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writerStreaming(ctx.io, &ebuf);
    opts.stderr = &stderr.interface;
    opts.stdin = Io.File.stdin();
    var report_state = Report{ .ctx = ctx, .stdout = &stdout, .stderr = &stderr };
    const observer: sed.Observer = .{ .context = &report_state, .func = report };
    const result = sed.run(env, &program, opts, inputs.items, &stdout.interface, observer) catch return oom(ctx);
    if (!program.closeFiles(observer)) return 4;
    return result.exit_code;
}

/// Word a script error the way GNU sed does; returns the exit status.
fn reportCompileError(ctx: cli.Context, d: *const sed.CompileError) u8 {
    switch (d.kind) {
        .syntax => {
            if (d.chunk.is_file) {
                cli.warn(ctx, "file {s} line {d}: {s}", .{ d.chunk.name, d.line, d.message() });
            } else {
                cli.warn(ctx, "-e expression #{d}, char {d}: {s}", .{ d.chunk.index, d.pos, d.message() });
            }
            return 1;
        },
        .unmatched_brace => {
            cli.warn(ctx, "-e expression #{d}, char 0: unmatched `{{'", .{d.chunk.index});
            return 1;
        },
        .open_output => {
            cli.warn(ctx, "couldn't open file {s}: {s}", .{ d.name(), sys.errnoText(d.errno) });
            return 4;
        },
        .missing_label => {
            cli.warn(ctx, "can't find label for jump to `{s}'", .{d.name()});
            return 4;
        },
    }
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

const Report = struct { ctx: cli.Context, stdout: *Io.File.Writer, stderr: *Io.File.Writer };

/// Word the library's events as GNU sed does.
fn report(context: ?*anyopaque, ev: sed.Event) void {
    const st: *const Report = @ptrCast(@alignCast(context.?));
    const ctx = st.ctx;
    switch (ev) {
        .cant_read => |e| cli.warn(ctx, "can't read {s}: {s}", .{ e.name, sys.errnoText(e.errno) }),
        .cant_edit => |n| cli.warn(ctx, "couldn't edit {s}: not a regular file", .{n}),
        .subprocess_failed => cli.warn(ctx, "error in subprocess", .{}),
        .read_error => |e| cli.warn(ctx, "read error on {s}: {s}", .{ e.name, sys.errnoText(e.errno) }),
        .write_error => |e| {
            if (e.errno) |no| {
                cli.warn(ctx, "couldn't write {d} item{s} to {s}: {s}", .{ e.items, plural(e.items), e.name, sys.errnoText(no) });
            } else {
                // The error belongs to a writer we gave the library.
                const w = if (std.mem.eql(u8, e.name, "stdout")) st.stdout else st.stderr;
                const werr = w.err orelse error.WriteFailed;
                cli.warn(ctx, "couldn't write {d} item{s} to {s}: {s}", .{ e.items, plural(e.items), e.name, cli.errText(werr) });
            }
        },
        .temp_open_failed => |e| cli.warn(ctx, "couldn't open temporary file {s}: {s}", .{ e.path, sys.errnoText(e.errno) }),
        .rename_failed => |e| cli.warn(ctx, "cannot rename {s}: {s}", .{ e.name, sys.errnoText(e.errno) }),
        .group_not_kept => |e| cli.warn(ctx, "warning: {s}: could not keep the group ({s}); the new group gets only the permissions of others", .{ e.name, sys.errnoText(e.errno) }),
        .permissions_not_kept => |e| cli.warn(ctx, "warning: {s}: could not keep all of its permissions and access ACL ({s}); the new file allows nobody more", .{ e.name, sys.errnoText(e.errno) }),
        .close_failed => |e| cli.warn(ctx, "couldn't close {s}: {s}", .{ e.name, sys.errnoText(e.errno) }),
        .no_previous_regex => |ch| {
            if (ch.is_file) {
                cli.warn(ctx, "file {s} line 1: no previous regular expression", .{ch.name});
            } else cli.warn(ctx, "-e expression #{d}, char 0: no previous regular expression", .{ch.index});
        },
    }
}
