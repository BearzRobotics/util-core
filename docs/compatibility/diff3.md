# diff3: compatibility record

Status: complete for the GNU options; verified against GNU diffutils 3.12. Date: 2026-11-20

## Reference

GNU diffutils 3.12 (`/usr/bin/diff3 --version` on the development machine). Consulted: the GNU manual nodes "Comparing Three Files", "Merging with diff3" and "Merging Incomplete Sets of Changes" (https://www.gnu.org/software/diffutils/manual/). The behaviour was settled by probing the installed binary (stdout, stderr, exit status); the 3.12 sources were read for understanding of the algorithm only (no code or text copied; this project is GPL-2.0-or-later and independent).

## Supported options

- `-e/--ed`, `-E/--show-overlap`, `-3/--easy-only`, `-x/--overlap-only`, `-X`, `-A/--show-all`, `-i`, `-m/--merge`, `-a/--text`, `--strip-trailing-cr`, `-T/--initial-tab`, `-L/--label` (up to three, only with -E, -A and -m, as GNU), `-v/--version`, `--help`.
- The default report (`====`, `====1`, `====2`, `====3` stanzas with `N:RANGEc` lines), ed scripts in reverse order with the lone-dot protection (`..` plus `s/^\.//`), bracketed conflicts, the merged file, exit status 1 when a script or merge holds conflict markers.
- Option combinations: the six ed-style letters exclude each other and `-m` excludes `-i` ("incompatible options"); `-X` behaves as `-x` (GNU prints no brackets for it).
- Diagnostics worded as GNU's, including the `diff:` lines and "subsidiary program 'diff' failed (exit status 2)" for a missing file and "No newline at end of file" warnings for ed scripts.

## Extensions

- `--json` (not in GNU): `{files, conflicts, blocks}` with each block's `kind` (`unchanged`, `only-first`, `only-second`, `only-third`, `overlap`) and, for the three files, `start`, `count` and `lines`. Refused with the other output options. Listed in `--help` as a non-GNU line. Tested by `test/test_diff3_json.sh` against GNU's own report.

## Known deviations and gaps

- The comparison is built in (`diffcore`, run as `diff --horizon-lines=100` would) unless `--diff-program` names another program, which is run as GNU runs it (`PROGRAM [-a] [--strip-trailing-cr] --horizon-lines=100 ---no-directory -- OTHER COMMON`) and whose normal-format output is parsed; the line text still comes from the files, so a program whose output contradicts the files can differ from GNU.
- Like GNU, the common file of the two comparisons is the third file for the default report and the middle file for ed scripts and merges, and the comparisons run from the other file to the common one.
- A binary input is reported as `diff failed: Binary files A and B differ`, naming the pair GNU's order of comparisons reaches first.
- With an ed script and a binary input, GNU may print "No newline at end of file" notes from the comparison that ran before the failing one; we print none (8 of 300000 generated comparisons).
- Block merging follows the "touching blocks conflict" rule observed in GNU; unusual overlaps of several blocks of both comparisons were tested only on generated inputs.

## Measured agreement

Generated triples (text of several vocabularies, whitespace and case variants, code-like lines, blank-heavy, CRLF and mixed line ends, binary, very long lines, repetitive 20-60k-line files, empty files, missing final newlines): 20000 triples in 15 option sets, 299992 of 300000 comparisons byte-identical (stdout, stderr, status) to GNU diff3 3.12; the 8 differences are the binary-with-ed-script case above.

## Library

`util_core.diff3`: `merge3` returns `Result` (three `Lines`, `Block`s with a `Kind` and a `Range` per file); `writeNormal`, `writeEd`, `writeMerge` and `writeJson` print it.

## Tests

`sh test/test_diff3.sh` (differential, fixed triples and generated triples), `sh test/test_diff3_json.sh`.
