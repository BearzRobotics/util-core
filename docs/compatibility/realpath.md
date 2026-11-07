# realpath: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU realpath 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/realpath --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "realpath invocation" (`info '(coreutils) realpath invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/realpath-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), realpath, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/realpath.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_realpath.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-e, -m`: All components must exist / none need to.
- `-s, --strip, --no-symlinks`: Do not expand symbolic links (existence and loops are still diagnosed as GNU does); overridden by -L.
- `-L, -P`: Resolve `..` before symbolic links / as encountered (default).
- `-q`: Quiet.
- `-z`: NUL-terminated.
- `--relative-to=DIR, --relative-base=DIR`: Relative output; a relative-to directory outside the relative-base disables it.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Same resolver as readlink (src/paths.zig).

## Known deviations and gaps

- `-L` is accepted and resolves like `-P` apart from its interaction with `-s`; the difference matters only when `..` follows a symbolic link.

## Tests

test/test_realpath.sh (551 cases: option mixes over 33 paths, relative-to/base combinations) — differential tests using run_tree (two fresh directories, GNU in one and ours in the other; stdout, stderr with the directory name masked, exit status and the resulting tree including symlink targets are compared).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
