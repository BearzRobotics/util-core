# cut: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU cut 9.7 in the C locale. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/cut --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "cut invocation" (`info '(coreutils) cut invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cut-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cut, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cut.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_cut.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-b, --bytes=LIST`: Select these bytes.
- `-c, --characters=LIST`: Select these characters. In this implementation characters are bytes, so -c is the same as -b (as GNU in a single-byte locale).
- `-f, --fields=LIST`: Select these fields; lines without the delimiter are printed unchanged unless -s.
- `-d, --delimiter=DELIM`: Field delimiter, a single byte (default TAB).
- `-s, --only-delimited`: With -f, do not print lines that contain no delimiter.
- `--output-delimiter=STRING`: Separator printed between selected fields or, with -b/-c, between separate ranges. An empty string means a NUL byte (GNU).
- `--complement`: Select everything except LIST.
- `-n`: Accepted and ignored.
- `-z, --zero-terminated`: Lines end with NUL instead of newline.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- LIST elements: `N`, `N-M`, `N-`, `-M`, separated by commas or blanks; overlapping elements are merged and output follows input order, each position once (POSIX).
- A final line without a newline gets one.
- Diagnostics for bad lists reproduce GNU's wording (`invalid byte/character position 'a'`, `invalid decreasing range`, `fields are numbered from 1`, ...).

## Known deviations and gaps

- Multibyte (UTF-8) characters are not interpreted: -c and -n behave as in a C locale.
- `--help` text is shorter than GNU's; diagnostics use ASCII quotes (GNU uses curly quotes in UTF-8 locales).
- Windows and macOS untested.

## Tests

test/test_cut.sh (stdout, normalised stderr and exit status compared with GNU cut 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
