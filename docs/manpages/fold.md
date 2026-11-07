% FOLD(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-04

NAME
fold - wrap each input line to fit in specified width

SYNOPSIS
fold [-bs] [-w WIDTH] [FILE]...
fold --help | --version

OPTIONS
-b, --bytes
: Count bytes instead of columns.

-s, --spaces
: Break after the last blank (space or tab) that fits, if any.

-w, --width=WIDTH
: Maximum line width (default 80); `-WIDTH` is the obsolete spelling.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Invalid usage, or a file error.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/fold --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "fold invocation" (`info '(coreutils) fold invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/fold-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), fold, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fold.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_fold.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/fold.md for details.

LIMITATIONS
- Characters are bytes (C locale): wide and multibyte characters are not measured or kept whole.
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

SEE ALSO
docs/compatibility/fold.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
