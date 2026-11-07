# test: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU test 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/test --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "test invocation" (`info '(coreutils) test invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/test-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), test, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/test.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_test.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `! EXPR, ( EXPR ), EXPR -a EXPR, EXPR -o EXPR`: Negation, grouping, and, or.
- `-n, -z, STRING, = == != < >`: String tests and comparisons (bytewise).
- `-eq -ne -lt -le -gt -ge`: Integer comparisons of any length.
- `-nt -ot -ef`: Modification-time and same-file comparisons.
- `-e -f -d -b -c -p -S -h -L -s -g -u -k -r -w -x -O -G -N -t`: File and descriptor tests.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Follows GNU's structure exactly (found by differential testing): the POSIX rules for up to four arguments, the recursive grammar above that, and parenthesised groups judged by those rules too; syntax errors exit with status 2 and GNU's wording (`missing argument after 'x'`, `'x': binary operator expected`, `extra argument 'x'`, `')' expected, found 'x'`).
- As `[` the last argument must be `]`; `[ --help` and `[ --version` (without the bracket) print the help and version; `test --help` is just a true string.
- `-r -w -x` use access(2); `-O -G -N`, `-ef` and file-type tests use sys.fileStat (statx).

## Known deviations and gaps

- `-v` and `-R` (bash extensions) are not GNU test operators and are rejected as GNU does.
- `[ --version` prints a core-utils banner instead of GNU's.

## Tests

test/test_test.sh (5500 cases: 380 hand-written argument lists run both as `test` and as `[`, bracket error cases, and 2500 seeded random token sequences, each also as `[`) compared with GNU test 9.7.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
