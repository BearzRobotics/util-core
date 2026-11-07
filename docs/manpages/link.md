% LINK(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
link - create a hard link by calling link(2)

SYNOPSIS
link FILE1 FILE2
link --help | --version

DESCRIPTION
Create a hard link by calling link(2).

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
Reference: GNU coreutils 9.7 (`/usr/bin/link --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "link invocation" (`info '(coreutils) link invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/link-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), link, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/link.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_link.sh`).
See docs/compatibility/link.md for details.

LIMITATIONS
- Error wording comes from the Zig error set, so rare errno values may print their Zig name.

SEE ALSO
docs/compatibility/link.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
