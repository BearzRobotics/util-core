% SYNC(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
sync - flush file system buffers

SYNOPSIS
sync [OPTION] [FILE]...
sync --help | --version

DESCRIPTION
Flush file system buffers.

OPTIONS
-d, --data
: fdatasync each FILE.

-f, --file-system
: syncfs the file system containing each FILE.

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
Reference: GNU coreutils 9.7 (`/usr/bin/sync --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "sync invocation" (`info '(coreutils) sync invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sync-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), sync, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sync.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sync.sh`).
See docs/compatibility/sync.md for details.

LIMITATIONS
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/sync.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
