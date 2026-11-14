# printenv: compatibility record

Status: implemented; differential tests pass against GNU printenv 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/printenv --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "printenv invocation" (`info '(coreutils) printenv invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/printenv-invocation.html). POSIX does not specify `printenv`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_printenv.sh`).

## Supported options

- `-0, --null`: End each output line with NUL instead of newline.
- `--help, --version`: Print help or version and exit.
- `--json` (extension, not in GNU): one JSON object of NAME to value (every variable, or just the requested ones; a requested name that is not set is left out and the status is 1, as in the text form). A name containing `=` is never found. Values that are not valid UTF-8 are written with U+FFFD. Cannot be combined with `-0`. Not listed in `--help`. Rules: `docs/decisions/0003-json-output.md`.

## Supported behaviour

- No operands: every NAME=value; operands: the value of each set variable, nothing for unset ones; a name containing `=` is never found.
- -0/--null, abbreviated long options, `--`.

## Known deviations and gaps

- Environment order is the order given by the process environment map (insertion order); verified identical to GNU for `env -i A=1 B=2`.
- --help text is shorter than GNU's.

## Tests

test/test_printenv.sh (stdout, normalised stderr and exit status compared with GNU printenv 9.7).

`sh test/test_printenv_json.sh`: 15 checks of `--json` against GNU printenv for quoting, newlines, UTF-8, several names, unset names and statuses, the empty environment and the refused `-0`.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
