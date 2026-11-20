# cmp: compatibility record

Status: complete for the GNU options; verified against GNU diffutils 3.12. Date: 2026-11-19

## Reference

GNU diffutils 3.12 (`/usr/bin/cmp --version` on the development machine). Consulted: the GNU manual node "Invoking cmp" (https://www.gnu.org/software/diffutils/manual/html_node/Invoking-cmp.html) and POSIX.1-2024 cmp. Behaviour was settled by probing the installed binary (stdout, stderr, exit status) and is checked by `sh test/test_cmp.sh`.

## Supported options

- `-b, --print-bytes` (also `-c`, `--print-chars`, which GNU accepts without documenting): show the differing bytes.
- `-i SKIP[:SKIP2], --ignore-initial=...`: skip bytes; the largest of repeated values wins, as in GNU. Numbers are decimal, `0x` hexadecimal or `0` octal, with the multipliers `kB K MB M G T P E Z Y` (and `B`/`iB` forms); a value too large is the maximum, not an error.
- `-l, --verbose`: every difference; the byte-number column has the width of the digits of the smaller regular file (minus the skip).
- `-n, --bytes=LIMIT`, `-s, --quiet, --silent`, `-v, --version`, `--help`.
- SKIP1 and SKIP2 operands, `-` or a missing second operand for standard input.
- Messages: `A B differ: char N, line L` (`byte` with -b), `cmp: EOF on F after byte N, line L` / `in line L` / `which is empty` (stderr), `options -l and -s are incompatible`, `invalid --bytes value`, `invalid --ignore-initial value`, `extra operand`, `missing operand after`.
- Exit status 0, 1, 2 as GNU; two operands that are the same file (same inode and time, same skips) are equal without being read.

## Extensions

- `--json` (not in GNU): one object `{file1, file2, equal, bytes_compared, first_difference, eof, ...}`; with `-l` also `difference_count` and `differences`. Refused with `-b` and `-s` (they define a text layout or no output). Listed in `--help` as a non-GNU line. Rules: `docs/decisions/0003-json-output.md`. Tested by `test/test_cmp_json.sh` against GNU's text output.

## Known deviations and gaps

- The "same file" shortcut compares inode and modification time (std.Io has no device number); GNU also compares the device.
- A directory operand fails when it is first read ("Is a directory"), as in GNU, but a directory compared with itself is equal.
- Not run on macOS or Windows.

## Library

`util_core.cmp`: `compare(env, options, inputs, sink)` reports `Difference` and `Eof` events and returns a `Summary`; `run` formats them as GNU text or `--json`. No argument parsing, no process state.

## Tests

`sh test/test_cmp.sh` (differential against GNU cmp 3.12, 1216 cases including generated pairs), `sh test/test_cmp_json.sh` (30 checks).
