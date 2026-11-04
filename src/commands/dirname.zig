//! dirname — strip the last path component. Reference: GNU coreutils
//! dirname(1), POSIX dirname. Only '/' is a separator (see basename.zig).

const std = @import("std");
const cli = @import("../cli.zig");

pub fn main(ctx: cli.Context) u8 {
    const args = ctx.args;
    if (cli.soleArg(args, "--help")) {
        return if (cli.writeStdout(ctx.io, "Usage: dirname [OPTION] NAME...\n" ++
            "Output each NAME with its last non-slash component and trailing slashes\n" ++
            "removed; if NAME contains no /'s, output '.'.\n\n" ++
            "  -z, --zero     end each output line with NUL, not newline\n")) 0 else 1;
    }
    if (cli.soleArg(args, "--version")) return if (cli.printVersion(ctx)) 0 else 1;

    var terminator: u8 = '\n';
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "-z") or std.mem.eql(u8, a, "--zero")) {
            terminator = 0;
        } else {
            cli.warn(ctx, "invalid option -- '{s}'\nTry '{s} --help' for more information.", .{ a[1..], ctx.name });
            return 1;
        }
    }
    const names = args[i..];
    if (names.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var out = cli.Out.init(ctx.io);
    for (names) |n| {
        out.write(dirName(n));
        out.writeByte(terminator);
    }
    out.flush();
    return if (out.failed) 1 else 0;
}

/// POSIX dirname. The result borrows from `path` (or is a static literal).
pub fn dirName(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1; // trailing slashes
    if (end == 1 and path[0] == '/') return "/";
    // Drop the last component.
    while (end > 0 and path[end - 1] != '/') end -= 1;
    if (end == 0) return ".";
    // Drop the slashes that separated it from the parent.
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

test "dirName" {
    const t = std.testing;
    try t.expectEqualStrings("/usr/bin", dirName("/usr/bin/echo"));
    try t.expectEqualStrings("/usr", dirName("/usr/bin/"));
    try t.expectEqualStrings(".", dirName("echo"));
    try t.expectEqualStrings(".", dirName(""));
    try t.expectEqualStrings("/", dirName("/"));
    try t.expectEqualStrings("/", dirName("///"));
    try t.expectEqualStrings("/", dirName("/a"));
    try t.expectEqualStrings("a", dirName("a//b"));
    try t.expectEqualStrings("a", dirName("a/b/"));
    try t.expectEqualStrings(".", dirName("a/"));
    try t.expectEqualStrings("..", dirName("../x"));
}
