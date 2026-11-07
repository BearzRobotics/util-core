% MKFIFO(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
mkfifo - make named pipes

SYNOPSIS
mkfifo [OPTION]... NAME...
mkfifo --help | --version

DESCRIPTION
Make named pipes.

OPTIONS
-m, --mode=MODE
: Set the permissions (chmod syntax, relative to a=rw); applied after creation so the umask does not remove bits.

-Z, --context[=CTX]
: Accepted; with a CTX a warning says SELinux is unavailable.

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
Reference: GNU coreutils 9.7 (`/usr/bin/mkfifo --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mkfifo invocation" (`info '(coreutils) mkfifo invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mkfifo-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mkfifo, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mkfifo.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mkfifo.sh`).
See docs/compatibility/mkfifo.md for details.

LIMITATIONS
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/mkfifo.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
