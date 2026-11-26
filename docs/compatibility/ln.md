# ln: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU ln 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/ln --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "ln invocation" (`info '(coreutils) ln invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/ln-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), ln, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/ln.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_ln.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-s, --symbolic`: Symbolic links.
- `-f, --force`: Replace existing destinations.
- `-i, --interactive`: Prompt (reads y/n from standard input).
- `-b, --backup[=CONTROL]`: Back up replaced files (`none`, `simple`, `numbered`, `existing` and their aliases); `-S SUFFIX` (which also turns backups on) and `SIMPLE_BACKUP_SUFFIX` set the simple suffix; one that is empty or contains `/` means `~`. Backups are named as by cp, mv and install: `existing` is numbered when any numbered backup exists, and `numbered` takes the highest number plus one.
- `-L, -P`: Hard links follow / do not follow symbolic-link sources.
- `-n, --no-dereference`: Treat a symlink-to-directory destination as a file.
- `-r, --relative`: With -s, make the link relative to its own directory.
- `-t DIR, -T`: Target directory / treat the destination as a normal file.
- `-v, --verbose`: Print each link as GNU does (`'dest' => 'src'`, `->` for symbolic ones, `'backup~' ~ 'dest' => 'src'` with backups).
- `-d, -F`: Ignored.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Operand forms and every diagnostic reproduce GNU 9.7; the 'same file' test is only made when the destination would be replaced (-f, -i or a backup), as GNU does.
- With -i and no backup the 'same file' test is made as with -f. GNU 9.7 does not make it, so answering yes to `ln -si LINK FILE`, where LINK points to FILE, destroys FILE; here it is refused with status 1.
- `ln -f LINK FILE` (a hard link, without -L or a backup), where LINK is a symbolic link leading to FILE and FILE has no other name, is refused as 'same file'. GNU 9.7 replaces FILE by a link to itself and the data is lost.

## Library

Library: module `util_core.ln` (`src/lib/ln.zig`); the executable only parses arguments and words the diagnostics.

## Extensions

None. Behaviour that is not GNU's is listed under "Known deviations and gaps".

## Known deviations and gaps

- `--help` is shorter than GNU's.

## Tests

test/test_ln.sh (142 cases: hard, symbolic, relative, backup and interactive forms and their errors) — differential tests using run_tree (two fresh directories, GNU in one and ours in the other; stdout, stderr with the directory name masked, exit status and the resulting tree including symlink targets, link counts and which names are one file are compared).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
