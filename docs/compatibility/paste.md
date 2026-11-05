# paste: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU paste 9.7 in the C locale. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/paste --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "paste invocation" (`info '(coreutils) paste invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/paste-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), paste, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/paste.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_paste.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-d, --delimiters=LIST`: Delimiters used circularly instead of TAB. Escapes: `\n`, `\t`, `\\`, `\0` (empty string).
- `-s, --serial`: Paste the lines of one file at a time.
- `-z, --zero-terminated`: Lines end with NUL instead of newline.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Parallel mode: the delimiter list restarts for every output line; an exhausted file acts as empty lines; output stops when all files are exhausted.
- Serial mode: one output line per file, the delimiter list restarts for every file; an empty file gives an empty line.
- Every `-` operand reads successive lines from the one standard input; with no operand standard input is used (GNU; POSIX requires an operand).
- A missing file stops processing before any output (exit 1), as GNU.

## Known deviations and gaps

- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.
- Windows and macOS untested.

## Tests

test/test_paste.sh (stdout, normalised stderr and exit status compared with GNU paste 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
