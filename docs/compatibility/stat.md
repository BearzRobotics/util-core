# stat: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU stat 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/stat --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "stat invocation" (`info '(coreutils) stat invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/stat-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), stat, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/stat.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_stat.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Library

Module `util_core.stat` (`src/lib/stat.zig`); the executable `src/commands/stat.zig` is a thin wrapper that parses arguments and words the diagnostics (decision 0004).

## Supported options

- `-L, --dereference`: Follow symbolic links.
- `-f, --file-system`: Show file system status.
- `-c, --format=FORMAT / --printf=FORMAT`: Custom format (--printf interprets backslash escapes and prints no trailing newline).
- `-t, --terse`: Terse form.
- `--cached=MODE`: Accepted (statx sync flags are not passed on).
- `--help, --version`: Print help or version and exit.
- `--json` (extension, not in GNU): one JSON object per operand, one per line; with `-f`, the file-system fields. Cannot be combined with `-c`, `--printf` or `-t`. Listed in `--help` as a non-GNU line. Keys and value rules: `docs/decisions/0003-json-output.md`.

## Supported behaviour

- File data comes from statx(2) (including birth time); `-f` uses statfs(2) with GNU's file-system type table.
- Directives, printf-style flags/width/precision, `%N` quoting (QUOTING_STYLE honoured when a format is given; the quoting is that of the C locale, so in a UTF-8 locale non-ASCII characters are escaped where GNU prints them, and `locale` and `clocale` use ASCII quotes) and the `%X`-style fractional seconds follow GNU stat.c.

## Extensions

Per decision 0005 every departure from GNU is listed here.

- `--json`: one JSON object per operand. A long option GNU does not define, so it never changes the meaning of a GNU option; it is rejected (with a message) when combined with options that would define text layout or units, and is listed in `--help` as a non-GNU line. Off unless given; the default output is byte-for-byte GNU. Library callers get it through the `json` field of the options, default false. Covered by `test/test_stat_json.sh` (which also checks the GNU path through `test/test_stat.sh`). Rules: `docs/decisions/0003-json-output.md`.

## Known deviations and gaps

- `%C` reads the `security.selinux` attribute; without it GNU's `failed to get security context` diagnostic is reproduced.
- `%m` walks up the directory tree looking for a device change; bind mounts are not resolved through the mount table.
- With `-L`, `%m` of a link to a file is the mount point of the target. GNU 9.7 gives the mount point of the directory holding the link.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_stat.sh`: 989 differential cases against GNU stat 9.7 in the C locale. `sh test/test_stat_json.sh`: 254 cases that compare every `--json` field with what GNU stat prints for the same file (GNU has no `--json`, so this is not a text comparison).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
