% LS(1) util-core 0.0.0-dev | Util Core Manual
% Util Core contributors
% 2026-11-07

NAME
ls - list directory contents

SYNOPSIS
ls [OPTION]... [FILE]...
ls --help | --version

DESCRIPTION
List directory contents.

OPTIONS
-a, --all
: Do not ignore entries starting with `.`.

-A, --almost-all
: Like `-a` without the implied `.` and `..`.

--author
: With `-l`, print the author (the owner) of each file.

-b, --escape
: C-style escapes for nongraphic characters.

--block-size=SIZE
: Scale sizes by SIZE (K, M, KB, KiB, human-readable, si, a leading `'`); also from LS_BLOCK_SIZE, BLOCK_SIZE, BLOCKSIZE.

-B, --ignore-backups
: Ignore entries ending with `~`.

-c / -u
: With `-lt` sort by and show ctime / atime; with `-l` show it and sort by name; otherwise sort by it.

-C, -x, -m, -1, -l, --format=WORD
: Output format: columns, rows, comma list, one per line, long. `across`, `horizontal`, `commas`, `long`, `single-column`, `verbose`, `vertical` are accepted.

--color[=WHEN]
: Colour output by LS_COLORS (default colours when it is unset and TERM or COLORTERM allow it).

-d, --directory
: List directories themselves.

-D, --dired
: Emit the `//DIRED//` offsets for Emacs.

-f
: `-a -U`.

-F, --classify[=WHEN], --file-type, -p, --indicator-style=WORD
: Append type indicators.

--full-time, --time-style=STYLE
: `full-iso`, `long-iso`, `iso`, `locale`, `+FORMAT` (two lines for old and recent files); TIME_STYLE is honoured.

-g, -o, -G, --no-group, -n
: Long-format owner/group variations and numeric ids.

--group-directories-first
: Directories before files.

-h, --human-readable, --si, -k
: Size units.

-H, -L, --dereference-command-line-symlink-to-dir
: Symbolic link handling.

--hide=PATTERN, -I, --ignore=PATTERN
: Skip entries matching a shell pattern (`fnmatch` with FNM_PERIOD).

--hyperlink[=WHEN]
: OSC 8 hyperlinks (`file://HOST/PATH`).

-i, --inode
: Print inode numbers.

-N, -q, -Q, --quoting-style=WORD, --show-control-chars, --hide-control-chars
: Name quoting; `QUOTING_STYLE` is honoured.

-r, -R, -S, -t, -U, -v, -X, --sort=WORD, --time=WORD
: Ordering (`none`, `size`, `time`, `version`, `extension`, `name`, `width`); times `atime`, `ctime`, `mtime`, `birth`.

-s, --size
: Allocated size in blocks.

-T, --tabsize=COLS, -w, --width=COLS
: Tab stops and line width; COLUMNS and TABSIZE are honoured.

-Z, --context
: Security context (read from the `security.selinux` attribute; `?` when absent).

--zero
: End lines with NUL.

--help, --version
: Print help or version and exit.

EXIT STATUS
Status	Meaning
0	Success.
1	Minor problems (for example, cannot access a subdirectory).
2	Serious trouble (for example, cannot access a command-line argument, or a usage error).

ENVIRONMENT
none (locale variables are ignored; behaviour is that of the C locale)

STANDARD STREAMS
Results go to standard output; diagnostics go to standard error prefixed with the command name.

COMPATIBILITY
Reference: GNU coreutils 9.7 (`/usr/bin/ls --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "ls invocation" (`info '(coreutils) ls invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), ls, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ls.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_ls.sh`).
See docs/compatibility/ls.md for details.

LIMITATIONS
- Only the C locale is modelled: names sort bytewise, only ASCII counts as printable (with `-q` every other byte becomes `?`), `locale` quoting uses `'`, and month names are English. GNU in a UTF-8 locale differs.
- `std.Io` does not report `.` and `..`, so they are added at the start of each directory; GNU lists them wherever the file system returns them (first on common file systems).
- Capability colouring (`ca=`) is accepted in LS_COLORS but never applied.
- SELinux contexts are read from the `security.selinux` attribute only; ACLs are detected through the `system.posix_acl_*` attributes, so `+` appears only when the file system exposes them.
- The terminal is not put into raw mode and no signal handlers restore colour on SIGINT/SIGTSTP.
- A directory's contents are not streamed: all names of one directory are held in memory (except for the `-U1` case, which GNU also streams).

SEE ALSO
docs/compatibility/ls.md, docs/architecture.md

VERSION
This manual describes the development version 0.0.0-dev; no release exists.
