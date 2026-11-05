//! nl — number lines of files.
//! References: GNU coreutils manual "nl invocation" (9.7); POSIX.1-2024 nl
//! (an XSI utility).
//!
//! Logical pages (header/body/footer) are separated by lines made of the
//! section delimiter repeated three, two or one times (`\:\:\:`, `\:\:`, `\:`);
//! such a line is replaced by an empty line and, unless -p, restarts the
//! numbering. All input files form one document. A line that is not numbered
//! is written as spaces of the width of the number plus the separator.
//! Not implemented: the `pBRE` numbering style (needs the project's POSIX BRE
//! engine, which does not exist yet) — it is rejected with an error.

const std = @import("std");
const cli = @import("../cli.zig");
const lines = @import("../lines.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "body-numbering", "section-delimiter", "footer-numbering", "header-numbering", "line-increment", "join-blank-lines", "number-format", "no-renumber", "number-separator", "starting-line-number", "number-width", "help", "version" };

const Style = enum { all, text, none };
const Format = enum { ln, rn, rz };

const Config = struct {
    body: Style = .text,
    header: Style = .none,
    footer: Style = .none,
    delim: []const u8 = "\\:",
    increment: i64 = 1,
    join_blank: u64 = 1,
    format: Format = .rn,
    renumber: bool = true,
    sep: []const u8 = "\t",
    start: i64 = 1,
    width: usize = 6,
};

pub fn main(ctx: cli.Context) u8 {
    var cfg: Config = .{};
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return oom(ctx);
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, a, '=');
            const m = cli.matchLong(a[2 .. eq orelse a.len], &long_names);
            const k = switch (m) {
                .found => |k| k,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            };
            switch (k) {
                7 => cfg.renumber = false,
                11 => return help(ctx),
                12 => return if (cli.printVersion(ctx)) 0 else 1,
                else => {
                    var val: []const u8 = undefined;
                    if (eq) |e| {
                        val = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--{s}' requires an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                            return 1;
                        }
                        val = args[i];
                    }
                    const letter: u8 = switch (k) {
                        0 => 'b',
                        1 => 'd',
                        2 => 'f',
                        3 => 'h',
                        4 => 'i',
                        5 => 'l',
                        6 => 'n',
                        8 => 's',
                        9 => 'v',
                        else => 'w',
                    };
                    if (!setOption(ctx, &cfg, letter, val)) return 1;
                },
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'p' => cfg.renumber = false,
            'b', 'd', 'f', 'h', 'i', 'l', 'n', 's', 'v', 'w' => {
                var val: []const u8 = a[j + 1 ..];
                if (val.len == 0) {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- '{c}'\nTry '{s} --help' for more information.", .{ a[j], ctx.name });
                        return 1;
                    }
                    val = args[i];
                }
                if (!setOption(ctx, &cfg, a[j], val)) return 1;
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    var delim_pair: [2]u8 = undefined;
    if (cfg.delim.len == 1) {
        delim_pair = .{ cfg.delim[0], ':' };
        cfg.delim = &delim_pair;
    }

    // Section delimiter lines: delim x3 = header, x2 = body, x1 = footer.
    var d3: std.ArrayList(u8) = .empty;
    defer d3.deinit(ctx.gpa);
    var d2: std.ArrayList(u8) = .empty;
    defer d2.deinit(ctx.gpa);
    if (cfg.delim.len > 0) {
        for (0..3) |_| d3.appendSlice(ctx.gpa, cfg.delim) catch return oom(ctx);
        for (0..2) |_| d2.appendSlice(ctx.gpa, cfg.delim) catch return oom(ctx);
    }

    const stdin_only = [_][]const u8{"-"};
    const inputs: []const []const u8 = if (files.items.len == 0) &stdin_only else files.items;
    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;

    var section: enum { header, body, footer } = .body;
    var number: i64 = cfg.start;
    var blank_run: u64 = 0;
    for (inputs) |path| {
        const file = cli.openInput(ctx.io, path) catch |e| {
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            status = 1;
            continue;
        };
        defer cli.closeInput(ctx.io, file);
        var reader = lines.LineReader.init(ctx.gpa, ctx.io, file, '\n');
        defer reader.deinit();
        while (reader.next() catch |e| {
            out.flush();
            cli.warn(ctx, "{s}: {s}", .{ path, cli.errText(e) });
            status = 1;
            break;
        }) |line| {
            if (cfg.delim.len > 0 and (std.mem.eql(u8, line.text, d3.items) or std.mem.eql(u8, line.text, d2.items) or std.mem.eql(u8, line.text, cfg.delim))) {
                section = if (line.text.len == d3.items.len) .header else if (line.text.len == d2.items.len) .body else .footer;
                if (cfg.renumber) number = cfg.start;
                blank_run = 0;
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
                out.write(cfg.sep);
            } else {
                var pad: usize = cfg.width + cfg.sep.len;
                while (pad > 0) : (pad -= 1) out.writeByte(' ');
            }
            out.write(line.text);
            out.writeByte('\n');
            if (out.failed) break;
        }
        if (out.failed) break;
    }
    out.flush();
    if (out.failed) {
        cli.warn(ctx, "write error", .{});
        return 1;
    }
    return status;
}

fn writeNumber(out: *cli.Out, n: i64, cfg: Config) void {
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

fn parseStyle(ctx: cli.Context, val: []const u8, what: []const u8) ?Style {
    if (val.len > 0) switch (val[0]) {
        'a' => return .all,
        't' => return .text,
        'n' => return .none,
        'p' => {
            cli.warn(ctx, "numbering style 'p' (regular expression) is not supported yet", .{});
            return null;
        },
        else => {},
    };
    cli.warn(ctx, "invalid {s} numbering style: '{s}'\nTry '{s} --help' for more information.", .{ what, val, ctx.name });
    return null;
}

fn parseInt(ctx: cli.Context, val: []const u8, what: []const u8) ?i64 {
    return std.fmt.parseInt(i64, val, 10) catch {
        cli.warn(ctx, "invalid {s}: '{s}'", .{ what, val });
        return null;
    };
}

fn setOption(ctx: cli.Context, cfg: *Config, letter: u8, val: []const u8) bool {
    switch (letter) {
        'b' => cfg.body = parseStyle(ctx, val, "body") orelse return false,
        'h' => cfg.header = parseStyle(ctx, val, "header") orelse return false,
        'f' => cfg.footer = parseStyle(ctx, val, "footer") orelse return false,
        'd' => {
            // A single character is followed by the default ':' (resolved in main).
            cfg.delim = val;
        },
        'i' => cfg.increment = parseInt(ctx, val, "line number increment") orelse return false,
        'v' => cfg.start = parseInt(ctx, val, "starting line number") orelse return false,
        'l' => {
            const v = std.fmt.parseInt(u64, val, 10) catch {
                cli.warn(ctx, "invalid line number of blank lines: '{s}'{s}", .{ val, rangeSuffix(val) });
                return false;
            };
            cfg.join_blank = v;
        },
        'w' => {
            const v = std.fmt.parseInt(usize, val, 10) catch {
                cli.warn(ctx, "invalid line number field width: '{s}'{s}", .{ val, rangeSuffix(val) });
                return false;
            };
            if (v == 0) {
                cli.warn(ctx, "invalid line number field width: '{s}': Numerical result out of range", .{val});
                return false;
            }
            cfg.width = v;
        },
        'n' => {
            if (std.mem.eql(u8, val, "ln")) cfg.format = .ln else if (std.mem.eql(u8, val, "rn")) cfg.format = .rn else if (std.mem.eql(u8, val, "rz")) cfg.format = .rz else {
                cli.warn(ctx, "invalid line numbering format: '{s}'\nTry '{s} --help' for more information.", .{ val, ctx.name });
                return false;
            }
        },
        's' => cfg.sep = val,
        else => unreachable,
    }
    return true;
}

/// GNU says "Numerical result out of range" for numbers that are well formed
/// but negative or too large for an unsigned option.
fn rangeSuffix(val: []const u8) []const u8 {
    _ = std.fmt.parseInt(i128, val, 10) catch return "";
    return ": Numerical result out of range";
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: nl [OPTION]... [FILE]...\n" ++
        "Write each FILE to standard output, with line numbers added.\n\n" ++
        "  -b, --body-numbering=STYLE      use STYLE for numbering body lines\n" ++
        "  -d, --section-delimiter=CC      use CC for logical page delimiters\n" ++
        "  -f, --footer-numbering=STYLE    use STYLE for numbering footer lines\n" ++
        "  -h, --header-numbering=STYLE    use STYLE for numbering header lines\n" ++
        "  -i, --line-increment=NUMBER     line number increment at each line\n" ++
        "  -l, --join-blank-lines=NUMBER   group of NUMBER empty lines counted as one\n" ++
        "  -n, --number-format=FORMAT      insert line numbers according to FORMAT\n" ++
        "  -p, --no-renumber               do not reset line numbers for each section\n" ++
        "  -s, --number-separator=STRING   add STRING after (possible) line number\n" ++
        "  -v, --starting-line-number=NUMBER  first line number for each section\n" ++
        "  -w, --number-width=NUMBER       use NUMBER columns for line numbers\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n\n" ++
        "STYLE is one of: a (all lines), t (non-empty lines), n (no lines).\n" ++
        "FORMAT is one of: ln (left justified), rn (right justified), rz (zero filled).\n")) 0 else 1;
}
