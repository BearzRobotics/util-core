# Handoff: bug hunt (written 2026-11-27)

## The task (maintainer's words)

> "go through and fix one at a time commit and push. Once all of these are
> fixed update docs and vendor a new release."

Approach, also the maintainer's: be a bug hunter. Keep the existing
functionality, and assume the logic is wrong until it is proven good.

## Safety rules

- **Cap memory** whenever a tool gets endless or huge input:
  `(ulimit -v 1000000; timeout 20 zig-out/bin/NAME ...)`. A time limit alone is
  not enough. Uncapped runs got `pr` (19 GB, 11-26 05:40) and `cut` (24 GB,
  11-26 16:18) killed by the kernel; the second ended the session, and the
  first very likely ended the one before. Put the cap in test cases too.
- Never run `test/test_sync.sh`, `test/test_df.sh` or `test/run_all_tests.sh`.
  Run `test/test_rm.sh` only in a sandbox with a read-only root.
- Fuzzing stays paused. INFRA-003 and INFRA-004 are about the fuzz tooling.
  The three `.claude/worktrees` hold unmerged fuzzing work: leave them.

## State

- Branch `bug-fixes`; every report in `docs/bugs/` has a Status section (none
  open, 2026-11-27). The last code fix is `cd6600a`.
- Partly done, as their Status sections say: REGX-019 (xz output is still held
  whole, a limit of Zig's decoder, and so is the compressed file), REGX-025
  (a repeat count stacked on a repetition, `a*\{2\}`, is accepted where GNU
  sed refuses it), INFRA-014 (leaving the built-in pager while its input is
  blocked, and dd on SIGINT, end the process), DISK-032 (documented; names are
  not looked up through NSS).
- 0.3.0 is released; see the end of this file. Next: Windows.

### CI

`ci.yml` now runs the differential suites in an Ubuntu 26.04 container
(`scripts/suites-container.sh`; allow-list in `scripts/run-suites.sh`, which
fails on an unlisted suite), and `release.yml` needs CI to pass. A push cancels
the branch's previous run and the suite job takes about 20 minutes, so watch
the last one (`gh run watch`). The container uses mawk, so suites that make
random cases with awk try other values there than here: that has found real
bugs.

## How to work

For each bug: reproduce against `/usr/bin/<cmd>` (`LC_ALL=C`), compare random
inputs where that fits, fix, add the case to `test/test_<cmd>.sh`, then:

```sh
zig build -Doptimize=ReleaseSafe            # check its exit status: a failed
                                            # build leaves the old binaries
sh test/test_<cmd>.sh                       # cap the output (head -c)
zig build test -Doptimize=ReleaseSafe
git add FILES && git commit && git push origin bug-fixes
printf '\n## Status\n\nFixed in %s.\n' HASH >> docs/bugs/ID-*.md
```

- One commit per bug. Add files by name.
- End commit messages with the attribution line Claude Code gives.
- Reports are in `docs/bugs/` (ignored by git). The README table is ordered by
  severity but lists only 241 of the 265 files, so find open ones with
  `grep -L '^## Status' docs/bugs/[A-Z]*-[0-9]*.md`.
- Duplicates and reports that an earlier fix covers get a Status naming it.
- A deliberate difference from GNU goes in the man page,
  `docs/compatibility/<cmd>.md` and `docs/compatibility/extensions.md`.
  Clearer diagnostics than GNU's are welcome if documented.
- `test/pty_less.py` is timing-sensitive and fails now and then under load.

## Seen, not changed

- diff3 -e, -E and -A, when two of the files differ only in a final newline:
  GNU treats them differently from its own default and -m output; we do not.
- timeout leaves a signal that was ignored ignored in the command; GNU's
  handlers make exec reset it.
- `grep '[&&]'` fails in the C locale (also with regex-zig 0.4.0); GNU accepts.
- `cut -z -f...`: when the last record has no terminator and ends in the field
  delimiter, GNU writes no final NUL; we write one.
- Not in the audit, seen under `ulimit -v` (fix like cut and pr):
  `paste /dev/zero /dev/zero` buffers whole lines where GNU streams; `fmt`
  reads its whole input and, out of memory, exits 1 silently (`numfmt` streams
  since 7b4e134; its old case has not been retried); `join`
  out of memory is silent too; `nl /dev/zero` says "OutOfMemory"; `tac` says
  "read error: OutOfMemory" on endless input; `grep -a a /dev/zero` was still
  running after 8 s where GNU had said "memory exhausted".
- `date -d @9223372036854775807` prints a nine-digit-plus year; GNU says
  "time ... is out of range" (also for huge relative times).
- Invalid TZ rule fields show "UTC"
  where glibc keeps the standard name (same offset in the cases tried).
- A `%a` of a denormal long double and the printf status after underflow
  differ from GNU (found while testing MISC-016).
- From a date fuzz, not compared with a build from before 751aa2e:
  `date -d 'seconds 1 jan +2147483647'` gives year 2147483647 in GNU and
  "invalid date" here (the new range check refuses the parsed year
  -2147483647); `'-4294967296 minutes -'` in EST5EDT differs around DST.
- `tree --du` (and `--prune` with `-P`) lists each subtree once per level
  above it. Since FSOP-033 it finishes 1500 levels, but 2040 take over 60 s on a
  busy machine, where tree 2.3.1 is quick. Not in the audit.
- Quoting (`quotearg.zig`, `quote.zig`) knows the C locale only (except cat's
  diagnostics): in UTF-8, stat %N and others escape what GNU prints.
- grep -P in UTF-8: `\w` leaves out non-decimal numbers, `\h \v` are ASCII,
  `\R \X \N \K` are missing, and a variable-width look-behind falls back to
  byte matching. The first and last need work in regex-zig.
- backups: in a directory that may not be listed, --backup=existing makes a
  simple backup over an older one, as GNU does (FSOP-029).
- cat's query of the terminal background (theme auto) opens and closes the
  terminal with TCSAFLUSH: what the user had typed ahead is lost, and so is
  what arrives while it waits. Found with test/pty_less.py on one loaded CPU.
  Not in the audit.
- head: when `-n -N` writes nothing we leave stdin where it was (documented).

## After 0.3.0: Windows

Maintainer, 2026-11-27: release 0.3.0 for Linux only; then widen the Windows
tests and fix the Windows bugs, keeping Linux as it is.

- `test/test_windows_wine.sh` is a smoke test (79 cases, fewer than 30 of about
  105 commands) and wine hides real faults. Windows needs checks of every
  command, above all those that change files, run on the VM, kept in the repo.
- Known failures: "Known to fail on Windows" in `docs/portability.md`. Also to
  examine: `ls 'p.txt*'` says "Invalid argument" (cmd does not expand
  wildcards), and `xargs` fed by cmd's `echo` got "BadPathName".
- On the VM, cmd takes `mkdir.exe` and `date.exe` for its own commands: use
  full paths. SSH is OpenSSH for Windows (user `aimgr`; ask for the password,
  never store it).
- On this host a saved NetworkManager connection `virbr0` stops libvirt's
  `default` network: `nmcli connection down virbr0` before
  `virsh net-start default`; afterwards `virsh net-destroy default` and
  `nmcli connection up virbr0`.
- Then publish Windows archives again (`release.yml`, README, release.md).

## Release

0.3.0 was published on 2026-11-27 from `651a3d5` (main): two Linux archives,
SHA256SUMS and the vendored source archive. No Windows archives.
