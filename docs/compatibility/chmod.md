# chmod: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU chmod 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/chmod --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "chmod invocation" (`info '(coreutils) chmod invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/chmod-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), chmod, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/chmod.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_chmod.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-c, -v, -f`: Report changes / every file / suppress most errors.
- `-R, -H, -L, -P`: Recurse; symlink-to-directory arguments traversed (-H, default), all symlinks traversed (-L), none (-P). Symlinks met inside a tree are skipped unless -L.
- `-h, --no-dereference, --dereference`: Act on a symlink itself (it cannot change, so it is left alone) or its target.
- `--reference=RFILE`: Use RFILE's mode.
- `--preserve-root, --no-preserve-root`: Refuse to recurse on `/` (including `/.`, reported as `(same as '/')`).
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Mode text is parsed by src/mode.zig (octal; symbolic with `ugoa`, `+-=`, `rwxXst`, copy-from-class). With no `who` the umask applies; a removal the umask prevents is reported as `new permissions are A, not B` (exit 1).
- A directory keeps its set-user-ID/set-group-ID bits for octal modes of fewer than five digits and for symbolic modes that do not mention `s`.
- A mode-like first argument such as `-w` or `-rwx` is the MODE, not an option.

## Known deviations and gaps

- `-h` on a symlink does nothing (as on Linux, where symlink modes cannot be changed); `--help` is shorter than GNU's.

## Tests

test/test_chmod.sh (278 cases: octal and 70 symbolic modes on files and directories, five umasks, verbose and quiet forms, --reference, recursion with -H/-L/-P, symlinks, option and mode errors) — differential tests using run_tree (two fresh directories, GNU in one and ours in the other; stdout, stderr with the directory name masked, exit status and the resulting tree with modes and symlink targets are compared).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
