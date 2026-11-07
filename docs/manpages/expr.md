% EXPR(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
expr - evaluate expressions

SYNOPSIS
expr EXPRESSION
expr --help | --version

DESCRIPTION
Evaluate expressions.

OPTIONS
ARG1 | ARG2
: ARG1 if neither null nor 0, else ARG2 (0 when both are null).

ARG1 & ARG2
: ARG1 if neither is null or 0, else 0.

= == != < <= > >=
: Comparison: integers numerically (arbitrary size), otherwise bytewise (C locale).

+ - * / %
: Arbitrary-precision integer arithmetic.

STRING : REGEXP, match
: Anchored POSIX basic regular expression match; prints the \\( \\) group or the match length.

substr, index, length, +
: String functions and the `+ TOKEN` quoting form.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Result is neither null nor 0.
1	Result is null or 0.
2	Invalid expression (or division by zero).
3	Internal error.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/expr --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "expr invocation" (`info '(coreutils) expr invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/expr-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), expr, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/expr.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_expr.sh`).
See docs/compatibility/expr.md for details.

LIMITATIONS
- `--help` prints `expr` instead of GNU's argv[0] path.
- Regex errors are classified into glibc's common messages (unmatched parenthesis, bracket, brace; trailing backslash); other bad patterns say `Invalid regular expression`.
- Alternation and `*` backtracking follow the regex package (leftmost-first), not POSIX leftmost-longest, for BRE extensions such as `\\|`.
- Locale is C only: lengths and indexes count bytes.

SEE ALSO
docs/compatibility/expr.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
