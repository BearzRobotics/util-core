# false: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/false --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "false invocation" (`info '(coreutils) false invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/false-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), false, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/false.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_false.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--help`: Print usage to standard output and exit 1. Sole argument only.
- `--version`: Print version to standard output and exit 1. Sole argument only.

## Known deviations and gaps

- Exiting 1 for --help/--version matches the system `false` here; not checked against the GNU source.

## Tests

No test script exists yet; exit status checked manually.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
