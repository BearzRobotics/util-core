# head: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU head 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/head --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "head invocation" (`info '(coreutils) head invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/head-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), head, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/head.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_head.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-c, --bytes=[-]NUM`: Print the first NUM bytes; with a leading `-`, all but the last NUM bytes.
- `-n, --lines=[-]NUM`: Print the first NUM lines (default 10); with a leading `-`, all but the last NUM lines.
- `-q, --quiet, --silent`: Never print file name headers.
- `-v, --verbose`: Always print file name headers.
- `-z, --zero-terminated`: Lines end with NUL instead of newline.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- NUM suffixes b, kB, K, KiB, M, MB, MiB, G, T, P, E, Z, Y, R, Q (GNU manual "Block size"); counts that overflow 64 bits mean "unbounded".
- Headers `==> NAME <==` for several files (`standard input` for `-`), with a blank line between files (POSIX format).
- Obsolete `-NUM[bkm][cqv]` accepted only as the first argument.
- POSIX 1.4: when head stops early on a seekable standard input, the file offset is left just past the last byte it output, so `(head -n1; cat) < file` works (verified against GNU).
- Last of -c / -n wins. Unreadable files are reported and processing continues (exit 1). A directory is reported as `error reading ...: Is a directory`.

## Known deviations and gaps

- `-c -N` / `-n -N` hold the last N items in memory (as GNU does for non-seekable input).
- `--help` text is shorter than GNU's; diagnostics use ASCII quotes (GNU uses curly quotes in UTF-8 locales).
- Multibyte characters are not interpreted: -c counts bytes and lines are split on a single delimiter byte, as in GNU.
- Windows and macOS untested.

## Tests

test/test_head.sh (stdout, normalised stderr, exit status compared with GNU head 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
