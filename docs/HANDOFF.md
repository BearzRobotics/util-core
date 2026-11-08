# Handoff for the next Claude (written 2026-11-07)

## What this project is
A Zig 0.17.1 reimplementation of GNU coreutils 9.7 (plus the absorbed
find/grep/sed/xargs/locate/updatedb/tree, all done). The owner wants drop-in
behaviour verified against the real GNU binaries on this machine
(`/usr/bin/<cmd>` is GNU 9.7), small and fast binaries, and everything done
through `std.Io` except the documented exceptions. Read `ai/AGENTS.md` first
(engineering rules), then `docs/status.md`, `docs/architecture.md`,
`docs/decisions/0002-std-io-exceptions.md`.

## State
- 99 commands are implemented, tested and documented (every command on the
  list, including the absorbed sed, grep, find, xargs, tree, locate and
  updatedb). `docs/status.md` is the authority; update it whenever a command
  lands.
- Oracles: coreutils, find 4.10.0, grep 3.12 and sed 4.9 are GNU in /usr/bin.
  tree 2.3.1 is /usr/bin/tree (`ORACLE_OK=1`). locate/updatedb/xargs oracles are
  built from the findutils-4.10.0 tarball by `tools/build-gnu-findutils.sh` into
  `~/.cache/util-core/findutils` (suites skip if absent; `GNU_BIN` overrides).
- Next: the stress-testing pass the owner asked for (large inputs, hostile
  option combinations, low-memory/full-disk behaviour, fuzzing the regex
  translator and the parsers against the GNU binaries).
- Unix-only utilities belong in util-unix and are not to be added here:
  chmod, id, groups, tty, uname, chown, chgrp, chcon, runcon, kill, stty,
  who, pinky, hostname, uptime.

## Workflow that works (follow it)
1. Probe GNU: `--help`, then the exact error texts and edge cases
   (`/usr/bin/<cmd> ... 2>&1`). Use `LC_ALL=C`.
2. Write `src/commands/<name>.zig` (`pub fn main(ctx: cli.Context) u8`), add it
   to BOTH lists in `src/commands.zig` (`all` and `modules`), and to
   `src/test_all.zig` if it adds a shared module.
3. Write `test/test_<name>.sh`. Text tools use `run_cmp` (compares stdout,
   normalised stderr, exit status with GNU). File-system tools use `run_tree`
   (two fresh dirs, compares output with the dir name masked, exit status, and
   the resulting tree with modes and symlink targets; `TREE_STDIN=file`
   supplies standard input; `TREE_UMASK=` sets the umask). `test/hashtests.sh`
   and `test/basetests.sh` are shared case tables. Add seeded random cases
   (awk with `srand`) — they found most of the subtle bugs.
4. Iterate until every case passes. Differences usually come from GNU quirks
   (message wording, order of checks, what is printed before an error): record
   them in the code comment and the compatibility doc.
5. Docs: `tools/gendoc.py` (`gen(...)`) writes `docs/compatibility/<cmd>.md`
   and `docs/manpages/<cmd>.md`; see any earlier call in git history
   (`git log -p -S'gen("rm"'`) for the argument shapes. Cite what was actually
   consulted (GNU manual node, POSIX page) and list real deviations.
6. Commit per batch with the `Co-Authored-By: Claude Sonnet 5.5` line.

## Build and test commands
- `zig build -Doptimize=ReleaseSafe` then `sh test/test_<cmd>.sh`
  (tests run `zig-out/bin/<cmd>`). Debug builds are too slow for factor and
  the big sort/tac/tail cases, and a plain `zig build` overwrites zig-out with
  Debug. `zig build test` runs the unit tests.
- `sh test/run_all_tests.sh` runs everything (stub suites for unimplemented
  commands fail by design).
- Performance: `sh bench/run.sh <util>` (poop; reports cycles, instructions,
  RSS, binary size vs GNU). See `docs/benchmarks/`.

## Conventions and helpers
- Output: `cli.Out` (buffered stdout), `cli.warn` (stderr with command name),
  `cli.writeStdout`, `cli.readChunk`, `cli.openInput`.
- Quoting in diagnostics must match GNU: `cli.quote` (quotef: only when
  needed), `cli.quoteA` (quoteaf: always quoted), `cli.quoteC` (quote():
  C-style escapes). Use `{f}` in format strings.
- Long options: `cli.matchLong` / `cli.badLong` (lists ambiguous candidates).
- OS facilities `std.Io` lacks live ONLY in `src/sys.zig` (signals, umask,
  terminal size, pid probe, O_APPEND open, identity, uname, CPU affinity,
  `fileStat` = statx with uid/gid/device/blocks, `errnoText`). Add a function
  there and a row to decision 0002 when you need another. Never call
  `std.posix`/`std.os` from a command.
- Shared modules: `hash.zig`, `hashsum.zig`, `baseenc.zig`, `bytes.zig`
  (vector byte search), `userdb.zig` (/etc/passwd, /etc/group), `paths.zig`
  (canonicalisation), `numparse.zig` (f80 float parsing), `fmt_float.zig`
  (exact C float formatting, f64 and f80), `mode.zig` (chmod modes),
  `posixre.zig` (BRE/ERE -> the regex package's Perl dialect), `tabs.zig`,
  `lines.zig`, `count_arg.zig`.
- The regex package (remote dependency BearzRobotics/regex-zig, imported as
  `regex`, not to be modified here) has no POSIX dialect; `posixre.zig`
  translates BRE/ERE and the findutils/Emacs/awk dialects, and emulates
  leftmost-longest alternation (`Finder`, `Flags.alt`) and UTF-8 classes
  (`unicode.zig`, `unicode_tables.zig`). grep -P is regex-zig's Perl dialect,
  not PCRE2.

## Pitfalls learned the hard way
- `/tmp` is a small shared tmpfs that other projects fill. Keep build prefixes
  out of it (use `zig-out` or delete them). `test/testlib.sh` keeps every test
  temp file under one directory it removes on exit.
- Never `pkill -f <pattern>` with a pattern that appears in your own command
  line (it kills the shell). Kill by pid.
- A test script that runs a command which can hang needs `timeout`; GNU
  `factor` itself hangs on some 77-digit inputs.
- `std.Io.File.Stat` has no uid/gid/device/blocks: use `sys.fileStat`.
- GNU quirks are everywhere; trust the oracle, not memory. Examples: `join`
  sets its "unpairable seen" flag AFTER advancing; `test` only treats
  `--help/--version` specially for `[`; `base32` rejects a padded short tail
  without output; `chmod` re-checks umask-protected removals.
- Leave unrelated user files alone (`/tmp/util-unix-bench`, the owner's other
  projects). `Readme.md` was removed at the owner's request.

## Known gaps (also in each compatibility doc)
sort: no --debug, no external merge. factor: no elliptic-curve method
(very hard numbers are reported, not factored). users: no systemd-logind
fallback. rm: --one-file-system accepted, not enforced. printf/seq: f80
approximations of `long double` beyond x87 range. Locale: C everywhere except sed, grep, find, tree and locate (UTF-8 vs C only).
tree lacks -H/--fromfile/--gitignore/--info/--hyperlink/--compress/--condense/-R;
find lacks -D tracing, -O, -files0-from, -context; locate lacks the old bigram
database format; updatedb ignores --localuser/--netuser.

## Owner preferences
Cite GNU manual + POSIX for every command (see memory
`gnu-posix-references`), use `std.Io` and document exceptions (memory
`std-io-exceptions`), size and speed matter, commit per batch is welcome,
and the owner asked to be told when work is partial. They said "leave Io" when
asked about a custom Io: do not replace std.Io.
