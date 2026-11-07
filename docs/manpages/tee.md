% TEE(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-04

NAME
tee - read from standard input and write to standard output and files

SYNOPSIS
tee [-aip] [--output-error[=MODE]] [FILE]...
tee --help | --version

OPTIONS
-a, --append
: Append to files (opened with O_APPEND) instead of truncating.

-i, --ignore-interrupts
: Ignore SIGINT.

-p
: Same as --output-error=warn-nopipe.

--output-error[=MODE]
: MODE is warn, warn-nopipe (default for the option), exit or exit-nopipe. Without the option SIGPIPE keeps its default action.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Input copied to every output.
1	Any open, read or write failure, or invalid usage.

ENVIRONMENT
none (SIGINT and SIGPIPE dispositions are changed as described)

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/tee --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "tee invocation" (`info '(coreutils) tee invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tee-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tee, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tee.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_tee.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/tee.md for details.

LIMITATIONS
- `-a` is POSIX-only for now (Windows reports an error).
- --help text is shorter than GNU's.
- In --output-error modes the process stops when no output remains open; the exact diagnostic order for several simultaneous failures was not compared exhaustively.
- Processing of 13 or more file operands is supported (POSIX minimum) but not tested beyond a few.

SEE ALSO
docs/compatibility/tee.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
