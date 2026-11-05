% TR(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
tr - translate, squeeze, and/or delete characters

SYNOPSIS
tr [-cCdst] STRING1 [STRING2]
tr --help | --version

OPTIONS
-c, -C, --complement
: Use the complement of STRING1 (all other byte values, ascending).

-d, --delete
: Delete bytes in STRING1.

-s, --squeeze-repeats
: Replace runs of a repeated byte listed in the last string by one byte.

-t, --truncate-set1
: Truncate STRING1 to the length of STRING2 when translating.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Invalid usage or an I/O error.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/tr --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "tr invocation" (`info '(coreutils) tr invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tr-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tr, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tr.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_tr.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/tr.md for details.

LIMITATIONS
- Bytes only (C locale): no multibyte characters, no collation order, equivalence classes contain just their one character.
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

SEE ALSO
docs/compatibility/tr.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
