# sum: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU sum 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/sum --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "sum invocation" (`info '(coreutils) sum invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sum-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sum.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-r`: BSD algorithm (default); 1024-byte blocks; `%05d %5d`.
- `-s, --sysv`: System V algorithm; 512-byte blocks; `%d %d`.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Names are printed when at least one file operand is given (not for implicit standard input).

## Known deviations and gaps

- None known.

## Tests

test/test_sum.sh (212 cases: both algorithms, block-size boundaries, 1 MB, stdin, errors) compared with GNU sum 9.7 under LC_ALL=C.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
