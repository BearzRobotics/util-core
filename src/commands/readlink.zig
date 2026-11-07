//! readlink — print the value of a symbolic link or canonical file name.
//! Reference: GNU coreutils manual "readlink invocation" (9.7).

const std = @import("std");
const cli = @import("../cli.zig");
const paths = @import("../paths.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "canonicalize", "canonicalize-existing", "canonicalize-missing", "no-newline", "quiet", "silent", "verbose", "zero", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var mode: paths.Mode = .none;
    var newline = true;
    var verbose = false;
    var zero = false;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(ctx.gpa);
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            files.append(ctx.gpa, a) catch return 1;
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
            if (eq != null) {
                cli.warn(ctx, "option '--{s}' doesn't allow an argument\nTry '{s} --help' for more information.", .{ long_names[k], ctx.name });
                return 1;
            }
            switch (k) {
                0 => mode = .canonical,
                1 => mode = .existing,
                2 => mode = .missing,
                3 => newline = false,
                4, 5 => verbose = false,
                6 => verbose = true,
                7 => zero = true,
                8 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'f' => mode = .canonical,
            'e' => mode = .existing,
            'm' => mode = .missing,
            'n' => newline = false,
            'q', 's' => verbose = false,
            'v' => verbose = true,
            'z' => zero = true,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (files.items.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (files.items.len > 1 and !newline) {
        cli.warn(ctx, "ignoring --no-newline with multiple arguments", .{});
        newline = true;
    }
    var out = cli.Out.init(ctx.io);
    var status: u8 = 0;
    for (files.items) |f| {
        var perr: paths.Error = error.NotFound;
        const result: ?[]u8 = if (mode == .none) blk: {
            var buf: [4096]u8 = undefined;
            const n = Io.Dir.cwd().readLink(ctx.io, f, &buf) catch |e| {
                if (verbose) {
                    out.flush();
                    cli.warn(ctx, "{f}: {s}", .{ cli.quote(f), if (e == error.NotLink) "Invalid argument" else cli.errText(e) });
                }
                break :blk null;
            };
            break :blk ctx.gpa.dupe(u8, buf[0..n]) catch null;
        } else paths.resolve(ctx, f, mode) catch |e| blk: {
            perr = e;
            break :blk null;
        };
        if (result) |r| {
            defer ctx.gpa.free(r);
            out.write(r);
            if (newline or zero) out.writeByte(if (zero) 0 else '\n');
        } else {
            if (verbose and mode != .none) {
                out.flush();
                const msg = switch (perr) {
                    error.NotDir => "Not a directory",
                    error.Loop => "Too many levels of symbolic links",
                    error.NameTooLong => "File name too long",
                    else => "No such file or directory",
                };
                cli.warn(ctx, "{f}: {s}", .{ cli.quote(f), msg });
            }
            status = 1;
        }
    }
    out.flush();
    return if (out.failed) 1 else status;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: readlink [OPTION]... FILE...\nPrint value of a symbolic link or canonical file name\n\n  -f, --canonicalize            canonicalize by following every symlink in\n                                every component of the given name recursively;\n                                all but the last component must exist\n  -e, --canonicalize-existing   canonicalize by following every symlink in\n                                every component of the given name recursively,\n                                all components must exist\n  -m, --canonicalize-missing    canonicalize by following every symlink in\n                                every component of the given name recursively,\n                                without requirements on components existence\n  -n, --no-newline              do not output the trailing delimiter\n  -q, --quiet,\n  -s, --silent                  suppress most error messages (on by default)\n  -v, --verbose                 report error messages\n  -z, --zero                    end each output line with NUL, not newline\n      --help        display this help and exit\n      --version     output version information and exit\n")) 0 else 1;
}
