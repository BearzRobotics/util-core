% LOGNAME(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
logname - print the user's login name

SYNOPSIS
logname
logname --help | --version

DESCRIPTION
Print the user's login name.

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
Reference: GNU coreutils 9.7 (`/usr/bin/logname --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "logname invocation" (`info '(coreutils) logname invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/logname-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), logname, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/logname.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_logname.sh`).
See docs/compatibility/logname.md for details.

LIMITATIONS
- The utmp fallback of getlogin() is not implemented, so a login known only to utmp is reported as `no login name`.

SEE ALSO
docs/compatibility/logname.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
