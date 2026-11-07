% MKNOD(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
mknod - make block or character special files, or named pipes

SYNOPSIS
mknod [OPTION]... NAME TYPE [MAJOR MINOR]
mknod --help | --version

DESCRIPTION
Make block or character special files, or named pipes.

OPTIONS
-m, --mode=MODE
: Permissions.

-Z, --context[=CTX]
: As for mkfifo.

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
Reference: GNU coreutils 9.7 (`/usr/bin/mknod --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "mknod invocation" (`info '(coreutils) mknod invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mknod-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mknod, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mknod.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_mknod.sh`).
See docs/compatibility/mknod.md for details.

LIMITATIONS
- Creating block/character devices needs privilege that the development account lacks, so those paths were verified only down to the "Operation not permitted" diagnostic.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/mknod.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
