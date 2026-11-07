# tty: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU tty 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/tty --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "tty invocation" (`info '(coreutils) tty invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tty-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tty, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tty.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_tty.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-s, --silent, --quiet`: Print nothing; only the exit status.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Prints the target of /proc/self/fd/0 when standard input is a terminal, otherwise `not a tty`.
- Exit status 0 on a terminal, 1 when not, 2 for bad usage, 3 on a write error.

## Known deviations and gaps

- None known.

## Tests

test/test_tty.sh compared with GNU tty 9.7 (standard input is never a terminal under the test harness).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
