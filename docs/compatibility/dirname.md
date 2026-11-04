# dirname: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/dirname --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "dirname invocation" (`info '(coreutils) dirname invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/dirname-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), dirname, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/dirname.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_dirname.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-z, --zero`: End each output line with NUL instead of newline.
- `--help, --version`: Sole argument only.

## Known deviations and gaps

- Only / is a path separator, including on Windows.
- //, a POSIX-implementation-defined path, prints / .

## Tests

test/test_dirname.sh; unit test in src/commands/dirname.zig

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
