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

## Library

Library: module `util_core.cp` (`src/lib/cp.zig`) over the shared copy engine `src/copy.zig`; the executable only parses arguments and words usage errors. The engine reports GNU-worded diagnostics as text events (it knows the control flow that selects the message); the wrapper routes them.

## Extensions

None. Behaviour that is not GNU's is listed under "Known deviations and gaps".

## Known deviations and gaps

- Only the C locale: names, quotes and messages are the English/ASCII ones.
- The source tree is walked through open directories (src/dirat.zig): everything below an operand is examined, opened, read and hard-linked by its name in the directory that was listed, so a directory replaced by a link while cp or a cross-device mv runs is not followed, and source names are not limited by PATH_MAX. The walk stops below 10000 levels.
- The destination tree is walked the same way: everything below an operand is created and given its mode, owner, times and ACLs by name in the directory that was made or examined, so recursive copies (and cross-device mv) also reach destinations past PATH_MAX. A symbolic link that was in the destination when cp looked is treated as in GNU (a regular file is written through it). One that appears afterwards is not followed; for a file that is reported as `cannot create regular file X: it was replaced by a symbolic link while being copied`, where GNU would write through it. The directories `--parents` makes or finds are checked to be the same ones when copying into them and when restoring their attributes. Preserving the ACL of a fifo, or of a directory that cannot be read, needs /proc. A hard link to a file copied earlier (`--preserve=links`) is still made from that copy's path, as in GNU.
- POSIX ACLs travel with the mode (`-p`, `-a`, `--preserve=mode`, and mv between file systems): the source's access ACL and a directory's default ACL are copied, as in GNU. If the destination cannot store them the copy is reported (`preserving permissions for ...`) and, unlike GNU 9.7, which leaves the ACL mask as the owning group's permission, the group and other bits are narrowed so that nobody gains access. SELinux contexts and other extended attributes are not copied (`--preserve=context` fails as on a kernel without SELinux; `-Z` and `--context` are accepted and ignored). ACLs are handled on Linux only.
- Reflink (`--reflink=always`) is not implemented: it reports `failed to clone ... Operation not supported` and leaves an existing destination unchanged, even on file systems where GNU can clone; `auto` falls back to a normal copy. File data is copied with read/write rather than `copy_file_range`, so `--debug` states what GNU would report.
- Sparse files: holes are detected with SEEK_DATA/SEEK_HOLE and recreated; `--sparse=always` turns blocks of zeros into holes.
- Reading a FIFO source blocks until a writer appears, exactly like GNU.

## Tests

`sh test/test_cp.sh`: about 820 differential cases against GNU cp 9.7 (C locale) comparing output, exit status, file tree, modes, checksums, link counts and which names are one file; the sparse cases also compare allocated blocks.

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
