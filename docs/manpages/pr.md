% PR(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
pr - paginate or columnate files for printing

SYNOPSIS
pr [OPTION]... [FILE]...
pr --help | --version

DESCRIPTION
Paginate or columnate files for printing.

OPTIONS
+FIRST[:LAST], --pages
: Page range.

-COLUMN, --columns
: Columns, down unless -a.

-a, --across / -m, --merge
: Columns across / files side by side.

-d, -f/-F, -t, -T, -h, -l, -w, -W, -o, -s, -S, -J
: Layout controls.

-n[SEP[DIGITS]], -N
: Line numbers.

-e, -i, -c, -v
: Tabs and non-printing characters.

-D FORMAT
: Date format of the header (strftime, with the GNU extensions).

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	An error occurred (or, for check-style modes, a check failed).

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/pr --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "pr invocation" (`info '(coreutils) pr invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/pr-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), pr, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pr.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_pr.sh`).
See docs/compatibility/pr.md for details.

LIMITATIONS
- Widths count bytes (C locale).
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/pr.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
