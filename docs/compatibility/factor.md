# factor: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU factor 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/factor --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "factor invocation" (`info '(coreutils) factor invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/factor-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_factor.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-h, --exponents`: Print repeated factors as `p^e` unless e is 1.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Numbers are read from the operands or, with none, from standard input (blank, tab and newline separate tokens). A leading `+` and leading blanks and zeros are accepted; anything else is `'TOKEN' is not a valid positive integer` (exit 1, processing continues).
- Numbers up to 2^128-1 use 128-bit arithmetic: trial division by primes below 2000, Miller-Rabin (25 prime bases) and Brent's Pollard rho in Montgomery form. Larger inputs are reduced by trial division with std.math.big, then handled the same way when what remains fits 128 bits.
- Output is `N: f1 f2 ...` in ascending order; `0:` and `1:` have no factors.

## Known deviations and gaps

- **Hard numbers:** GNU also uses elliptic-curve factoring; this implementation does not. A number whose smallest unresolved factors are both large (for example two primes of 57 bits needs about 10 seconds; two of 64 bits or 2^128+1 is out of reach) is reported on standard error as `too hard to factor` after 2^29 rho steps, exit status 1, instead of being factored. Numbers beyond 128 bits whose remaining part is composite are limited to a few thousand big-integer rho steps.
- `--version` prints `factor (util-core) 0.0.0-dev`; `--help` is shorter than GNU's.

## Tests

test/test_factor.sh (615 cases: every number to 300, word and 128-bit boundaries, prime products, powers, numbers beyond 128 bits, operand and stdin forms, errors, seeded random values) compared with GNU factor 9.7 under LC_ALL=C. Run it against a ReleaseSafe or ReleaseFast build; a Debug build is too slow for the largest cases.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
