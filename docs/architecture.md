# Architecture

Describes what is implemented now (not the target in `ai/SPECS.md`). Update it
with every structural change.

- Toolchain: Zig 0.17.1 (`zig version`). APIs were checked against the
  standard-library source shipped with that toolchain
  (`~/.zvm/0.17.1/lib/std`).
- Binary size: the floor is std's `Io` runtime (`std.process.Init` starts
  `Io.Threaded`, about 75 KB of code, plus the allocator and start-up code),
  which the project deliberately keeps using (decision 0002, ai/AGENTS.md §13);
  it should shrink as std.Io matures. Release builds drop stack-trace support
  and the segfault handler (`std_options`/`panic` in exe.zig and multicall.zig),
  worth about 3 KB per binary. Stripped `true` is 233 KB in ReleaseFast and
  149 KB in ReleaseSmall (GNU's dynamically linked 35 KB excludes libc); the
  multicall `main` holds all commands in 513 KB (ReleaseSmall).
- Build: release modes strip command executables by default (`-Dstrip=false`
  keeps debug info); Debug builds are never stripped by default.
- Commands implemented: `true`, `false`, `yes`, `echo`, `basename`, `dirname`,
  `cat` (GNU baseline, no enhancements yet), `wc` (see its header comment for
  deviations).

## Layout

```
build.zig            build graph: per-command exes, multicall exe, tests
src/
  cli.zig            Context, --help/--version helpers, diagnostics, Out
                     (sticky-error buffered stdout), openInput/readChunk
                     ("-" = stdin), errText (strerror-style wording)
                     matchLong/badLong/invalidShort (getopt-style long
                     option matching and GNU diagnostics), giveBack
                     (POSIX 1.4 offset, via the Io vtable's fileSeekBy)
  sys.zig            the only place that touches std.posix/std.os: signal
                     dispositions, umask, terminal width, pid probe, O_APPEND
                     open (no std.Io equivalents in Zig 0.17.1)
  lines.zig          LineReader: arbitrarily long delimiter-terminated lines
                     (cut, paste, uniq, fold-style filters, nl)
  count_arg.zig      [+|-]NUM[suffix] parsing for head/tail (GNU "Block size")
  fmt_float.zig      exact C printf %e/%f/%g for doubles (seq; later printf)
  mode.zig           chmod/mkdir -m mode parsing (octal and symbolic)
  commands.zig       registry: `all` (names) + `modules` (imports) + get/find
  commands/<name>.zig  one frontend per command: pub fn main(ctx) u8
  exe.zig            entry point of an individual executable
  multicall.zig      entry point of the multicall executable
  test_all.zig       unit-test root
test/                shell tests (test_<cmd>.sh, testlib.sh, run_all_tests.sh)
docs/                this file, decisions/, manpages/
```

## Data flow

```
 individual exe (exe.zig)          multicall exe (multicall.zig)
   build option `command`            argv[0] basename in enabled list? -> run
          │                          else argv[1] is the command name
          ▼                                   │
   commands.get(name) ───────────────► commands.find(enabled, name)
          │
          ▼
   cli.Context{ name, args, io, gpa } ──► command main(ctx) ──► exit status
```

`std.process.Init` (Zig 0.17 "juicy main") supplies `io`, `gpa` and the
argument vector; the entry points convert these into a `cli.Context` and
nothing below them touches process-wide state. Commands therefore run
identically in both modes, and the same unit and shell tests cover both
(SPEC §7).

## Build

- `zig build` installs one executable per command plus `main`.
- `-Dcommands=a,b` restricts the set; unknown names fail the build.
- `exe.zig` receives its command through a generated `build_options` module;
  the multicall binary receives the enabled list the same way. Only commands
  referenced through `commands.get` are compiled in.
- `@import` needs string literals, so adding a command means: create
  `src/commands/<name>.zig`, then add it to both `all` and `modules` in
  `src/commands.zig`.
- Nothing in `build.zig` depends on the host OS; `-Dtarget=x86_64-windows`
  builds (verified for the three current commands; not run on Windows).

## Conventions for command frontends

- Parse arguments, pick streams, return the exit status. Reusable logic goes in
  a separate function/module that takes explicit allocators and readers/writers
  and never exits or writes to stdout implicitly (SPEC §6.1).
- Diagnostics go to stderr through `cli.warn`, prefixed with the command name.
- Streams are read in 64 KiB chunks and written through `cli.Out`; commands
  never load whole inputs. Per-file open/read errors are reported as
  `<name>: <file>: <reason>`, processing continues, and the exit status is 1.
- Pure helpers (`baseName`, `dirName`, the `cat` formatter, the `wc` scanner)
  are separate functions with unit tests.
- Output failure (e.g. closed pipe) returns a non-zero status instead of
  panicking.

## Dependencies

No external dependencies yet. Planned: `regex-zig` (`~/de/regex-zig`) for
`grep`/`sed`. Until it has a release it is referenced by local path in
`build.zig.zon`; it will later be fetched as a vendored GitHub tarball with a
pinned hash. Zig-native API first; any C FFI is later and optional.

## Testing

- `zig build test` runs unit tests from `src/test_all.zig`.
- `test/testlib.sh` also provides `run_cmp` (stdout, stderr and exit status
  compared separately) and `run_tree` (also compares the resulting file tree,
  for mkdir/rmdir-style commands) and caps file sizes with `ulimit -f`.
- `sh test/test_<cmd>.sh` compares our binary in `zig-out/bin/` against
  `/usr/bin/<cmd>`, which must be GNU coreutils (`testlib.sh` refuses to run
  otherwise). Differential checks show agreement with one GNU build; they are
  not by themselves conformance evidence, so each command's compatibility record
  also cites the GNU manual and POSIX.1-2024 pages it was checked against.
- echo, basename, dirname, cat, wc, true, false, yes, dircolors, pwd, printenv, sleep, tee, head, tac, tail, seq, mkdir, rmdir, cut, paste, uniq, fold, nl and tr pass
  against GNU coreutils 9.7, plus manual `cat`/`wc` comparisons on a binary
  file (`-A -n -b -s -T -e`, `-l -w -m -c -L`).
- Tests are not yet run for both dispatch modes (SPEC §11).

## Known gaps

- No per-command compatibility records (`docs/compatibility/`) or manpages yet.
- No CI; Windows and macOS are unverified.
- Only the minimal `--help`/`--version` text exists; the version string is
  `0.0.0-dev`.

## Shared helpers added with the process commands

- `src/getopt.zig`: getopt_long-compatible parser (permutation, bundling,
  unique-prefix long options, glibc diagnostics). New commands use it instead of
  hand-written loops. `--help`/`--version` are built in.
- `src/exec.zig`: runs another program. It searches PATH in the *modified*
  environment (std.process.replace does not) and reports failures in the GNU
  styles of env (`'x': No such file or directory`) and nohup/chroot/stdbuf
  (`failed to run command 'x': ...`).
- `src/help/<cmd>.txt`: `--help` text, generated from GNU by `tools/mkhelp.sh`
  (without the GNU project footer) and embedded with `@embedFile`.

## Library module

`build.zig` exports a `util_core` module (root `src/lib.zig`) for dependants:
`dep.module("util_core")`. It re-exports `cli` (the `Context` every command
takes), the command registry (`commands.get("echo")(ctx)`), `getopt`, `tz`,
`strftime`, `datetime`, `fmt_float`, `posixre`, `hash` and `mode`. Everything
else under `src/` is internal and may change. The module imports the `regex`
package, which the build wires in.
