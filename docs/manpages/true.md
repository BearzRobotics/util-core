% TRUE(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-04

NAME
true - do nothing, successfully

SYNOPSIS
true [IGNORED]...
true --help | --version

DESCRIPTION
Exit with status 0. All arguments are ignored, except that a sole --help or --version prints a short text to standard output (still exiting 0).

OPTIONS
--help
: Print usage to standard output and exit 0. Only recognised as the sole argument.

--version
: Print version to standard output and exit 0. Only recognised as the sole argument.

EXIT STATUS
Status	Meaning
0	Always.

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/true --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "true invocation" (`info '(coreutils) true invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/true-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), true, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/true.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_true.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/true.md for details.

LIMITATIONS
- --help text is abbreviated compared with GNU's.
- Argument-ignoring and sole-argument rules follow GNU true.c from memory; not verified against the source.

SEE ALSO
docs/compatibility/true.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
