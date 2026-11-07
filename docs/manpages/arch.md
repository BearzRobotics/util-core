% ARCH(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
arch - print the machine hardware name

SYNOPSIS
arch
arch --help | --version

DESCRIPTION
Print the machine hardware name.

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
Reference: GNU coreutils 9.7 (`/usr/bin/arch --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "arch invocation" (`info '(coreutils) arch invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/arch-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_arch.sh`).
See docs/compatibility/arch.md for details.

LIMITATIONS
- None known.

SEE ALSO
docs/compatibility/arch.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
