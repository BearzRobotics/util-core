# cp: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU cp 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/cp --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "cp invocation" (`info '(coreutils) cp invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/cp-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), cp, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/cp.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_cp.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-a, --archive`: Same as `-dR --preserve=all`.
- `--attributes-only`: Copy attributes, not data.
- `--backup[=CONTROL], -b, -S, --suffix`: Backups (`none`, `simple`, `existing`, `numbered`); VERSION_CONTROL and SIMPLE_BACKUP_SUFFIX are honoured.
- `--copy-contents, -d, -H, -L, -P`: Symlink and special-file handling.
- `-f, -i, -n, -u, --update[=WHEN]`: Overwrite policy (`all`, `none`, `none-fail`, `older`).
- `-l, -s`: Hard or symbolic links instead of copies.
- `-p, --preserve[=LIST], --no-preserve=LIST`: mode, ownership, timestamps, links, context, xattr, all.
- `--parents, -R/-r, -t, -T, -v, -x, --debug`: Directories, destination handling, verbosity.
- `--reflink[=WHEN], --sparse=WHEN, --remove-destination, --strip-trailing-slashes, --keep-directory-symlink`: As documented by GNU.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- The control flow follows copy.c: stat of source and destination, same-file detection, hard-link preservation across arguments, backup creation and un-backup on failure, directory creation with deferred permissions, and the exact diagnostics (`cannot create regular file`, `will not overwrite just-created`, `omitting directory`, ...).
- Directory entries are copied in inode order, like gnulib's `savedir(SAVEDIR_SORT_FASTREAD)`.
- `-n` prints GNU 9.7's warning about its non-portable behaviour; an interactive refusal makes the exit status 1.

## Known deviations and gaps

- Only the C locale: names, quotes and messages are the English/ASCII ones.
- SELinux contexts, ACLs and extended attributes are not copied (`--preserve=context` fails as on a kernel without SELinux; `-Z` and `--context` are accepted and ignored).
- Reflink (`--reflink=always`) reports `failed to clone ... Operation not supported`; `auto` falls back to a normal copy. File data is copied with read/write rather than `copy_file_range`, so `--debug` states what GNU would report.
- Sparse files: holes are detected with SEEK_DATA/SEEK_HOLE and recreated; `--sparse=always` turns blocks of zeros into holes.
- Reading a FIFO source blocks until a writer appears, exactly like GNU.

## Tests

`sh test/test_cp.sh`: about 740 differential cases against GNU cp 9.7 (C locale) comparing output, exit status, file tree, modes and checksums.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
