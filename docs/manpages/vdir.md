% VDIR(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
vdir - list directory contents verbosely

SYNOPSIS
vdir [OPTION]... [FILE]...
vdir --help | --version

DESCRIPTION
List directory contents verbosely.

OPTIONS
(all ls options)
: Same as `ls`; `ls -l -b`: long listing with C-style escapes.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Minor problems.
2	Serious trouble.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/vdir --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "vdir invocation" (`info '(coreutils) vdir invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/vdir-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_vdir.sh`).
See docs/compatibility/vdir.md for details.

LIMITATIONS
- Same as `ls`.

SEE ALSO
docs/compatibility/vdir.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
