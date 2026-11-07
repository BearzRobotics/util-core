% ENV(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
env - run a program in a modified environment, or print the environment

SYNOPSIS
env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]
env --help | --version

DESCRIPTION
Run a program in a modified environment, or print the environment.

OPTIONS
-i, --ignore-environment, -
: Start with an empty environment.

-0, --null
: End each printed variable with NUL (not allowed with a command).

-u, --unset=NAME
: Remove NAME from the environment.

-C, --chdir=DIR
: Change directory before running COMMAND (only the last -C counts).

-a, --argv0=ARG
: Pass ARG as COMMAND's argv[0].

-S, --split-string=S
: Split S into arguments (quotes, escapes, ${VAR}, comments) and re-parse.

-v, --debug
: Trace each step on standard error.

--block-signal[=SIG], --default-signal[=SIG], --ignore-signal[=SIG]
: Change the signal disposition inherited by COMMAND; without SIG every signal.

--list-signal-handling
: Print non-default signal dispositions to standard error.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
125	env itself failed.
126	COMMAND found but could not be invoked.
127	COMMAND not found.
other	The exit status of COMMAND.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/env --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "env invocation" (`info '(coreutils) env invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/env-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), env, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/env.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_env.sh`).
See docs/compatibility/env.md for details.

LIMITATIONS
- `NAME=VALUE` with an empty NAME is ignored (the environment map cannot hold it); GNU stores it.
- `--help` omits the "GNU coreutils online help" footer.

SEE ALSO
docs/compatibility/env.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
