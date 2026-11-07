% TOUCH(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
touch - change file timestamps

SYNOPSIS
touch [OPTION]... FILE...
touch --help | --version

DESCRIPTION
Change file timestamps.

OPTIONS
-a, -m, --time=WORD
: Which time to change.

-c, --no-create
: Do not create files.

-d, --date=STRING
: GNU date string (relative to the reference time with -r).

-t [[CC]YY]MMDDhhmm[.ss]
: POSIX time.

-r, --reference=FILE
: Use FILE's times.

-h, --no-dereference
: Change a symlink itself.

-f
: Ignored.

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
Reference: GNU coreutils 9.7 (`/usr/bin/touch --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "touch invocation" (`info '(coreutils) touch invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/touch-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), touch, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/touch.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_touch.sh`).
See docs/compatibility/touch.md for details.

LIMITATIONS
- The obsolete `touch MMDDhhmm file` form is not supported (GNU 9.7 itself only enables it for POSIX2 versions before 200112).
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/touch.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
