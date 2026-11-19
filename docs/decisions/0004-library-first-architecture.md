# 0004: Library first; the executables are thin wrappers

Status: accepted by the maintainer. Date: 2026-11-19. Supersedes the
"extract only where reuse is meaningful" rule of decision 0003 (the `--json`
rules there still apply).

## Context

Until now each command's logic lived in `src/commands/<name>.zig`, mixed with
argument parsing and diagnostics, and `util_core` exported only helpers. The
maintainer's requirement: every command is usable as a Zig library on top of
`std.Io` (dksh, DKDE and other programs link it), and the executables are
wrappers. util-unix already works this way (its decision 0002).

## Decision

- Every command has a library module `src/lib/<name>.zig`, exported from
  `src/lib.zig` as `util_core.<name>` (for example `util_core.wc`).
- A library module takes `common.Env` (`std.Io` plus an allocator, optionally
  the environment map). It does **no argument parsing, no printing to a
  terminal, no `exit`, and changes no process-wide state** (signals, umask,
  environment, current directory).
- Output goes to a caller-supplied `*std.Io.Writer`; input comes from
  `common.Input` (a path, or an open `Io.File`) or a caller-supplied
  `*Io.Reader`. The library never touches `Io.File.stdout()` on its own.
- Problems that do not end the whole operation (an unreadable file, a skipped
  entry) are reported through a `common.Observer(Event)` callback that the
  command defines; the caller words and routes them. Fatal conditions are
  returned as errors. Results come back as values (`Result`, counts, lists).
- Options are a plain `Options` struct with defaults. The library has no
  notion of `argv`.
- Library modules may import `std`, `common.zig`, other library modules and
  the pure helper modules (`bytes`, `hash`, `numparse`, ...). They may call
  `sys.zig` for the facilities `std.Io` lacks (decision 0002) only when
  those are queries; they never call its signal or umask mutators. They do not
  import `cli.zig`.
- `src/commands/<name>.zig` is the wrapper: it parses `argv` exactly as GNU
  does (same validation order, so diagnostics match), builds the `Options`
  and inputs, calls the library, words observer events as GNU diagnostics, and
  turns the result into an exit status. `--help` and `--version` text and
  `cli.finish` handling stay in the wrapper.
- Unit tests of the logic live in the library module and run against
  `src/lib.zig` alone. Behaviour is verified by `test/test_<cmd>.sh` against
  GNU, unchanged by a refactor: a command is converted only when its suite
  passes before and after with identical counts.
- Where logic is shared by several commands (hashsum, baseenc, ...), the shared
  module is itself a library module and the per-command modules are thin.

## Build modes (same date)

`zig build -Dmode=standalone|multicall|all` selects what is installed:
one binary per command, only the `util-core` multicall binary, or both
(default). Applies to util-unix as well (binary `util-unix`). The library
module `util_core` is independent of the mode.

## First command: wc

`src/lib/wc.zig` holds the counters, the column-width rule, the table and
`--json` writers and `run(env, options, inputs, writer, observer)`.
`src/commands/wc.zig` is the argument parser and the diagnostics. Verified:
`test/test_wc.sh` 82/82 and `test/test_wc_json.sh` 46/46 before and after.

## Conversion status

Tracked in `docs/status.md`. Commands not yet converted keep their logic in
`src/commands/` and are still reachable through `util_core.commands`.
