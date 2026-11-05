% PASTE(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
paste - merge lines of files

SYNOPSIS
paste [-sz] [-d LIST] [FILE]...
paste --help | --version

OPTIONS
-d, --delimiters=LIST
: Delimiters used circularly instead of TAB. Escapes: `\n`, `\t`, `\\`, `\0` (empty string).

-s, --serial
: Paste the lines of one file at a time.

-z, --zero-terminated
: Lines end with NUL instead of newline.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Invalid usage, a file could not be opened, or a write failed.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/paste --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "paste invocation" (`info '(coreutils) paste invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/paste-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), paste, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/paste.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_paste.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/paste.md for details.

LIMITATIONS
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.
- Windows and macOS untested.

SEE ALSO
docs/compatibility/paste.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
