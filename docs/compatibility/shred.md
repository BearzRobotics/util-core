# shred: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU shred 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/shred --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "shred invocation" (`info '(coreutils) shred invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/shred-invocation.html). POSIX does not specify this utility. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_shred.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-f, --force`: Make the file writable if needed.
- `-n, --iterations=N`: Number of passes (default 3).
- `--random-source=FILE`: Take random bytes from FILE.
- `-s, --size=N`: Shred this many bytes.
- `-u, --remove[=HOW]`: Remove after overwriting (`unlink`, `wipe`, `wipesync`).
- `-v, --verbose, -x, --exact, -z, --zero`: Progress, exact size, final zero pass.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- The pass layout (random first and last, the fixed-pattern groups of GNU shred.c shuffled in between), the small-file double pass, size rounding, file-name wiping and the verbose messages follow shred.c.

## Known deviations and gaps

- Random data and the order of the fixed patterns come from the operating system's generator, not GNU's ISAAC stream: `--random-source` supplies the bytes but the resulting passes differ from GNU's for the same file.
- Direct I/O is not requested.

## Tests

`sh test/test_shred.sh`: about 250 differential cases against GNU shred 9.7 with pattern names masked.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
