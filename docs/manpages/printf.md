% PRINTF(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
printf - format and print data

SYNOPSIS
printf FORMAT [ARGUMENT]...
printf --help | --version

DESCRIPTION
Format and print data.

OPTIONS


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
Reference: GNU coreutils 9.7 (`/usr/bin/printf --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "printf invocation" (`info '(coreutils) printf invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/printf-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), printf, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/printf.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_printf.sh`).
See docs/compatibility/printf.md for details.

LIMITATIONS
- `--help`/`--version` print util-core text (GNU prints its argv[0] path).
- Multibyte characters are bytes (C locale).
- `1e400` and other values beyond x87 range are `inf` only past f80, as in GNU.

SEE ALSO
docs/compatibility/printf.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
