% TAC(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-04

NAME
tac - concatenate and print files in reverse

SYNOPSIS
tac [-br] [-s SEPARATOR] [FILE]...
tac --help | --version

OPTIONS
-b, --before
: The separator is attached to the beginning of the record that follows it.

-s, --separator=STRING
: Use STRING as the record separator (default newline). An empty string means NUL.

-r, --regex
: Interpret the separator as a regular expression. NOT IMPLEMENTED: rejected with an error.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	All files processed.
1	A file could not be read, or invalid usage.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/tac --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "tac invocation" (`info '(coreutils) tac invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tac-invocation.html). POSIX does not specify `tac`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_tac.sh`).
See docs/compatibility/tac.md for details.

LIMITATIONS
- `-r` / `--regex` is not implemented (a regex engine is available in the project; planned).
- A named regular file is read backwards in 64 KiB windows (memory stays proportional to the window and the longest record). Standard input, pipes and size-0 pseudo files are read fully into memory; GNU spools those to a temporary file.
- Error text for unreadable files follows GNU (`failed to open 'X' for reading`) but read errors mid-file are reported more generically.

SEE ALSO
docs/compatibility/tac.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
