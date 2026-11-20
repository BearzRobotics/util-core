# diff: compatibility record

Status: complete for the GNU options except `--diff-program` (which diff does not have) and locale collation; verified against GNU diffutils 3.12. Date: 2026-11-20

## Reference

GNU diffutils 3.12 (`/usr/bin/diff --version` on the development machine). Consulted: the GNU manual chapters "Comparing and Merging Files" (normal, context, unified, ed, RCS, side by side, if-then-else formats, directories, options) and POSIX.1-2024 diff. The installed binary was probed for stdout, stderr and exit status; the FreeBSD diff (`tools/bsdrun.sh diff`) was looked at for ideas only. Behaviour was verified against the GNU binary (and, for algorithms, by reading the 3.12 sources for understanding only); no GNU code or text is copied: this project is GPL-2.0-or-later and independent.

## Supported options

- Styles: `--normal`, `-c/-C NUM/--context[=NUM]`, `-u/-U NUM/--unified[=NUM]`, `-NUM`, `-e/--ed`, `-f`, `-n/--rcs`, `-y/--side-by-side` with `-W`, `--left-column`, `--suppress-common-lines`, `--tabsize`, `-D/--ifdef`, `--line-format`, `--old/new/unchanged-line-format`, `--old/new/unchanged/changed-group-format` (all `%` directives of the manual).
- Content options: `-i -E -Z -b -w -B -I RE -a --strip-trailing-cr -d -H --horizon-lines`, `-p -F RE`, `--label`, `-t -T --suppress-blank-empty`, `--color[=WHEN] --palette` (default colours; the palette keys ad, de, hd, ln).
- Pagination: `-l/--paginate` passes each file's output through the project's own `pr` library (in process) with the title `diff OPTIONS NAME1 NAME2`, matching GNU's `pr -h` pipe including the header page layout.
- Reporting: `-q -s`, "Binary files differ" (NUL in the first 4096 bytes), "No newline at end of file", exit status 0/1/2.
- Directories: `-r -N --unidirectional-new-file --no-dereference -x -X -S --ignore-file-name-case --from-file --to-file`, "Only in", "Common subdirectories", file-type mismatch messages, "Symbolic links ... differ", the `diff -r ...` line before each file, labels replacing the first name.
- Diagnostics worded as GNU's, including the option errors with the "Try" line as its own diagnostic and the ed-style "No newline at end of file" warning (status 2).

## The algorithm

`src/lib/diffcore.zig` reproduces what GNU diff does, not a textbook Myers diff: lines are put in equivalence classes (a comparison key per line implements -i -b -w -Z -E), identical leading and trailing lines are cut off (keeping `horizon_lines`, at least the context size), lines matching nothing in the other file are discarded with GNU's run heuristics, the divide-and-conquer search stops at GNU's `too_expensive` cut-off (and uses the "big snake" heuristic with `--speed-large-files`), and the resulting change flags are slid with GNU's boundary-shifting rules. Memory is linear in the number of lines; there is no recursion; files over 1 GiB are refused.

## Measured agreement

Generated file pairs (random vocabulary, random edits, repeated and blank lines, trailing white space, CRLF, no trailing newline, empty files), each compared in 20 output configurations (normal, context, unified, ed, rcs, forward ed, side by side with three widths, -U 0/1/8, -C 1, -i -w -b -B -Z -E -d -H, --strip-trailing-cr, -D, a line format, -p, horizon): 99% agree byte for byte with GNU diff 3.12 (1539 of 1560 comparisons in the last 60-pair run; the differences were in the `-B -u` and `-D`/line-format cases listed under gaps and were being worked on). The three-way and side-by-side suites agree on all generated inputs.

## Extensions

- `--json` (not in GNU): see the man page. Refused with an output style or a layout option. Listed in `--help` as a non-GNU line. Tested by `test/test_diff_json.sh`, which rebuilds GNU's unified text from the JSON hunks.

## Known deviations and gaps

- `-l` uses the built-in page formatter, not a `pr` found on the path.
- File names are ordered bytewise (C locale), not by locale collation.
- Non-C locales are not modelled (character width, collation, the context-diff date format of a non-C `LC_TIME`).
- Files that are not regular (FIFOs, sockets, devices) inside a directory comparison are treated as identical when both sides have the same type.
- Time stamps in headers use the TZ rules of `tz.zig`; a non-regular standard input uses the current time, as GNU.
- Not run on Windows or macOS (the code uses `std.Io` only; no raw descriptors).

## Library

`util_core.diffcore` (lines, `compare` returning `Edit`s, `Flags`) and `util_core.diff`: `compareData` returns a `Compared` (line tables and `Item`s with the -B/-I verdict), `hunks` groups it into `Hunk`s of `HunkLine`s (kind context/removed/added, text, no_newline), `run` compares two operands (files, `-`, directories) and writes GNU text or JSON. No argument parsing and no process state.

## Tests

`sh test/test_diff.sh` (formats on fixed pairs, side-by-side widths, line formats, errors, standard input, directories, generated pairs; `NPAIRS` sets how many), `sh test/test_diff_json.sh`.
