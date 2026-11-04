//! basename — strip directory and suffix. Reference: GNU coreutils basename(1),
//! POSIX basename.
//!
//! Only '/' is treated as a separator (also on Windows; backslash handling is
//! not yet specified for this command).

const std = @import("std");
const cli = @import("../cli.zig");

pub fn main(ctx: cli.Context) u8 {
    const args = ctx.args;
    if (cli.soleArg(args, "--help")) {
        return if (cli.writeStdout(ctx.io, "Usage: basename NAME [SUFFIX]\n" ++
            "  or:  basename OPTION... NAME...\n" ++
            "Print NAME with any leading directory components removed.\n\n" ++
            "  -a, --multiple       support multiple arguments\n" ++
            "  -s, --suffix=SUFFIX  remove a trailing SUFFIX; implies -a\n" ++
            "  -z, --zero           end each output line with NUL, not newline\n")) 0 else 1;
    }
    if (cli.soleArg(args, "--version")) return if (cli.printVersion(ctx)) 0 else 1;

    var multiple = false;
    var suffix: ?[]const u8 = null;
    var terminator: u8 = '\n';

    // Option parsing (GNU getopt_long style, with permutation of operands).
    var operands: std.ArrayList([]const u8) = .empty;
    defer operands.deinit(ctx.gpa);
    var only_operands = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            operands.append(ctx.gpa, a) catch return oom(ctx);
        } else if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
        } else if (std.mem.eql(u8, a, "--multiple")) {
            multiple = true;
        } else if (std.mem.eql(u8, a, "--zero")) {
            terminator = 0;
        } else if (std.mem.eql(u8, a, "--suffix")) {
            i += 1;
            if (i == args.len) return missingArg(ctx, "--suffix");
            suffix = args[i];
            multiple = true;
        } else if (std.mem.startsWith(u8, a, "--suffix=")) {
            suffix = a["--suffix=".len..];
            multiple = true;
        } else if (a[1] != '-') {
            // Cluster of short options.
            var j: usize = 1;
            while (j < a.len) : (j += 1) switch (a[j]) {
                'a' => multiple = true,
                'z' => terminator = 0,
                's' => {
                    multiple = true;
                    if (j + 1 < a.len) {
                        suffix = a[j + 1 ..];
                    } else {
                        i += 1;
                        if (i == args.len) return missingArg(ctx, "-s");
                        suffix = args[i];
                    }
                    break;
                },
                else => return badOption(ctx, a[j .. j + 1]),
            };
        } else return badOption(ctx, a);
    }

    var names = operands.items;
    if (names.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }
    if (!multiple) {
        if (names.len > 2) {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ names[2], ctx.name });
            return 1;
        }
        if (names.len == 2) {
            suffix = names[1];
            names = names[0..1];
        }
    }

    var out = cli.Out.init(ctx.io);
    for (names) |n| {
        out.write(baseName(n, suffix));
        out.writeByte(terminator);
    }
    out.flush();
    return if (out.failed) 1 else 0;
}

/// POSIX/GNU basename of `path` with an optional suffix removed. The result
/// borrows from `path`. A suffix equal to the whole name is not removed.
pub fn baseName(path: []const u8, suffix: ?[]const u8) []const u8 {
    if (path.len == 0) return path;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    if (end == 1 and path[0] == '/') return path[0..1]; // all slashes -> "/"
    const start = if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |s| s + 1 else 0;
    var name = path[start..end];
    if (suffix) |suf| {
        if (suf.len > 0 and suf.len < name.len and std.mem.endsWith(u8, name, suf)) {
            name = name[0 .. name.len - suf.len];
        }
    }
    return name;
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn missingArg(ctx: cli.Context, opt: []const u8) u8 {
    cli.warn(ctx, "option '{s}' requires an argument\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}

fn badOption(ctx: cli.Context, opt: []const u8) u8 {
    cli.warn(ctx, "invalid option -- '{s}'\nTry '{s} --help' for more information.", .{ opt, ctx.name });
    return 1;
}

test "baseName" {
    const t = std.testing;
    try t.expectEqualStrings("echo", baseName("/usr/bin/echo", null));
    try t.expectEqualStrings("bin", baseName("/usr/bin/", null));
    try t.expectEqualStrings("/", baseName("///", null));
    try t.expectEqualStrings("", baseName("", null));
    try t.expectEqualStrings(".", baseName(".", null));
    try t.expectEqualStrings("script", baseName("script.sh", ".sh"));
    try t.expectEqualStrings(".sh", baseName(".sh", ".sh")); // whole name kept
    try t.expectEqualStrings("script.sh", baseName("script.sh", ".py"));
    try t.expectEqualStrings("archive", baseName("a/archive.tar.gz", ".tar.gz"));
}
