# comm: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU comm 9.7 in the C locale. Date: 2026-11-06

## Reference

GNU coreutils 9.7 (`/usr/bin/comm --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-06: the GNU manual node "comm invocation" (`info '(coreutils) comm invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/comm-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), comm, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/comm.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_comm.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-1, -2, -3`: Suppress column 1 (lines only in FILE1), 2 (only in FILE2) or 3 (in both).
- `--check-order / --nocheck-order`: Fail at once on unsorted input / never check. By default disorder is reported once per file, only when an unpairable line has been seen.
- `--output-delimiter=STR`: Separate columns with STR instead of TAB.
- `--total`: Print a summary line of the three counts.
- `-z, --zero-terminated`: Lines end with NUL instead of newline.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Either FILE may be `-` for standard input, but not both.
- Exit status 1 after a reported disorder ("input is not in sorted order"), as in GNU.

## Known deviations and gaps

- Comparison is bytewise (C locale); LC_COLLATE is not consulted.
- `--help` text and diagnostic quoting are ASCII; wording follows GNU 9.7.
- `-z` and `--total` are GNU extensions; POSIX specifies only `-1 -2 -3`.

## Tests

test/test_comm.sh (stdout, normalised stderr and exit status compared with GNU comm 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
