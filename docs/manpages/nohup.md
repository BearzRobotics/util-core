% NOHUP(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
nohup - run a program immune to hangups

SYNOPSIS
nohup COMMAND [ARG]...
nohup --help | --version

DESCRIPTION
Run a program immune to hangups.

OPTIONS


--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
125	nohup itself failed.
126	COMMAND found but could not be invoked.
127	COMMAND not found.
other	The exit status of COMMAND.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/nohup --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "nohup invocation" (`info '(coreutils) nohup invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/nohup-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), nohup, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/nohup.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_nohup.sh`).
See docs/compatibility/nohup.md for details.

LIMITATIONS
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/nohup.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
