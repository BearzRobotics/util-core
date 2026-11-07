//! uname — print system information.
//! Reference: GNU coreutils manual "uname invocation" (9.7); POSIX.1-2024 uname.
//! -p and -i print the machine name where the system has nothing better, as
//! GNU 9.7 does on this platform; -a leaves them out only when they would be
//! "unknown".

const std = @import("std");
const cli = @import("../cli.zig");
const sys = @import("../sys.zig");

const long_names = [_][]const u8{ "all", "kernel-name", "nodename", "kernel-release", "kernel-version", "machine", "processor", "hardware-platform", "operating-system", "help", "version" };

const S = 1;
const N = 2;
const R = 4;
const V = 8;
const M = 16;
const P = 32;
const I = 64;
const O = 128;

pub fn main(ctx: cli.Context) u8 {
    var want: u32 = 0;
    var only_operands = false;
    for (ctx.args) |a_z| {
        const a: []const u8 = a_z;
        if (only_operands or a.len < 2 or a[0] != '-') {
            cli.warn(ctx, "extra operand '{s}'\nTry '{s} --help' for more information.", .{ a, ctx.name });
            return 1;
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
                0 => want |= 255,
                1 => want |= S,
                2 => want |= N,
                3 => want |= R,
                4 => want |= V,
                5 => want |= M,
                6 => want |= P,
                7 => want |= I,
                8 => want |= O,
                9 => return help(ctx),
                else => return if (cli.printVersion(ctx)) 0 else 1,
            }
            continue;
        }
        for (a[1..]) |c| switch (c) {
            'a' => want |= 255,
            's' => want |= S,
            'n' => want |= N,
            'r' => want |= R,
            'v' => want |= V,
            'm' => want |= M,
            'p' => want |= P,
            'i' => want |= I,
            'o' => want |= O,
            else => {
                cli.invalidShort(ctx, c);
                return 1;
            },
        };
    }
    if (want == 0) want = S;
    const all = want == 255;
    const u = sys.uname();
    var out = cli.Out.init(ctx.io);
    var first = true;
    inline for (.{
        .{ S, u.sysname },
        .{ N, u.nodename },
        .{ R, u.release },
        .{ V, u.version },
        .{ M, u.machine },
        .{ P, u.machine },
        .{ I, u.machine },
        .{ O, "GNU/Linux" },
    }) |e| {
        if (want & e[0] != 0) {
            // "-a" would omit an unknown -p / -i; both are known here.
            _ = all;
            if (!first) out.writeByte(' ');
            out.write(e[1]);
            first = false;
        }
    }
    out.writeByte('\n');
    out.flush();
    return if (out.failed) 1 else 0;
}

fn help(ctx: cli.Context) u8 {
    return if (cli.writeStdout(ctx.io, "Usage: uname [OPTION]...\n" ++
        "Print certain system information.  With no OPTION, same as -s.\n\n" ++
        "  -a, --all                print all information, in the following order,\n" ++
        "                             except omit -p and -i if unknown:\n" ++
        "  -s, --kernel-name        print the kernel name\n" ++
        "  -n, --nodename           print the network node hostname\n" ++
        "  -r, --kernel-release     print the kernel release\n" ++
        "  -v, --kernel-version     print the kernel version\n" ++
        "  -m, --machine            print the machine hardware name\n" ++
        "  -p, --processor          print the processor type (non-portable)\n" ++
        "  -i, --hardware-platform  print the hardware platform (non-portable)\n" ++
        "  -o, --operating-system   print the operating system\n" ++
        "      --help        display this help and exit\n" ++
        "      --version     output version information and exit\n")) 0 else 1;
}
