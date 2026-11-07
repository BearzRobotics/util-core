# unexpand: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU unexpand 9.7 in the C locale. Date: 2026-11-06

## Reference

GNU coreutils 9.7 (`/usr/bin/unexpand --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-06: the GNU manual node "unexpand invocation" (`info '(coreutils) unexpand invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/unexpand-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), unexpand, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/unexpand.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_unexpand.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --all`: Convert all blank runs, not only leading ones.
- `--first-only`: Convert only leading blanks; overrides -a and the implied -a of -t.
- `-t, --tabs=N | LIST`: Tab stops as for expand; implies -a.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- A single space reaching a tab stop after non-blank text stays a space unless the run continues (a TAB would save nothing); matches GNU, checked with randomised differential tests.
- Held blanks that do not reach a stop are written unchanged.

## Known deviations and gaps

- Columns count bytes (C locale).
- `--first-only` is a GNU extension; POSIX specifies `-a` and `-t`.

## Tests

test/test_unexpand.sh (stdout, normalised stderr and exit status compared with GNU unexpand 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
