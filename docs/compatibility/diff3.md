# diff3: compatibility record

Status: complete for the GNU options; verified against GNU diffutils 3.12. Date: 2026-11-20

## Reference

GNU diffutils 3.12 (`/usr/bin/diff3 --version` on the development machine). Consulted: the GNU manual nodes "Comparing Three Files", "Merging with diff3" and "Merging Incomplete Sets of Changes" (https://www.gnu.org/software/diffutils/manual/). The behaviour was settled by probing the installed binary (stdout, stderr, exit status).

## Supported options

- `-e/--ed`, `-E/--show-overlap`, `-3/--easy-only`, `-x/--overlap-only`, `-X`, `-A/--show-all`, `-i`, `-m/--merge`, `-a/--text`, `--strip-trailing-cr`, `-T/--initial-tab`, `-L/--label` (up to three, only with -E, -A and -m, as GNU), `-v/--version`, `--help`.
- The default report (`====`, `====1`, `====2`, `====3` stanzas with `N:RANGEc` lines), ed scripts in reverse order with the lone-dot protection (`..` plus `s/^\.//`), bracketed conflicts, the merged file, exit status 1 when a script or merge holds conflict markers.
- Option combinations: the six ed-style letters exclude each other and `-m` excludes `-i` ("incompatible options"); `-X` behaves as `-x` (GNU prints no brackets for it).
- Diagnostics worded as GNU's, including the `diff:` lines and "subsidiary program 'diff' failed (exit status 2)" for a missing file and "No newline at end of file" warnings for ed scripts.

## Extensions

- `--json` (not in GNU): `{files, conflicts, blocks}` with each block's `kind` (`unchanged`, `only-first`, `only-second`, `only-third`, `overlap`) and, for the three files, `start`, `count` and `lines`. Refused with the other output options. Listed in `--help` as a non-GNU line. Tested by `test/test_diff3_json.sh` against GNU's own report.

## Known deviations and gaps

- The comparison is built in (`diffcore`); `--diff-program` other than `diff` is refused.
- A binary input is reported as `diff failed: Binary files A and B differ` with the pair chosen as GNU does for the cases probed.
- Block merging follows the "touching blocks conflict" rule observed in GNU; unusual overlaps of several blocks of both comparisons were tested only on generated inputs.

## Library

`util_core.diff3`: `merge3` returns `Result` (three `Lines`, `Block`s with a `Kind` and a `Range` per file); `writeNormal`, `writeEd`, `writeMerge` and `writeJson` print it.

## Tests

`sh test/test_diff3.sh` (differential, fixed triples and generated triples), `sh test/test_diff3_json.sh`.
