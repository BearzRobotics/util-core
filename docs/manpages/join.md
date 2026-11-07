% JOIN(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
join - join lines of two files on a common field

SYNOPSIS
join [OPTION]... FILE1 FILE2
join --help | --version

DESCRIPTION
Join lines of two files on a common field.

OPTIONS
-1 FIELD, -2 FIELD, -j FIELD
: Join field of file 1, of file 2, or of both (`-j1 N`/`-j2 N` obsolete forms accepted).

-a FILENUM, -v FILENUM
: Also print unpairable lines of that file / print only those (no joined lines).

-e STRING
: Replace empty or missing output fields with STRING.

-o FORMAT
: Output list (`0`, `M.N`; `auto` infers it from the first lines).

-t CHAR
: Field separator (`-t ''` makes the whole line the field).

-i, --ignore-case
: Compare join fields ignoring ASCII case.

--header
: Treat the first line of each file as a header, joined and printed first.

--check-order, --nocheck-order
: Always / never diagnose unsorted input (default: only after an unpairable line was seen).

-z, --zero-terminated
: NUL-terminated lines.

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
Reference: GNU coreutils 9.7 (`/usr/bin/join --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "join invocation" (`info '(coreutils) join invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/join-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), join, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/join.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_join.sh`).
See docs/compatibility/join.md for details.

LIMITATIONS
- Comparison is bytewise (C locale; -i folds ASCII only).
- `--version` prints `join (util-core) 0.0.0-dev`; `--help` is shorter than GNU's.

SEE ALSO
docs/compatibility/join.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
