% REALPATH(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
realpath - print the resolved absolute file name

SYNOPSIS
realpath [OPTION]... FILE...
realpath --help | --version

DESCRIPTION
Print the resolved absolute file name.

OPTIONS
-e, -m
: All components must exist / none need to.

-s, --strip, --no-symlinks
: Do not expand symbolic links (existence and loops are still diagnosed as GNU does); overridden by -L.

-L, -P
: Resolve `..` before symbolic links / as encountered (default).

-q
: Quiet.

-z
: NUL-terminated.

--relative-to=DIR, --relative-base=DIR
: Relative output; a relative-to directory outside the relative-base disables it.

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
Reference: GNU coreutils 9.7 (`/usr/bin/realpath --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "realpath invocation" (`info '(coreutils) realpath invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), realpath, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/realpath.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_realpath.sh`).
See docs/compatibility/realpath.md for details.

LIMITATIONS
- `-L` is accepted and resolves like `-P` apart from its interaction with `-s`; the difference matters only when `..` follows a symbolic link.

SEE ALSO
docs/compatibility/realpath.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
