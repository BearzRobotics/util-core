% SEQ(1) core-utils 0.0.0-dev | Core Utils Manual
% Core Utils contributors
% 2026-11-04

NAME
seq - print a sequence of numbers

SYNOPSIS
seq [OPTION]... LAST
seq [OPTION]... FIRST LAST
seq [OPTION]... FIRST INCREMENT LAST
seq --help | --version

OPTIONS
-f, --format=FORMAT
: printf-style format with exactly one of %e %E %f %F %g %G (and any %%). %a / %A are NOT IMPLEMENTED.

-s, --separator=STRING
: Separate numbers with STRING (default newline); the output always ends with a newline.

-w, --equal-width
: Pad with leading zeros to a common width. Cannot be combined with -f.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Invalid operand, option or format, or a write error.

ENVIRONMENT
none

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/seq --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "seq invocation" (`info '(coreutils) seq invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/seq-invocation.html). POSIX does not specify `seq`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_seq.sh`).
See docs/compatibility/seq.md for details.

LIMITATIONS
- The -f / hex / non-decimal path uses double precision; GNU uses long double, so values beyond 2^53 or not exactly representable can differ in the last digits.
- Decimal operands whose exact value does not fit in 128 bits fall back to the double path.
- %a / %A in a format are rejected; locale decimal points and thousands separators are not supported (C locale only).
- An option that follows a number-like operand is still parsed as an option (GNU stops option parsing at the first negative-number operand).
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

SEE ALSO
docs/compatibility/seq.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
