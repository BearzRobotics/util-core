# NAME

tree - list contents of directories in a tree-like format

# SYNOPSIS

    tree [OPTION]... [DIRECTORY]...
    tree --help | --version

# DESCRIPTION

List contents of directories in a tree-like format.

# OPTIONS

-a, -d, -l, -f, -x, -L LEVEL
: All files, directories only, follow symlinks, full path prefix, stay on one file system, depth limit.

-P PATTERN, -I PATTERN, --ignore-case, --matchdirs, --prune, --filelimit N
: Pattern include/exclude, case-insensitive matching, match directory names, drop empty directories, do not open large directories.

-p, -u, -g, -s, -h, --si, --du, -D, --timefmt FMT, -F, --inodes, --device
: Per-entry information and classification characters.

-v, -t, -c, -U, -r, --sort=KEY, --dirsfirst, --filesfirst
: Sorting (name, version, size, mtime, ctime, none).

-q, -N, -Q
: Replace unprintable characters, print raw, or quote names.

-i, -A, -S, -n, -C, --charset=NAME, --noreport
: Indentation, line-drawing character sets, colours (LS_COLORS), report line.

-X, -J
: XML and JSON output.

-o FILE
: Write the listing to FILE.

--version, --help
: Print version or the option summary.

--help, --version
: Print help or version and exit.

# EXIT STATUS

| Status | Meaning |
|---|---|
| 0 | Success. |
| 1 | Invalid option or argument. |
| 2 | A directory could not be opened. |


# ENVIRONMENT

LC_ALL, LC_CTYPE, LANG
: A UTF-8 locale selects box-drawing characters and decides which characters of a name are printable.

TZ
: The time zone of dates.

TERM
: Without it nothing is coloured, even with `-C`.

TREE_COLORS, LS_COLORS
: The colour table; the first that is set is used. When it is empty and colour is wanted, tree's built-in table is used.

NO_COLOR, CLICOLOR, CLICOLOR_FORCE
: Without `-C`, a non-empty NO_COLOR turns colour off. Colour otherwise needs a table (CLICOLOR provides the built-in one) and a terminal (CLICOLOR_FORCE does without).

# STANDARD STREAMS

Results go to standard output; diagnostics go to standard error prefixed with the command name.

# COMPATIBILITY

Reference: tree 2.3.1 by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser and Kyosuke Tokoro (`/usr/bin/tree --version` on the development machine). tree has no specification beyond its manual page; the behaviour was taken from the installed binary and checked with differential tests (`sh test/test_tree.sh`).

A modification time whose year is too large for a calendar date (a file system can hold such a time) is shown as a number of seconds since the Epoch; tree 2.3.1 crashes on it.

See docs/compatibility/tree.md for details.

# LIMITATIONS

- User and group names come from `/etc/passwd` and `/etc/group` alone, not through NSS. tree asks the C library, which knows more sources. For accounts that exist only in LDAP, SSSD, systemd-homed or as systemd dynamic users, `-u` and `-g` print numbers.
- Output that cannot be written (a full disk, with or without `-o`) is reported as `tree: write error: ...` with status 1; tree 2.3.1 is silent and exits 0.
- Not implemented: `-H` (HTML), `--fromfile`, `--fromtabfile`, `--gitignore`, `--info`, `--hyperlink`, `--compress`, `--condense`, `-R`, `--opt-toggle`, ACL and SELinux display.
- The multi-root JSON/XML output reproduces tree's separators only for the cases covered by the tests; a symbolic link to the start directory in -J output lacks tree's empty `contents` array.
- --charset names other than UTF-8 and ASCII only change the last connector (`&middot;--`) like tree does; the 'Valid charsets' list for a missing argument is not printed.

# SEE ALSO

docs/compatibility/tree.md, docs/architecture.md

# VERSION

This manual describes util-core 0.2.0.

