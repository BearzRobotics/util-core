# tac: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU tac 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/tac --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "tac invocation" (`info '(coreutils) tac invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tac-invocation.html). POSIX does not specify `tac`. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_tac.sh`).

## Supported options

- `-b, --before`: The separator is attached to the beginning of the record that follows it.
- `-s, --separator=STRING`: Use STRING as the record separator (default newline). An empty string means NUL.
- `-r, --regex`: Interpret the separator as a regular expression. NOT IMPLEMENTED: rejected with an error.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Each file is reversed separately; `-` and no operands mean standard input.
- Multi-byte separators are matched without overlap; the result was compared against GNU for overlapping and edge cases (separators at the start, end and doubled).

## Known deviations and gaps

- `-r` / `--regex` is not implemented (a regex engine is available in the project; planned).
- A named regular file is read backwards in 64 KiB windows (memory stays proportional to the window and the longest record). Standard input, pipes and size-0 pseudo files are read fully into memory; GNU spools those to a temporary file.
- Error text for unreadable files follows GNU (`failed to open 'X' for reading`) but read errors mid-file are reported more generically.

## Tests

test/test_tac.sh (stdout, normalised stderr, exit status compared with GNU tac 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
