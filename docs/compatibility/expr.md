# expr: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU expr 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/expr --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "expr invocation" (`info '(coreutils) expr invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/expr-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), expr, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/expr.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_expr.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `ARG1 | ARG2`: ARG1 if neither null nor 0, else ARG2 (0 when both are null).
- `ARG1 & ARG2`: ARG1 if neither is null or 0, else 0.
- `= == != < <= > >=`: Comparison: integers numerically (arbitrary size), otherwise bytewise (C locale).
- `+ - * / %`: Arbitrary-precision integer arithmetic.
- `STRING : REGEXP, match`: Anchored POSIX basic regular expression match; prints the \\( \\) group or the match length.
- `substr, index, length, +`: String functions and the `+ TOKEN` quoting form.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Operands after `|` and `&` that short-circuiting skips are parsed but not evaluated, so `0 & 1 / 0` prints 0.
- A non-integer POS/LENGTH to `substr` gives the null string with status 1.
- Exit status 0/1 by result, 2 for syntax errors and (as GNU 9.7) division by zero, 3 for out-of-memory.

## Known deviations and gaps

- `--help` prints `expr` instead of GNU's argv[0] path.
- Regex errors are classified into glibc's common messages (unmatched parenthesis, bracket, brace; trailing backslash); other bad patterns say `Invalid regular expression`.
- Alternation and `*` backtracking follow the regex package (leftmost-first), not POSIX leftmost-longest, for BRE extensions such as `\\|`.
- Locale is C only: lengths and indexes count bytes.

## Tests

`sh test/test_expr.sh`: 212 differential cases (arithmetic incl. bignum, comparisons, logic and short-circuit, string functions, regex, syntax errors, seeded random arithmetic).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
