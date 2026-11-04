% ECHO(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
echo - display a line of text

SYNOPSIS
echo [-neE] [STRING]...
echo --help | --version

DESCRIPTION
Write the arguments separated by single spaces, followed by a newline. Leading arguments made only of the letters n, e, E (such as -ne) are options; everything after the first other argument is printed literally.

OPTIONS
-n
: Do not output the trailing newline.

-e
: Interpret backslash escapes: \\a \\b \\c \\e \\f \\n \\r \\t \\v \\\\ \\0NNN (up to 3 octal digits) \\xHH (1-2 hex digits). \\c stops all further output.

-E
: Do not interpret escapes (default). Last of -e/-E wins.

--help, --version
: Recognised only as the sole argument.

EXIT STATUS
Status	Meaning
0	Success.
1	Write failure.

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/echo --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "echo invocation" (`info '(coreutils) echo invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/echo-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), echo, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/echo.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_echo.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/echo.md for details.

LIMITATIONS
- POSIXLY_CORRECT / XSI behaviour (where echo interprets escapes by default) is not implemented.
- \\NNN octal without a leading 0 is printed literally.

SEE ALSO
docs/compatibility/echo.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
