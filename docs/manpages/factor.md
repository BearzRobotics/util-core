% FACTOR(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
factor - print the prime factors of each number

SYNOPSIS
factor [-h] [NUMBER]...
factor --help | --version

DESCRIPTION
Print the prime factors of each number.

OPTIONS
-h, --exponents
: Print repeated factors as `p^e` unless e is 1.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	An error occurred (or, for check-style modes, a check failed).

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/factor --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "factor invocation" (`info '(coreutils) factor invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/factor-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_factor.sh`).
See docs/compatibility/factor.md for details.

LIMITATIONS
- **Hard numbers:** GNU also uses elliptic-curve factoring; this implementation does not. A number whose smallest unresolved factors are both large (for example two primes of 57 bits needs about 10 seconds; two of 64 bits or 2^128+1 is out of reach) is reported on standard error as `too hard to factor` after 2^29 rho steps, exit status 1, instead of being factored. Numbers beyond 128 bits whose remaining part is composite are limited to a few thousand big-integer rho steps.
- `--version` prints `factor (util-core) 0.0.0-dev`; `--help` is shorter than GNU's.

SEE ALSO
docs/compatibility/factor.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
