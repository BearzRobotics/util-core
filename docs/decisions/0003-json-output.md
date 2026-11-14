# 0003: `--json` output, and extracting data into the library

Status: proposed (branch `structured-output`). Date: 2026-11-14

## Context

The commands in `src/commands/` mix argument parsing, data gathering and
printing, so `util_core` exports helpers but no command results. The
maintainer wants structured output for the commands whose output is records
(stat, ls, df, du, find, ...), usable both as `--json` and as a Zig library
(from dksh and DKDE). ai/SPECS.md 6.1 asks for extraction "where reuse is
meaningful", not for every command.

## Decision

- The shared rules for every `--json` command (which commands qualify,
  framing, key names, value types, errors) are util-unix decision 0007. They
  apply here unchanged.
- Extract per command, only for commands that get `--json`. Data and its
  formatting move into a library module that prints nothing and reads no
  process state; the command keeps argument parsing, diagnostics and the GNU
  text path.
- The text path is not rewritten. If the command already has a data struct
  (stat: `sys.FileStat`, `sys.StatFs`) the library module consumes it. If it
  does not (ls, df, du, find), the command is split first, behind its GNU
  differential suite, before any JSON is added.
- `--json` is a long option only and is absent from `--help`, whose text is
  compared with GNU's.
- `src/json.zig` is a copy of util-unix `src/lib/json.zig`. Two small copies
  are cheaper than a package for one 70-line file; revisit if a third
  consumer appears.

## First command: stat

`src/fileinfo.zig` (exported as `util_core.fileinfo`) now owns `fileType`,
`modeString` and the file-system type table, moved out of `stat.zig` without
change, plus `writeJson` and `writeFsJson`. `stat.zig` aliases the moved
names, so the GNU text path is the same code. Verified: `test/test_stat.sh`
989/989 against GNU stat 9.7 before and after, and `test/test_stat_json.sh`
compares every JSON field with GNU's own value.

## Second command: df

`df` builds string cells for its table, so there was no data struct to reuse.
`getDev` now also records a numeric `fsusage.Entry` beside each row it adds
(same order, same filtering, so the entry list is exactly the rows `df` would
print), and `--json` prints the entries instead of the table. The text table
code is untouched. `fsusage.zig` (exported as `util_core.fsusage`) holds the
`Entry` type and the writer. Units are fixed (bytes and plain counts), so
`--json` is refused with the block-size, human-readable, inode, portability,
type and `--output` options, which only change the text layout.
Verified: `test/test_df.sh` 290/290 before and after; `test/test_df_json.sh`.

## Consequences

- Every later command adds one library module and one test script in the same
  pattern; the key names for file metadata (`mode_octal`, `atime_nsec`,
  `link_target`, ...) are fixed by `fileinfo` and reused by ls, find and du.
- A name that is not valid UTF-8 appears with U+FFFD in `name`. Convention 5
  of decision 0007 (`name_bytes`) is not implemented yet for stat; the
  limitation is listed here so it is not forgotten.
