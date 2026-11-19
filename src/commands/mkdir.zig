// SPDX-License-Identifier: GPL-2.0-or-later
//! mkdir: thin wrapper over `util_core.mkdir` (decision 0004). Parses
//! arguments the way GNU mkdir does and words the diagnostics; -Z/--context
//! are accepted and ignored.

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");
const mode_mod = @import("../mode.zig");
const mkdir = @import("../lib/mkdir.zig");
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

    const umask = sys.umask();
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

    const env: mkdir.Env = .{ .io = ctx.io, .gpa = ctx.gpa, .environ = ctx.environ };
    const ok = mkdir.run(env, .{ .parents = parents, .mode = final_mode, .verbose = verbose, .umask = umask }, dirs.items, .{
        .context = @constCast(&ctx),
        .func = report,
    });
    return if (ok) 0 else 1;
}

/// Word one library event the way GNU mkdir does.
fn report(context: ?*anyopaque, ev: mkdir.Event) void {
    const ctx: *const cli.Context = @ptrCast(@alignCast(context.?));
    switch (ev) {
        .created => |p| cli.say(ctx.*, "created directory '{s}'", .{p}),
        .not_a_directory => |p| cli.warn(ctx.*, "cannot create directory '{s}': Not a directory", .{p}),
        .exists => |p| cli.warn(ctx.*, "cannot create directory '{s}': File exists", .{p}),
        .create_failed => |f| cli.warn(ctx.*, "cannot create directory '{s}': {s}", .{ f.path, cli.errText(f.err) }),
        .chmod_failed => |f| cli.warn(ctx.*, "cannot set permissions of '{s}': {s}", .{ f.path, cli.errText(f.err) }),
    }
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
