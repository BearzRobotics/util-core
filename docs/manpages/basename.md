% BASENAME(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
basename - strip directory and suffix from file names

SYNOPSIS
basename NAME [SUFFIX]
basename OPTION... NAME...
basename --help | --version

DESCRIPTION
Print each NAME with leading directory components and trailing slashes removed, and optionally a trailing SUFFIX. A suffix equal to the whole name is not removed.

OPTIONS
-a, --multiple
: Treat every operand as a NAME.

-s, --suffix=SUFFIX
: Remove SUFFIX; implies -a.

-z, --zero
: End each output line with NUL instead of newline.

--help, --version
: Sole argument only.

EXIT STATUS
Status	Meaning
0	Success.
1	Missing/extra operand, invalid option, or write failure.

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/basename --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "basename invocation" (`info '(coreutils) basename invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/basename-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), basename, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/basename.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_basename.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/basename.md for details.

LIMITATIONS
- Only / is a path separator, including on Windows.
- Abbreviated long options (e.g. --mult) are not accepted.

SEE ALSO
docs/compatibility/basename.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
