# seq: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU seq 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/seq --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "seq invocation" (`info '(coreutils) seq invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/seq-invocation.html). POSIX does not specify `seq`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_seq.sh`).

## Supported options

- `-f, --format=FORMAT`: printf-style format with exactly one of %e %E %f %F %g %G (and any %%). %a / %A are NOT IMPLEMENTED.
- `-s, --separator=STRING`: Separate numbers with STRING (default newline); the output always ends with a newline.
- `-w, --equal-width`: Pad with leading zeros to a common width. Cannot be combined with -f.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Operands: decimal, exponent (`1e-2`), hexadecimal, `inf`/`-inf` (as LAST, an infinite sequence). `nan` is rejected.
- Fixed-point decimal operands are evaluated with exact scaled integers: `seq 0 0.1 0.3` includes 0.3 and there is no accumulated error. The default output format is %.PRECf where PREC is the largest precision of FIRST and INCREMENT, with exponents taken into account (`1e-5` has precision 5).
- -w width = the longer of FIRST and LAST formatted; negative numbers pad after the sign (`seq -w -2 2` prints -2 -1 00 01, as GNU).
- Float formatting is exact (src/fmt_float.zig) and was fuzzed against C printf semantics over 177,100 spec/value pairs with no mismatches.

## Known deviations and gaps

- The -f / hex / non-decimal path uses double precision; GNU uses long double, so values beyond 2^53 or not exactly representable can differ in the last digits.
- Decimal operands whose exact value does not fit in 128 bits fall back to the double path.
- %a / %A in a format are rejected; locale decimal points and thousands separators are not supported (C locale only).
- An option that follows a number-like operand is still parsed as an option (GNU stops option parsing at the first negative-number operand).
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

## Tests

test/test_seq.sh (stdout, normalised stderr, exit status compared with GNU seq 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
