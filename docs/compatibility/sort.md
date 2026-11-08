# sort: compatibility record

Status: implemented with the gaps listed below; 868 differential test cases pass against GNU sort 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/sort --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "sort invocation" (`info '(coreutils) sort invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sort-invocation.html) and "Version sort ordering" (read, not implemented); POSIX.1-2024 (IEEE Std 1003.1-2024), sort, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sort.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sort.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-b, -d, -f, -i, -r`: Ignore leading blanks in key positions; dictionary order; fold case (ASCII); ignore non-printing (0x20-0x7e kept); reverse.
- `-n, -g, -h, -M`: Numeric (exact decimal), general numeric (double), human numeric (SI suffixes k/K, M..Q), month (JAN..DEC). `--sort=WORD` selects them by name or unique prefix.
- `-k F[.C][OPTS][,F[.C][OPTS]]`: Key definition; OPTS from `bdfghiMnr`. A key with no letters inherits the global options.
- `-t SEP`: Field separator (one byte, or `\0` for NUL).
- `-s, -u`: Stable (no last-resort comparison); output only the first of each run of equal keys.
- `-c, -C, --check[=diagnose-first|quiet|silent]`: Check that the single input is sorted (and strictly ordered with -u); exit 1 on disorder.
- `-m`: Merge presorted inputs (k-way, earlier input wins ties).
- `-o FILE`: Write to FILE; input is read completely first, so `sort -o f f` works.
- `-z`: NUL-terminated records.
- `--files0-from=F`: Read NUL-separated input names from F (`-` for standard input).
- `-S, -T, --parallel, --batch-size, --compress-program`: Accepted and validated, then ignored: sorting holds all input in memory on one thread.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Key extraction mirrors GNU `begfield`/`limfield`: 1-based fields and characters, `-t` separators versus blank-to-nonblank transitions (blank = space, tab or newline), `-b` on either end, an end before the start giving an empty key.
- Comparison order is the key list, then (unless `-s` or `-u`) a bytewise comparison of the whole line, reversed only by the global `-r`. This is the POSIX "last resort" rule and GNU's documented behaviour.
- Incompatible orderings are rejected like GNU (`options '-gn' are incompatible`; `-d`/`-i` with a numeric ordering).
- Diagnostics and exit statuses follow GNU: 0 success, 1 disorder under `-c`/`-C`, 2 error. The `-c` message is `sort: FILE:LINE: disorder: TEXT`.
- A final line without a terminator is accepted and terminated on output.

## Known deviations and gaps

- **Not implemented (rejected with exit status 2):** `--debug`. `-V/--version-sort` follows gnulib's filevercmp (suffix handling, `~`, leading dots) and `-R/--random-sort` hashes keys with MD5 over the 16-byte `--random-source` seed exactly like GNU (the key text is NUL-terminated only when the collation locale is not C/POSIX), so seeded output matches GNU byte for byte; without a seed the system RNG is used.
- Sorting holds the whole input in memory; there are no temporary files, so `-S`, `-T`, `--batch-size`, `--compress-program` have no effect and inputs larger than memory fail. `-c`/`-C` and `-m` (to standard output, at most 128 inputs, standard input named at most once) stream one line per input instead.
- Single-threaded; `--parallel=N` is validated and ignored.
- Comparison is bytewise (C locale). LC_COLLATE, LC_CTYPE and LC_NUMERIC (thousands separators, multibyte characters) are not consulted; `-f` folds ASCII only.
- `-g` parses with `double`; GNU uses `long double`, so values that differ only beyond 53 bits compare equal here. NaNs compare equal to each other; GNU orders them by representation.
- The traditional `+POS1 -POS2` key syntax is not recognised (those arguments are file names).
- An ambiguous long option prints `option '--s' is ambiguous` without GNU's `; possibilities:` list (shared `cli.badLong`).
- A write failure reports `write failed: 'standard output'` without the strerror text.
- `--version` prints `sort (util-core) 0.0.0-dev`; `--help` lists only the implemented options.

## Tests

test/test_sort.sh: stdout, normalised stderr and exit status compared with GNU sort 9.7 under LC_ALL=C. It covers every ordering option, keys with and without `-t`, option and key error messages, `-z`, `-o`, `--files0-from`, `-c`/`-C`, `-m`, and 12 seeded pseudo-random inputs run through 35 option combinations each, version sort (-V) on a hand-made list and 10 random inputs, and random sort (-R) with a fixed `--random-source`.

## Performance (poop, ReleaseFast, 300 000 lines, 2026-11-07)

Measured against GNU sort 9.7, which sorts on several threads. Wall time on the development machine (WSL2) varied by up to 2x between runs, so the table uses CPU cycles and peak memory, which were stable. Ours relative to GNU (full run: docs/benchmarks/2026-11-07-after.md):

| Command | Cycles | Peak RSS |
|---|---|---|
| `sort` | 1.03 | 0.87 |
| `sort -u` | 1.10 | 0.87 |
| `sort -r` | 0.83 | 0.87 |
| `sort -f` | 1.40 | 1.28 |
| `sort -k1,1` | 1.36 | 0.97 |
| `sort -n -k2,2` | 0.29 | 1.25 |
| `sort -t, -k3,3n -k2,2` (CSV) | 0.52 | 1.67 |
| `sort -g -k4,4` | 0.96 | 1.08 |
| `sort -m` (2 files) | 0.75 | 1.01 |
| `sort -c` | 0.92 | 1.01 |

How it gets there: key positions, `-n`/`-g` values and `-f`/`-d`/`-i` transformed keys are computed once per line, not once per comparison; the sort permutes 24-byte items (an 8-byte order-preserving prefix of the first key, the line pointer and its index) with a stable merge sort over a scratch buffer, so most comparisons end at one integer compare; byte strings are compared eight bytes at a time; `-c` and `-m` stream. Because GNU is multi-threaded, our single thread still takes longer in wall time (about 1.5x to 2x for text sorts in the last run, while `-n -k2,2` and `-m` were faster).

Remaining gap: `-k` with a lexicographic key follows two table lookups on a prefix tie; storing the key's offset in the item would avoid that. Threads are not used. Binary size (stripped ReleaseFast) is 343 KB against GNU's 105 KB (GNU is dynamically linked).

## Not yet done

- The unimplemented options above.
- Not run under multicall dispatch.
- Not run on Windows or macOS.
