# grep: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU grep 3.12. Date: 2026-11-07

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

## Known deviations and gaps

- `-P` uses the Perl dialect of regex-zig, not PCRE2: features such as recursion, conditionals and Unicode properties are missing and error messages differ (`invalid Perl regular expression`).
- Every line is searched with one backtracking regex per pattern (no DFA, no Boyer-Moore): very large pattern lists (`-f` with thousands of words) are slow.
- Binary detection looks at each 96 KiB read rather than at GNU's buffer boundaries, so a NUL byte appearing far into a large file may switch to binary mode at a slightly different line.
- The `-q`/`/dev/null` shortcut that makes GNU exit 0 on the first match even after earlier errors is implemented only for `-q`.
- UTF-8 character classes use Unicode 16 tables and may differ from glibc's C.UTF-8 for rare code points; other locales are treated as C.

## Tests

`sh test/test_grep.sh`: about 7000 differential cases against GNU grep 3.12 (options crossed with inputs, regex syntax for BRE/ERE/fixed/Perl, context, colours with GREP_COLORS, binary and encoding handling, recursion with include/exclude, UTF-8 locale, error messages and exit statuses).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
