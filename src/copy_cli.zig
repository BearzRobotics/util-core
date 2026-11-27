// SPDX-License-Identifier: GPL-2.0-or-later
//! Wrapper-side routing of the copy engine's events for cp, mv and install:
//! buffered standard output, diagnostics on standard error and the prompts.

const std = @import("std");
const cli = @import("cli.zig");
const copy = @import("copy.zig");
const Io = std.Io;

pub const Routing = struct {
    ctx: cli.Context,
    out: *cli.Out,

    pub fn sink(r: *Routing) copy.Sink {
        return .{
            .observer = .{ .context = r, .func = observe },
            .confirm = .{ .context = r, .func = confirm },
        };
    }
};

fn observe(context: ?*anyopaque, ev: copy.Event) void {
    const r: *Routing = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .out => |t| r.out.write(t),
        .flush => r.out.flush(),
        .diag => |t| cli.warn(r.ctx, "{s}", .{t}),
    }
}

fn confirm(context: ?*anyopaque, p: copy.Prompt) bool {
    const r: *Routing = @ptrCast(@alignCast(context.?));
    const ctx = r.ctx;
    switch (p.kind) {
        .replace_override => cli.writeStderrNoNl(ctx, "{s}: replace {f}, overriding mode {o:0>4} ({s})? ", .{ ctx.name, cli.quoteA(p.path), p.mode, &p.perms }),
        .unwritable => cli.writeStderrNoNl(ctx, "{s}: unwritable {f} (mode {o:0>4}, {s}); try anyway? ", .{ ctx.name, cli.quoteA(p.path), p.mode, &p.perms }),
        .overwrite => cli.writeStderrNoNl(ctx, "{s}: overwrite {f}? ", .{ ctx.name, cli.quoteA(p.path) }),
    }
    return cli.readYes(ctx.io, Io.File.stdin());
}
