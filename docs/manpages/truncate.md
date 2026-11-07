% TRUNCATE(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
truncate - shrink or extend the size of files

SYNOPSIS
truncate [-co] (-s SIZE | -r RFILE) FILE...
truncate --help | --version

DESCRIPTION
Shrink or extend the size of files.

OPTIONS
-s, --size=SIZE
: New size; prefixes `+ - < > / %` and suffixes K, M, G, T, P, E, Z, Y, R, Q (1024) or KB, MB, ... (1000); a plain `b` is not a valid suffix.

-r, --reference=RFILE
: Use RFILE's size (alone), or as the base of a relative SIZE.

-c
: Do not create files.

-o
: SIZE counts I/O blocks.

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
Reference: GNU coreutils 9.7 (`/usr/bin/truncate --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "truncate invocation" (`info '(coreutils) truncate invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/truncate-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), truncate, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/truncate.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_truncate.sh`).
See docs/compatibility/truncate.md for details.

LIMITATIONS
- None known.

SEE ALSO
docs/compatibility/truncate.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
