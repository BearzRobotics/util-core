% NPROC(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-07

NAME
nproc - print the number of processing units available

SYNOPSIS
nproc [--all] [--ignore=N]
nproc --help | --version

DESCRIPTION
Print the number of processing units available.

OPTIONS
--all
: Count installed processors (the cpuN entries of /sys/devices/system/cpu).

--ignore=N
: Leave out N processors, but never print less than 1.

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
Reference: GNU coreutils 9.7 (`/usr/bin/nproc --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "nproc invocation" (`info '(coreutils) nproc invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/nproc-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_nproc.sh`).
See docs/compatibility/nproc.md for details.

LIMITATIONS
- `--all` counts directories under /sys/devices/system/cpu; GNU asks the C library for the configured processors, which gives the same answer on Linux.

SEE ALSO
docs/compatibility/nproc.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
