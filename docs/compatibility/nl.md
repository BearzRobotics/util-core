# nl: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU nl 9.7 in the C locale. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/nl --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "nl invocation" (`info '(coreutils) nl invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/nl-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), nl (an XSI-option utility in that edition), https://pubs.opengroup.org/onlinepubs/9799919799/utilities/nl.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_nl.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-b, --body-numbering=STYLE`: Style for body lines: `a` all, `t` non-empty (default), `n` none. `pBRE` is NOT IMPLEMENTED.
- `-h, --header-numbering=STYLE / -f, --footer-numbering=STYLE`: Same for headers and footers (default `n`).
- `-d, --section-delimiter=CC`: Section delimiter characters (default `\:`); one character is followed by `:`; empty disables sections.
- `-i, --line-increment=N`: Line number increment (default 1, may be negative).
- `-l, --join-blank-lines=N`: Number only every Nth of consecutive empty lines (with style `a`).
- `-n, --number-format=FMT`: `ln`, `rn` (default) or `rz`.
- `-p, --no-renumber`: Do not reset the number at each section.
- `-s, --number-separator=STRING`: Text between the number and the line (default TAB).
- `-v, --starting-line-number=N`: First number of each section (default 1).
- `-w, --number-width=N`: Width of the number field (default 6).
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- All files form one document; a section delimiter line is replaced by an empty line and restarts numbering unless -p.
- Unnumbered lines are written as spaces of width + separator length, then the text (GNU).

## Known deviations and gaps

- The `pBRE` style (number lines matching a basic regular expression) is rejected with an error: it needs a POSIX BRE engine, which the project's regex library does not provide yet.
- Characters are bytes; no multibyte handling.
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

## Tests

test/test_nl.sh (stdout, normalised stderr and exit status compared with GNU nl 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
