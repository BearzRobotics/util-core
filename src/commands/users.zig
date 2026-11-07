//! users — print the login names of the users currently logged in.
//! Reference: GNU coreutils manual "users invocation" (9.7). Reads Linux
//! utmp records (384 bytes; type 7 is a user process).

const std = @import("std");
const cli = @import("../cli.zig");
const Io = std.Io;

const record_size = 384;
const user_process = 7;

pub fn main(ctx: cli.Context) u8 {
    var file_arg: ?[]const u8 = null;
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            if (file_arg != null) {
                cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
                return 1;
            }
            file_arg = a;
            continue;
        }
        if (std.mem.eql(u8, a, "--")) {
            only_operands = true;
            continue;
        }
        if (a[1] == '-') {
            const m = cli.matchLong(a[2..], &.{ "help", "version" });
            switch (m) {
                .found => |k| return if (k == 0) help(ctx) else if (cli.printVersion(ctx)) 0 else 1,
                else => {
                    cli.badLong(ctx, a, m);
                    return 1;
                },
            }
        }
        cli.invalidShort(ctx, a[1]);
        return 1;
    }
    const path = file_arg orelse "/var/run/utmp";
    // GNU 9.7 (built with systemd) falls back to logind sessions when the
    // utmp file cannot be read and then prints nothing for a bad file name;
    // logind's session files are private data, so we just print nothing.
    const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return 0;
    defer f.close(ctx.io);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.gpa);
    while (true) {
        data.ensureUnusedCapacity(ctx.gpa, 64 * 1024) catch return 1;
        const n = cli.readChunk(ctx.io, f, data.unusedCapacitySlice()) catch return 0;
        if (n == 0) break;
        data.items.len += n;
    }
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(ctx.gpa);
    var off: usize = 0;
    while (off + record_size <= data.items.len) : (off += record_size) {
        const rec = data.items[off..][0..record_size];
        const kind = std.mem.readInt(i16, rec[0..2], .little);
        if (kind != user_process) continue;
        const user = std.mem.sliceTo(rec[44..76], 0);
        if (user.len == 0) continue;
        names.append(ctx.gpa, user) catch return 1;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out = cli.Out.init(ctx.io);
    for (names.items, 0..) |n, i| {
        if (i > 0) out.writeByte(' ');
        out.write(n);
    }
    if (names.items.len > 0) out.writeByte('\n');
    out.flush();
    return if (out.failed) 1 else 0;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: users [OPTION]... [FILE]\n" ++
        "Output who is currently logged in according to FILE.\n" ++
        "If FILE is not specified, use /var/run/utmp.  /var/log/wtmp as FILE is common.\n\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
