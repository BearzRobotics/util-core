% TIMEOUT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
timeout - run a command with a time limit

SYNOPSIS
timeout [OPTION] DURATION COMMAND [ARG]...
timeout --help | --version

DESCRIPTION
Run a command with a time limit.

OPTIONS
-f, --foreground
: Do not create a process group; only the command receives the signal.

-k, --kill-after=DURATION
: Send KILL this long after the first signal.

-p, --preserve-status
: Exit with the command's status even on timeout.

-s, --signal=SIGNAL
: Signal to send (default TERM).

-v, --verbose
: Diagnose signals sent.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
124	The command timed out (without --preserve-status).
125	timeout itself failed.
126	COMMAND found but could not be invoked.
127	COMMAND not found.
128+N	The command was killed by signal N.
other	The exit status of COMMAND.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/timeout --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "timeout invocation" (`info '(coreutils) timeout invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), timeout, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/timeout.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_timeout.sh`).
See docs/compatibility/timeout.md for details.

LIMITATIONS
- Requires Linux 5.3+ (pidfd_open).
- GNU also ignores SIGTTIN/SIGTTOU while waiting; we do not.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/timeout.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
