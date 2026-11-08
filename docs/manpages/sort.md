% SORT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
sort - sort, merge or check lines of text

SYNOPSIS
sort [OPTION]... [FILE]...
sort [OPTION]... --files0-from=F
sort --help | --version

DESCRIPTION
Writes the sorted concatenation of all FILEs to standard output. With no FILE, or when FILE is `-`, standard input is read. Lines are compared by one or more keys (the whole line when no key is given); lines whose keys compare equal are then compared bytewise unless -s or -u is given.

OPTIONS
-b, -d, -f, -i, -r
: Ignore leading blanks in key positions; dictionary order; fold case (ASCII); ignore non-printing (0x20-0x7e kept); reverse.

-n, -g, -h, -M
: Numeric (exact decimal), general numeric (double), human numeric (SI suffixes k/K, M..Q), month (JAN..DEC). `--sort=WORD` selects them by name or unique prefix.

-k F[.C][OPTS][,F[.C][OPTS]]
: Key definition; OPTS from `bdfghiMnr`. A key with no letters inherits the global options.

-t SEP
: Field separator (one byte, or `\0` for NUL).

-s, -u
: Stable (no last-resort comparison); output only the first of each run of equal keys.

-c, -C, --check[=diagnose-first|quiet|silent]
: Check that the single input is sorted (and strictly ordered with -u); exit 1 on disorder.

-m
: Merge presorted inputs (k-way, earlier input wins ties).

-o FILE
: Write to FILE; input is read completely first, so `sort -o f f` works.

-z
: NUL-terminated records.

--files0-from=F
: Read NUL-separated input names from F (`-` for standard input).

-S, -T, --parallel, --batch-size, --compress-program
: Accepted and validated, then ignored: sorting holds all input in memory on one thread.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success (with -c/-C: the input is ordered).
1	With -c/-C: the input is not ordered.
2	An error occurred (unreadable input, bad option or key, unsupported option).

ENVIRONMENT
none (locale variables are ignored; comparisons are bytewise)

STANDARD STREAMS
Sorted output goes to standard output unless -o is given; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/sort --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "sort invocation" (`info '(coreutils) sort invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/sort-invocation.html) and "Version sort ordering" (read, not implemented); POSIX.1-2024 (IEEE Std 1003.1-2024), sort, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/sort.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_sort.sh`).
See docs/compatibility/sort.md for details.

LIMITATIONS
- **Not implemented (rejected with exit status 2):** `--debug`. `-V/--version-sort` follows gnulib's filevercmp (suffix handling, `~`, leading dots) and `-R/--random-sort` hashes keys with MD5 over the 16-byte `--random-source` seed exactly like GNU (the key text is NUL-terminated only when the collation locale is not C/POSIX), so seeded output matches GNU byte for byte; without a seed the system RNG is used.
- Sorting holds the whole input in memory; there are no temporary files, so `-S`, `-T`, `--batch-size`, `--compress-program` have no effect and inputs larger than memory fail. `-c`/`-C` and `-m` (to standard output, at most 128 inputs, standard input named at most once) stream one line per input instead.
- Single-threaded; `--parallel=N` is validated and ignored.
- Comparison is bytewise (C locale). LC_COLLATE, LC_CTYPE and LC_NUMERIC (thousands separators, multibyte characters) are not consulted; `-f` folds ASCII only.
- `-g` parses with `double`; GNU uses `long double`, so values that differ only beyond 53 bits compare equal here. NaNs compare equal to each other; GNU orders them by representation.
- The traditional `+POS1 -POS2` key syntax is not recognised (those arguments are file names).
- An ambiguous long option prints `option '--s' is ambiguous` without GNU's `; possibilities:` list (shared `cli.badLong`).
- A write failure reports `write failed: 'standard output'` without the strerror text.
- `--version` prints `sort (util-core) 0.0.0-dev`; `--help` lists only the implemented options.

SEE ALSO
docs/compatibility/sort.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
