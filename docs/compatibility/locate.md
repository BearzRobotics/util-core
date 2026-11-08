# locate: compatibility record

Status: implemented; differential tests pass against GNU locate 4.10.0 (C locale). Date: 2026-11-07

## Reference

GNU findutils 4.10.0 (`locate`/`updatedb`). The oracle binaries are built from the findutils-4.10.0 source tarball by `tools/build-gnu-findutils.sh` into `~/.cache/util-core/findutils`; the suites skip if that is absent. Behaviour was checked against the GNU binaries run with LC_ALL=C. Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-d, --database=PATH`: Colon-separated list of databases (default LOCATE_PATH, then /usr/local/var/locatedb).
- `-b, --basename / -w, --wholename`: Match the base name only, or the whole path (default).
- `-i, --ignore-case`: Case-insensitive matching.
- `-r, --regex / --regextype=TYPE`: Patterns are regular expressions of the given findutils dialect.
- `-A, --all`: All patterns must match (default: any).
- `-c, --count, -l N, --limit=N`: Print only a count, or stop after N matches.
- `-e, -E, --existing, --non-existing`: Only print entries that still exist (or no longer exist).
- `-S, --statistics, -0, --null, -p, --print, -H, -P, -L, -m, -s`: Statistics, NUL separators, follow/nofollow for -e, accepted compatibility options.
- `--max-database-age D`: Warning threshold for old databases.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Reads LOCATE02 and slocate databases (front-coded names) and prints matching entries; glob patterns use fnmatch, other patterns are substring matches.
- Exit status 0 when something matched (or with -c/-S/--limit=0), 1 otherwise.

## Known deviations and gaps

- The old (bigram) database format is not supported.

## Tests

`sh test/test_locate.sh`: about 1580 differential cases against GNU locate 4.10.0 on databases built by GNU updatedb from a fixture tree.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
