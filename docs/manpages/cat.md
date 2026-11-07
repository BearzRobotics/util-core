% CAT(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-04

NAME
cat - concatenate files and print on the standard output

SYNOPSIS
cat [OPTION]... [FILE]...
cat --help | --version

DESCRIPTION
Copy each FILE (or standard input when none is given, or for the name -) to standard output in order. Without formatting options the data is copied unchanged in 64 KiB chunks. When standard output is a terminal and no GNU formatting option (-A -b -e -E -n -s -t -T -v) is given, cat shows a bat-style view instead: file header, grid and line numbers. In pipes and redirects the output is always the GNU-compatible bytes. With color on and a matching grammar, the text is syntax-highlighted. Paging and git change markers are not implemented yet.

OPTIONS
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
: Comma-separated bat view components: full, plain, header, grid, numbers.

--color=WHEN
: auto (terminal only), always or never. Colors header, grid and numbers.

--decorations=WHEN
: auto (terminal only), always or never. always forces the bat view in pipes. A GNU formatting option always selects the GNU path.

-l, --language=NAME
: Highlight with the grammar NAME: its full name, scope (`source.rust`), the last part of the scope (`rust`) or a file extension (`rs`). Without this option the grammar is chosen from the file name, then from the grammar's first-line pattern. Unknown names are an error. Only used in the bat view with color on.

--syntax-dir=DIR
: Also load `*.sublime-syntax` files from DIR. May be repeated.

--list-languages
: Print the loaded grammars (name, tab, extensions) and exit.

-u
: Ignored.

-v, --show-nonprinting
: Use ^ and M- notation except for LF and TAB.

--help, --version
: Sole-argument handling is not required; either may appear anywhere.

EXIT STATUS
Status	Meaning
0	All inputs copied.
1	A file could not be opened or read, an option was invalid, or writing failed. Remaining files are still processed.

STANDARD STREAMS
Normal output goes to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/cat --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-04: the GNU manual node "cat invocation" (`info '(coreutils) cat invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cat-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cat, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cat.html. Behaviour was also checked by differential tests against the GNU binary (`sh test/test_cat.sh`). Where POSIX and GNU differ, the text below says which one we follow.
See docs/compatibility/cat.md for details.

LIMITATIONS
- No syntax highlighting, paging or other bat-inspired features yet (open decision: highlighting backend).
- Does not detect 'input file is output file'.
- Short options must be separate or clustered; abbreviated long options are not accepted.

SEE ALSO
docs/compatibility/cat.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.

FILES

`$XDG_CONFIG_HOME/cat/syntaxes` or `~/.config/cat/syntaxes`: Sublime Text `.sublime-syntax` grammars. None are bundled yet. Grammars are loaded only when a highlighted view is possible (terminal output, color on), so plain use pays nothing.

Colors come from a built-in theme that uses the terminal's 16 ANSI colors. There is no theme option yet.

ENVIRONMENT

NO_COLOR
: When set to a non-empty string, no color is used (no syntax colors, the gutter is drawn faint instead of gray) unless `--color=always` is given. Bold and faint styles remain, as the no-color.org convention allows. An empty value is ignored. `--color=never` removes every escape sequence. The grid, line numbers and header are not affected. (SPEC section 5.4.)

TERM
: With `TERM=dumb`, `--color=auto` emits no escape sequences at all.

XDG_CONFIG_HOME, HOME
: Locate the grammar directory `cat/syntaxes`.
