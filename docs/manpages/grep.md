# NAME

grep - print lines that match patterns

# SYNOPSIS

    grep [OPTION]... PATTERNS [FILE]...
    grep --help | --version

# DESCRIPTION

Print lines that match patterns.

# OPTIONS

-E, -F, -G, -P
: Extended, fixed-string, basic (default) or Perl-style patterns; naming two different matchers is an error.

-e PATTERNS, -f FILE
: Add patterns (newline separates several); an empty `-f` file matches nothing.

-i, -y, --no-ignore-case
: Ignore case (also for non-ASCII letters in a UTF-8 locale).

-v, -w, -x
: Invert the match; whole words only; whole lines only.

-c, -l, -L, -q, -s, -m NUM
: Count, list files with/without matches, quiet, silence file errors, stop after NUM selected lines.

-o, -b, -n, -H, -h, --label, -T, -Z, -z
: Only the matching parts, byte offsets, line numbers, file names, stdin label, tab alignment, NUL after names, NUL-terminated records.

-A, -B, -C, -NUM, --group-separator, --no-group-separator
: Context lines and separators.

--color[=WHEN], GREP_COLORS
: Highlighting with the sl/cx/mt/ms/mc/fn/ln/bn/se/rv/ne capabilities.

-a, -I, --binary-files, -U
: Binary file handling: NUL bytes and, in UTF-8 locales, invalid encodings make a file binary.

-r, -R, -d, -D, --include, --exclude, --exclude-from, --exclude-dir
: Recursion, directory/device handling and file-name globs.

--line-buffered, -u
: Flush every line; obsolete -u accepted.

--help, --version
: Print help or version and exit.

# EXTENSIONS (NOT IN GNU)

Every option below is opt-in; without it grep behaves as GNU grep 3.12 (decision 0006). The long names are listed in `--help` on lines ending in "(not in GNU)". Where an extension's short letter would clash with GNU's, only the long form exists. Where ripgrep, ugrep and FreeBSD grep disagree with GNU on what an option means, GNU wins.

From ripgrep (tested against `rg` 15):

--json
: Print JSON Lines in ripgrep's message schema (`begin`, `match`, `context`, `end`, `summary`); text that is not UTF-8 is `{"bytes": base64}`. Binary detection is off (every file is searched as text), `-o` is ignored. Nothing but JSON is written: there are no group separators, `--stats` adds nothing (the `end` and `summary` messages carry the numbers), and `-c`, `-l`, `-L` and `--count-matches` are refused (status 2; ripgrep instead lets whichever of the two comes last win).

--smart-case
: Ignore case unless a pattern has an uppercase letter (an escaped letter such as `\S` does not count). `-i` wins.

--glob=GLOB
: With `-r`: include files matching GLOB; `!GLOB` excludes. Later globs win; a file matching no glob is excluded when any include glob exists. A pattern without a slash matches the file name at any depth, otherwise the path; `**` spans directories. Files named on the command line are never filtered.

--type=NAME, --type-not=NAME, --type-list
: With `-r`: only (or never) files of a built-in type such as `c`, `py`, `rust`, `zig`, `md`. `--type-list` prints the table (a subset of ripgrep's, same names and globs).

--hidden, --no-hidden
: GNU `-r` searches hidden files; `--hidden` says so explicitly and `--no-hidden` skips names starting with a dot.

--ignore-vcs, --no-ignore
: With `-r`, honour `.gitignore` and `.ignore` files found in the searched directories (negation, `dir/`, anchored and `**` patterns). Off by default, so recursion stays GNU. `--no-ignore` turns it off again. An ignore file is used only if it is a regular file of at most 4 MiB, and a `.gitignore` only if it is not a symbolic link (as in git); otherwise a warning says so (`-s` silences it) and nothing is hidden on its account.

--replace=TEXT
: Print each selected line with every match replaced by TEXT, or with `-o` only the replaced matches. TEXT may use `$1`, `${name}`, `$name` (longest word) and `$$`; an unknown group is empty.

--count-matches
: Per file, the number of matches (not lines); files without matches are not listed.

--stats
: After the results print the number of matches, lines, files, bytes and the time spent.

--max-columns=NUM, --max-columns-preview
: Lines (or with `-o`, matches) longer than NUM are replaced by `[Omitted long matching line]`; with the preview option the first NUM bytes are shown.

--sort=KEY, --sortr=KEY
: With `-r`, visit directory entries in order: `path` (also `name`), `modified`, `accessed`, `created`, `size`, `none`. `--sortr` reverses; ugrep's `rname`, `rsize`, ... spelling is accepted.

From ugrep:

--and=PATTERN, --andnot=PATTERN, --not=PATTERN, --bool
: Boolean queries. `-e A -e B --and -e C` selects lines with (A or B) and C; `--andnot P` is `--and --not P`; `--not P` alone adds "or not P" to the current group. `--bool` reads PATTERN as a query: spaces mean AND, `|` or OR, `-` or NOT, parentheses group, "quoted" is a literal. The pattern syntax is the one chosen with -E/-F/-G/-P (GNU's default -G, not ugrep's -E).

From FreeBSD grep (tested against the FreeBSD grep of the Chimera Linux sysroot):

-O, -p, -S
: With `-r`: follow directory links on the command line only (`-O`), never (`-p`), or everywhere (`-S`). Links to files met while walking are read with `-O` and `-p`, unlike GNU `-r`.

--include-dir=GLOB
: With `-r`, search only directories whose name matches GLOB (the starting directory included).

--mmap
: Accepted and ignored.

--decompress
: Search inside gzip, zlib, xz and zstd files (recognised by their magic number) and, otherwise, the file as it is. All gzip members, xz streams and zstd frames of a file are searched; if anything else follows gzip, zlib or xz data (zero padding aside), what could be decompressed is searched, the rest is reported and the status is 2. bzip2, lzma and lz4 are not supported (a diagnostic is printed and the file is searched as is). Standard input is not decompressed. FreeBSD's `-J`, `-Z`, `-X`, `-M` and `-z` conflict with GNU and are not provided. A file is checked before any of it is shown. Gzip, zlib and zstd data that decodes to more than 32 MB is read twice for that and not held in memory; xz data is always held whole.

Abbreviations of long options keep GNU's meaning: `--cou` is `--count` although `--count-matches` also starts that way.

# DIFFERENCES FROM GNU

Diagnostics are clearer than GNU's where GNU is silent or uninformative (decision 0005 update). Standard output and the exit status are GNU's; only the text on standard error differs.

- An invalid `-P` pattern: GNU prints PCRE's message; we print `invalid Perl regular expression: REASON (at offset N in 'PATTERN')`.
- A regular expression search that gives up (the backtracking or stack limit of regex-zig on a line): GNU -P prints `exceeded PCRE's backtracking limit` and exits 2; we print `FILE: regular expression search exceeded its limits near line N; lines it gave up on were treated as not matching`, exit status 2.
- Out of memory: GNU prints `memory exhausted`; we add what usually causes it (a huge pattern list or a line larger than memory).
- `--decompress` problems: damaged data and unsupported formats are named.
- An invalid `--bool` query, `--type` name or `--sort` key says what is wrong; GNU has no such options.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | A line was selected. |
| 1 | No line was selected. |
| 2 | An error occurred (unless -q found a match). |


# ENVIRONMENT

none (locale variables are ignored; behaviour is that of the C locale)

# STANDARD STREAMS

Results go to standard output; diagnostics go to standard error prefixed with the command name.

# COMPATIBILITY

Reference: GNU grep 3.12 (`/usr/bin/grep --version` on the development machine). Consulted 2026-11-07: the GNU grep manual (https://www.gnu.org/software/grep/manual/grep.html) and POSIX.1-2024 grep, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/grep.html. Behaviour was checked by differential tests against the GNU binary (`sh test/test_grep.sh`).

See docs/compatibility/grep.md for details.

# LIMITATIONS

- `-P` uses the Perl dialect of regex-zig, not PCRE2: features such as recursion, conditionals, `\R`, `\X`, `\N` and `\K` are missing and error messages differ (`invalid Perl regular expression`).
- `-P` in a UTF-8 locale matches characters: `\w`, `\s`, `\b`, classes, `\p{..}`, `\x{..}` and `-i` are Unicode-aware, and `\d` is ASCII, as in GNU. Three differences remain. `\w` leaves out numbers that are not decimal digits (`²`, `½`). `\h` and `\v` are ASCII only. A look-behind must have a fixed width in bytes: `(?<=\w)`, `(?<!\w)` and `-w` are handled, but a pattern with another one of variable width, such as `(?<=\s)`, is matched byte by byte instead, where `\w`, `\s` and `\b` know only ASCII.
- With four or more patterns the lines are selected by one lazily built DFA over all of them; `-o`, colours and `--replace` still try each pattern, and the first such use compiles every pattern separately. Patterns with back-references fall back to one search per pattern.
- Binary detection looks at each 96 KiB read rather than at GNU's buffer boundaries, so a NUL byte appearing far into a large file may switch to binary mode at a slightly different line.
- UTF-8 character classes use Unicode 16 tables and may differ from glibc's C.UTF-8 for rare code points; other locales are treated as C.

# SEE ALSO

docs/compatibility/grep.md, docs/architecture.md

# VERSION

This manual describes util-core 0.3.0.

