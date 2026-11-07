See docs/HANDOFF.md for the working method and pitfalls.

# Implementation status

Updated 2026-11-07. Every implemented command has a differential test suite
against GNU coreutils 9.7 (`test/test_<cmd>.sh`), a compatibility record
(`docs/compatibility/<cmd>.md`) and a manual page (`docs/manpages/<cmd>.md`).

## Implemented (86)

true false yes echo basename dirname cat wc dircolors pwd printenv sleep tee
head tac tail seq mkdir rmdir cut paste uniq fold nl tr expand unexpand comm
tsort sort md5sum sha1sum sha224sum sha256sum sha384sum sha512sum b2sum cksum
sum base64 base32 basenc factor join uname arch nproc whoami logname hostid id
groups tty users unlink link readlink realpath truncate ln chmod rm test [ printf expr env nice nohup timeout sync stdbuf chroot pathchk mkfifo mknod mktemp split od fmt shuf numfmt pr ptx csplit date touch

## Not yet implemented

- **Files:** cp, mv, dd, install, shred, chown, chgrp,
  stat, df, du, ls, dir, vdir, chcon, runcon.
- **Processes and environment:** kill, stty, who, pinky.
- **Absorbed utilities (not in GNU coreutils):** find, grep, sed, xargs, locate,
  updatedb, tree.
- Not coreutils but listed by earlier planning: hostname, uptime.

`test/` still contains stub suites for most of the unimplemented commands;
`sh test/run_all_tests.sh` reports them as failing until the command exists.

## Known gaps in implemented commands

See each command's `docs/compatibility/<cmd>.md`; the larger ones are: sort
(no -R, -V, --debug, no external merge), factor (no elliptic-curve method),
users (no systemd-logind fallback), and the locale-dependent behaviour that is
C-locale only everywhere.

## How to continue

- Build for tests with `zig build -Doptimize=ReleaseSafe` (some suites, e.g.
  factor, are too slow in Debug).
- Add a command: write `src/commands/<name>.zig`, register it in
  `src/commands.zig` (both lists), write `test/test_<name>.sh` with `run_cmp`
  (text commands) or `run_tree` (file-system commands), then generate the docs
  with `tools/gendoc.py`.
- OS facilities `std.Io` lacks go through `src/sys.zig` and decision 0002.
- `sh bench/run.sh <util>` compares speed and size with GNU using poop.
