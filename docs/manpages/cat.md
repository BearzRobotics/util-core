# NAME

cat - concatenate files and print on the standard output

# SYNOPSIS

    cat [OPTION]... [FILE]...
    cat --help | --version

# DESCRIPTION

Copy each FILE (or standard input when none is given, or for the name -) to standard output in order. Without formatting options the data is copied unchanged in 64 KiB chunks. When standard output is a terminal and no GNU formatting option (-A -b -e -E -n -s -t -T -v) is given, cat shows a bat-style view instead: file header, grid and line numbers. In pipes and redirects the output is always the GNU-compatible bytes. With color on and a matching grammar, the text is syntax-highlighted; grammars for about 70 common languages and formats are built in (see `--list-languages`). When the view is longer than the screen it is paged, as bat does: through the program in `$BAT_PAGER` or `$PAGER` (or `--pager`), and otherwise through the built-in pager, which has the keys of less(1) (see less(1) in this package), scrolls while cat is still writing and prints at once, without taking over the screen, when everything fits on one screen. The built-in pager does not touch the terminal until the output no longer fits: until then the keyboard belongs to the shell or to another program of the pipeline (a password prompt, say). When any input is a terminal, cat is the plain one: no view and no paging. What has been read is written before cat reads on. Git change markers (`changes` style, default) need `git` in an absolute directory of PATH: a file with differences from the git index gets a marker column (`+` added, `~` modified, `‾`/`_` lines removed above/below). The repository next to a displayed file is not trusted and cannot make cat run a program. cat does not run `git diff`; it runs only `git cat-file blob`, `git check-attr` and `git config --get core.autocrlf`, with `core.fsmonitor` and hooks turned off, lazy fetching and all transports forbidden, and optional locks off, and compares the file with the index copy itself. A file with a `filter` (git-lfs, for example), `ident` or `working-tree-encoding` attribute gets no markers, because only git running those conversions could compare it; symbolic links and files over 64 MiB get none either. A CRLF checkout of a file stored with LF is not marked as changed when git's attributes or `core.autocrlf` convert it.

# OPTIONS

-A, --show-all
: Equivalent to -vET.

-b, --number-nonblank
: Number non-empty lines; overrides -n.

-e
: Equivalent to -vE.

-E, --show-ends
: Print $ at the end of each line.

-n, --number
: Number all lines (width 6, then a tab).

-s, --squeeze-blank
: Collapse runs of empty lines into one.

-t
: Equivalent to -vT.

-T, --show-tabs
: Show TAB as ^I.

-p, --plain
: bat view without header, grid or line numbers.

--style=LIST
: Comma-separated bat view components: full, plain, header, header-filesize, grid, numbers, changes. The default is bat's: header (file name), grid and line numbers, without the `Size:` line; `full` adds the size. Long lines, and a long file name in the header, wrap at the terminal width under a blank line-number column, as in bat.

--color=WHEN
: auto (terminal only), always or never. Colors header, grid and numbers.

--decorations=WHEN
: auto (terminal only), always or never. always forces the bat view in pipes. A GNU formatting option always selects the GNU path.

--paging=WHEN
: auto (default: page the bat view on a terminal), always (page whenever standard output is a terminal) or never.

-P, --no-paging
: Same as `--paging=never`.

--pager=CMD
: The pager program, with its arguments; words are quoted as for a shell (on Windows a backslash stands for itself). A pager that exits with a failure is reported and cat exits with status 1. Default: `$BAT_PAGER`, then `$PAGER`, then the built-in pager. A bare `less` gets `-FRX`. A pager that is just `cat` means no paging. cat starts the pager with `UTIL_CORE_CAT_PAGER` set, and a cat that finds it set never starts a pager (one reached through a script, say); given only the pager's standard input, it also passes it on undecorated.

-l, --language=NAME
: Highlight with the grammar NAME: its full name, scope (`source.rust`), the last part of the scope (`rust`) or a file extension (`rs`). Without this option the grammar is chosen from the file name, then from the grammar's first-line pattern. Unknown names are an error. Only used in the bat view with color on.

--syntax-dir=DIR
: Also load `*.sublime-syntax` files from DIR. May be repeated.

--list-languages
: Print the loaded grammars (name, tab, extensions) and exit.

--theme=NAME
: Color theme: `auto` (default: dark or light by the terminal background), `dark`, `light`, or a name from `--list-themes`. Also `$BAT_THEME`.

--theme-dark=NAME, --theme-light=NAME
: The themes `auto`/`dark`/`light` choose (defaults `night` and `day`; also `$BAT_THEME_DARK`, `$BAT_THEME_LIGHT`).

--list-themes
: Print the themes (built in and in `~/.config/cat/themes`) and exit.

-u
: Ignored.

-v, --show-nonprinting
: Use ^ and M- notation except for LF and TAB.

--help, --version
: Sole-argument handling is not required; either may appear anywhere.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | All inputs copied. |
| 1 | A file could not be opened or read, an option was invalid, or writing failed. Remaining files are still processed. |


# STANDARD STREAMS

Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

# COMPATIBILITY

Reference: GNU coreutils 9.7 (`/usr/bin/cat --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "cat invocation" (`info '(coreutils) cat invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cat-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cat, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cat.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_cat.sh`). Where POSIX and GNU differ, the text below says which one we follow.

See docs/compatibility/cat.md for details.

# LIMITATIONS

- The built-in grammars are our own, basic ones (no embedding, e.g. no JavaScript inside HTML; some heuristics are documented in docs/compatibility/builtin-grammars.md); no tmTheme files. Column counting for wrapping and tabs counts bytes, not UTF-8 characters.
- Windows: the console is switched to ANSI escape processing and UTF-8 output before the view is drawn; if that fails, color and style escapes are left off. Verified only under wine and by compiling.
- Does not detect 'input file is output file'.
- Short options must be separate or clustered; abbreviated long options are not accepted.

# SEE ALSO

docs/compatibility/cat.md, docs/architecture.md

# VERSION

This manual describes util-core 0.2.0.

# FILES


`$XDG_CONFIG_HOME/cat/syntaxes` or `~/.config/cat/syntaxes` (a variable that is empty or not an absolute path is ignored): Sublime Text `.sublime-syntax` grammars. Your grammars are found before the built-in ones. Grammars are loaded only when a highlighted view is possible (terminal output, color on), so plain use pays nothing.

`$XDG_CONFIG_HOME/cat/themes/NAME.theme` or `~/.config/cat/themes/NAME.theme`: your themes, one rule per line (`comment = #6c7a8c italic`, `keyword = 5 bold`, `string = #9ece6a on 0`, `extends = night`). Built-in themes: ansi (the terminal's 16 palette colors), night, ember, day, paper. With 24-bit colors the terminal is recognised from `$COLORTERM`, `$WT_SESSION` and similar; otherwise colors are reduced to 256 or 16. `auto` queries the terminal for its background color (OSC 11); terminals that do not answer are treated as dark unless `$COLORFGBG` says otherwise.

# ENVIRONMENT


NO_COLOR
: When set to a non-empty string, no color is used (no syntax colors, the gutter is drawn faint instead of gray) unless `--color=always` is given. Bold and faint styles remain, as the no-color.org convention allows. An empty value is ignored. `--color=never` removes every escape sequence. The grid, line numbers and header are not affected. (SPEC section 5.4.)

TERM
: With `TERM=dumb`, `--color=auto` emits no escape sequences at all.

XDG_CONFIG_HOME, HOME
: Locate the grammar directory `cat/syntaxes`.

