% PRINTENV(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
printenv - print all or part of the environment

SYNOPSIS
printenv [OPTION]... [VARIABLE]...
printenv --help | --version

OPTIONS
-0, --null
: End each output line with NUL instead of newline.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	All named variables were found (or no operands).
1	At least one named variable was not found.
2	Invalid option or write error.

ENVIRONMENT
all (that is the command's purpose)

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/printenv --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "printenv invocation" (`info '(coreutils) printenv invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/printenv-invocation.html). POSIX does not specify `printenv`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_printenv.sh`).
See docs/compatibility/printenv.md for details.

LIMITATIONS
- Environment order is the order given by the process environment map (insertion order); verified identical to GNU for `env -i A=1 B=2`.
- --help text is shorter than GNU's.

SEE ALSO
docs/compatibility/printenv.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
