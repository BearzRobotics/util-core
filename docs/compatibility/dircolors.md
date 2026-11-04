# dircolors: compatibility record

Status: implemented from the GNU source and the GNU manual; differential tests against GNU dircolors 9.7 pass (`sh test/test_dircolors.sh`). Date: 2026-11-04

## References (consulted 2026-11-04)

- GNU coreutils manual, "dircolors invocation", https://www.gnu.org/software/coreutils/manual/html_node/dircolors-invocation.html (page header: GNU Coreutils 9.12).
- GNU coreutils `src/dircolors.c` and `src/dircolors.hin`, master branch, from https://raw.githubusercontent.com/coreutils/coreutils/master/ (the cgit URLs returned 404). The source was read for behaviour only. Its copyright header is Free Software Foundation / H. Peter Anvin, GPLv3 or later; no code or comment text was copied. Our database file contains the same data (terminal names, color values, extensions) with our own comments.
- POSIX does not specify dircolors.

The installed `/usr/bin/dircolors` is GNU coreutils 9.7. Our built-in database follows GNU master (see above), which is newer than 9.7: the `-b`/`-c`/`--print-ls-colors` output for terminals with colors therefore differs from 9.7 in the extension list (measured: 9.7 has `*.ace *.alz *.arc *.arj *.bz *.tbz *.zoo`, which master dropped; master has `*.bz3 *.tbz3`, which 9.7 lacks). Output for terminals without colors (`dumb`, unlisted TERM) is identical. `--print-database` differs because our comments are our own; the GNU comments are copyrighted and not copied.

## Supported

- `-b / --sh / --bourne-shell`, `-c / --csh / --c-shell`, `-p / --print-database`, `--print-ls-colors`, `--help`, `--version`, `--`; clustered short options; abbreviated long options.
- FILE, `-` for standard input, built-in database when omitted.
- The database format: keywords (case-insensitive), `.ext` and `*pattern` entries, ignored OPTIONS / COLOR / EIGHTBIT, comments, TERM / COLORTERM state machine with cancelling, CRLF.
- Option conflict checks and messages in GNU's order; shell guess from $SHELL (basename exactly csh / tcsh; empty or unset SHELL is an error); all database problems reported, no output on error; `<internal>` for the built-in database.
- Quoting as GNU's `append_quoted` (`'`, `:`, `=`, `\`, `^`, and `!` for C shell); `--print-ls-colors` output unquoted.

## Differences found in the earlier uutils reference (historical; we follow GNU)

| Case | GNU source | uutils 0.10.0 (no longer the reference) |
|---|---|---|
| Default database | lists terminals; unlisted TERM gives `LS_COLORS=''` | full output for any TERM |
| Unknown keyword outside a TERM block | ignored | error |
| `#` inside a word (`DIR a#b`) | value is `a` | value is `a#b` |
| `=` in a value | escaped as `\=` | not escaped |
| A TERM line after matching entries | can cancel them | does not |
| `--print-ls-colors` | raw strings | shell-quoted strings |
| Error text | `FILE:LINE: unrecognized keyword 'KW'` | no file or line |

## Known gaps

- The manual says the C shell default applies when SHELL "ends with csh or tcsh"; the source compares the basename exactly. We follow the source. Which one a given GNU release has was not checked.
- The built-in database follows master (2026-11-04), which differs from older releases (for example the list of terminals and the extensions `.apk`, `.crate`, `.egg`, `.pyz`). Behaviour of older GNU versions is not reproduced.
- The database text printed by `-p` has our own comments, so it differs from GNU's `-p` text in the comments only.
- Quoting of file names in diagnostics is a simple approximation of gnulib's quotef.
- Read errors use the system error text, without GNU's `read error` wording.
- Not run under multicall dispatch, on Windows, or on macOS.

## Tests

`test/test_dircolors.sh` (57 checks, expectations derived from the GNU source) and unit tests in `src/commands/dircolors.zig` (glob matcher, parser, TERM state machine, quoting, built-in database).
