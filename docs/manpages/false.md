% FALSE(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-04

NAME
false - do nothing, unsuccessfully

SYNOPSIS
false [IGNORED]...
false --help | --version

DESCRIPTION
Exit with status 1. All arguments are ignored, except that a sole --help or --version prints a short text to standard output (still exiting 1).

OPTIONS
--help
: Print usage to standard output and exit 1. Sole argument only.

--version
: Print version to standard output and exit 1. Sole argument only.

EXIT STATUS
Status	Meaning
1	Always.

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/false --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "false invocation" (`info '(coreutils) false invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/false-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), false, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/false.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_false.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/false.md for details.

LIMITATIONS
- Exiting 1 for --help/--version matches the system `false` here; not checked against the GNU source.

SEE ALSO
docs/compatibility/false.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
