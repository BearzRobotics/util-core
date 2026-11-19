# date: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU date 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/date --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "date invocation" (`info '(coreutils) date invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/date-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), date, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/date.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_date.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Library

Module `util_core.date` (`src/lib/date.zig`); the executable `src/commands/date.zig` is a thin wrapper that parses arguments and words the diagnostics (decision 0004).

## Supported options

- `-d, --date=STRING`: Display the time described by STRING (GNU date input formats, TZ="..." prefix, @EPOCH).
- `-f, --file=DATEFILE`: Like -d for every line.
- `-r, --reference=FILE`: Display FILE's modification time.
- `-u, --utc, --universal`: Use UTC.
- `-I[FMT], --iso-8601, -R/--rfc-email, --rfc-3339=FMT`: Standard output formats.
- `--resolution`: Print the clock resolution (1 ns).
- `-s, --set=STRING / MMDDhhmm[[CC]YY][.ss]`: Set the clock (clock_settime; needs privilege).
- `+FORMAT`: strftime conversions with the GNU flags, widths, %N, %:z, %q.
- `--help, --version`: Print help or version and exit.
- `--json` (extension, not in GNU): one JSON object per date (one per line with `-f`) with `epoch`, `nsec`, `iso8601`, `year`, `month`, `day`, `hour`, `minute`, `second`, `weekday` (name), `weekday_number` (ISO: Monday 1, Sunday 7), `day_of_year` (1-based), `utc_offset` (seconds east of UTC), `zone` and `dst`. `-d`, `-f`, `-r` and `-u` and the TZ variable apply. Cannot be combined with a format (`+FORMAT`, `-I`, `-R`, `--rfc-3339`), `-s` or `--resolution`. Not listed in `--help`. Rules: `docs/decisions/0003-json-output.md`.

## Supported behaviour

- The input grammar of GNU parse-datetime.y (dates, times, zones, relative items, weekdays, ordinals, `ago`) is reproduced, including its quirks (e.g. `12:34:56 +1 month` takes +1 as a zone offset) and mktime-based validation of nonexistent local times.
- Zones: TZ unset = /etc/localtime, empty = UTC, names from /usr/share/zoneinfo (TZif v1-4 plus the POSIX rule footer), or a POSIX TZ string.

## Extensions

Per decision 0005 every departure from GNU is listed here.

- `--json`: one JSON object per date. A long option GNU does not define, so it never changes the meaning of a GNU option; it is rejected (with a message) when combined with options that would define text layout or units, and is absent from `--help`. Off unless given; the default output is byte-for-byte GNU. Library callers get it through the `json` field of the options, default false. Covered by `test/test_date_json.sh` (which also checks the GNU path through `test/test_date.sh`). Rules: `docs/decisions/0003-json-output.md`.

## Known deviations and gaps

- `--debug` is accepted and ignored (GNU prints the parse trace to standard error).
- Leap seconds are not modelled.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_date.sh`: 3755 differential cases against GNU date 9.7 in the C locale. Includes 1200 seeded random date strings in two zones and DST-boundary cases in three zones.

`sh test/test_date_json.sh`: 502 checks of `--json` against GNU date, field by field, for eight instants in five zones (UTC, New York, Kolkata, Adelaide, London), the UTC offset in seconds, DST, nanoseconds, `-u`, `-f`, `-r` and the refused combinations.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
