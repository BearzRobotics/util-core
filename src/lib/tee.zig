// SPDX-License-Identifier: GPL-2.0-or-later
//! tee library (decision 0004): copy an input to several destinations.
//! References: GNU coreutils manual "tee invocation" (9.7); POSIX.1-2024 tee.
//!
//! Output is not buffered: each chunk read is written immediately to every
//! destination, so destinations are open files, not `*Io.Writer`s (the
//! per-destination error kind, such as a broken pipe, decides what happens
//! next). Error handling follows the GNU manual's --output-error table.
//!
//! The library never changes signal dispositions: a host that wants
//! --ignore-interrupts or a broken pipe seen as a write error ignores the
//! signals itself before calling `run`.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const sys = @import("../sys.zig");

pub const Env = common.Env;
pub const Input = common.Input;

/// What to do when a write fails (GNU --output-error).
pub const Mode = enum { default, warn, warn_nopipe, exit, exit_nopipe };

pub const Options = struct {
    /// Open the named files for appending instead of truncating.
    append: bool = false,
    output_error: Mode = .default,
};

/// A destination. Standard output is passed by the host as an open file;
/// named destinations are opened (and closed) by the library.
pub const Destination = struct {
    name: []const u8,
    target: Target,

    pub const Target = union(enum) {
        path: []const u8,
        /// Already open; the library does not close it.
        file: Io.File,
    };
};

/// A problem with one destination or with the input; `name` is the
/// destination's name, or "standard input".
pub const Event = struct {
    name: []const u8,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

const Output = struct {
    file: Io.File,
    name: []const u8,
    owned: bool,
    alive: bool = true,
};

pub fn run(env: Env, options: Options, input: Io.File, destinations: []const Destination, observer: Observer) error{OutOfMemory}!Result {
    const mode = options.output_error;
    var outs: std.ArrayList(Output) = .empty;
    defer outs.deinit(env.gpa);
    defer for (outs.items) |o| if (o.owned) o.file.close(env.io);

    var status: u8 = 0;
    for (destinations) |d| switch (d.target) {
        .file => |f| try outs.append(env.gpa, .{ .file = f, .name = d.name, .owned = false }),
        .path => |p| {
            const file = openOutput(env.io, p, options.append) catch |e| {
                observer.emit(.{ .name = d.name, .err = e });
                status = 1;
                if (mode == .exit or mode == .exit_nopipe) return .{ .failed = true };
                continue;
            };
            try outs.append(env.gpa, .{ .file = file, .name = d.name, .owned = true });
        },
    };

    var live: usize = outs.items.len;
    var buf: [64 * 1024]u8 = undefined;
    while (live > 0) {
        const n = common.readChunk(env.io, input, &buf) catch |e| {
            observer.emit(.{ .name = "standard input", .err = e });
            status = 1;
            break;
        };
        if (n == 0) break;
        for (outs.items) |*o| {
            if (!o.alive) continue;
            o.file.writeStreamingAll(env.io, buf[0..n]) catch |e| {
                const pipe = e == error.BrokenPipe;
                // A closed pipe only shows as an error here when SIGPIPE is
                // ignored; by default GNU then drops the output in silence.
                const quiet = pipe and (mode == .default or mode == .warn_nopipe or mode == .exit_nopipe);
                if (!quiet) {
                    observer.emit(.{ .name = o.name, .err = e });
                    status = 1;
                }
                if (mode == .exit or (mode == .exit_nopipe and !pipe)) return .{ .failed = true };
                o.alive = false;
                live -= 1;
            };
        }
    }
    return .{ .failed = status != 0 };
}

fn openOutput(io: Io, path: []const u8, append: bool) !Io.File {
    if (append) return sys.openAppend(path);
    return Io.Dir.cwd().createFile(io, path, .{});
}

/// Parse the argument of --output-error.
pub fn parseMode(text: []const u8) ?Mode {
    if (std.mem.eql(u8, text, "warn")) return .warn;
    if (std.mem.eql(u8, text, "warn-nopipe")) return .warn_nopipe;
    if (std.mem.eql(u8, text, "exit")) return .exit;
    if (std.mem.eql(u8, text, "exit-nopipe")) return .exit_nopipe;
    return null;
}

test "parseMode" {
    try std.testing.expectEqual(Mode.warn, parseMode("warn").?);
    try std.testing.expectEqual(Mode.exit_nopipe, parseMode("exit-nopipe").?);
    try std.testing.expect(parseMode("x") == null);
}
