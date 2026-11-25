# Changelog

## Unreleased

**`cat`**
- Grammars are read with the `yaml-zig` package: `.sublime-syntax` files may now use anchors,
  aliases, tags and multi-line quoted strings. Invalid YAML and repeated keys are now refused.
- Fixed: Elixir `~s'''` and `~s"""` heredocs were not highlighted (invalid YAML in the grammar).

## 0.2.0

Two new commands (`time`, `less`), a bat-faithful `cat` with highlighting for 73 languages, themes, git markers and paging, and a Windows console fix.

**New commands: `time` and `less`** (105 commands)

**`time`**
- GNU time 1.9 behaviour: `-f/--format` with every format letter and the `TIME` variable, `-p`,
  `-v`, `-o`, `-a`, `-q`, the "Command exited with non-zero status" and "Command terminated by
  signal" lines, exit status 126/127/128+N; differential suite `test/test_time.sh` against
  `/usr/bin/time`. Linux (wait4 rusage), macOS (compile-checked) and Windows (GetProcessTimes,
  peak working set; compile-checked).
- `--bench` (extension, decision 0005): crap-style comparison of commands (mean ± σ, min … max,
  outliers, delta with significance; hardware counters on Linux where the kernel allows), with
  hyperfine-style `--runs/--min-runs/--max-runs/--warmup`, `--setup/--prepare/--conclude/--cleanup`,
  `--parameter-list/--parameter-scan`, `--input`, `--bench-output`, `--env`, `--metrics`,
  `--export-json` and `--export-csv`. Library module `util_core.time`.

**New command: `less`**
- A streaming pager with the usual keys (scroll, search, follow), `-F -R -S -N -i -I`; it shows a pipe
  while it is still being written. Built in so paging works on Windows without a separate download.
  Library module `util_core.pager`; shared terminal layer `sys.Tty`.

**`cat`**
- Syntax highlighting out of the box: 73 built-in grammars of our own: C, C++, C#, Rust, Zig, Go, Java,
  Kotlin, Scala, Swift, Dart, Groovy, JavaScript, TypeScript, Python, Ruby, Perl, PHP, Lua, Julia, R,
  Elixir, Erlang, Clojure, Haskell, F#, Visual Basic, Pascal, Odin, Nim, Tcl, AWK, shell, PowerShell,
  batch, Vim script, SQL, HTML, XML, CSS, SCSS, Sass, Less, JSON, YAML, TOML, INI, generic config
  files, `.env`, Markdown, reStructuredText, AsciiDoc, LaTeX, Jinja, Handlebars, CSV, diff, Makefile,
  CMake, qmake, Meson, Ninja, Terraform/HCL, Nix, Protobuf, GraphQL, Dockerfile, git ignore,
  Verilog, VHDL, GLSL, HLSL and assembly.
- Themes: `--theme`, `--theme-dark`, `--theme-light`, `--list-themes`, `$BAT_THEME`; five built-in themes (`ansi`, `night`, `ember`, `day`, `paper`) with 24-bit colors reduced to 256/16 colors as the terminal allows; `auto` asks the terminal for its background color. User themes in `~/.config/cat/themes`.
- Git change markers in the line-number gutter (`changes` style, on by default), as in bat.
- Paging like bat: a long view goes through `$BAT_PAGER`/`$PAGER` or the built-in pager, which
  scrolls while `cat` is still writing; `--paging`, `-P`, `--pager`.
- The terminal view now matches bat 0.26.1's default: no `Size:` line (only `--style=full` adds
  it), and long lines and long file names wrap under a blank line-number column.
- Windows: the console is switched to ANSI escape processing and UTF-8 output before the view is drawn.

**Library**
- `sys.waitUsage` (child resource usage), `sys.Perf` (perf_event_open counters) and
  `sys.enableAnsiOutput` (Windows console setup).

**Platforms**
- The Windows console view of `cat` and the built-in pager (`less`) were checked on real Windows
  (Windows Terminal) with the 0.2.0 release candidate: ANSI colors, no stair-stepping, key input, scrolling.

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
