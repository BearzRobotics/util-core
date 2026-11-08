% TREE(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
tree - list contents of directories in a tree-like format

SYNOPSIS
tree [OPTION]... [DIRECTORY]...
tree --help | --version

DESCRIPTION
List contents of directories in a tree-like format.

OPTIONS
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

EXIT STATUS
Status	Meaning
0	Success.
1	Invalid option or argument.
2	A directory could not be opened.

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: tree 2.3.1 by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser and Kyosuke Tokoro (`/usr/bin/tree --version` on the development machine). tree has no specification beyond its manual page; the behaviour was taken from the installed binary and checked with differential tests (`sh test/test_tree.sh`).
See docs/compatibility/tree.md for details.

LIMITATIONS
- Not implemented: `-H` (HTML), `--fromfile`, `--fromtabfile`, `--gitignore`, `--info`, `--hyperlink`, `--compress`, `--condense`, `-R`, `--opt-toggle`, ACL and SELinux display.
- The multi-root JSON/XML output reproduces tree's separators only for the cases covered by the tests; a symbolic link to the start directory in -J output lacks tree's empty `contents` array.
- --charset names other than UTF-8 and ASCII only change the last connector (`&middot;--`) like tree does; the 'Valid charsets' list for a missing argument is not printed.

SEE ALSO
docs/compatibility/tree.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
