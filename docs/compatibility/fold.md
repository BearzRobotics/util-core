# fold: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU fold 9.7 in the C locale. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/fold --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "fold invocation" (`info '(coreutils) fold invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/fold-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), fold, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fold.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_fold.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-b, --bytes`: Count bytes instead of columns.
- `-s, --spaces`: Break after the last blank (space or tab) that fits, if any.
- `-w, --width=WIDTH`: Maximum line width (default 80); `-WIDTH` is the obsolete spelling.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Column rules from POSIX: tab advances to the next multiple of 8, backspace decrements, carriage return resets to 0. A line is broken before the character that would exceed the width.
- The break algorithm follows GNU's fold.c; results were compared over many widths, tabs, backspaces, CRs and -s cases.

## Known deviations and gaps

- Characters are bytes (C locale): wide and multibyte characters are not measured or kept whole.
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

## Tests

test/test_fold.sh (stdout, normalised stderr and exit status compared with GNU fold 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
