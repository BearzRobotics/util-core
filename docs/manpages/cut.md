% CUT(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
cut - remove sections from each line of files

SYNOPSIS
cut -b LIST [-n] [FILE]...
cut -c LIST [FILE]...
cut -f LIST [-d DELIM] [-s] [FILE]...
cut --help | --version

OPTIONS
-b, --bytes=LIST
: Select these bytes.

-c, --characters=LIST
: Select these characters. In this implementation characters are bytes, so -c is the same as -b (as GNU in a single-byte locale).

-f, --fields=LIST
: Select these fields; lines without the delimiter are printed unchanged unless -s.

-d, --delimiter=DELIM
: Field delimiter, a single byte (default TAB).

-s, --only-delimited
: With -f, do not print lines that contain no delimiter.

--output-delimiter=STRING
: Separator printed between selected fields or, with -b/-c, between separate ranges. An empty string means a NUL byte (GNU).

--complement
: Select everything except LIST.

-n
: Accepted and ignored.

-z, --zero-terminated
: Lines end with NUL instead of newline.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	All files processed.
1	Invalid usage, or a file could not be read.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/cut --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "cut invocation" (`info '(coreutils) cut invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cut-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cut, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cut.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_cut.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/cut.md for details.

LIMITATIONS
- Multibyte (UTF-8) characters are not interpreted: -c and -n behave as in a C locale.
- `--help` text is shorter than GNU's; diagnostics use ASCII quotes (GNU uses curly quotes in UTF-8 locales).
- Windows and macOS untested.

SEE ALSO
docs/compatibility/cut.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
