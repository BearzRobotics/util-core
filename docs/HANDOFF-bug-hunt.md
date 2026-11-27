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

- Branch `bug-fixes`; the last fix is `42bdd30` (echo, basename, dirname tests).
- `main` is at `8b435a0`, behind `bug-fixes`. It has the pr width
  fix, regex-zig 0.5.0, the less fixes and the less docs. Merge the rest with
  the release, as `git merge --no-ff -F MSGFILE bug-fixes`
  (`git merge -F -` does not read standard input).
- All TEXT-* reports are done, and MISC-003, 004 and 005.
- 103 report files have no Status section (19 medium, the rest low),
  as of 42bdd30. Some may be fixed already: reproduce each one first.

### Done 2026-11-27

pr streams its input (a3a515f). MISC-006 (fec5e91, `test/test_sigpipe.sh`),
MISC-008, 010, 016, 018, 020, 022-025, 028, 031 and 038 are done. Next:
the other unmarked reports (INFRA, REGX, VIEW medium, then low severity).

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
- Open medium first, then low.
- These come before the old TEXT range in the table and are still open:
  INFRA-003/004/006/012 and MISC-003..038 where unmarked. DISK-020's Status
  says "Still open".
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
