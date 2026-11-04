% YES(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
yes - repeatedly output a line

SYNOPSIS
yes [STRING]...
yes --help | --version

DESCRIPTION
Repeatedly write STRING (arguments joined by single spaces), or y if none, each followed by a newline, until the write fails or the process is killed. Output is assembled into an 8 KiB buffer so each write is a large call.

OPTIONS
--help
: Print usage and exit 0.

--version
: Print version and exit 0.

--
: End option processing.

EXIT STATUS
Status	Meaning
0	--help or --version.
1	Write failure (for example a closed pipe) or an invalid option.

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/yes --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "yes invocation" (`info '(coreutils) yes invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/yes-invocation.html). POSIX does not specify `yes`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_yes.sh`).
See docs/compatibility/yes.md for details.

LIMITATIONS
- Any other argument starting with - is rejected as an invalid option (matches the system yes here; GNU yes treats only --help/--version specially, so this may differ from GNU).
- On a closed pipe the process exits 1 after a failed write; whether the shell sees SIGPIPE depends on the runtime.

SEE ALSO
docs/compatibility/yes.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
