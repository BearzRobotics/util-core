# tree: compatibility record

Status: implemented with the gaps listed below; differential tests pass against tree 2.3.1 (C and UTF-8 locales). Date: 2026-11-07

## Reference

tree 2.3.1 by Steve Baker, Thomas Moore, Francesc Rocher, Florian Sesser and Kyosuke Tokoro (`/usr/bin/tree --version` on the development machine). tree has no specification beyond its manual page; the behaviour was taken from the installed binary and checked with differential tests (`sh test/test_tree.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, -d, -l, -f, -x, -L LEVEL`: All files, directories only, follow symlinks, full path prefix, stay on one file system, depth limit.
- `-P PATTERN, -I PATTERN, --ignore-case, --matchdirs, --prune, --filelimit N`: Pattern include/exclude, case-insensitive matching, match directory names, drop empty directories, do not open large directories.
- `-p, -u, -g, -s, -h, --si, --du, -D, --timefmt FMT, -F, --inodes, --device`: Per-entry information and classification characters.
- `-v, -t, -c, -U, -r, --sort=KEY, --dirsfirst, --filesfirst`: Sorting (name, version, size, mtime, ctime, none).
- `-q, -N, -Q`: Replace unprintable characters, print raw, or quote names.
- `-i, -A, -S, -n, -C, --charset=NAME, --noreport`: Indentation, line-drawing character sets, colours (LS_COLORS), report line.
- `-X, -J`: XML and JSON output.
- `-o FILE`: Write the listing to FILE.
- `--version, --help`: Print version or the option summary.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Output follows tree 2.3.1: `|--`/`` `-- `` lines in the C locale and box-drawing characters in UTF-8 locales, `name -> target` for links, and the `N directories, M files` report (the start directory counts only when something is listed).
- Names are escaped as tree does for the locale (octal escapes, `\\` and `\ ` in the C locale).
- Directories that cannot be opened get an inline `[error opening dir]` note and exit status 2; link loops get `[recursive, not followed]`.

## Known deviations and gaps

- Not implemented: `-H` (HTML), `--fromfile`, `--fromtabfile`, `--gitignore`, `--info`, `--hyperlink`, `--compress`, `--condense`, `-R`, `--opt-toggle`, ACL and SELinux display.
- The multi-root JSON/XML output reproduces tree's separators only for the cases covered by the tests; a symbolic link to the start directory in -J output lacks tree's empty `contents` array.
- --charset names other than UTF-8 and ASCII only change the last connector (`&middot;--`) like tree does; the 'Valid charsets' list for a missing argument is not printed.

## Tests

`sh test/test_tree.sh`: about 650 differential cases against tree 2.3.1 (installed here) in the C and C.UTF-8 locales on a fixture with odd names, links, loops, fifos and an unreadable directory, including LS_COLORS variants. tree is not a GNU program, so the test library is told to accept it as the reference.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
