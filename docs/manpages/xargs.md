% XARGS(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
xargs - build and execute command lines from standard input

SYNOPSIS
xargs [OPTION]... COMMAND [INITIAL-ARGS]...
xargs --help | --version

DESCRIPTION
Build and execute command lines from standard input.

OPTIONS
-0, --null, -d, --delimiter=DELIM
: Items end with NUL or the given character; no quote or backslash processing.

-a, --arg-file=FILE
: Read items from FILE instead of standard input.

-E EOF-STR, -e[EOF-STR], --eof[=EOF-STR]
: Logical end-of-file string.

-I R, -i[R], --replace[=R]
: Replace R in the initial arguments with each input line (one command per item).

-L N, -l[N], --max-lines[=N]
: At most N non-blank input lines per command.

-n N, --max-args=N, -s N, --max-chars=N, -x, --exit
: Limits on the argument count and command length.

-P N, --max-procs=N, --process-slot-var=VAR
: Run several commands at once; the slot number is exported in VAR.

-p, --interactive, -t, --verbose, -o, --open-tty
: Prompting (needs /dev/tty), tracing, and reading the child's input from the terminal.

-r, --no-run-if-empty, --show-limits
: Skip an empty run; print the size limits.

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
Reference: GNU findutils xargs 4.10.0 (`/usr/bin/xargs --version` on the development machine). Consulted 2026-11-07: the findutils manual "xargs invocation"; POSIX.1-2024 xargs, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/xargs.html. Behaviour was checked by differential tests against the installed binary run with LC_ALL=C (`sh test/test_xargs.sh`).
See docs/compatibility/xargs.md for details.

LIMITATIONS
- -x combined with an argument that cannot fit differs from GNU in some edge cases (the exact point at which GNU aborts is not reproduced).
- -P runs commands concurrently but reaps them in start order, so a failing later command is reported after earlier ones finish.
- -p and -o need a controlling terminal, which the test suite does not have; the error path is checked only by hand.

SEE ALSO
docs/compatibility/xargs.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
