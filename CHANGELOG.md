# Changelog

## 0.1.0

First release. 103 commands (everything in `docs/status.md`), each with a manual page,
a compatibility record and a differential test suite against the GNU reference.

**Architecture**
- Library first: every command is a function in the `util_core` Zig module that takes
  `std.Io`, parses no arguments, prints nothing it was not asked to and changes no process
  state; the executables are thin wrappers (decisions 0002 and 0004). Other Zig projects
  import `util_core` as a package dependency.
- Build modes: `-Dmode=standalone` (one binary per command), `-Dmode=multicall` (one `util-core`
  binary: `util-core ls ...`, `util-core --list`, or invoked through a link named after a
  command) or `-Dmode=all` (default). `-Dcommands=a,b,c` builds a subset; `-Dman=false` skips
  the manual pages; release builds are stripped by default (`-Dstrip`).
- Manual pages in the dkman layout (Markdown, `docs/manpages/`), installed with `-Dman`
  (default on) to `share/man/man1/NAME.1.md`.

**Commands**
- The coreutils set (text, file, hashing, system and shell-utility commands), plus `sed`,
  `grep`, `find`, `tree`, `locate` and `updatedb`.
- Diffutils: `cmp`, `diff`, `diff3` and `sdiff` with the GNU algorithm, every output format
  and the directory options (verified against GNU diffutils 3.12). Known gap: locale collation (C locale only).
- `grep` extensions (decision 0006): ripgrep-, ugrep- and FreeBSD-derived options, all opt-in
  (`--smart-case`, `--glob`, `--replace`, `--count-matches`, `--stats`, `--type`, `--and`/`--not`,
  `--decompress`, ...), with clearer diagnostics.

**GNU compatibility and its extensions**
- GNU behaviour is the default and is checked against GNU coreutils 9.7, grep 3.12 and
  diffutils 3.12. Departures are opt-in or terminal-only and are indexed in
  `docs/compatibility/extensions.md` (decision 0005): `--json` structured output on `ls`, `stat`,
  `df`, `du`, `wc`, `date`, `printenv`, the checksum commands, `cmp`, `diff`, `diff3`, `sdiff`,
  `grep` and `find -json`; a bat-style view for `cat` on a terminal; and diagnostics that are
  clearer than GNU's where GNU is silent, each documented in the command's manual page.

**Platforms**
- Linux x86_64 and aarch64: the reference platform; every test suite runs here.
- Windows x86_64 and aarch64: the whole library and all commands compile; x86_64 passes
  `test/test_windows_wine.sh` (79 cases, wine 10.0) under wine; this release was NOT rechecked on real Windows (the maintainer's VM would not get a network address
  on release day); it is the first item for 0.1.1. See `docs/release.md`. Windows-specific differences are in `docs/portability.md`.
- macOS x86_64 and aarch64: builds from source and is compile-checked in CI, but has never
  been run (no maintainer owns a Mac), and no prebuilt macOS binaries are published.

**Known gaps**: see `docs/status.md` and each `docs/compatibility/<cmd>.md` (for example `sort`
has no external merge, locale-dependent behaviour is C-locale only).
