# ln: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU ln 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/ln --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "ln invocation" (`info '(coreutils) ln invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), ln, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ln.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_ln.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-s, --symbolic`: Symbolic links.
- `-f, --force`: Replace existing destinations.
- `-i, --interactive`: Prompt (reads y/n from standard input).
- `-b, --backup[=CONTROL]`: Back up replaced files (`none`, `simple`, `numbered`, `existing` and their aliases); `-S SUFFIX` and `SIMPLE_BACKUP_SUFFIX` set the simple suffix.
- `-L, -P`: Hard links follow / do not follow symbolic-link sources.
- `-n, --no-dereference`: Treat a symlink-to-directory destination as a file.
- `-r, --relative`: With -s, make the link relative to its own directory.
- `-t DIR, -T`: Target directory / treat the destination as a normal file.
- `-v, --verbose`: Print each link as GNU does (`'dest' => 'src'`, `->` for symbolic ones, `'backup~' ~ 'dest' => 'src'` with backups).
- `-d, -F`: Ignored.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Operand forms and every diagnostic reproduce GNU 9.7; the 'same file' test is only made when the destination would be replaced (-f, -i or a backup), as GNU does.

## Known deviations and gaps

- Same-file detection compares inode numbers only (`std.Io.File.Stat` has no device number), so files on different devices with equal inode numbers would be taken for one file.
- `--help` is shorter than GNU's.

## Tests

test/test_ln.sh (87 cases: hard, symbolic, relative, backup and interactive forms and their errors) — differential tests using run_tree (two fresh directories, GNU in one and ours in the other; stdout, stderr with the directory name masked, exit status and the resulting tree including symlink targets are compared).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
