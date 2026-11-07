% HOSTID(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
hostid - print the numeric identifier of the current host

SYNOPSIS
hostid
hostid --help | --version

DESCRIPTION
Print the numeric identifier of the current host.

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
Reference: GNU coreutils 9.7 (`/usr/bin/hostid --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "hostid invocation" (`info '(coreutils) hostid invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/hostid-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_hostid.sh`).
See docs/compatibility/hostid.md for details.

LIMITATIONS
- Host names are resolved through /etc/hosts only, not DNS.

SEE ALSO
docs/compatibility/hostid.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
