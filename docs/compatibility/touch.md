# touch: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU touch 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/touch --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "touch invocation" (`info '(coreutils) touch invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/touch-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), touch, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/touch.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_touch.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, -m, --time=WORD`: Which time to change.
- `-c, --no-create`: Do not create files.
- `-d, --date=STRING`: GNU date string (relative to the reference time with -r).
- `-t [[CC]YY]MMDDhhmm[.ss]`: POSIX time.
- `-r, --reference=FILE`: Use FILE's times.
- `-h, --no-dereference`: Change a symlink itself.
- `-f`: Ignored.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- `-` touches standard output. With neither -a nor -m, "-d now" behaves like no -d, as in GNU. Times are set with utimensat(2) to nanosecond precision.

## Known deviations and gaps

- The obsolete `touch MMDDhhmm file` form is not supported (GNU 9.7 itself only enables it for POSIX2 versions before 200112).
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_touch.sh`: 327 differential cases against GNU touch 9.7 in the C locale. Compares atime and mtime to the nanosecond for every explicit-time case.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
