# tr: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU tr 9.7 in the C locale. Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/tr --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "tr invocation" (`info '(coreutils) tr invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/tr-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), tr, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/tr.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_tr.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-c, -C, --complement`: Use the complement of STRING1 (all other byte values, ascending).
- `-d, --delete`: Delete bytes in STRING1.
- `-s, --squeeze-repeats`: Replace runs of a repeated byte listed in the last string by one byte.
- `-t, --truncate-set1`: Truncate STRING1 to the length of STRING2 when translating.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Strings: bytes, ranges `a-z`, classes `[:alpha:]` (C locale), `[=c=]`, `[c*n]` / `[c*]` (string2 only; `[c*]` fills to the length of string1), backslash escapes (`\a \b \f \n \r \t \v \\` and octal) and `\X` for a literal X.
- A short STRING2 is padded with its last byte (GNU), or string1 is truncated with -t. Case conversion `[:lower:]` <-> `[:upper:]` must be aligned as in GNU.
- Operand-count rules and all diagnostics (including the two-line ones and the octal-escape warnings) match GNU tr 9.7.

## Known deviations and gaps

- Bytes only (C locale): no multibyte characters, no collation order, equivalence classes contain just their one character.
- `--help` text is shorter than GNU's; ASCII quotes in diagnostics.

## Tests

test/test_tr.sh (stdout, normalised stderr and exit status compared with GNU tr 9.7 under LC_ALL=C).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
