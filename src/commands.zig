//! Command registry. Each command lives in src/commands/<name>.zig and exports
//! `pub fn main(ctx: cli.Context) u8`.
//!
//! To add a command: create its file, then add it to both `all` and `modules`.

const std = @import("std");
const cli = @import("cli.zig");

/// Every command this source tree knows about.
pub const all = [_][]const u8{ "true", "false", "yes", "echo", "basename", "dirname", "cat", "wc", "dircolors", "pwd", "printenv", "sleep", "tee", "head", "tac", "tail", "seq", "mkdir", "rmdir", "cut", "paste", "uniq", "fold", "nl", "tr", "expand", "unexpand", "comm", "tsort", "sort", "cksum", "md5sum", "sha1sum", "sha224sum", "sha256sum", "sha384sum", "sha512sum", "b2sum", "sum", "base64", "base32", "basenc", "factor", "join", "arch", "nproc", "whoami", "logname", "hostid", "users", "unlink", "link", "readlink", "realpath", "truncate", "ln", "rm", "test", "[", "printf", "expr", "env", "nice", "nohup", "timeout", "sync", "chroot", "stdbuf", "pathchk", "mkfifo", "mknod", "mktemp", "split", "od", "fmt", "shuf", "numfmt", "pr", "ptx", "csplit", "date", "touch", "stat", "ls", "dir", "vdir", "du", "df", "cp", "mv", "install", "dd", "shred", "xargs", "sed", "grep", "find" };

/// Command source files, keyed by command name. @import needs a string
/// literal, so each command is listed here explicitly. Importing a file only
/// parses it; a command's code is compiled into a binary only when `get`
/// references it.
pub const modules = .{
    .true = @import("commands/true.zig"),
    .false = @import("commands/false.zig"),
    .yes = @import("commands/yes.zig"),
    .echo = @import("commands/echo.zig"),
    .basename = @import("commands/basename.zig"),
    .dirname = @import("commands/dirname.zig"),
    .cat = @import("commands/cat.zig"),
    .wc = @import("commands/wc.zig"),
    .dircolors = @import("commands/dircolors.zig"),
    .pwd = @import("commands/pwd.zig"),
    .printenv = @import("commands/printenv.zig"),
    .sleep = @import("commands/sleep.zig"),
    .tee = @import("commands/tee.zig"),
    .head = @import("commands/head.zig"),
    .tac = @import("commands/tac.zig"),
    .tail = @import("commands/tail.zig"),
    .seq = @import("commands/seq.zig"),
    .mkdir = @import("commands/mkdir.zig"),
    .rmdir = @import("commands/rmdir.zig"),
    .cut = @import("commands/cut.zig"),
    .paste = @import("commands/paste.zig"),
    .uniq = @import("commands/uniq.zig"),
    .fold = @import("commands/fold.zig"),
    .nl = @import("commands/nl.zig"),
    .tr = @import("commands/tr.zig"),
    .expand = @import("commands/expand.zig"),
    .unexpand = @import("commands/unexpand.zig"),
    .comm = @import("commands/comm.zig"),
    .tsort = @import("commands/tsort.zig"),
    .sort = @import("commands/sort.zig"),
    .cksum = @import("commands/cksum.zig"),
    .md5sum = @import("commands/md5sum.zig"),
    .sha1sum = @import("commands/sha1sum.zig"),
    .sha224sum = @import("commands/sha224sum.zig"),
    .sha256sum = @import("commands/sha256sum.zig"),
    .sha384sum = @import("commands/sha384sum.zig"),
    .sha512sum = @import("commands/sha512sum.zig"),
    .b2sum = @import("commands/b2sum.zig"),
    .sum = @import("commands/sum.zig"),
    .base64 = @import("commands/base64.zig"),
    .base32 = @import("commands/base32.zig"),
    .basenc = @import("commands/basenc.zig"),
    .factor = @import("commands/factor.zig"),
    .join = @import("commands/join.zig"),
    .arch = @import("commands/arch.zig"),
    .nproc = @import("commands/nproc.zig"),
    .whoami = @import("commands/whoami.zig"),
    .logname = @import("commands/logname.zig"),
    .hostid = @import("commands/hostid.zig"),
    .users = @import("commands/users.zig"),
    .unlink = @import("commands/unlink.zig"),
    .link = @import("commands/link.zig"),
    .readlink = @import("commands/readlink.zig"),
    .realpath = @import("commands/realpath.zig"),
    .truncate = @import("commands/truncate.zig"),
    .ln = @import("commands/ln.zig"),
    .rm = @import("commands/rm.zig"),
    .@"test" = @import("commands/test.zig"),
    .@"[" = @import("commands/bracket.zig"),
    .printf = @import("commands/printf.zig"),
    .expr = @import("commands/expr.zig"),
    .env = @import("commands/env.zig"),
    .nice = @import("commands/nice.zig"),
    .nohup = @import("commands/nohup.zig"),
    .timeout = @import("commands/timeout.zig"),
    .sync = @import("commands/sync.zig"),
    .chroot = @import("commands/chroot.zig"),
    .stdbuf = @import("commands/stdbuf.zig"),
    .pathchk = @import("commands/pathchk.zig"),
    .mkfifo = @import("commands/mkfifo.zig"),
    .mknod = @import("commands/mknod.zig"),
    .mktemp = @import("commands/mktemp.zig"),
    .split = @import("commands/split.zig"),
    .od = @import("commands/od.zig"),
    .fmt = @import("commands/fmt.zig"),
    .shuf = @import("commands/shuf.zig"),
    .numfmt = @import("commands/numfmt.zig"),
    .pr = @import("commands/pr.zig"),
    .ptx = @import("commands/ptx.zig"),
    .csplit = @import("commands/csplit.zig"),
    .date = @import("commands/date.zig"),
    .touch = @import("commands/touch.zig"),
    .stat = @import("commands/stat.zig"),
    .ls = @import("commands/ls.zig"),
    .dir = @import("commands/dir.zig"),
    .vdir = @import("commands/vdir.zig"),
    .du = @import("commands/du.zig"),
    .df = @import("commands/df.zig"),
    .cp = @import("commands/cp.zig"),
    .mv = @import("commands/mv.zig"),
    .install = @import("commands/install.zig"),
    .dd = @import("commands/dd.zig"),
    .shred = @import("commands/shred.zig"),
    .xargs = @import("commands/xargs.zig"),
    .sed = @import("commands/sed.zig"),
    .grep = @import("commands/grep.zig"),
    .find = @import("commands/find.zig"),
};

/// Frontend for a command known at comptime.
pub fn get(comptime name: []const u8) cli.CommandFn {
    return @field(modules, name).main;
}

/// Runtime lookup restricted to the `enabled` command names.
pub fn find(comptime enabled: []const []const u8, name: []const u8) ?cli.CommandFn {
    inline for (enabled) |e| {
        if (std.mem.eql(u8, e, name)) return get(e);
    }
    return null;
}
