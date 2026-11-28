# tree: compatibility record

Status: implemented with the gaps listed below; differential tests pass against tree 2.3.1 (C and UTF-8 locales). Date: 2026-11-07

Library: `util_core.tree` (`src/lib/tree.zig`); `src/commands/tree.zig` is the thin wrapper (decision 0004).

## Reference

tree 2.3.1 by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser and Kyosuke Tokoro (`/usr/bin/tree --version` on the development machine). tree has no specification beyond its manual page; the behaviour was taken from the installed binary and checked with differential tests (`sh test/test_tree.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, -d, -l, -f, -x, -L LEVEL`: All files, directories only, follow symlinks, full path prefix, stay on one file system, depth limit.
- `-P PATTERN, -I PATTERN, --ignore-case, --matchdirs, --prune, --filelimit N`: Pattern include/exclude, case-insensitive matching, match directory names, drop empty directories, do not open large directories.
- `-p, -u, -g, -s, -h, --si, --du, -D, --timefmt FMT, -F, --inodes, --device`: Per-entry information and classification characters.
- `-v, -t, -c, -U, -r, --sort=KEY, --dirsfirst, --filesfirst`: Sorting (name, version, size, mtime, ctime, none).
- `-q, -N, -Q`: Replace unprintable characters, print raw, or quote names.
- `-i, -A, -S, -n, -C, --charset=NAME, --noreport`: Indentation, line-drawing character sets, colours, report line. Colour is chosen as tree does: never without `$TERM`; `-C` always; otherwise not with `-n` or a non-empty `$NO_COLOR`, and only on a terminal (or with `$CLICOLOR_FORCE`) when there is a table or `$CLICOLOR` is set. The table is `$TREE_COLORS`, else `$LS_COLORS`; when that is empty and colour is wanted, tree's built-in one.
- `-X, -J`: XML and JSON output.
- `-o FILE`: Write the listing to FILE.
- `--version, --help`: Print version or the option summary.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Output follows tree 2.3.1: `|--`/`` `-- `` lines in the C locale and box-drawing characters in UTF-8 locales, `name -> target` for links, and the `N directories, M files` report (the start directory counts only when something is listed).
- Names are escaped as tree does for the locale (octal escapes, `\\` and `\ ` in the C locale). In a UTF-8 locale, characters that are not printable (the C1 controls among them) are shown as their number in octal, or `?` with `-q`; `-N` writes names as they are. Which characters are printable comes from util-core's Unicode tables, which can be older than the system's, so a recently assigned character may be escaped.
- Directories that cannot be opened get an inline `[error opening dir]` note and exit status 2; link loops get `[recursive, not followed]`.

## Extensions

None added by util-core: tree is not a GNU program and its own options (`-J`, `-X`, `--du`, ...) are tree 2.3.1 behaviour. The differences from tree 2.3.1 are listed under "Known deviations and gaps". The library (`util_core.tree`) reports unreadable directories as Observer events in addition to the inline `[error opening dir]` note.

## Known deviations and gaps

- User and group names come from `/etc/passwd` and `/etc/group` alone, not through NSS. tree asks the C library, which knows more sources. For accounts that exist only in LDAP, SSSD, systemd-homed or as systemd dynamic users, `-u` and `-g` print numbers.
- Output that cannot be written (a full disk, with or without `-o`) is reported as `tree: write error: ...` with status 1; tree 2.3.1 is silent and exits 0.
- Not implemented: `-H` (HTML), `--fromfile`, `--fromtabfile`, `--gitignore`, `--info`, `--hyperlink`, `--compress`, `--condense`, `-R`, `--opt-toggle`, ACL and SELinux display.
- The multi-root JSON/XML output reproduces tree's separators only for the cases covered by the tests; a symbolic link to the start directory in -J output lacks tree's empty `contents` array.
- With `--du -l` and links that lead into each other, which link is followed and which is `recursive, not followed` depends on the order of the walk. tree 2.3.1 takes the order in which the file system returns the names; ours takes the order of the listing, so the result is the same everywhere. The total is not affected.
- `-J` and `-X` differences from tree 2.3.1 that are left as they are: with `-i` tree writes the JSON on one line (ours keeps the indentation); tree prints inode and device `0` for the start directory and for symbolic links under `--inodes`/`--device` (ours prints the real numbers, which is more useful); with `-J -l -f` tree 2.3.1 names a link that it does not follow `DIR/.` (ours prints its path). With `-l` a link to an already-listed directory is `recursive, not followed` in every output mode and for `--du`, as in tree.
- A modification time whose year does not fit a `struct tm` is shown as seconds since the Epoch (`--timefmt` is not applied to it). tree 2.3.1 crashes on such a file.
- --charset names other than UTF-8 and ASCII only change the last connector (`&middot;--`) like tree does; the 'Valid charsets' list for a missing argument is not printed.

## Tests

`sh test/test_tree.sh`: 741 differential cases against tree 2.3.1 (installed here) in the C and C.UTF-8 locales on a fixture with odd names, links, loops, fifos and an unreadable directory, including LS_COLORS variants. tree is not a GNU program, so the test library is told to accept it as the reference. The structured output (`-J`, `-X`) is covered with `-f`, `-h`, `--si`, `-D`, `--timefmt`, `-pugsD`, `--du` and several roots; those cases found and fixed four gaps (see decision 0003).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
