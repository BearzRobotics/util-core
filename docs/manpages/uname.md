% UNAME(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
uname - print system information

SYNOPSIS
uname [-asnrvmpio]
uname --help | --version

DESCRIPTION
Print system information.

OPTIONS
-a, --all
: All of the following, in this order.

-s, --kernel-name
: Kernel name.

-n, --nodename
: Network node host name.

-r, --kernel-release
: Kernel release.

-v, --kernel-version
: Kernel version.

-m, --machine
: Machine hardware name.

-p, --processor
: Processor type; the machine name here, as GNU 9.7 prints on this platform.

-i, --hardware-platform
: Hardware platform; the machine name.

-o, --operating-system
: `GNU/Linux`.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	An error occurred (or, for check-style modes, a check failed).

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/uname --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "uname invocation" (`info '(coreutils) uname invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/uname-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), uname, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/uname.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_uname.sh`).
See docs/compatibility/uname.md for details.

LIMITATIONS
- `-p`/`-i` always print the machine name; GNU prints `unknown` and omits them from `-a` on systems that cannot tell, which does not occur on Linux/x86_64.

SEE ALSO
docs/compatibility/uname.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
