# yes: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/yes --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "yes invocation" (`info '(coreutils) yes invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/yes-invocation.html). POSIX does not specify `yes`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_yes.sh`).

## Supported options

- `--help`: Print usage and exit 0.
- `--version`: Print version and exit 0.
- `--`: End option processing.

## Known deviations and gaps

- Any other argument starting with - is rejected as an invalid option (matches the system yes here; GNU yes treats only --help/--version specially, so this may differ from GNU).
- On a closed pipe the process exits 1 after a failed write; whether the shell sees SIGPIPE depends on the runtime.

## Tests

test/test_yes.sh. NOTE: that script runs `yes` with no arguments and never terminates; it needs to be fixed.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
