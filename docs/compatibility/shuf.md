# shuf: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU shuf 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/shuf --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "shuf invocation" (`info '(coreutils) shuf invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/shuf-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), shuf, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/shuf.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_shuf.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-e, --echo`: Treat arguments as lines.
- `-i, --input-range=LO-HI`: Permute the integers LO through HI.
- `-n, --head-count=COUNT`: Output at most COUNT lines.
- `-o, --output=FILE`: Write to FILE (may be the input).
- `-r, --repeat`: Lines may repeat.
- `-z, --zero-terminated`: NUL line delimiter.
- `--random-source=FILE`: Read random bytes from FILE.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- With --random-source the output is byte-identical to GNU's: random numbers are drawn like gnulib randint (buffered, rejection of the unusable range) and permutations use the same partial Fisher-Yates swaps (randperm_new, including the sparse variant for huge ranges); inputs over 8 MiB with -n use reservoir sampling as GNU does. Without it the bytes come from the system random source.

## Known deviations and gaps

- `--help` omits the "GNU coreutils online help" footer.

## Tests

`sh test/test_shuf.sh`: 145 differential cases against GNU shuf 9.7 in the C locale. Byte-for-byte comparisons with --random-source, including 0-18446744073709551615 ranges and reservoir sampling.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
