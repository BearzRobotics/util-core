% DIRNAME(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
dirname - strip the last component from file names

SYNOPSIS
dirname [OPTION] NAME...
dirname --help | --version

DESCRIPTION
Print each NAME with its last non-slash component and trailing slashes removed. If NAME has no slash, print . (a dot).

OPTIONS
-z, --zero
: End each output line with NUL instead of newline.

--help, --version
: Sole argument only.

EXIT STATUS
Status	Meaning
0	Success.
1	Missing operand, invalid option, or write failure.

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/dirname --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "dirname invocation" (`info '(coreutils) dirname invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/dirname-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), dirname, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/dirname.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_dirname.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/dirname.md for details.

LIMITATIONS
- Only / is a path separator, including on Windows.
- //, a POSIX-implementation-defined path, prints / .

SEE ALSO
docs/compatibility/dirname.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
