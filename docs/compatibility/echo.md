# echo: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/echo --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "echo invocation" (`info '(coreutils) echo invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/echo-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), echo, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/echo.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_echo.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-n`: Do not output the trailing newline.
- `-e`: Interpret backslash escapes: \\a \\b \\c \\e \\f \\n \\r \\t \\v \\\\ \\0NNN (up to 3 octal digits) \\xHH (1-2 hex digits). \\c stops all further output.
- `-E`: Do not interpret escapes (default). Last of -e/-E wins.
- `--help, --version`: Recognised only as the sole argument.

## Known deviations and gaps

- POSIXLY_CORRECT / XSI behaviour (where echo interprets escapes by default) is not implemented.
- \\NNN octal without a leading 0 is printed literally.

## Tests

test/test_echo.sh

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
