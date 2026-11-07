% WHOAMI(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
whoami - print the effective user name

SYNOPSIS
whoami
whoami --help | --version

DESCRIPTION
Print the effective user name.

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
Reference: GNU coreutils 9.7 (`/usr/bin/whoami --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "whoami invocation" (`info '(coreutils) whoami invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/whoami-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_whoami.sh`).
See docs/compatibility/whoami.md for details.

LIMITATIONS
- Only /etc/passwd is consulted (no NSS), so users known only to LDAP or similar are not found.

SEE ALSO
docs/compatibility/whoami.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
