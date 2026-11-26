# cat: compatibility record

Status: partial (not verified). Date: 2026-11-04

## Reference

GNU coreutils 9.7 (`/usr/bin/cat --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "cat invocation" (`info '(coreutils) cat invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cat-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cat, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cat.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_cat.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-A, --show-all`: Equivalent to -vET.
- `-b, --number-nonblank`: Number non-empty lines; overrides -n.
- `-e`: Equivalent to -vE.
- `-E, --show-ends`: Print $ at the end of each line. As GNU 9.7 does, a carriage return directly before the newline is shown as `^M` (also when it is the last byte of one read and the newline the first of the next, or of the next file).
- `-n, --number`: Number all lines (width 6, then a tab).
- `-s, --squeeze-blank`: Collapse runs of empty lines into one.
- `-t`: Equivalent to -vT.
- `-T, --show-tabs`: Show TAB as ^I.
- `-u`: Ignored.
- `-v, --show-nonprinting`: Use ^ and M- notation except for LF and TAB.
- `--help, --version`: Sole-argument handling is not required; either may appear anywhere.

## Library

Module `util_core.cat` (`src/lib/cat.zig`); `src/commands/cat.zig` is the thin wrapper that parses arguments and words the diagnostics (decision 0004).

## Extensions

Terminal view (decision 0005, presentation on a terminal): when standard output is a terminal and no GNU formatting option (-A -b -e -E -n -s -t -T -v) was given, output is a bat-style view (header, grid, line numbers, optional syntax highlighting). Switch it off with `-p`/`--plain` or `--decorations=never`; it never applies to pipes or redirects (`--decorations=always` forces it). New options with no GNU meaning: `-p`, `--plain`, `--style=LIST`, `--color=WHEN`, `--decorations=WHEN`, `-l`/`--language`, `--syntax-dir`, `--list-languages`. In the library the view is the explicit `Options.view` field, null by default (byte-exact GNU). Covered by the "bat view" group of test/test_cat.sh, which also checks that the GNU path is unchanged.

## Known deviations and gaps

- Deliberate deviation from GNU: on a terminal, with no GNU formatting option, output is the bat-style view (header, grid, line numbers, tabs expanded to 4). Pipes and redirects stay byte-exact GNU.
- Syntax highlighting: 73 built-in grammars of our own (docs/compatibility/builtin-grammars.md) plus Sublime grammars loaded from disk (sublime-syntax.md); themes (below); no cache (all grammars are parsed at the start of a highlighted run).
- Themes: `--theme=NAME|auto|dark|light`, `--theme-dark`, `--theme-light`, `--list-themes`, `$BAT_THEME`, `$BAT_THEME_DARK`, `$BAT_THEME_LIGHT`. Built in: `ansi` (the terminal's 16 palette colors), `night`, `ember` (dark) and `day`, `paper` (light), our own palettes with 24-bit colors that are reduced to 256 or 16 colors when the terminal cannot show more (depth from `$COLORTERM`, `$TERM`, `$WT_SESSION` and a few known terminals). `auto`, the default, asks the terminal whether its background is dark or light (OSC 11 plus a device-attributes request, 250 ms at most; `$COLORFGBG`, then dark, when it does not answer) and uses `night` or `day`; on a terminal limited to 16 colors it uses `ansi`. Your own themes are `~/.config/cat/themes/NAME.theme` (`%APPDATA%\cat\themes` on Windows): `scope = #rrggbb|0..15|inherit [bold] [italic] [underline] [on COLOR]` per line, `extends = night` to start from a built-in theme, `#` comments. bat's TextMate `.tmTheme` files are not read.
- Git change markers: with the `changes` style (on by default) a file that differs from the git index gets a marker column: `+` added, `~` modified, `‾`/`_` lines removed above/below. The index copy is read with `git cat-file blob` and compared by our own diff engine, so it needs `git` in an absolute PATH directory (and a host environment in the library); `git diff` is not used because repository configuration can make it run programs (cat(1)). No marker column for files outside a repository, untracked, unmodified or staged-only (as bat), nor for files with a `filter`, `ident` or `working-tree-encoding` attribute, symbolic links, binary files or files over 64 MiB. Where a diff is ambiguous, the marked lines are those GNU diff would pick, which can differ from git's.
- Paging: `--paging`, `-P`, `--pager`; the built-in pager is shared with `less` (docs/compatibility/less.md). Not implemented yet: -r/-H, UTF-8 aware column counting (tab stops and the grid count bytes).
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

Differences kept: no `rule` / `snip` styles; the rule width is the terminal width, or 80 columns when output is
not a terminal (bat also uses 80 there); `--color=always` output is not
compared (bat uses its own Monokai-style truecolor themes; ours are different palettes).

Highlighting speed on a 2.5 MB Rust file (repetitive sample; bat's own Rust
grammar versus Rust Enhanced, so not like for like): bat 4.4 s and 12 MB RSS,
ours 2.4 s and 2.3 MB RSS (ReleaseSafe). Startup on a 317-byte file is the
same (about 10 ms or less). Ours has no grammar cache yet, so a full grammar
set will add startup time.

NO_COLOR, TERM=dumb and --color are handled through `cli.colorEnabled` and
`cli.styleEnabled` (SPEC 5.4): NO_COLOR removes color but keeps bold/faint
(no-color.org convention); `--color=never` and TERM=dumb remove all escapes.
Tests in test/test_cat.sh run under script(1).

## Update 2026-11-21

Default style now matches bat 0.26.1: no `Size:` line (only `--style=full` adds it). Long lines and the header wrap at the terminal width under a blank line-number gutter, byte-identical to bat for a 150-byte line at 80 columns. On Windows the console gets ANSI processing and UTF-8 output enabled before the view is drawn (`sys.enableAnsiOutput`); compile-checked for x86_64-windows, not yet run on a real console. Paging (built-in streaming pager or `$PAGER`) and built-in grammars were added afterwards. Still open: truecolor theme, git markers.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
- No differential tests against a pinned GNU build.
