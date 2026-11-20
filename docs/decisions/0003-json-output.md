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
- `--json` is a long option only. It was first kept out of `--help`; since
  2026-11-19 it is listed there on one line marked "(not in GNU)" (find lists
  `-json` on an "Actions (not in GNU)" line) and in each man page. The
  differential `--help` tests drop exactly those lines before comparing with
  GNU's text (`help_cmp` in test/testlib.sh, `help_cmp_find`).
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

## Third command: du

`du` has one print point (`printSize`) for every line, and the path it is
given is a temporary that is freed right after, so each entry is serialized
as it is produced (`diskusage.writeEntry`) into a buffer that is written when
the walk ends. The traversal and the text path are untouched. `diskusage.zig`
(exported as `util_core.diskusage`) holds `Entry` and the writer. Verified:
`test/test_du.sh` 315/315 before and after; `test/test_du_json.sh`.

## Fourth command: ls (with dir and vdir)

`ls` already collects a `FileInfo` per file (with the `sys.FileStat`), sorts
the list and then dispatches on the format, so `--json` is a branch in
`printCurrentFiles` that prints the sorted list through `fileinfo`. Directory
headers, the `total` line and the blank separators are suppressed, and the
array brackets are written by the first and last entry. `--json` selects the
`-l` format internally, so every field is available and symlinks are not
followed by default (a symlink to a directory is listed as a link; `-L`/`-H`
change that). That is a deliberate difference from plain `ls`, which follows a
command-line symlink to a directory. Presentation options are accepted and
have no effect; they are not refused, because there are dozens and ls users
combine them freely. Verified: `test/test_ls.sh` 1291/1291, `test_dir.sh` and
`test_vdir.sh` 38/38, `test/test_ls_json.sh`.

## Fifth group: wc, printenv, date and the checksum tools

These need no restructuring of the text path. Each gets a small library module
holding the data and its writer (`wordcount`, `dateinfo`, `digestinfo`;
`printenv` uses `json` directly) and a hook where the command already has the
finished values. Choices that follow decision 0007:

- `wc`, the checksum tools and `date` report per input, so one object per line.
  Only the selected counts of `wc` are present (an unselected count is absent,
  not null, because null means unknown).
- `factor` was left out: its numbers can exceed 128 bits and JSON numbers are
  not exact past 2^53, so every value would have to be a string, and the text
  form is already trivial to parse. `users` (covered by `who --json`) and
  `locate` (`@(locate x)` already yields the list) were left out too.
- `date --json` is refused with any format option, since the fields are fixed.
- Found by the unit test, not by GNU comparison: Zig prints a signed integer
  with a fill width as `+2009`, so the year is clamped to unsigned before
  formatting (`dateinfo.zig`).
- `wc` keeps its documented deviation from GNU (code points for `-m`, ASCII
  whitespace for words); the JSON reports this wc's counts, and the test
  compares with GNU only where the deviation does not apply.

Verified: the GNU text baselines of all these commands unchanged (wc 82, printenv
14, the digest tools 116 each, cksum 556, date 3755), plus the four `--json`
test scripts.

## Sixth: find

`find` is an expression evaluator, so the natural form is an action, not a
global flag: `-json` is a primary like `-print` that prints one object per
file, streamed, with the same fields as `ls --json` (`printJson` in
`find.zig`, over `fileinfo`). It is the streaming form decision 0007 left open
for `find`: one object per line, not an array. The traversal, the tests and
the existing actions are untouched. Verified: `test/test_find.sh` 1987/1987
before and after; `test/test_find_json.sh`.

## Seventh: tree (no new flag)

`tree` is not a GNU command and already has structured output: `-J` (JSON)
and `-X` (XML), compatible with tree 2.3.1, which is installed here and is the
reference. A `--json` flag would only duplicate `-J`, so none was added;
scripts should use `tree -J`. Its shape (nested `contents`, a final `report`
object) is the reference's, not decision 0007's: compatibility with the
reference wins for a command that is a clone of an existing program.

Comparing `-J`/`-X` with the real tree on more option combinations found four
gaps in util-core's tree, all fixed and now covered by the differential test:
`-f` must put the full path in `name`; `-h` and `--si` write the JSON size as
a string; the time is the text listing's format and honours `--timefmt` (ours
had printed an ISO timestamp in JSON and ignored `--timefmt`); and `--du` adds
the total to the report (and exits 0 with an unreadable directory, as the
text listing does). Differences left alone are listed in
docs/compatibility/tree.md. Verified: `test/test_tree.sh` 741/741 (657 before).

## Consequences

- Every later command adds one library module and one test script in the same
  pattern; the key names for file metadata (`mode_octal`, `atime_nsec`,
  `link_target`, ...) are fixed by `fileinfo` and reused by ls, find and du.
- A name that is not valid UTF-8 appears with U+FFFD in `name`. Convention 5
  of decision 0007 (`name_bytes`) is not implemented yet for stat; the
  limitation is listed here so it is not forgotten.
