% NUMFMT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
numfmt - convert numbers from/to human-readable strings

SYNOPSIS
numfmt [OPTION]... [NUMBER]...
numfmt --help | --version

DESCRIPTION
Convert numbers from/to human-readable strings.

OPTIONS
--from=UNIT, --to=UNIT
: none, auto, si, iec, iec-i scaling.

--from-unit=N, --to-unit=N
: Unit sizes.

--round=METHOD
: up, down, from-zero, towards-zero, nearest.

--padding=N
: Pad (negative = left-align).

--format=FORMAT
: printf-style %f with flags, width, precision.

--field=FIELDS, -d, --delimiter=X
: Fields to convert.

--header[=N]
: Pass the first N lines through.

--suffix=SUFFIX
: Accept and add a suffix.

--invalid=MODE
: abort, fail, warn, ignore.

-z, --zero-terminated
: NUL line delimiter.

--debug
: Print warnings about invalid input.

--grouping
: Accepted; has no effect in the C locale.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	All numbers converted.
1	Usage error.
2	A conversion failed (default, or --invalid=fail).

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/numfmt --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "numfmt invocation" (`info '(coreutils) numfmt invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/numfmt-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), numfmt, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/numfmt.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_numfmt.sh`).
See docs/compatibility/numfmt.md for details.

LIMITATIONS
- Only the C locale is supported (no thousands grouping).
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/numfmt.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
