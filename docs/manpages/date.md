% DATE(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
date - print or set the system date and time

SYNOPSIS
date [OPTION]... [+FORMAT]
date --help | --version

DESCRIPTION
Print or set the system date and time.

OPTIONS
-d, --date=STRING
: Display the time described by STRING (GNU date input formats, TZ="..." prefix, @EPOCH).

-f, --file=DATEFILE
: Like -d for every line.

-r, --reference=FILE
: Display FILE's modification time.

-u, --utc, --universal
: Use UTC.

-I[FMT], --iso-8601, -R/--rfc-email, --rfc-3339=FMT
: Standard output formats.

--resolution
: Print the clock resolution (1 ns).

-s, --set=STRING / MMDDhhmm[[CC]YY][.ss]
: Set the clock (clock_settime; needs privilege).

+FORMAT
: strftime conversions with the GNU flags, widths, %N, %:z, %q.

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
Reference: GNU coreutils 9.7 (`/usr/bin/date --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "date invocation" (`info '(coreutils) date invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/date-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), date, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/date.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_date.sh`).
See docs/compatibility/date.md for details.

LIMITATIONS
- `--debug` is accepted and ignored (GNU prints the parse trace to standard error).
- Leap seconds are not modelled.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/date.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
