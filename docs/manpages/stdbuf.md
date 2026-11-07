% STDBUF(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
stdbuf - run a command with modified buffering of its standard streams

SYNOPSIS
stdbuf OPTION... COMMAND
stdbuf --help | --version

DESCRIPTION
Run a command with modified buffering of its standard streams.

OPTIONS
-i, --input=MODE
: Buffering of standard input (not L).

-o, --output=MODE
: Buffering of standard output.

-e, --error=MODE
: Buffering of standard error.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
125	stdbuf itself failed.
126	COMMAND found but could not be invoked.
127	COMMAND not found.
other	The exit status of COMMAND.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/stdbuf --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "stdbuf invocation" (`info '(coreutils) stdbuf invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/stdbuf-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), stdbuf, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/stdbuf.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_stdbuf.sh`).
See docs/compatibility/stdbuf.md for details.

LIMITATIONS
- We do not ship libstdbuf.so: the one installed by GNU coreutils (/usr/libexec/coreutils/libstdbuf.so) is used and stdbuf fails with "failed to find libstdbuf.so" if absent.
- Like GNU, statically linked programs and programs that do not use C stdio are unaffected.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/stdbuf.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
