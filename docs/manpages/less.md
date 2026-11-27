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
: Quit at once, printing the text, if it fits on one screen. The terminal is not touched until the text is longer than that, so what is typed meanwhile is left for others. The text is shown as the pager would show it: without `-R`, control characters appear as `^X` and are not sent to the terminal.

-R, --RAW-CONTROL-CHARS, -r
: Pass colour escape sequences (`ESC [` digits, `;` or `:`, `m`) and OSC 8 hyperlinks through; every other escape sequence is shown as `^[` and the text that follows it. Without it, control characters are shown as `^X`. With or without it, the control characters U+0080 to U+009F are shown as `<U+009B>` and bytes that are not part of a UTF-8 character as `<9B>`; valid UTF-8 is passed in every locale.

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

space, f, ^F, PgDn: forward one screen. b, ^B, PgUp: backward one screen. d, ^D and u, ^U: half a screen. j, e, ^N, Enter, Down and k, y, ^P, Up: one row. g, <, Home: top. G, >, End: bottom. `/text` and `?text`: search forward and backward (plain text, ignoring colour escape sequences; the search does not wrap). n, N: repeat in the same and the other direction. F: follow (see FOLLOWING). =: show the position. r, R, ^L: redraw. h: one-line help. q, Q, ^C: quit (while following, ^C stops following instead).

# FOLLOWING

F goes to the end of the text and shows new data as it arrives, from a pipe or from a file that is still being written, such as a log. All the keys keep working. After scrolling back, the view stays where it is while data continues to be read; G, or scrolling to the end, makes it move with the data again. ^X or ^C stops following and q quits. When several files are given, the last one is followed. A file is followed through the descriptor opened at the start: one that is renamed and replaced (log rotation) is not reopened, and after one is truncated nothing is shown until it grows past what was already read.

Unlike less(1), where no other command works until following is interrupted, scrolling, searching and quitting work while following.

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

One deliberate difference: scrolling, searching and quitting work while following (see FOLLOWING).

# LIMITATIONS

- Regular-expression search, marks, `:n`/`:p` between files, the `LESS` variable, editing (`v`), horizontal scrolling and numeric prefixes are not implemented.
- Widths count bytes and UTF-8 characters as one column; wide characters are not handled.
- Output that never ends and is never read will keep growing the text in memory.
- Windows: console input and sizing are compile-checked only.

# SEE ALSO

cat(1), docs/compatibility/less.md

# VERSION

This manual describes util-core 0.2.0.
