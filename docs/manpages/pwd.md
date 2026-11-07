% PWD(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-04

NAME
pwd - print name of current/working directory

SYNOPSIS
pwd [-LP]
pwd --help | --version

OPTIONS
-L, --logical
: Use $PWD if it is an absolute name of the current directory with no `.` or `..` components (same directory as the physical one); otherwise behave as -P.

-P, --physical
: Print the physical directory, with no symbolic-link components. Default unless POSIXLY_CORRECT is set.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Invalid option, cannot determine the directory, or write failure.

ENVIRONMENT
PWD, POSIXLY_CORRECT

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/pwd --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "pwd invocation" (`info '(coreutils) pwd invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/pwd-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), pwd, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pwd.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_pwd.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/pwd.md for details.

LIMITATIONS
- Default is -P as in the GNU manual; POSIX.1-2024 says the default is -L. With POSIXLY_CORRECT set we default to -L.
- Extra operands print `pwd: ignoring non-option arguments` and are otherwise ignored (as GNU).
- --help text is shorter than GNU's; error messages use ASCII quotes (GNU uses curly quotes in UTF-8 locales).
- $PWD validity is checked by comparing resolved paths, GNU compares device/inode; they differ only if two distinct directories resolve identically.
- Paths longer than PATH_MAX are not handled.

SEE ALSO
docs/compatibility/pwd.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
