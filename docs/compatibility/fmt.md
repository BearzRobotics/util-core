# fmt: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU fmt 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/fmt --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "fmt invocation" (`info '(coreutils) fmt invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/fmt-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), fmt, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/fmt.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_fmt.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-w, --width=WIDTH`: Maximum line width (default 75, at most 2500).
- `-g, --goal=WIDTH`: Goal width (default 93% of the width).
- `-c, --crown-margin`: Preserve the indentation of the first two lines.
- `-t, --tagged-paragraph`: First line indent differs from the second.
- `-s, --split-only`: Split long lines, do not refill.
- `-u, --uniform-spacing`: One space between words, two after sentences.
- `-p, --prefix=STRING`: Only reformat lines beginning with STRING.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- A faithful port of GNU's cost-based paragraph filling, including the 1000-word/5000-character chunking of long paragraphs. Algorithm and constants follow GNU fmt.c (coreutils 9.6 source, consulted 2026-11-07).

## Known deviations and gaps

- Widths count bytes (C locale).
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_fmt.sh`: 278 differential cases against GNU fmt 9.7 in the C locale. Includes seeded random paragraphs and a 3000-word paragraph.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
