% SUM(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
sum - print BSD or System V checksums and block counts

SYNOPSIS
sum [-r] [-s] [FILE]...
sum --help | --version

DESCRIPTION
Print BSD or System V checksums and block counts.

OPTIONS
-r
: BSD algorithm (default); 1024-byte blocks; `%05d %5d`.

-s, --sysv
: System V algorithm; 512-byte blocks; `%d %d`.

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
Reference: GNU coreutils 9.7 (`/usr/bin/sum --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "sum invocation" (`info '(coreutils) sum invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sum-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sum.sh`).
See docs/compatibility/sum.md for details.

LIMITATIONS
- None known.

SEE ALSO
docs/compatibility/sum.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
