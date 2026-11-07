% UNEXPAND(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-06

NAME
unexpand - convert spaces to tabs

SYNOPSIS
unexpand [-a | --first-only] [-t TABLIST] [FILE]...
unexpand --help | --version

OPTIONS
-a, --all
: Convert all blank runs, not only leading ones.

--first-only
: Convert only leading blanks; overrides -a and the implied -a of -t.

-t, --tabs=N | LIST
: Tab stops as for expand; implies -a.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	All files processed.
1	A file could not be read, or invalid usage.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/unexpand --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-06: the GNU manual node "unexpand invocation" (`info '(coreutils) unexpand invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/unexpand-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), unexpand, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/unexpand.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_unexpand.sh`).
See docs/compatibility/unexpand.md for details.

LIMITATIONS
- Columns count bytes (C locale).
- `--first-only` is a GNU extension; POSIX specifies `-a` and `-t`.

SEE ALSO
docs/compatibility/unexpand.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
