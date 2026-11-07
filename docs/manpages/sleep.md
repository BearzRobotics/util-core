% SLEEP(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-04

NAME
sleep - delay for a specified amount of time

SYNOPSIS
sleep NUMBER[SUFFIX]...
sleep --help | --version

OPTIONS
--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Slept for the requested time.
1	Missing operand, invalid interval or option.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/sleep --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "sleep invocation" (`info '(coreutils) sleep invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sleep-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), sleep, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sleep.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_sleep.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/sleep.md for details.

LIMITATIONS
- POSIX allows exit status 0 on SIGALRM; no special SIGALRM handling here (the default action terminates the process).
- Number parsing uses the C locale only (GNU also tries the current locale's decimal point).
- A total that overflows a 96-bit nanosecond count is treated as `inf`.
- --help text is shorter than GNU's.

SEE ALSO
docs/compatibility/sleep.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
