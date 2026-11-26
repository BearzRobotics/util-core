# grep: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU grep 3.12; extensions per decision 0006 implemented and tested. Date: 2026-11-19

Library: `util_core.grep` (src/lib/grep.zig): `Matcher.compile` builds a compiled pattern list usable on any buffer (`isMatch`, `find`); `run` walks files, directories and standard input and writes to an `Io.Writer`; non-fatal problems go to an `Observer(Event)`. `src/commands/grep.zig` only parses arguments and words the diagnostics (decision 0004).

## Reference

GNU grep 3.12 (`/usr/bin/grep --version` on the development machine). Consulted 2026-11-07: the GNU grep manual (https://www.gnu.org/software/grep/manual/grep.html) and POSIX.1-2024 grep, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/grep.html. Behaviour was checked by differential tests against the GNU binary (`sh test/test_grep.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-E, -F, -G, -P`: Extended, fixed-string, basic (default) or Perl-style patterns; naming two different matchers is an error.
- `-e PATTERNS, -f FILE`: Add patterns (newline separates several); an empty `-f` file matches nothing.
- `-i, -y, --no-ignore-case`: Ignore case (also for non-ASCII letters in a UTF-8 locale).
- `-v, -w, -x`: Invert the match; whole words only; whole lines only.
- `-c, -l, -L, -q, -s, -m NUM`: Count, list files with/without matches, quiet, silence file errors, stop after NUM selected lines.
- `-o, -b, -n, -H, -h, --label, -T, -Z, -z`: Only the matching parts, byte offsets, line numbers, file names, stdin label, tab alignment, NUL after names, NUL-terminated records.
- `-A, -B, -C, -NUM, --group-separator, --no-group-separator`: Context lines and separators.
- `--color[=WHEN], GREP_COLORS`: Highlighting with the sl/cx/mt/ms/mc/fn/ln/bn/se/rv/ne capabilities.
- `-a, -I, --binary-files, -U`: Binary file handling: NUL bytes and, in UTF-8 locales, invalid encodings make a file binary.
- `-r, -R, -d, -D, --include, --exclude, --exclude-from, --exclude-dir`: Recursion, directory/device handling and file-name globs.
- `--line-buffered, -u`: Flush every line; obsolete -u accepted.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Context output follows GNU: `--` separators between non-adjacent groups (also between files), trailing context after `-m`, and the -A0/-B0 separators.
- `-f /dev/null` and the empty pattern with `-v` exit at once with status 1, as in GNU.
- Binary files print `grep: FILE: binary file matches` to standard error after the first match; lines that are not valid UTF-8 are skipped individually in UTF-8 locales.
- ERE leniency of GNU grep: leading `*`, `+`, `?` and `{n}` are ignored with a warning, an unmatched `)` and a `{` that does not start an interval are literals.
- Leftmost-longest matching for alternation is emulated (see sed); `-w` and `-x` are implemented with look-around, so they pick the same match GNU's retry loop does.
- `-R` (and the other modes that follow links) does not search a directory that is already being searched; as GNU grep it warns `recursive directory loop` (not with `-s`), which does not change the exit status.
- A recursive search reaches files through the open directories. Where links are not followed, a symbolic link that takes the place of a file or directory after it was listed is not followed either. It stops with `File name too long` below 10000 levels (4000 in a debug build) or 64 KiB of path.

## Extensions

Every extension is opt-in and leaves GNU behaviour unchanged when not used (decisions 0005 and 0006). Library `Options` fields default to GNU behaviour; the wrapper flags are long options except FreeBSD's `-O`, `-p`, `-S` (letters GNU does not use). Each is listed in `--help` on a line ending in "(not in GNU)". Tests: `sh test/test_grep_ext.sh` (oracle in the "Test" column). Where the oracles disagree with GNU on a meaning, GNU wins.

| Option | Kind | Why / semantics | Test oracle |
|---|---|---|---|
| `--json` | ripgrep | JSON Lines, ripgrep's schema (begin, match, context, end, summary; `{"bytes": base64}` for non-UTF-8). Searches every file as text; `-o`, `--replace` do not change the messages. No group separators or `--stats` text; `-c`, `-l`, `-L`, `--count-matches` are refused (rg: the later of the two options wins). | `rg --json`, timings normalised |
| `--smart-case` | ripgrep | Case-insensitive unless a pattern has an uppercase letter; escapes (`\S`) do not count; `-i` wins. | `rg --smart-case` |
| `--glob=GLOB` | ripgrep | Include/exclude (`!`) with gitignore-style globs, later wins, only while walking (command-line files are never filtered, as in rg). | `rg -g` |
| `--hidden`, `--no-hidden` | ripgrep | GNU `-r` already searches hidden files, so `--hidden` is the default spelled out and `--no-hidden` skips dot names. rg's default (hidden skipped) is `--no-hidden`. | `rg --hidden`, `rg` |
| `--ignore-vcs`, `--no-ignore` | ripgrep | `.gitignore` / `.ignore` honoured only when asked (GNU does not read them); `--no-ignore` is the default. Only files inside the searched directories are read (no parent, global or `.git/info/exclude` files; rg reads those). | `rg --no-require-git` |
| `--replace=TEXT` | ripgrep | Replacement with `$N`, `${name}`, `$name`, `$$`; whole line or, with `-o`, each match. | `rg -r` |
| `--count-matches` | ripgrep | Matches per file; files with none are omitted (rg's rule, unlike GNU `-c`). | `rg --count-matches` |
| `--stats` | ripgrep | Statistics block after the results. | `rg --stats`, times normalised |
| `--type`, `--type-not`, `--type-list` | ripgrep | Built-in table: 31 names copied from rg's (c, cpp, py, rust, zig, js, ts, md, sh, ...); not all 218. | `rg -t/-T`, every table line is in `rg --type-list` |
| `--max-columns`, `--max-columns-preview` | ripgrep | Omit (or cut) lines of NUM bytes or more including the terminator. | `rg --max-columns` |
| `--sort=KEY`, `--sortr=KEY` | ripgrep, ugrep | Directory entries in `path`/`name`, `modified`, `accessed`, `created`, `size` order, or `none`. | `rg --sort`, `--sortr` |
| `--and`, `--andnot`, `--not`, `--bool` | ugrep | Boolean queries on a line. Pattern syntax is the -E/-F/-G/-P choice, default -G (ugrep's default is -E). | `ugrep` |
| `-O`, `-p`, `-S` | FreeBSD | Symbolic links with `-r`: command line only, never, all (`-S` is GNU's `-R` behaviour). `-O`/`-p` read links to files met while walking; GNU `-r` skips them. FreeBSD's default (`-R` follows all links) is not adopted: GNU wins. | FreeBSD grep |
| `--include-dir=GLOB` | FreeBSD | Descend only into matching directories (also tested on the starting directory). | FreeBSD grep |
| `--mmap` | FreeBSD | Accepted, ignored. | FreeBSD grep |
| `--decompress` | FreeBSD (`-Z`/`-z`/`-J`...) | gzip, zlib, xz, zstd by magic number, through std.compress. bzip2 is detected and reported, searched raw; lzma/lz4/brotli/zip unsupported. Not applied to standard input. All gzip members, xz streams (with stream padding) and zstd frames are searched; other data after gzip, zlib or xz data is reported (status 2). FreeBSD's short letters clash with GNU (`-Z`, `-z`, `-X`) and are not provided. | `ugrep -z` (same formats) |

Better diagnostics (kind "diagnostic"; stdout and exit status are GNU's, only stderr text differs; tests check status and the text):

| Case | GNU | Ours |
|---|---|---|
| invalid `-P` pattern | PCRE's message | `invalid Perl regular expression: REASON (at offset N in 'PATTERN')` |
| search gives up on a line (backtracking/stack limit) | -P: `exceeded PCRE's backtracking limit`, status 2 | `FILE: regular expression search exceeded its limits near line N; lines it gave up on were treated as not matching`, status 2 (before this change the line silently counted as no match) |
| memory exhausted | `memory exhausted` | plus the usual cause |
| `--decompress` damaged or unsupported data | n/a | named per file |
| bad `--bool` query, `--type`, `--sort`, `--max-columns` | n/a | says what is wrong |

Behaviour that is not an option:

- Pattern lists of four or more patterns are searched with one lazily built DFA (regex-zig 0.3.0 `Regex` over `(?:p1)|(?:p2)|...`) for line selection; leftmost-longest `-o` output, colours and `--replace` still use the per-pattern search, compiled on first use. Patterns with back-references are not combined. Output is byte-identical (baseline suite). A 3000-word `-f` list over a 3 MB file went from 16.4 s to 1.6 s (see Performance).
- `-q`, and output to `/dev/null`, stop at the first selected line and exit 0 even after earlier errors, as GNU does.
- A getopt change: an abbreviation of a long option that fits a GNU option and an extension means the GNU option (`--cou` is `--count`), so no GNU invocation becomes ambiguous.
- `--color=BOGUS` prints GNU's help without the extension lines.

## Performance

Full matrix (GNU grep, ours before/after, ripgrep, ugrep over 100 MB, 10 MB, UTF-8 and 10000-file inputs): docs/benchmarks/grep.md, produced by `sh bench/grep-matrix.sh`.

How lines are selected: the pattern is analysed once (src/lib/grep_scan.zig). A required literal is searched over the whole read buffer with a vectorised scan (src/bytes.zig `Needle`), and only the line around a hit reaches the regex; for a bare literal, or `-w`/`-x`/`^lit`/`lit$` of one, the line check needs no regex at all. Several patterns (`-F`/`-f` lists of any size, an alternation, or an expression such as `(two|the)s?` that expands to a small finite set of strings) are searched by an Aho-Corasick automaton over byte classes (src/multisearch.zig, tables capped at 96 MB): a vector scan on the first two bytes of the literals (up to 12 distinct pairs) finds candidate starts, the automaton confirms them, and when the strings are the pattern's whole language (no `*`/`+`, anchors or classes beyond a few bytes) the hit selects the line with no regex, also under `-i` (ASCII folding), `-w` and `-x` (all occurrences are checked, falling back to the regex when a neighbour is a non-ASCII byte in UTF-8). Other patterns use up to eight required literals or a combined lazy DFA over the buffer. Skipped lines are counted in bulk (line numbers, byte offsets, `-v -c`). None of this is used with context before a match, `-v` output, boolean queries or after the first NUL in a file (binary), where every line is looked at (the automaton still answers each line).

Results on the 100 MB file: a rare literal 36 ms (GNU 64, ripgrep 16, ugrep 17; was 224); `-i` 28 ms (GNU 62; was 117); `-w -c` 95 ms (GNU 155; was 209); `-E` alternation of three literals 34 ms (GNU 99; was 200). Multi-literal round (10 MB unless noted): `-f` with 3000 words 49 ms (GNU 135, rg 52, ugrep 36; was 236); `-F -f` 1000 words 46 ms (GNU 154; was 104); `-F` with 10 patterns over 100 MB 86 ms (GNU 289, rg 58, ugrep 69; was 382); `-E '(two|the)s?'` 9 ms (GNU 12; was 33). A 3000-word `-w` list, which took minutes through the DFA, takes 60 ms. `-r --include` skips a regular file the globs reject from the directory entry alone (no stat), as GNU does.

Still behind GNU: patterns that need the DFA on every line (`^[a-m]+[[:space:]][n-z]+` 8.5x, `-x` with a regex 3x, UTF-8 `-i` and `.` 3x). The regex-zig 0.3.0 DFA loop costs 30-60 instructions per byte; see the notes in docs/benchmarks/grep.md. Also `-r` over 10000 small files was measured at about 1.1x GNU with one stat, open, read and close per file; there is now also an fstat of the opened file (not re-measured).

## Known deviations and gaps

- `-P` uses the Perl dialect of regex-zig, not PCRE2: features such as recursion, conditionals and Unicode properties are missing and error messages differ (`invalid Perl regular expression`).
- Large pattern lists use the combined DFA (or the Aho-Corasick search) only for line selection and only without back-references; `-o`, colour and `--replace` with thousands of patterns compile each pattern on first use and are slow. With `-f` lists the line selection itself uses the Aho-Corasick search (faster than GNU); `-o` and colour need the per-pattern search.
- Not adopted: regex-zig's native POSIX BRE (the BRE/ERE-to-Perl translation in posixre.zig carries GNU's leniency rules and diagnostics, and was not re-verified against 7049 cases with the native parser).
- `\<` and `\>` in the C locale: the pattern is translated for regex-zig's Perl dialect, which has only `\b`. Where a literal word character or `\w` is next to the anchor on the word's side (`\<foo`, `bar\>`), `\b` means the same and is used. Elsewhere (`s/\>//`, `\<[a-z]*`) a lookahead is added, which, as in UTF-8 locales, needs the backtracking engine: it is slower, and on very long lines the search can reach its limit. Removing that needs word-start and word-end assertions in the Perl dialect of regex-zig.
- Binary detection looks at each 96 KiB read rather than at GNU's buffer boundaries, so a NUL byte appearing far into a large file may switch to binary mode at a slightly different line.
- Binary detection at GNU's exact buffer boundaries is not matched (kept above); the `-q`/`/dev/null` early exit gap is closed.
- UTF-8 character classes use Unicode 16 tables and may differ from glibc's C.UTF-8 for rare code points; other locales are treated as C.

## Tests

`sh test/test_grep_ext.sh`: the extensions against `rg`, `ugrep`, FreeBSD grep (tools/bsdrun.sh) and GNU grep for the unchanged paths.

`sh test/test_grep.sh`: about 7000 differential cases against GNU grep 3.12 (options crossed with inputs, regex syntax for BRE/ERE/fixed/Perl, context, colours with GREP_COLORS, binary and encoding handling, recursion with include/exclude, UTF-8 locale, error messages and exit statuses).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
