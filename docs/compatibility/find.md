# find: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU find 4.10. Date: 2026-11-07

## Reference

GNU findutils 4.10.0 (`/usr/bin/find --version` on the development machine). Consulted 2026-11-07: the GNU find manual (https://www.gnu.org/software/findutils/manual/html_mono/find.html) and POSIX.1-2024 find, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/find.html. Behaviour was checked by differential tests against the GNU binary (`sh test/test_find.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-H, -L, -P`: Symbolic link handling: command-line only, always, never (default).
- `-O level, -D opts`: Accepted; optimisation levels and debug options have no effect (-D help lists them).
- `-maxdepth N, -mindepth N, -depth/-d, -mount/-xdev, -noleaf, -ignore_readdir_race, -follow, -daystart, -warn/-nowarn`: Traversal options.
- `-name, -iname, -path/-wholename, -ipath, -lname, -ilname, -regex, -iregex, -regextype`: Name tests (fnmatch globs; regular expressions default to the Emacs syntax).
- `-type, -xtype, -size, -perm, -user, -group, -uid, -gid, -nouser, -nogroup, -links, -inum, -samefile, -empty, -fstype, -readable, -writable, -executable`: File property tests.
- `-atime, -ctime, -mtime, -amin, -cmin, -mmin, -used, -newer, -anewer, -cnewer, -newerXY`: Time tests; X and Y are a, c, m (and t for a date string); B (birth time) is rejected as GNU does here.
- `-print, -print0, -printf, -fprint, -fprint0, -fprintf, -ls, -fls`: Output actions; -printf supports all GNU directives and flags.
- `-exec, -execdir, -ok, -okdir (; and +), -delete, -prune, -quit`: Command, removal and control actions.
- `( ) ! -not -a -and -o -or ,`: Operators with GNU's precedence and error messages.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Entries are visited in readdir order (fts without a comparison function); `-depth` visits directories after their contents.
- If the expression has no action other than -prune or -quit, `-print` is added.
- `-exec ... +` batches arguments (about 100 KB per command line) and runs the rest at the end; `-execdir` runs in the file's directory with a `./name` argument.
- Symbolic-link loops under -L are reported like GNU (`File system loop detected`).
- The minute tests (-amin/-cmin/-mmin/-used) round up and the day tests round down, as GNU's pred_timewindow does.

## Known deviations and gaps

- Only the C locale and UTF-8 quoting of file names in messages are handled; there is no multibyte-aware matching in -name.
- `-regex` accepts Emacs, POSIX basic and extended syntax by translating them to the regex-zig Perl dialect; leftmost-longest alternation is not emulated (the whole path must match, so results are the same except for rare cases with back-references).
- -files0-from, -context (SELinux), -D tracing output and the optimiser (-O) are not implemented.
- `-exec` batching limits are fixed (about 100 KB) instead of being computed from ARG_MAX.
- `-fstype` reads /proc/self/mountinfo; file systems not listed there report `unknown`.

## Tests

`sh test/test_find.sh`: about 2,000 differential cases against GNU find 4.10 on a fixture tree with symlinks, loops, fifos, odd names, old timestamps and unreadable directories (tests, -printf directives, -exec/-ok with scripted answers, -delete and file-system changes compared with run_tree, error messages and exit statuses).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
