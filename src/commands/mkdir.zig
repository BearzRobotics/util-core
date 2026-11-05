//! mkdir — make directories.
//! References: GNU coreutils manual "mkdir invocation" (9.7); POSIX.1-2024
//! mkdir.
//!
//! -m MODE sets the final mode exactly (relative to a=rwx; src/mode.zig). The
//! directory is created with MODE masked to rwx bits and then chmod'ed, so it
//! is never less restrictive than MODE (POSIX requirement). -p creates missing
//! parents with the umask-modified mode plus u+wx (GNU: "=rwx,u+wx") and
//! ignores existing directories. -Z/--context are accepted and ignored: no
//! SELinux/SMACK support.

const std = @import("std");
const cli = @import("../cli.zig");
const mode_mod = @import("../mode.zig");
const Io = std.Io;

const long_names = [_][]const u8{ "mode", "parents", "verbose", "context", "help", "version" };

pub fn main(ctx: cli.Context) u8 {
    var mode_text: ?[]const u8 = null;
    var parents = false;
    var verbose = false;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(ctx.gpa);
    const args = ctx.args;
    var i: usize = 0;
    var only_operands = false;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (only_operands or a.len < 2 or a[0] != '-') {
            dirs.append(ctx.gpa, a) catch return oom(ctx);
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
                0 => {
                    if (eq) |e| {
                        mode_text = a[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            cli.warn(ctx, "option '--mode' requires an argument\nTry '{s} --help' for more information.", .{ctx.name});
                            return 1;
                        }
                        mode_text = args[i];
                    }
                },
                1 => parents = true,
                2 => verbose = true,
                3 => {},
                4 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        var j: usize = 1;
        while (j < a.len) : (j += 1) switch (a[j]) {
            'p' => parents = true,
            'v' => verbose = true,
            'Z' => {},
            'm' => {
                if (j + 1 < a.len) {
                    mode_text = a[j + 1 ..];
                } else {
                    i += 1;
                    if (i >= args.len) {
                        cli.warn(ctx, "option requires an argument -- 'm'\nTry '{s} --help' for more information.", .{ctx.name});
                        return 1;
                    }
                    mode_text = args[i];
                }
                break;
            },
            else => {
                cli.invalidShort(ctx, a[j]);
                return 1;
            },
        };
    }

    const umask = cli.getUmask();
    var final_mode: ?u16 = null;
    if (mode_text) |t| {
        final_mode = mode_mod.apply(t, 0o777, true, umask) orelse {
            cli.warn(ctx, "invalid mode '{s}'", .{t});
            return 1;
        };
    }
    if (dirs.items.len == 0) {
        cli.warn(ctx, "missing operand\nTry '{s} --help' for more information.", .{ctx.name});
        return 1;
    }

    var status: u8 = 0;
    for (dirs.items) |d| {
        if (!makeOne(ctx, d, parents, verbose, final_mode, umask)) status = 1;
    }
    return status;
}

/// Create `path` (and with `parents` its missing ancestors). Returns false
/// after reporting an error.
fn makeOne(ctx: cli.Context, path: []const u8, parents: bool, verbose: bool, mode: ?u16, umask: u16) bool {
    if (parents) {
        // Walk the prefixes of the path, creating the missing ones.
        const trimmed = trimSlashes(path);
        var idx: usize = 0;
        while (idx < trimmed.len) {
            // End of the next component (skip leading slashes first).
            while (idx < trimmed.len and trimmed[idx] == '/') idx += 1;
            while (idx < trimmed.len and trimmed[idx] != '/') idx += 1;
            const prefix = trimmed[0..idx];
            const is_last = idx >= trimmed.len;
            if (is_last) break;
            const st = Io.Dir.cwd().statFile(ctx.io, prefix, .{});
            if (st) |s| {
                if (s.kind == .directory) continue;
                cli.warn(ctx, "cannot create directory '{s}': Not a directory", .{prefix});
                return false;
            } else |_| {}
            // Parent mode: umask-modified rwx plus u+wx.
            const pmode: u16 = (0o777 & ~umask) | 0o300;
            Io.Dir.cwd().createDir(ctx.io, prefix, .fromMode(pmode)) catch |e| {
                if (e == error.PathAlreadyExists) continue;
                cli.warn(ctx, "cannot create directory '{s}': {s}", .{ prefix, cli.errText(e) });
                return false;
            };
            if (pmode != (pmode & ~umask)) chmod(ctx, prefix, pmode);
            if (verbose) cli.say(ctx, "created directory '{s}'", .{prefix});
        }
        // Final component: an existing directory is not an error with -p.
        if (Io.Dir.cwd().statFile(ctx.io, trimmed, .{})) |s| {
            if (s.kind == .directory) return true;
            cli.warn(ctx, "cannot create directory '{s}': File exists", .{path});
            return false;
        } else |_| {}
    }
    const create_mode: u16 = if (mode) |m| m & 0o777 else 0o777;
    Io.Dir.cwd().createDir(ctx.io, path, .fromMode(create_mode)) catch |e| {
        cli.warn(ctx, "cannot create directory '{s}': {s}", .{ path, cli.errText(e) });
        return false;
    };
    if (verbose) cli.say(ctx, "created directory '{s}'", .{path});
    if (mode) |m| {
        // The kernel applied the umask at creation; set the exact mode now.
        Io.Dir.cwd().setFilePermissions(ctx.io, path, .fromMode(m), .{}) catch |e| {
            cli.warn(ctx, "cannot set permissions of '{s}': {s}", .{ path, cli.errText(e) });
            return false;
        };
    }
    return true;
}

fn chmod(ctx: cli.Context, path: []const u8, mode: u16) void {
    Io.Dir.cwd().setFilePermissions(ctx.io, path, .fromMode(mode), .{}) catch {};
}

fn trimSlashes(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and p[end - 1] == '/') end -= 1;
    return p[0..end];
}

fn oom(ctx: cli.Context) u8 {
    cli.warn(ctx, "out of memory", .{});
    return 1;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: mkdir [OPTION]... DIRECTORY...\n" ++
        "Create the DIRECTORY(ies), if they do not already exist.\n\n" ++
        "  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask\n" ++
        "  -p, --parents     no error if existing, make parent directories as needed\n" ++
        "  -v, --verbose     print a message for each created directory\n" ++
        "  -Z                set SELinux security context (ignored)\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}

test "trimSlashes" {
    try std.testing.expectEqualStrings("a/b", trimSlashes("a/b//"));
    try std.testing.expectEqualStrings("/", trimSlashes("///"));
    try std.testing.expectEqualStrings("a", trimSlashes("a"));
}
