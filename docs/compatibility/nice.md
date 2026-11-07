# nice: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU nice 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/nice --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "nice invocation" (`info '(coreutils) nice invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/nice-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), nice, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/nice.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_nice.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-n, --adjustment=N`: Add N to the niceness (default 10); also the obsolete forms -N and --N.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- With no COMMAND the current niceness is printed; with an adjustment and no COMMAND it is an error.
- If the priority cannot be changed because of permissions a warning is printed and COMMAND still runs; the result is clamped to -20..19.

## Known deviations and gaps

- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_nice.sh`: 30 differential cases against GNU nice 9.7 in the C locale. 

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
