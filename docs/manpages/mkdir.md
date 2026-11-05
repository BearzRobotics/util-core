% MKDIR(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
mkdir - make directories

SYNOPSIS
mkdir [-pvZ] [-m MODE] DIRECTORY...
mkdir --help | --version

OPTIONS
-m, --mode=MODE
: Set the mode of each created directory (chmod syntax, relative to a=rwx; the umask applies only to clauses without who). Does not affect parents made by -p.

-p, --parents
: Create missing parents (mode: umask-modified rwx plus u+wx); existing directories are not an error.

-v, --verbose
: Print `mkdir: created directory 'X'` on standard output for each directory created.

-Z, --context[=CTX]
: Accepted and ignored (no SELinux/SMACK support).

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Every directory was created (or already existed with -p).
1	Invalid usage or mode, or any directory could not be created.

ENVIRONMENT
none (the process umask is consulted)

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/mkdir --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "mkdir invocation" (`info '(coreutils) mkdir invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/mkdir-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), mkdir, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mkdir.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_mkdir.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/mkdir.md for details.

LIMITATIONS
- GNU 9.7 creates `-m +t` (also `o+t`, `a+t`) as 1755; we create 1777. The rule behind GNU's result was not determined, so it is not emulated.
- The umask is read with umask(2) on Linux; elsewhere 022 is assumed.
- -Z / --context are ignored.
- Windows: mode bits are not meaningful; untested.

SEE ALSO
docs/compatibility/mkdir.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
