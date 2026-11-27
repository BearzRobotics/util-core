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

- Branch `bug-fixes`; the last fix is `07a9a74` (date format flags).
- `main` is at `8b435a0`, behind `bug-fixes`. Merge with the release, as
  `git merge --no-ff -F MSGFILE bug-fixes` (`git merge -F -` does not read
  standard input).
- All TEXT-*, high and medium reports are done. 66 report files have no Status
  section, all low, as of 07a9a74. Some may be fixed already or be duplicates
  (DISK-006/040, FSOP-022/031, MISC-007/041, MISC-021/DISK-039): reproduce
  each one first.
- Next: the other crash reports (MISC-037, VIEW-015, VIEW-019), then the rest.

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
- Windows and macOS cross-builds were last checked at fec5e91; later commits
  change shared code.
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

## The release, at the end

1. Update the docs, including CHANGELOG.md and the central deviation index.
2. Choose the version (`build.zig.zon` says 0.2.0; tags v0.0.0 to v0.2.0).
3. Earlier releases attached a vendored source archive; see "Release" under
   State in `docs/HANDOFF.md`. That recipe predates the yaml-zig dependency:
   both `regex` and `yaml` need vendoring, and the result must build with an
   empty `ZIG_GLOBAL_CACHE_DIR`. `scripts/package.sh` builds binary archives.
   Look at what the v0.2.0 GitHub release has attached, and ask the maintainer
   if "vendor a new release" is unclear.
4. Merge into main, tag, `gh release create`.
