% WC(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
wc - print newline, word, and byte counts for each file

SYNOPSIS
wc [OPTION]... [FILE]...
wc --help | --version

DESCRIPTION
Count lines, words and bytes (default) of each FILE, or of standard input, and print a total line when more than one input is given. Words are separated by ASCII whitespace.

OPTIONS
-l, --lines
: Newline count.

-w, --words
: Word count.

-m, --chars
: UTF-8 code-point count (bytes that are not continuation bytes), independent of locale.

-c, --bytes
: Byte count.

-L, --max-line-length
: Longest line: tabs advance to multiples of 8; printable ASCII has width 1, all other bytes width 0 (C-locale behaviour).

EXIT STATUS
Status	Meaning
0	Success.
1	A file could not be read, an option was invalid, or writing failed.

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/wc --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "wc invocation" (`info '(coreutils) wc invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/wc-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), wc, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/wc.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_wc.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/wc.md for details.

LIMITATIONS
- --files0-from and --total are rejected with an error (not implemented).
- Column width follows GNU's rule (sum of st_size of regular-file inputs; width at least 7 if any input is not a regular file; unopenable inputs ignored), checked against GNU wc 9.7 for files, stdin redirected from a file, pipes and /dev/null. POSIX leaves the width unspecified.
- Output is buffered until all inputs are read, so with `2>&1` an error message appears before the lines of earlier files; GNU interleaves them in input order. The content of each stream is identical.
- Locale-specific multibyte widths (e.g. East Asian wide characters) are not handled.

SEE ALSO
docs/compatibility/wc.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
