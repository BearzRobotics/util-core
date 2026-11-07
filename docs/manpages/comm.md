% COMM(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-06

NAME
comm - compare two sorted files line by line

SYNOPSIS
comm [-123z] [--check-order | --nocheck-order] [--output-delimiter=STR] [--total] FILE1 FILE2
comm --help | --version

OPTIONS
-1, -2, -3
: Suppress column 1 (lines only in FILE1), 2 (only in FILE2) or 3 (in both).

--check-order / --nocheck-order
: Fail at once on unsorted input / never check. By default disorder is reported once per file, only when an unpairable line has been seen.

--output-delimiter=STR
: Separate columns with STR instead of TAB.

--total
: Print a summary line of the three counts.

-z, --zero-terminated
: Lines end with NUL instead of newline.

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
Reference: GNU coreutils 9.7 (`/usr/bin/comm --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-06: the GNU manual node "comm invocation" (`info '(coreutils) comm invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/comm-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), comm, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/comm.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_comm.sh`).
See docs/compatibility/comm.md for details.

LIMITATIONS
- Comparison is bytewise (C locale); LC_COLLATE is not consulted.
- `--help` text and diagnostic quoting are ASCII; wording follows GNU 9.7.
- `-z` and `--total` are GNU extensions; POSIX specifies only `-1 -2 -3`.

SEE ALSO
docs/compatibility/comm.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
