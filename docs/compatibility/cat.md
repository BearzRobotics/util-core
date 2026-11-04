# cat: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/cat --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "cat invocation" (`info '(coreutils) cat invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cat-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cat, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cat.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_cat.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-A, --show-all`: Equivalent to -vET.
- `-b, --number-nonblank`: Number non-empty lines; overrides -n.
- `-e`: Equivalent to -vE.
- `-E, --show-ends`: Print $ at the end of each line.
- `-n, --number`: Number all lines (width 6, then a tab).
- `-s, --squeeze-blank`: Collapse runs of empty lines into one.
- `-t`: Equivalent to -vT.
- `-T, --show-tabs`: Show TAB as ^I.
- `-u`: Ignored.
- `-v, --show-nonprinting`: Use ^ and M- notation except for LF and TAB.
- `--help, --version`: Sole-argument handling is not required; either may appear anywhere.

## Known deviations and gaps

- Deliberate deviation from GNU: on a terminal, with no GNU formatting option, output is the bat-style view (header, grid, line numbers, tabs expanded to 4). Pipes and redirects stay byte-exact GNU.
- Syntax highlighting: Sublime grammars loaded from disk (see sublime-syntax.md); no grammars bundled, no theme option, no cache (all grammars in the directories are parsed at startup of a highlighted run).
- Not implemented yet: paging, git change markers, -r/-H/-P, UTF-8 aware column counting (tab stops and the grid count bytes).
- Lines over 1 MiB are printed without highlighting.
- Does not detect 'input file is output file'.
- Short options must be separate or clustered; abbreviated long options are not accepted.

## Tests

test/test_cat.sh; unit tests for the formatter; manual comparison of -A -n -b -s -T -e on a binary file

## Comparison with bat 0.26.1 (installed 2026-11-04)

bat was run as a black box; its source and documentation were not consulted.
With `--color=never --decorations=always`, our output equals bat's byte for
byte for the styles full, numbers, grid, header, header-filesize and their
combinations, over: one file, two files, an empty file, a one-byte file, an
empty file followed by a file, a 1.5 KB file, and stdin. Conventions
reproduced: 5-column line-number gutter, `Size:` line, `<EMPTY>`, `STDIN` with
`Size: -`, blank line between files in header-only style, no `│` without line
numbers, nothing printed for an empty file unless a header is shown. Sizes use
decimal units with one decimal (`1.0 KB`, `2.0 MB`); the KB to MB switch at
2^20 bytes was observed, other boundaries are inferred.

Differences kept: no `changes` / `rule` / `snip` styles, no paging, no git
markers; the rule width is the terminal width, or 80 columns when output is
not a terminal (bat also uses 80 there); `--color=always` output is not
compared (bat uses truecolor themes, we use the 16 ANSI colors).

Highlighting speed on a 2.5 MB Rust file (repetitive sample; bat's own Rust
grammar versus Rust Enhanced, so not like for like): bat 4.4 s and 12 MB RSS,
ours 2.4 s and 2.3 MB RSS (ReleaseSafe). Startup on a 317-byte file is the
same (about 10 ms or less). Ours has no grammar cache yet, so a full grammar
set will add startup time.

NO_COLOR, TERM=dumb and --color are handled through `cli.colorEnabled` and
`cli.styleEnabled` (SPEC 5.4): NO_COLOR removes color but keeps bold/faint
(no-color.org convention); `--color=never` and TERM=dumb remove all escapes.
Tests in test/test_cat.sh run under script(1).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
