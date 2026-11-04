# printenv: compatibility record

Status: implemented; differential tests pass against GNU printenv 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/printenv --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "printenv invocation" (`info '(coreutils) printenv invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/printenv-invocation.html). POSIX does not specify `printenv`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_printenv.sh`).

## Supported options

- `-0, --null`: End each output line with NUL instead of newline.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- No operands: every NAME=value; operands: the value of each set variable, nothing for unset ones; a name containing `=` is never found.
- -0/--null, abbreviated long options, `--`.

## Known deviations and gaps

- Environment order is the order given by the process environment map (insertion order); verified identical to GNU for `env -i A=1 B=2`.
- --help text is shorter than GNU's.

## Tests

test/test_printenv.sh (stdout, normalised stderr and exit status compared with GNU printenv 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
