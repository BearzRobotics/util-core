# pr: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU pr 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/pr --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "pr invocation" (`info '(coreutils) pr invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/pr-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), pr, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pr.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_pr.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `+FIRST[:LAST], --pages`: Page range.
- `-COLUMN, --columns`: Columns, down unless -a.
- `-a, --across / -m, --merge`: Columns across / files side by side.
- `-d, -f/-F, -t, -T, -h, -l, -w, -W, -o, -s, -S, -J`: Layout controls.
- `-n[SEP[DIGITS]], -N`: Line numbers.
- `-e, -i, -c, -v`: Tabs and non-printing characters.
- `-D FORMAT`: Date format of the header (strftime, with the GNU extensions).
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Follows the structure of GNU pr.c function by function (page loop, stored columns with balancing, merge mode, form-feed handling), so output matches. The header date is the file's modification time in the zone given by TZ (default /etc/localtime), or the current time for standard input.

## Known deviations and gaps

- Widths count bytes (C locale).
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_pr.sh`: 1371 differential cases against GNU pr 9.7 in the C locale. 500 random option combinations, several time zones, form feeds in every position.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
