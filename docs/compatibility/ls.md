# ls: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU ls 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/ls --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "ls invocation" (`info '(coreutils) ls invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/ls-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), ls, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ls.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_ls.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --all`: Do not ignore entries starting with `.`.
- `-A, --almost-all`: Like `-a` without the implied `.` and `..`.
- `--author`: With `-l`, print the author (the owner) of each file.
- `-b, --escape`: C-style escapes for nongraphic characters.
- `--block-size=SIZE`: Scale sizes by SIZE (K, M, KB, KiB, human-readable, si, a leading `'`); also from LS_BLOCK_SIZE, BLOCK_SIZE, BLOCKSIZE.
- `-B, --ignore-backups`: Ignore entries ending with `~`.
- `-c / -u`: With `-lt` sort by and show ctime / atime; with `-l` show it and sort by name; otherwise sort by it.
- `-C, -x, -m, -1, -l, --format=WORD`: Output format: columns, rows, comma list, one per line, long. `across`, `horizontal`, `commas`, `long`, `single-column`, `verbose`, `vertical` are accepted.
- `--color[=WHEN]`: Colour output by LS_COLORS (default colours when it is unset and TERM or COLORTERM allow it).
- `-d, --directory`: List directories themselves.
- `-D, --dired`: Emit the `//DIRED//` offsets for Emacs.
- `-f`: `-a -U`.
- `-F, --classify[=WHEN], --file-type, -p, --indicator-style=WORD`: Append type indicators.
- `--full-time, --time-style=STYLE`: `full-iso`, `long-iso`, `iso`, `locale`, `+FORMAT` (two lines for old and recent files); TIME_STYLE is honoured.
- `-g, -o, -G, --no-group, -n`: Long-format owner/group variations and numeric ids.
- `--group-directories-first`: Directories before files.
- `-h, --human-readable, --si, -k`: Size units.
- `-H, -L, --dereference-command-line-symlink-to-dir`: Symbolic link handling.
- `--hide=PATTERN, -I, --ignore=PATTERN`: Skip entries matching a shell pattern (`fnmatch` with FNM_PERIOD).
- `--hyperlink[=WHEN]`: OSC 8 hyperlinks (`file://HOST/PATH`).
- `-i, --inode`: Print inode numbers.
- `-N, -q, -Q, --quoting-style=WORD, --show-control-chars, --hide-control-chars`: Name quoting; `QUOTING_STYLE` is honoured.
- `-r, -R, -S, -t, -U, -v, -X, --sort=WORD, --time=WORD`: Ordering (`none`, `size`, `time`, `version`, `extension`, `name`, `width`); times `atime`, `ctime`, `mtime`, `birth`.
- `-s, --size`: Allocated size in blocks.
- `-T, --tabsize=COLS, -w, --width=COLS`: Tab stops and line width; COLUMNS and TABSIZE are honoured.
- `-Z, --context`: Security context (read from the `security.selinux` attribute; `?` when absent).
- `--zero`: End lines with NUL.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Algorithms follow GNU ls.c: entries are collected per directory, sorted with a stable merge sort (names compare bytewise, as in the C locale), and printed in columns using the same width search as GNU, including tab indentation and the quoted-name alignment space.
- The long format column widths, the `total` line, the six-month `recent` rule for dates, the `?` placeholders for entries that cannot be examined, device numbers, symlink targets and `+` for entries carrying an ACL attribute follow GNU.
- Quoting is a port of the gnulib quotearg algorithm (all ten styles, extra quoted characters for `-F` indicators and `:` in directory headings).
- `-R` detects directory cycles through the device and inode of each directory being listed (`not listing already-listed directory`).
- Exit status is 0, 1 for minor problems (for example an unreadable subdirectory) and 2 for serious trouble (an unreadable command-line argument or a usage error).
- Colours use the LS_COLORS grammar of GNU (including extension globs with case folding rules, `ln=target`, escape sequences, and the known-terminal fallback when LS_COLORS is unset). An unparsable value disables colour with `unparsable value for LS_COLORS environment variable`.
- `dir` is `ls -C -b` and `vdir` is `ls -l -b`; they are separate commands sharing the implementation.

## Known deviations and gaps

- Only the C locale is modelled: names sort bytewise, only ASCII counts as printable (with `-q` every other byte becomes `?`), `locale` quoting uses `'`, and month names are English. GNU in a UTF-8 locale differs.
- `std.Io` does not report `.` and `..`, so they are added at the start of each directory; GNU lists them wherever the file system returns them (first on common file systems).
- Capability colouring (`ca=`) is accepted in LS_COLORS but never applied.
- SELinux contexts are read from the `security.selinux` attribute only; ACLs are detected through the `system.posix_acl_*` attributes, so `+` appears only when the file system exposes them.
- The terminal is not put into raw mode and no signal handlers restore colour on SIGINT/SIGTSTP.
- A directory's contents are not streamed: all names of one directory are held in memory (except for the `-U1` case, which GNU also streams).

## Tests

`sh test/test_ls.sh`: 1291 differential cases against GNU ls 9.7 (C locale) covering sorting, formats and widths, long format, time styles and zones, all quoting and indicator styles, ignore patterns, recursion and loop detection, dereference options, `--dired`, `--zero`, hyperlinks, LS_COLORS parsing and terminal output through `script`, plus `dir` and `vdir`.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
