// SPDX-License-Identifier: GPL-2.0-or-later
//! nl library (decision 0004): number lines of inputs.
//! References: GNU coreutils manual "nl invocation" (9.7); POSIX.1-2024 nl.
//!
//! Logical pages (header/body/footer) are separated by lines made of the
//! section delimiter repeated three, two or one times (`\:\:\:`, `\:\:`,
//! `\:`); such a line is replaced by an empty line and, unless `renumber` is
//! off, restarts the numbering. All inputs form one document. A line that is
//! not numbered is written as spaces of the width of the number plus the
//! separator. The `pBRE` numbering style (needs a POSIX BRE engine) is not
//! implemented.

const std = @import("std");
const Io = std.Io;
const common = @import("common.zig");
const lines = @import("../lines.zig");
const stickyout = @import("stickyout.zig");

pub const Env = common.Env;
pub const Input = common.Input;

pub const Style = enum { all, text, none };
pub const Format = enum { ln, rn, rz };

pub const Options = struct {
    body: Style = .text,
    header: Style = .none,
    footer: Style = .none,
    /// Section delimiter; a single character is followed by ':' (GNU).
    delimiter: []const u8 = "\\:",
    increment: i64 = 1,
    join_blank: u64 = 1,
    format: Format = .rn,
    renumber: bool = true,
    separator: []const u8 = "\t",
    start: i64 = 1,
    width: usize = 6,
};

/// A problem with one input; the run continues with the next one.
pub const Event = struct {
    name: []const u8,
    err: anyerror,
};

pub const Result = struct { failed: bool = false };

pub const Observer = common.Observer(Event);

pub fn run(env: Env, options: Options, inputs: []const Input, writer: *Io.Writer, observer: Observer) error{ OutOfMemory, WriteFailed }!Result {
    var cfg = options;
    var delim_pair: [2]u8 = undefined;
    if (cfg.delimiter.len == 1) {
        delim_pair = .{ cfg.delimiter[0], ':' };
        cfg.delimiter = &delim_pair;
    }

    // Section delimiter lines: delimiter x3 = header, x2 = body, x1 = footer.
    var d3: std.ArrayList(u8) = .empty;
    defer d3.deinit(env.gpa);
    var d2: std.ArrayList(u8) = .empty;
    defer d2.deinit(env.gpa);
    if (cfg.delimiter.len > 0) {
        for (0..3) |_| try d3.appendSlice(env.gpa, cfg.delimiter);
        for (0..2) |_| try d2.appendSlice(env.gpa, cfg.delimiter);
    }

    var out = stickyout.Out.init(writer);
    var result: Result = .{};

    var section: enum { header, body, footer } = .body;
    var number: i64 = cfg.start;
    var blank_run: u64 = 0;
    for (inputs) |in| {
        const name = in.name orelse "-";
        const opened = in.open(env.io) catch |e| {
            observer.emit(.{ .name = name, .err = e });
            result.failed = true;
            continue;
        };
        defer opened.close(env.io);
        var reader = lines.LineReader.init(env.gpa, env.io, opened.file, '\n');
        defer reader.deinit();
        while (reader.next() catch |e| {
            out.flush();
            observer.emit(.{ .name = name, .err = e });
            result.failed = true;
            break;
        }) |line| {
            if (cfg.delimiter.len > 0 and (std.mem.eql(u8, line.text, d3.items) or std.mem.eql(u8, line.text, d2.items) or std.mem.eql(u8, line.text, cfg.delimiter))) {
                section = if (line.text.len == d3.items.len) .header else if (line.text.len == d2.items.len) .body else .footer;
                if (cfg.renumber) number = cfg.start;
                // The count of blank lines runs on across sections, as in GNU.
                out.writeByte('\n');
                continue;
            }
            const style = switch (section) {
                .header => cfg.header,
                .body => cfg.body,
                .footer => cfg.footer,
            };
            var numbered = false;
            switch (style) {
                .none => {},
                .text => numbered = line.text.len > 0,
                .all => {
                    if (line.text.len == 0) {
                        blank_run += 1;
                        if (blank_run >= cfg.join_blank) {
                            numbered = true;
                            blank_run = 0;
                        }
                    } else {
                        blank_run = 0;
                        numbered = true;
                    }
                },
            }
            if (numbered) {
                writeNumber(&out, number, cfg);
                number +%= cfg.increment;
                out.write(cfg.separator);
            } else {
                var pad: usize = cfg.width + cfg.separator.len;
                while (pad > 0) : (pad -= 1) out.writeByte(' ');
            }
            out.write(line.text);
            out.writeByte('\n');
            if (out.failed) break;
        }
        if (out.failed) break;
    }
    try out.finish();
    return result;
}

fn writeNumber(out: *stickyout.Out, n: i64, cfg: Options) void {
    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{@abs(n)}) catch unreachable;
    const neg = n < 0;
    const len = digits.len + @intFromBool(neg);
    switch (cfg.format) {
        .ln => {
            if (neg) out.writeByte('-');
            out.write(digits);
            var pad = if (cfg.width > len) cfg.width - len else 0;
            while (pad > 0) : (pad -= 1) out.writeByte(' ');
        },
        .rn => {
            var pad = if (cfg.width > len) cfg.width - len else 0;
            while (pad > 0) : (pad -= 1) out.writeByte(' ');
            if (neg) out.writeByte('-');
            out.write(digits);
        },
        .rz => {
            if (neg) out.writeByte('-');
            var pad = if (cfg.width > len) cfg.width - len else 0;
            while (pad > 0) : (pad -= 1) out.writeByte('0');
            out.write(digits);
        },
    }
}
