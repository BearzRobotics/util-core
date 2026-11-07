% TEST(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
test - evaluate conditional expressions (also installed as `[`)

SYNOPSIS
test EXPRESSION | [ EXPRESSION ]
test --help | --version

DESCRIPTION
Evaluate conditional expressions (also installed as `[`).

OPTIONS
! EXPR, ( EXPR ), EXPR -a EXPR, EXPR -o EXPR
: Negation, grouping, and, or.

-n, -z, STRING, = == != < >
: String tests and comparisons (bytewise).

-eq -ne -lt -le -gt -ge
: Integer comparisons of any length.

-nt -ot -ef
: Modification-time and same-file comparisons.

-e -f -d -b -c -p -S -h -L -s -g -u -k -r -w -x -O -G -N -t
: File and descriptor tests.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	The expression is true.
1	The expression is false.
2	Syntax error.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/test --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "test invocation" (`info '(coreutils) test invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/test-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), test, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/test.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_test.sh`).
See docs/compatibility/test.md for details.

LIMITATIONS
- `-v` and `-R` (bash extensions) are not GNU test operators and are rejected as GNU does.
- `[ --version` prints a util-core banner instead of GNU's.

SEE ALSO
docs/compatibility/test.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
