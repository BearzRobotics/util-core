% GROUPS(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
groups - print the groups a user is in

SYNOPSIS
groups [USERNAME]...
groups --help | --version

DESCRIPTION
Print the groups a user is in.

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
Reference: GNU coreutils 9.7 (`/usr/bin/groups --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "groups invocation" (`info '(coreutils) groups invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/groups-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_groups.sh`).
See docs/compatibility/groups.md for details.

LIMITATIONS
- Only /etc/passwd and /etc/group are consulted.

SEE ALSO
docs/compatibility/groups.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
