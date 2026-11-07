# expand: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU expand 9.7 in the C locale. Date: 2026-11-06

## Reference

GNU coreutils 9.7 (`/usr/bin/expand --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-06: the GNU manual node "expand invocation" (`info '(coreutils) expand invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/expand-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), expand, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/expand.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_expand.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-i, --initial`: Convert only tabs before the first non-blank of each line.
- `-t, --tabs=N | LIST`: Tab stops every N columns (default 8), or a comma/blank separated list. The last item may be prefixed `/` (then every N columns) or `+` (then every N columns after the last stop); GNU extensions, see src/tabs.zig.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Backspace decrements the column (not below 0). A tab beyond the last stop of a plain list becomes one space.
- `-N` shorthand for `-t N` is accepted as in GNU.

## Known deviations and gaps

- Columns count bytes (C locale); multibyte and wide characters are not measured.
- `--help` text is GNU's, ASCII quotes in diagnostics.

## Tests

test/test_expand.sh (stdout, normalised stderr and exit status compared with GNU expand 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
