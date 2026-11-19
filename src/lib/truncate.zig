// SPDX-License-Identifier: GPL-2.0-or-later
//! truncate library: shrink or extend the size of files.
//! Reference: GNU coreutils manual "truncate invocation" (9.7).
//!
//! The caller parses the SIZE operand (src/count_arg.zig) and, for
//! --reference, reads the reference file's size; this module applies the
//! resulting `Options` to each file.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");

pub const Env = common.Env;

pub const Rel = enum { none, extend, reduce, at_most, at_least, round_down, round_up };

pub const Options = struct {
    /// -c: do not create files.
    no_create: bool = false,
    /// -o: `amount` counts I/O blocks of the file instead of bytes.
    io_blocks: bool = false,
    /// The relation of the new size to the old (the SIZE prefix character).
    rel: Rel = .none,
    /// SIZE (or, with only a reference, the reference file's size).
    amount: u64 = 0,
    /// Size of the --reference file, when one was given.
    ref_size: ?u64 = null,
    /// True when a SIZE operand was given in addition to the reference.
    have_size: bool = true,
};

pub const Event = union(enum) {
    /// Opening (or creating) the file failed.
    open_failed: struct { path: []const u8, err: anyerror },
    /// Its current size could not be read.
    size_failed: struct { path: []const u8, err: ?anyerror },
    /// Setting the length failed.
    truncate_failed: struct { path: []const u8, size: u64, err: anyerror },
};
pub const Observer = common.Observer(Event);

/// Truncate each file; returns false when any failed.
pub fn run(env: Env, options: Options, files: []const []const u8, observer: Observer) bool {
    var ok = true;
    for (files) |name| {
        if (!truncateOne(env, name, options, observer)) ok = false;
    }
    return ok;
}

pub fn truncateOne(env: Env, name: []const u8, options: Options, observer: Observer) bool {
    const io = env.io;
    const cwd = Io.Dir.cwd();
    // -c never creates: it opens only files that already exist.
    const file: Io.File = if (options.no_create)
        (cwd.openFile(io, name, .{ .mode = .write_only }) catch |e| {
            if (e != error.FileNotFound) {
                observer.emit(.{ .open_failed = .{ .path = name, .err = e } });
                return false;
            }
            return true;
        })
    else
        (cwd.createFile(io, name, .{ .truncate = false }) catch |e| {
            observer.emit(.{ .open_failed = .{ .path = name, .err = e } });
            return false;
        });
    defer file.close(io);
    const cur = file.length(io) catch |e| {
        observer.emit(.{ .size_failed = .{ .path = name, .err = e } });
        return false;
    };
    var amt: u64 = options.amount;
    if (options.io_blocks) {
        const st = file.stat(io) catch {
            observer.emit(.{ .size_failed = .{ .path = name, .err = null } });
            return false;
        };
        amt = options.amount *| st.block_size;
    }
    const target: u64 = if (options.rel == .none)
        (if (options.ref_size != null and !options.have_size) options.ref_size.? else amt)
    else blk: {
        const base: u64 = if (options.ref_size) |r| r else cur;
        break :blk switch (options.rel) {
            .extend => base +| amt,
            .reduce => base -| amt,
            .at_most => @min(base, amt),
            .at_least => @max(base, amt),
            .round_down => if (amt == 0) base else base - base % amt,
            .round_up => if (amt == 0) base else (base +| (amt - 1)) / amt * amt,
            .none => unreachable,
        };
    };
    file.setLength(io, target) catch |e| {
        observer.emit(.{ .truncate_failed = .{ .path = name, .size = target, .err = e } });
        return false;
    };
    return true;
}
