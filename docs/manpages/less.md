# NAME

less - page a file or a stream on the terminal

# SYNOPSIS

    less [OPTION]... [FILE]...
    less --help | --version

# DESCRIPTION

Show FILE (or standard input, or the name -) one screen at a time, with the keys of less(1). The input is read while it is shown: a pipe can be scrolled, searched and followed while it is still being written, and the process that feeds it is not stopped. When standard output is not a terminal, less copies its input like cat.

It is a small implementation, built into util-core so that paging works on every platform (Windows has no less) without a separate download; `cat` pages through the same code. Long lines wrap at the terminal width. Several files are shown one after the other as one text.

# OPTIONS

-F, --quit-if-one-screen
: Quit at once, printing the text, if it fits on one screen. The terminal is not touched until the text is longer than that, so what is typed meanwhile is left for others.

-R, --RAW-CONTROL-CHARS, -r
: Pass colour escape sequences through. Without it, control characters are shown as `^X`.

-S, --chop-long-lines
: Cut long lines at the screen edge instead of wrapping.

-N, --LINE-NUMBERS
: Number the lines.

-i, --ignore-case
: Searches ignore case unless the pattern contains a capital letter.

-I, --IGNORE-CASE
: Searches ignore case always.

-X -e -E -q -Q -s -c -d -m -M -w -L -K -n
: Accepted for compatibility; no effect.

--help, --version
: Print help or version and exit.

# KEYS

space, f, ^F, PgDn: forward one screen. b, ^B, PgUp: backward one screen. d, ^D and u, ^U: half a screen. j, e, ^N, Enter, Down and k, y, ^P, Up: one row. g, <, Home: top. G, >, End: bottom. `/text` and `?text`: search forward and backward (plain text, ignoring colour escape sequences; the search does not wrap). n, N: repeat in the same and the other direction. F: follow, keep reading and show new data until a key is pressed. =: show the position. r, R, ^L: redraw. h: one-line help. q, Q, ^C: quit.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | A file could not be opened, or a usage error. |

# ENVIRONMENT

none (the `LESS` variable is not read).

# STANDARD STREAMS

The screen is drawn on the alternate screen of the terminal; the keys are read from the terminal itself (`/dev/tty`, or the console on Windows), so standard input may be a pipe.

# COMPATIBILITY

Reference: GNU less 668 (`less --version` on the development machine). Behaviour was compared by hand, not by differential test; paging is interactive. See docs/compatibility/less.md.

# LIMITATIONS

- Regular-expression search, marks, `:n`/`:p` between files, the `LESS` variable, editing (`v`), horizontal scrolling and numeric prefixes are not implemented.
- Widths count bytes and UTF-8 characters as one column; wide characters are not handled.
- Output that never ends and is never read will keep growing the text in memory.
- Windows: console input and sizing are compile-checked only.

# SEE ALSO

cat(1), docs/compatibility/less.md

# VERSION

This manual describes util-core 0.2.0.
