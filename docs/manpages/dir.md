% DIR(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
dir - list directory contents in columns

SYNOPSIS
dir [OPTION]... [FILE]...
dir --help | --version

DESCRIPTION
List directory contents in columns.

OPTIONS
(all ls options)
: Same as `ls`; `ls -C -b`: columns with C-style escapes.

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
Reference: GNU coreutils 9.7 (`/usr/bin/dir --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "dir invocation" (`info '(coreutils) dir invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/dir-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_dir.sh`).
See docs/compatibility/dir.md for details.

LIMITATIONS
- Same as `ls`.

SEE ALSO
docs/compatibility/dir.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
