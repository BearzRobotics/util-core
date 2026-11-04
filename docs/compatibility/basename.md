# basename: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/basename --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "basename invocation" (`info '(coreutils) basename invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/basename-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), basename, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/basename.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_basename.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --multiple`: Treat every operand as a NAME.
- `-s, --suffix=SUFFIX`: Remove SUFFIX; implies -a.
- `-z, --zero`: End each output line with NUL instead of newline.
- `--help, --version`: Sole argument only.

## Known deviations and gaps

- Only / is a path separator, including on Windows.
- Abbreviated long options (e.g. --mult) are not accepted.

## Tests

test/test_basename.sh; unit test in src/commands/basename.zig

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
