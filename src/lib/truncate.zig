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
const sys = @import("../sys.zig");

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
    open_failed: struct { path: []const u8, errno: std.os.linux.E },
    /// Its current size could not be read.
    size_failed: struct { path: []const u8, err: ?anyerror },
    /// -o: `blocks` (taken from a "-" SIZE when `negative`) times the block
    /// size is not a valid file offset.
    block_overflow: struct { path: []const u8, blocks: u64, negative: bool, block_size: u64 },
    /// The new size of an extended or rounded-up file is not a valid offset.
    extend_overflow: struct { path: []const u8 },
    /// Setting the length failed.
    truncate_failed: struct { path: []const u8, size: u64, err: anyerror },
};
pub const Observer = common.Observer(Event);

/// The largest file offset (off_t). A result beyond it is an error: clamping
/// would turn an impossible request into a different, destructive one.
pub const max_size: u64 = std.math.maxInt(i64);

/// The largest `amount` for `rel`. A reduction is a negative off_t, so its
/// magnitude may be one larger than `max_size`.
pub fn maxAmount(rel: Rel) u64 {
    return if (rel == .reduce) max_size + 1 else max_size;
}

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
    // Non-blocking, so that a FIFO without a reader fails instead of hanging.
    // -c never creates: it opens only files that already exist.
    var flags = sys.O.WRONLY | sys.O.NONBLOCK | sys.O.NOCTTY;
    if (!options.no_create) flags |= sys.O.CREAT;
    var open_errno: std.os.linux.E = .SUCCESS;
    const fd = sys.openFd(name, flags, 0o666, &open_errno) orelse {
        if (options.no_create and open_errno == .NOENT) return true;
        observer.emit(.{ .open_failed = .{ .path = name, .errno = open_errno } });
        return false;
    };
    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
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
        const product = std.math.mul(u64, options.amount, st.block_size) catch null;
        if (product == null or product.? > maxAmount(options.rel)) {
            observer.emit(.{ .block_overflow = .{ .path = name, .blocks = options.amount, .negative = options.rel == .reduce, .block_size = st.block_size } });
            return false;
        }
        amt = product.?;
    }
    const target: u64 = if (options.rel == .none)
        (if (options.ref_size != null and !options.have_size) options.ref_size.? else amt)
    else blk: {
        const base: u64 = if (options.ref_size) |r| r else cur;
        break :blk switch (options.rel) {
            .extend => extended(base, amt) orelse {
                observer.emit(.{ .extend_overflow = .{ .path = name } });
                return false;
            },
            .reduce => base -| amt,
            .at_most => @min(base, amt),
            .at_least => @max(base, amt),
            .round_down => if (amt == 0) base else base - base % amt,
            .round_up => if (amt == 0 or base % amt == 0) base else extended(base, amt - base % amt) orelse {
                observer.emit(.{ .extend_overflow = .{ .path = name } });
                return false;
            },
            .none => unreachable,
        };
    };
    file.setLength(io, target) catch |e| {
        observer.emit(.{ .truncate_failed = .{ .path = name, .size = target, .err = e } });
        return false;
    };
    return true;
}

/// `base + more`, or null when that is not a valid file offset.
fn extended(base: u64, more: u64) ?u64 {
    const sum = std.math.add(u64, base, more) catch return null;
    return if (sum > max_size) null else sum;
}
