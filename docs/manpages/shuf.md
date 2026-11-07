% SHUF(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
shuf - generate random permutations

SYNOPSIS
shuf [OPTION]... [FILE]
shuf --help | --version

DESCRIPTION
Generate random permutations.

OPTIONS
-e, --echo
: Treat arguments as lines.

-i, --input-range=LO-HI
: Permute the integers LO through HI.

-n, --head-count=COUNT
: Output at most COUNT lines.

-o, --output=FILE
: Write to FILE (may be the input).

-r, --repeat
: Lines may repeat.

-z, --zero-terminated
: NUL line delimiter.

--random-source=FILE
: Read random bytes from FILE.

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
Reference: GNU coreutils 9.7 (`/usr/bin/shuf --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "shuf invocation" (`info '(coreutils) shuf invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/shuf-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), shuf, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/shuf.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_shuf.sh`).
See docs/compatibility/shuf.md for details.

LIMITATIONS
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/shuf.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
