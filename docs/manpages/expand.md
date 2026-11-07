% EXPAND(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-06

NAME
expand - convert tabs to spaces

SYNOPSIS
expand [-i] [-t TABLIST] [FILE]...
expand --help | --version

OPTIONS
-i, --initial
: Convert only tabs before the first non-blank of each line.

-t, --tabs=N | LIST
: Tab stops every N columns (default 8), or a comma/blank separated list. The last item may be prefixed `/` (then every N columns) or `+` (then every N columns after the last stop); GNU extensions, see src/tabs.zig.

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
Reference: GNU coreutils 9.7 (`/usr/bin/expand --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-06: the GNU manual node "expand invocation" (`info '(coreutils) expand invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/expand-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), expand, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/expand.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_expand.sh`).
See docs/compatibility/expand.md for details.

LIMITATIONS
- Columns count bytes (C locale); multibyte and wide characters are not measured.
- `--help` text is GNU's, ASCII quotes in diagnostics.

SEE ALSO
docs/compatibility/expand.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
