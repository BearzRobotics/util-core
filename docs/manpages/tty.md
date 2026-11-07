% TTY(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
tty - print the terminal name of standard input

SYNOPSIS
tty [-s]
tty --help | --version

DESCRIPTION
Print the terminal name of standard input.

OPTIONS
-s, --silent, --quiet
: Print nothing; only the exit status.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Standard input is a terminal.
1	It is not.
2	Bad usage.
3	Write error.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/tty --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "tty invocation" (`info '(coreutils) tty invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tty-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tty, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tty.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_tty.sh`).
See docs/compatibility/tty.md for details.

LIMITATIONS
- None known.

SEE ALSO
docs/compatibility/tty.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
