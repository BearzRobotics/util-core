# tee: compatibility record

Status: implemented; differential tests pass against GNU tee 9.7. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/tee --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "tee invocation" (`info '(coreutils) tee invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tee-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tee, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tee.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_tee.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --append`: Append to files (opened with O_APPEND) instead of truncating.
- `-i, --ignore-interrupts`: Ignore SIGINT.
- `-p`: Same as --output-error=warn-nopipe.
- `--output-error[=MODE]`: MODE is warn, warn-nopipe (default for the option), exit or exit-nopipe. Without the option SIGPIPE keeps its default action.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- All options above; a FILE named `-` is an ordinary file (POSIX and GNU ≥ 8.24).
- Data is copied chunk by chunk with no buffering delay (read ≤ 64 KiB, write to every destination).
- A file that cannot be opened or written is reported; the rest continue (POSIX consequences of errors); exit status 1.

## Known deviations and gaps

- `-a` is POSIX-only for now (Windows reports an error).
- --help text is shorter than GNU's.
- In --output-error modes the process stops when no output remains open; the exact diagnostic order for several simultaneous failures was not compared exhaustively.
- Processing of 13 or more file operands is supported (POSIX minimum) but not tested beyond a few.

## Tests

test/test_tee.sh (stdout, normalised stderr and exit status compared with GNU tee 9.7).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
