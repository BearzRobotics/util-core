See docs/HANDOFF.md for the working method and pitfalls.

# Implementation status

Updated 2026-11-07. Every implemented command has a differential test suite
against GNU coreutils 9.7 (`test/test_<cmd>.sh`), a compatibility record
(`docs/compatibility/<cmd>.md`) and a manual page (`docs/manpages/<cmd>.md`).

## Implemented (99)

true false yes echo basename dirname cat wc dircolors pwd printenv sleep tee
head tac tail seq mkdir rmdir cut paste uniq fold nl tr expand unexpand comm
tsort sort md5sum sha1sum sha224sum sha256sum sha384sum sha512sum b2sum cksum
sum base64 base32 basenc factor join arch nproc whoami logname hostid
users unlink link readlink realpath truncate ln rm test [ printf expr env nice nohup timeout sync stdbuf chroot pathchk mkfifo mknod mktemp split od fmt shuf numfmt pr ptx csplit date touch stat ls dir vdir du df cp mv install dd shred xargs sed grep find tree locate updatedb

## Not yet implemented

- **Moved to util-unix (removed from this project):** chmod, id, groups, tty, uname, chown, chgrp,
  chcon, runcon, kill, stty, who, pinky, hostname, uptime.
- **Absorbed utilities (not in GNU coreutils):** all done (sed, grep, find, tree, locate, updatedb).

`test/` still contains stub suites for most of the unimplemented commands;
`sh test/run_all_tests.sh` reports them as failing until the command exists.

## Known gaps in implemented commands

See each command's `docs/compatibility/<cmd>.md`; the larger ones are: sort
(no external merge), factor (no elliptic-curve method),
users (no systemd-logind fallback), and the locale-dependent behaviour that is
C-locale only everywhere.

## Come back to

- **`sync` differential suite (`test/test_sync.sh`) was not run on the converted
  build.** It calls GNU `sync -f`, which blocks for tens of minutes on the
  development drive, and the maintainer asked not to run it there (2026-11-19).
  Old and new `sync` binaries were compared on 18 invocations (identical stdout,
  stderr and status). Run the suite on a machine or drive where `sync` is
  cheap, then delete this item. Do not run it on the development drive.
- `shred`: `test_shred.sh` hangs at its `/dev/full` test (before and after the
  library conversion); check whether GNU `shred /dev/full` hangs too.
- `ls` library returns formatted text and `--json` only, not structured entries.
- Wrappers for find, tree, locate and updatedb pass `smp_allocator` because of
  intentional small leaks; fix the leaks and use the normal allocator.
- Two copies of the GNU file-name quoting code (`src/quote.zig`, `src/quoted.zig`)
  plus a third inside `src/lib/printf.zig`; merge into one pure module.
- Better diagnostics where GNU gives none (decision 0005 update): audit the
  commands, implement, document in man pages.
- grep extensions (decision 0006).

## How to continue

- Build for tests with `zig build -Doptimize=ReleaseSafe` (some suites, e.g.
  factor, are too slow in Debug).
- Add a command: write `src/commands/<name>.zig`, register it in
  `src/commands.zig` (both lists), write `test/test_<name>.sh` with `run_cmp`
  (text commands) or `run_tree` (file-system commands), then generate the docs
  with `tools/gendoc.py`.
- OS facilities `std.Io` lacks go through `src/sys.zig` and decision 0002.
- `sh bench/run.sh <util>` compares speed and size with GNU using poop.
