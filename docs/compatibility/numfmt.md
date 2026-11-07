# numfmt: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU numfmt 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/numfmt --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "numfmt invocation" (`info '(coreutils) numfmt invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/numfmt-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), numfmt, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/numfmt.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_numfmt.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `--from=UNIT, --to=UNIT`: none, auto, si, iec, iec-i scaling.
- `--from-unit=N, --to-unit=N`: Unit sizes.
- `--round=METHOD`: up, down, from-zero, towards-zero, nearest.
- `--padding=N`: Pad (negative = left-align).
- `--format=FORMAT`: printf-style %f with flags, width, precision.
- `--field=FIELDS, -d, --delimiter=X`: Fields to convert.
- `--header[=N]`: Pass the first N lines through.
- `--suffix=SUFFIX`: Accept and add a suffix.
- `--invalid=MODE`: abort, fail, warn, ignore.
- `-z, --zero-terminated`: NUL line delimiter.
- `--debug`: Print warnings about invalid input.
- `--grouping`: Accepted; has no effect in the C locale.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Arithmetic is done in x87 extended precision like GNU's `long double`. Algorithm and constants follow GNU numfmt.c (coreutils 9.6 source, consulted 2026-11-07).

## Known deviations and gaps

- Only the C locale is supported (no thousands grouping).
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_numfmt.sh`: 2448 differential cases against GNU numfmt 9.7 in the C locale. Includes 1200 seeded random conversions.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
