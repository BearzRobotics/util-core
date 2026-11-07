# csplit: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU csplit 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/csplit --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "csplit invocation" (`info '(coreutils) csplit invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/csplit-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), csplit, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/csplit.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_csplit.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `INTEGER, /REGEXP/[OFFSET], %REGEXP%[OFFSET], {N}, {*}`: Patterns.
- `-b, --suffix-format=FORMAT`: printf-style integer format for the numbering.
- `-f, --prefix`: Output prefix (default xx).
- `-n, --digits`: Digits in the number.
- `-k, -s/-q, -z, --suppress-matched`: Keep files, quiet, elide empty, drop matched lines.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Control flow and side effects (file creation, byte counts, cleanup on error) follow GNU csplit.c. Regular expressions are POSIX basic.

## Known deviations and gaps

- The whole input is read into memory before splitting.
- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_csplit.sh`: 277 differential cases against GNU csplit 9.7 in the C locale. Compares printed counts and the name, mode and checksum of every output file, including after errors.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
