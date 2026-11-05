% RMDIR(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
rmdir - remove empty directories

SYNOPSIS
rmdir [-pv] [--ignore-fail-on-non-empty] DIRECTORY...
rmdir --help | --version

OPTIONS
-p, --parents
: Remove DIRECTORY, then each ancestor in turn, stopping at the first that cannot be removed.

-v, --verbose
: Print `rmdir: removing directory, 'X'` on standard output before each removal.

--ignore-fail-on-non-empty
: Do not report or count failures caused by a non-empty directory.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Every directory was removed.
1	Invalid usage, or a directory could not be removed.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/rmdir --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "rmdir invocation" (`info '(coreutils) rmdir invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/rmdir-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), rmdir, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/rmdir.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_rmdir.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/rmdir.md for details.

LIMITATIONS
- `rmdir .` is refused by our code before calling the OS (the standard library treats EINVAL from rmdir as a programmer bug and panics); the message matches GNU's.
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

SEE ALSO
docs/compatibility/rmdir.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
