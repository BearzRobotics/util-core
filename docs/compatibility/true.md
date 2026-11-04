# true: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/true --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "true invocation" (`info '(coreutils) true invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/true-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), true, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/true.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_true.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--help`: Print usage to standard output and exit 0. Only recognised as the sole argument.
- `--version`: Print version to standard output and exit 0. Only recognised as the sole argument.

## Known deviations and gaps

- --help text is abbreviated compared with GNU's.
- Argument-ignoring and sole-argument rules follow GNU true.c from memory; not verified against the source.

## Tests

test/test_true.sh (exit code only)

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
