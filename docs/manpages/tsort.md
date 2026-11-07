% TSORT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-06

NAME
tsort - topological sort

SYNOPSIS
tsort [-w] [FILE]
tsort --help | --version

OPTIONS
-w
: Exit status is the number of cycles found (at most 125). POSIX.1-2024; GNU 9.7 lacks it, so there is no GNU reference output for it.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Invalid usage, unreadable input, or (comm, tsort) disorder / cycle found.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/tsort --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-06: the GNU manual node "tsort invocation" (`info '(coreutils) tsort invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tsort-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tsort, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tsort.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_tsort.sh`).
See docs/compatibility/tsort.md for details.

LIMITATIONS
- Which cycle GNU reports, and where it starts, follows GNU's internal tree walk. This implementation models it and matches on most small graphs and always on acyclic input, but identical diagnostics for every cyclic graph are not guaranteed.
- An odd number of tokens is rejected as in GNU.

SEE ALSO
docs/compatibility/tsort.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
