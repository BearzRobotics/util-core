% ID(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
id - print real and effective user and group IDs

SYNOPSIS
id [-Gghnruz] [USER]...
id --help | --version

DESCRIPTION
Print real and effective user and group IDs.

OPTIONS
-u, -g, -G
: Print only the effective user ID, group ID or all group IDs.

-n
: Names instead of numbers.

-r
: Real instead of effective IDs.

-z
: NUL-delimited output (not in the default format).

-a
: Ignored.

-Z, --context
: Reports that SELinux is not available.

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
Reference: GNU coreutils 9.7 (`/usr/bin/id --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "id invocation" (`info '(coreutils) id invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/id-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), id, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/id.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_id.sh`).
See docs/compatibility/id.md for details.

LIMITATIONS
- Names come from /etc/passwd and /etc/group only (no NSS).
- SELinux contexts are not supported (`-Z` fails as on a kernel without SELinux).

SEE ALSO
docs/compatibility/id.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
