% NICE(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
nice - run a program with modified scheduling priority

SYNOPSIS
nice [OPTION] [COMMAND [ARG]...]
nice --help | --version

DESCRIPTION
Run a program with modified scheduling priority.

OPTIONS
-n, --adjustment=N
: Add N to the niceness (default 10); also the obsolete forms -N and --N.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
125	nice itself failed.
126	COMMAND found but could not be invoked.
127	COMMAND not found.
other	The exit status of COMMAND.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/nice --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "nice invocation" (`info '(coreutils) nice invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/nice-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), nice, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/nice.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_nice.sh`).
See docs/compatibility/nice.md for details.

LIMITATIONS
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/nice.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
