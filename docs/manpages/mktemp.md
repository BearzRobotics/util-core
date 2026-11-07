% MKTEMP(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
mktemp - create a temporary file or directory, safely, and print its name

SYNOPSIS
mktemp [OPTION]... [TEMPLATE]
mktemp --help | --version

DESCRIPTION
Create a temporary file or directory, safely, and print its name.

OPTIONS
-d, --directory
: Create a directory.

-u, --dry-run
: Print a name without creating anything.

-q, --quiet
: Suppress diagnostics about creation failure.

--suffix=SUFF
: Append SUFF (no slash); the template must then end in X.

-p DIR, --tmpdir[=DIR]
: Put the file in DIR ($TMPDIR or /tmp without DIR).

-t
: Interpret TEMPLATE relative to $TMPDIR, else the -p directory, else /tmp.

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
Reference: GNU coreutils 9.7 (`/usr/bin/mktemp --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mktemp invocation" (`info '(coreutils) mktemp invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mktemp-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mktemp, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mktemp.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mktemp.sh`).
See docs/compatibility/mktemp.md for details.

LIMITATIONS
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/mktemp.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
