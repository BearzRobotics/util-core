% USERS(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
users - print the login names of logged-in users

SYNOPSIS
users [FILE]
users --help | --version

DESCRIPTION
Print the login names of logged-in users.

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
Reference: GNU coreutils 9.7 (`/usr/bin/users --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "users invocation" (`info '(coreutils) users invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/users-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_users.sh`).
See docs/compatibility/users.md for details.

LIMITATIONS
- GNU 9.7 is built with systemd and falls back to systemd-logind sessions when /var/run/utmp is absent (as on this WSL machine, where it prints the session user). logind's session files are private data and are not read, so without a utmp file this prints nothing.

SEE ALSO
docs/compatibility/users.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
