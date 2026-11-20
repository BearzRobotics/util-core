// SPDX-License-Identifier: GPL-2.0-or-later
//! Public library surface of util-core (the `util_core` module).
//!
//! Everything else under src/ is internal. Consumers add the dependency in
//! build.zig.zon and `exe.root_module.addImport("util_core",
//! dep.module("util_core"))`.

/// Command context and output helpers (`cli.Context` is what every command's
/// `main` takes).
pub const cli = @import("cli.zig");
/// Registry of commands: `commands.all`, `commands.get("ls")`, `commands.find`.
pub const commands = @import("commands.zig");
/// getopt_long-compatible option parser with glibc diagnostics.
pub const getopt = @import("getopt.zig");
/// TZif / POSIX TZ time zones and civil-date arithmetic.
pub const tz = @import("tz.zig");
/// GNU-compatible strftime (C locale).
pub const strftime = @import("strftime.zig");
/// Port of GNU's date-string parser.
pub const datetime = @import("datetime.zig");
/// Exact C-style floating-point formatting.
pub const fmt_float = @import("fmt_float.zig");
/// POSIX BRE/ERE translation onto the regex package.
pub const posixre = @import("posixre.zig");
/// Message digests (md5, sha*, blake2b, ...).
pub const hash = @import("hash.zig");
/// chmod-style symbolic and octal mode parsing.
pub const mode = @import("mode.zig");
/// File metadata as data (type and mode names, file-system types) and the
/// `--json` form of a stat result.
pub const fileinfo = @import("fileinfo.zig");
/// JSON string output helpers for the `--json` modes.
pub const json = @import("json.zig");
/// File system usage as data and its `--json` form.
pub const fsusage = @import("fsusage.zig");
/// Disk usage per path as data and its `--json` form.
pub const diskusage = @import("diskusage.zig");
/// `wc` results as data and their `--json` form.
pub const wordcount = @import("wordcount.zig");
/// A moment in time as broken-down data and its `--json` form.
pub const dateinfo = @import("dateinfo.zig");
/// A computed checksum as data and its `--json` form.
pub const digestinfo = @import("digestinfo.zig");

/// Command libraries (decision 0004): one namespace per command or shared
/// engine, no argument parsing and no terminal output. `dir` and `vdir` are
/// `ls` with different defaults and have no module of their own; `true`,
/// `false` and `test` are exported as `true_cmd`, `false_cmd` and `test_cmd`.
pub const arch = @import("lib/arch.zig");
pub const b2sum = @import("lib/b2sum.zig");
pub const base32 = @import("lib/base32.zig");
pub const base64 = @import("lib/base64.zig");
pub const baseenc = @import("lib/baseenc.zig");
pub const basename = @import("lib/basename.zig");
pub const basenc = @import("lib/basenc.zig");
pub const bracket = @import("lib/bracket.zig");
pub const cat = @import("lib/cat.zig");
pub const chroot = @import("lib/chroot.zig");
pub const cksum = @import("lib/cksum.zig");
pub const cmp = @import("lib/cmp.zig");
pub const diffcore = @import("lib/diffcore.zig");
pub const diff = @import("lib/diff.zig");
pub const diff3 = @import("lib/diff3.zig");
pub const sdiff = @import("lib/sdiff.zig");
pub const comm = @import("lib/comm.zig");
pub const common = @import("lib/common.zig");
pub const cp = @import("lib/cp.zig");
pub const csplit = @import("lib/csplit.zig");
pub const cut = @import("lib/cut.zig");
pub const date = @import("lib/date.zig");
pub const dd = @import("lib/dd.zig");
pub const df = @import("lib/df.zig");
pub const dircolors = @import("lib/dircolors.zig");
pub const dirname = @import("lib/dirname.zig");
pub const du = @import("lib/du.zig");
pub const echo = @import("lib/echo.zig");
pub const env = @import("lib/env.zig");
pub const expand = @import("lib/expand.zig");
pub const expr = @import("lib/expr.zig");
pub const factor = @import("lib/factor.zig");
pub const false_cmd = @import("lib/false.zig");
pub const find = @import("lib/find.zig");
pub const fmt = @import("lib/fmt.zig");
pub const fold = @import("lib/fold.zig");
pub const fu_common = @import("lib/fu_common.zig");
pub const grep = @import("lib/grep.zig");
pub const hashsum = @import("lib/hashsum.zig");
pub const head = @import("lib/head.zig");
pub const hostid = @import("lib/hostid.zig");
pub const install = @import("lib/install.zig");
pub const join = @import("lib/join.zig");
pub const link = @import("lib/link.zig");
pub const ln = @import("lib/ln.zig");
pub const locate = @import("lib/locate.zig");
pub const logname = @import("lib/logname.zig");
pub const ls = @import("lib/ls.zig");
pub const md5sum = @import("lib/md5sum.zig");
pub const mkdir = @import("lib/mkdir.zig");
pub const mkfifo = @import("lib/mkfifo.zig");
pub const mknod = @import("lib/mknod.zig");
pub const mktemp = @import("lib/mktemp.zig");
pub const mv = @import("lib/mv.zig");
pub const nice = @import("lib/nice.zig");
pub const nl = @import("lib/nl.zig");
pub const nohup = @import("lib/nohup.zig");
pub const nproc = @import("lib/nproc.zig");
pub const numfmt = @import("lib/numfmt.zig");
pub const od = @import("lib/od.zig");
pub const paste = @import("lib/paste.zig");
pub const pathchk = @import("lib/pathchk.zig");
pub const pr = @import("lib/pr.zig");
pub const printenv = @import("lib/printenv.zig");
pub const printf = @import("lib/printf.zig");
pub const ptx = @import("lib/ptx.zig");
pub const pwd = @import("lib/pwd.zig");
pub const readlink = @import("lib/readlink.zig");
pub const realpath = @import("lib/realpath.zig");
pub const rm = @import("lib/rm.zig");
pub const rmdir = @import("lib/rmdir.zig");
pub const sed = @import("lib/sed.zig");
pub const seq = @import("lib/seq.zig");
pub const sha1sum = @import("lib/sha1sum.zig");
pub const sha224sum = @import("lib/sha224sum.zig");
pub const sha256sum = @import("lib/sha256sum.zig");
pub const sha384sum = @import("lib/sha384sum.zig");
pub const sha512sum = @import("lib/sha512sum.zig");
pub const shred = @import("lib/shred.zig");
pub const shuf = @import("lib/shuf.zig");
pub const sink = @import("lib/sink.zig");
pub const sleep = @import("lib/sleep.zig");
pub const sort = @import("lib/sort.zig");
pub const split = @import("lib/split.zig");
pub const stat = @import("lib/stat.zig");
pub const stdbuf = @import("lib/stdbuf.zig");
pub const stickyout = @import("lib/stickyout.zig");
pub const sum = @import("lib/sum.zig");
pub const sync = @import("lib/sync.zig");
pub const tac = @import("lib/tac.zig");
pub const tail = @import("lib/tail.zig");
pub const tee = @import("lib/tee.zig");
pub const test_cmd = @import("lib/test.zig");
pub const timeout = @import("lib/timeout.zig");
pub const touch = @import("lib/touch.zig");
pub const tr = @import("lib/tr.zig");
pub const tree = @import("lib/tree.zig");
pub const true_cmd = @import("lib/true.zig");
pub const truncate = @import("lib/truncate.zig");
pub const tsort = @import("lib/tsort.zig");
pub const unexpand = @import("lib/unexpand.zig");
pub const uniq = @import("lib/uniq.zig");
pub const unlink = @import("lib/unlink.zig");
pub const updatedb = @import("lib/updatedb.zig");
pub const users = @import("lib/users.zig");
pub const wc = @import("lib/wc.zig");
pub const whoami = @import("lib/whoami.zig");
pub const wsink = @import("lib/wsink.zig");
pub const xargs = @import("lib/xargs.zig");
pub const yes = @import("lib/yes.zig");
