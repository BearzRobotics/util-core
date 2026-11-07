//! date — print or set the system date and time.
//! Reference: GNU coreutils manual "date invocation" (9.7); POSIX.1-2024 date
//! (output formats, -u, MMDDhhmm[[CC]YY] setting).
//!
//! -d/-f use src/datetime.zig (GNU's parse_datetime), output uses
//! src/strftime.zig, zones come from src/tz.zig (TZ, /etc/localtime, TZif).

const std = @import("std");
const cli = @import("../cli.zig");
const getopt = @import("../getopt.zig");
const sys = @import("../sys.zig");
const tzmod = @import("../tz.zig");
const strftime = @import("../strftime.zig");
const datetime = @import("../datetime.zig");
const Io = std.Io;

const help_text = @embedFile("../help/date.txt");

const rfc_email_format = "%a, %d %b %Y %H:%M:%S %z";

fn argmatch(ctx: cli.Context, opt: []const u8, value: []const u8, names: []const []const u8) ?usize {
    var found: ?usize = null;
    var amb = false;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, value)) return i;
        if (std.mem.startsWith(u8, n, value)) {
            if (found != null) amb = true;
            found = i;
        }
    }
    if (found != null and !amb) return found;
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (names) |nm| {
        const piece = std.fmt.bufPrint(buf[len..], "\n  - {f}", .{cli.quoteC(nm)}) catch break;
        len += piece.len;
    }
    cli.warn(ctx, "{s} argument {f} for {f}\nValid arguments are:{s}\nTry '{s} --help' for more information.", .{
        if (amb) "ambiguous" else "invalid", cli.quoteC(value), cli.quoteC(opt), buf[0..len], ctx.name,
    });
    return null;
}

fn showDate(ctx: cli.Context, out: *cli.Out, format: []const u8, when: datetime.Timespec, zone: *const tzmod.Zone) bool {
    const tm = tzmod.localtime(zone, when.sec);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.gpa);
    strftime.format(&buf, ctx.gpa, format, &tm, when.sec, when.nsec) catch return false;
    out.write(buf.items);
    out.writeByte('\n');
    return true;
}

pub fn main(ctx: cli.Context) u8 {
    const gpa = ctx.gpa;
    var datestr: ?[]const u8 = null;
    var set_datestr: ?[]const u8 = null;
    var set_date = false;
    var format: ?[]const u8 = null;
    var get_resolution = false;
    var batch_file: ?[]const u8 = null;
    var reference: ?[]const u8 = null;
    var utc = false;
    var out = cli.Out.init(ctx.io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var p = getopt.Parser.init(ctx, "d:f:I::r:Rs:u", &.{
        .{ .name = "date", .arg = .required, .id = 'd' },
        .{ .name = "debug", .id = 1100 },
        .{ .name = "file", .arg = .required, .id = 'f' },
        .{ .name = "iso-8601", .arg = .optional, .id = 'I' },
        .{ .name = "reference", .arg = .required, .id = 'r' },
        .{ .name = "resolution", .id = 1101 },
        .{ .name = "rfc-email", .id = 'R' },
        .{ .name = "rfc-822", .id = 'R' },
        .{ .name = "rfc-2822", .id = 'R' },
        .{ .name = "rfc-3339", .arg = .required, .id = 1102 },
        .{ .name = "set", .arg = .required, .id = 's' },
        .{ .name = "uct", .id = 'u' },
        .{ .name = "utc", .id = 'u' },
        .{ .name = "universal", .id = 'u' },
    });
    defer p.deinit();
    while (true) {
        const item = p.next();
        const o = switch (item) {
            .done => break,
            .bad => return 1,
            .opt => |o| o,
        };
        var new_format: ?[]const u8 = null;
        switch (o.id) {
            'd' => datestr = o.arg,
            1100 => {},
            'f' => batch_file = o.arg,
            1101 => get_resolution = true,
            1102 => {
                const names = [_][]const u8{ "date", "seconds", "ns" };
                const k = argmatch(ctx, "--rfc-3339", o.arg.?, &names) orelse return 1;
                new_format = switch (k) {
                    0 => "%Y-%m-%d",
                    1 => "%Y-%m-%d %H:%M:%S%:z",
                    else => "%Y-%m-%d %H:%M:%S.%N%:z",
                };
            },
            'I' => {
                const names = [_][]const u8{ "hours", "minutes", "date", "seconds", "ns" };
                const k: usize = if (o.arg) |a| (argmatch(ctx, "--iso-8601", a, &names) orelse return 1) else 2;
                new_format = switch (k) {
                    0 => "%Y-%m-%dT%H%:z",
                    1 => "%Y-%m-%dT%H:%M%:z",
                    2 => "%Y-%m-%d",
                    3 => "%Y-%m-%dT%H:%M:%S%:z",
                    else => "%Y-%m-%dT%H:%M:%S,%N%:z",
                };
            },
            'r' => reference = o.arg,
            'R' => new_format = rfc_email_format,
            's' => {
                set_datestr = o.arg;
                set_date = true;
            },
            'u' => utc = true,
            getopt.help_id => return if (cli.writeStdout(ctx.io, help_text ++ "\n")) 0 else 1,
            getopt.version_id => return if (cli.printVersion(ctx)) 0 else 1,
            else => unreachable,
        }
        if (new_format) |nf| {
            if (format != null) {
                cli.warn(ctx, "multiple output formats specified", .{});
                return 1;
            }
            format = nf;
        }
    }

    const option_specified_date: u32 = @as(u32, @intFromBool(datestr != null)) + @intFromBool(batch_file != null) + @intFromBool(reference != null) + @intFromBool(get_resolution);
    if (option_specified_date > 1) {
        getopt.usageError(ctx, "the options to specify dates for printing are mutually exclusive", .{});
        return 1;
    }
    if (set_date and option_specified_date != 0) {
        getopt.usageError(ctx, "the options to print and set the time may not be used together", .{});
        return 1;
    }
    const operands = p.operands.items;
    var operand_date: ?[]const u8 = null;
    if (operands.len > 0) {
        if (operands.len > 1) {
            getopt.usageError(ctx, "extra operand {f}", .{cli.quoteC(operands[1])});
            return 1;
        }
        if (operands[0].len > 0 and operands[0][0] == '+') {
            if (format != null) {
                cli.warn(ctx, "multiple output formats specified", .{});
                return 1;
            }
            format = operands[0][1..];
        } else if (set_date or option_specified_date != 0) {
            getopt.usageError(ctx, "the argument {f} lacks a leading '+';\nwhen using an option to specify date(s), any non-option\nargument must be a format string beginning with '+'", .{cli.quoteC(operands[0])});
            return 1;
        } else operand_date = operands[0];
    }
    if (format == null) format = if (get_resolution) "%s.%N" else "%a %b %e %H:%M:%S %Z %Y";

    // %-N becomes %9N at the clock's 1 ns resolution.
    var fmt_buf: std.ArrayList(u8) = .empty;
    {
        var i: usize = 0;
        const f = format.?;
        while (i < f.len) {
            if (f[i] == '%' and i + 2 < f.len + 0 and f[i + 1] == '-' and f[i + 2] == 'N') {
                fmt_buf.appendSlice(arena, "%9N") catch return 1;
                i += 3;
            } else if (f[i] == '%' and i + 1 < f.len) {
                fmt_buf.appendSlice(arena, f[i .. i + 2]) catch return 1;
                i += 2;
            } else {
                fmt_buf.append(arena, f[i]) catch return 1;
                i += 1;
            }
        }
    }
    const fmt = fmt_buf.items;

    const tz_env: ?[]const u8 = if (utc) "UTC0" else if (ctx.environ) |m| m.get("TZ") else null;
    var zone = tzmod.load(gpa, ctx.io, tz_env);
    defer zone.deinit();

    const ts_now = Io.Timestamp.now(ctx.io, .real);
    const now: datetime.Timespec = .{ .sec = @intCast(@divFloor(ts_now.nanoseconds, std.time.ns_per_s)), .nsec = @intCast(@mod(ts_now.nanoseconds, std.time.ns_per_s)) };

    var ok = true;
    if (batch_file) |bf| {
        const file = cli.openInput(ctx.io, bf) catch |e| {
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(bf), cli.errText(e) });
            return 1;
        };
        defer cli.closeInput(ctx.io, file);
        var data: std.ArrayList(u8) = .empty;
        var chunk: [65536]u8 = undefined;
        while (true) {
            const n = cli.readChunk(ctx.io, file, &chunk) catch {
                cli.warn(ctx, "{f}: read error", .{cli.quote(bf)});
                return 1;
            };
            if (n == 0) break;
            data.appendSlice(arena, chunk[0..n]) catch return 1;
        }
        var pos: usize = 0;
        while (pos < data.items.len) {
            const e = std.mem.indexOfScalarPos(u8, data.items, pos, '\n');
            const stop = e orelse data.items.len;
            const line = data.items[pos..stop];
            pos = if (e) |x| x + 1 else data.items.len;
            if (datetime.parse(gpa, ctx.io, line, now, &zone)) |when| {
                if (!showDate(ctx, &out, fmt, when, &zone)) ok = false;
            } else {
                out.flush();
                cli.warn(ctx, "invalid date {f}", .{cli.quoteC(line)});
                ok = false;
            }
        }
        out.flush();
        return if (ok) 0 else 1;
    }

    var when: datetime.Timespec = now;
    var valid_date = true;
    var shown_str: []const u8 = "";
    if (option_specified_date == 0 and !set_date) {
        if (operand_date) |od| {
            set_date = true;
            shown_str = od;
            const cur = tzmod.localtime(&zone, now.sec);
            if (datetime.posixTime(&zone, od, false, cur.year)) |t| when = .{ .sec = t, .nsec = 0 } else valid_date = false;
        }
    } else if (reference) |r| {
        var err: std.os.linux.E = .SUCCESS;
        const st = sys.fileStat(r, true, &err) orelse {
            cli.warn(ctx, "{f}: {s}", .{ cli.quote(r), sys.errnoText(err) });
            return 1;
        };
        when = .{ .sec = st.mtime_s, .nsec = st.mtime_ns };
    } else if (get_resolution) {
        when = .{ .sec = 0, .nsec = 1 };
    } else {
        const ds = set_datestr orelse datestr.?;
        shown_str = ds;
        if (datetime.parse(gpa, ctx.io, ds, now, &zone)) |t| when = t else valid_date = false;
    }
    if (!valid_date) {
        cli.warn(ctx, "invalid date {f}", .{cli.quoteC(shown_str)});
        return 1;
    }
    if (set_date) {
        if (sys.setRealtime(when.sec, when.nsec)) |e| {
            cli.warn(ctx, "cannot set date: {s}", .{sys.errnoText(e)});
            ok = false;
        }
    }
    if (!showDate(ctx, &out, fmt, when, &zone)) ok = false;
    out.flush();
    if (out.failed) return 1;
    return if (ok) 0 else 1;
}
