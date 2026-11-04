# sleep: compatibility record

Status: implemented; differential tests pass against GNU sleep 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/sleep --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "sleep invocation" (`info '(coreutils) sleep invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sleep-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), sleep, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sleep.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_sleep.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--help, --version`: Print help or version and exit.

## Supported behaviour

- One or more NUMBER[smhd] operands, summed (GNU extension; POSIX requires only one non-negative integer of seconds).
- NUMBER may be fractional, in exponent form, hexadecimal, or `inf`.
- Negative values, NaN and empty or malformed operands are rejected with `invalid time interval`.

## Known deviations and gaps

- POSIX allows exit status 0 on SIGALRM; no special SIGALRM handling here (the default action terminates the process).
- Number parsing uses the C locale only (GNU also tries the current locale's decimal point).
- A total that overflows a 96-bit nanosecond count is treated as `inf`.
- --help text is shorter than GNU's.

## Tests

test/test_sleep.sh (stdout, normalised stderr and exit status compared with GNU sleep 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
