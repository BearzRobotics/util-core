% READLINK(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
readlink - print the value of a symbolic link or a canonical file name

SYNOPSIS
readlink [-fenmqsvz] FILE...
readlink --help | --version

DESCRIPTION
Print the value of a symbolic link or a canonical file name.

OPTIONS
-f, -e, -m
: Canonicalise: last component may be missing / all must exist / nothing needs to exist.

-n
: No trailing delimiter (ignored with several operands, with a warning).

-q, -s, -v
: Quiet (default) / verbose errors.

-z
: NUL-terminated output.

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
Reference: GNU coreutils 9.7 (`/usr/bin/readlink --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "readlink invocation" (`info '(coreutils) readlink invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/readlink-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), readlink, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/readlink.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_readlink.sh`).
See docs/compatibility/readlink.md for details.

LIMITATIONS
- None known.

SEE ALSO
docs/compatibility/readlink.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
