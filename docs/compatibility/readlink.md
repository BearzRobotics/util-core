# readlink: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU readlink 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/readlink --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "readlink invocation" (`info '(coreutils) readlink invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/readlink-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), readlink, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/readlink.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_readlink.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-f, -e, -m`: Canonicalise: last component may be missing / all must exist / nothing needs to exist.
- `-n`: No trailing delimiter (ignored with several operands, with a warning).
- `-q, -s, -v`: Quiet (default) / verbose errors.
- `-z`: NUL-terminated output.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Resolution is done component by component in src/paths.zig; `-m` tolerates symlink loops and keeps them unresolved, `-f`/`-e` report `Too many levels of symbolic links`, and a trailing slash on a non-directory is `Not a directory` for `-f`/`-e`.

## Known deviations and gaps

- None known.

## Tests

test/test_readlink.sh (450 cases: every option over 29 awkward paths) — differential tests using run_tree (two fresh directories, GNU in one and ours in the other; stdout, stderr with the directory name masked, exit status and the resulting tree including symlink targets are compared).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
