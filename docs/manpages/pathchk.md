% PATHCHK(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
pathchk - check whether file names are valid or portable

SYNOPSIS
pathchk [OPTION]... NAME...
pathchk --help | --version

DESCRIPTION
Check whether file names are valid or portable.

OPTIONS
-p
: Check the POSIX portable character set and the minimum limits (14 per component, 255 per name).

-P
: Reject empty names and components that start with `-`.

--portability
: Same as -p -P.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	All names acceptable.
1	Some name is not acceptable, or a usage error.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/pathchk --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "pathchk invocation" (`info '(coreutils) pathchk invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/pathchk-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), pathchk, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pathchk.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_pathchk.sh`).
See docs/compatibility/pathchk.md for details.

LIMITATIONS
- Without -p the limits are the Linux defaults (NAME_MAX 255, PATH_MAX 4096); `pathconf` of the actual file system is not consulted.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/pathchk.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
