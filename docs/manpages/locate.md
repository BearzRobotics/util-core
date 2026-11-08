% LOCATE(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
locate - find files by name in a prebuilt database

SYNOPSIS
locate [OPTION]... PATTERN...
locate --help | --version

DESCRIPTION
Find files by name in a prebuilt database.

OPTIONS
-d, --database=PATH
: Colon-separated list of databases (default LOCATE_PATH, then /usr/local/var/locatedb).

-b, --basename / -w, --wholename
: Match the base name only, or the whole path (default).

-i, --ignore-case
: Case-insensitive matching.

-r, --regex / --regextype=TYPE
: Patterns are regular expressions of the given findutils dialect.

-A, --all
: All patterns must match (default: any).

-c, --count, -l N, --limit=N
: Print only a count, or stop after N matches.

-e, -E, --existing, --non-existing
: Only print entries that still exist (or no longer exist).

-S, --statistics, -0, --null, -p, --print, -H, -P, -L, -m, -s
: Statistics, NUL separators, follow/nofollow for -e, accepted compatibility options.

--max-database-age D
: Warning threshold for old databases.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	A match was found (or only statistics/count requested).
1	No match, or an error occurred.

ENVIRONMENT
LOCATE_PATH (locate); FINDOPTIONS, SEARCHPATHS, NETPATHS, PRUNEPATHS, PRUNEFS, LOCATE_DB (updatedb). Locale variables are ignored.

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU findutils 4.10.0 (`locate`/`updatedb`). The oracle binaries are built from the findutils-4.10.0 source tarball by `tools/build-gnu-findutils.sh` into `~/.cache/util-core/findutils`; the suites skip if that is absent. Behaviour was checked against the GNU binaries run with LC_ALL=C.
See docs/compatibility/locate.md for details.

LIMITATIONS
- The old (bigram) database format is not supported.

SEE ALSO
docs/compatibility/locate.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
