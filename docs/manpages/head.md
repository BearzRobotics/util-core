% HEAD(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
head - output the first part of files

SYNOPSIS
head [-qvz] [-c [-]NUM | -n [-]NUM] [FILE]...
head -NUM[bkm][cqv] [FILE]...
head --help | --version

OPTIONS
-c, --bytes=[-]NUM
: Print the first NUM bytes; with a leading `-`, all but the last NUM bytes.

-n, --lines=[-]NUM
: Print the first NUM lines (default 10); with a leading `-`, all but the last NUM lines.

-q, --quiet, --silent
: Never print file name headers.

-v, --verbose
: Always print file name headers.

-z, --zero-terminated
: Lines end with NUL instead of newline.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	All files processed.
1	Invalid usage, or a file could not be opened or read, or a write failed.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/head --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "head invocation" (`info '(coreutils) head invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/head-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), head, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/head.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_head.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/head.md for details.

LIMITATIONS
- `-c -N` / `-n -N` hold the last N items in memory (as GNU does for non-seekable input).
- `--help` text is shorter than GNU's; diagnostics use ASCII quotes (GNU uses curly quotes in UTF-8 locales).
- Multibyte characters are not interpreted: -c counts bytes and lines are split on a single delimiter byte, as in GNU.
- Windows and macOS untested.

SEE ALSO
docs/compatibility/head.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
