# wc: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/wc --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "wc invocation" (`info '(coreutils) wc invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/wc-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), wc, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/wc.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_wc.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-l, --lines`: Newline count.
- `-w, --words`: Word count.
- `-m, --chars`: UTF-8 code-point count (bytes that are not continuation bytes), independent of locale.
- `-c, --bytes`: Byte count. Used alone on a regular file with a nonzero size it is taken from the file size without reading (GNU does the same). `-l` alone counts newlines with a vector loop. A directory operand prints a line of zeros plus the "Is a directory" error, as GNU does.
- `-L, --max-line-length`: Longest line: tabs advance to multiples of 8; printable ASCII has width 1, all other bytes width 0 (C-locale behaviour).
- `--json` (extension, not in GNU): one JSON object per input and a last one with `total: true` when there is more than one, one per line. `file` is null for standard input read without an operand. Only the selected counts are present (`lines`, `words`, `chars`, `bytes`, `max_line_length`); with no selection, lines, words and bytes. The counts are this wc's (see its deviations): `-m` counts UTF-8 code points and words split on ASCII whitespace, whatever the locale. Not listed in `--help`. Rules: `docs/decisions/0003-json-output.md`.

## Known deviations and gaps

- --files0-from and --total are rejected with an error (not implemented).
- Column width follows GNU's rule (sum of st_size of regular-file inputs; width at least 7 if any input is not a regular file; unopenable inputs ignored), checked against GNU wc 9.7 for files, stdin redirected from a file, pipes and /dev/null. POSIX leaves the width unspecified.
- Output is buffered until all inputs are read, so with `2>&1` an error message appears before the lines of earlier files; GNU interleaves them in input order. The content of each stream is identical.
- Locale-specific multibyte widths (e.g. East Asian wide characters) are not handled.

## Tests

test/test_wc.sh (differential against GNU wc 9.7, including column width for regular-file stdin, pipe and /dev/null); unit test for the scanner; manual comparison of -l -w -m -c -L

`sh test/test_wc_json.sh`: 46 checks of `--json` against GNU wc counts (ASCII inputs for every count, binary and UTF-8 inputs for lines, bytes and `-L`) and against this wc's own text output where the documented locale difference applies; keys, totals, stdin, directories, errors and refused combinations.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
