# truncate: compatibility record

Status: implemented with the gaps listed below; differential tests pass against GNU truncate 9.7 in the C locale. Date: 2026-11-07

## Reference

GNU coreutils 9.7 (`/usr/bin/truncate --version` on the development machine, installed from Ubuntu `gnu-coreutils` 9.7-3ubuntu2.1). Consulted 2026-11-07: the GNU manual node "truncate invocation" (`info '(coreutils) truncate invocation'`, https://www.gnu.org/software/coreutils/manual/html_node/truncate-invocation.html); POSIX.1-2024 (IEEE Std 1003.1-2024), truncate, https://pubs.opengroup.org/onlinepubs/9799919799/utilities/truncate.html. Behaviour was also checked by differential tests against the GNU binary run with LC_ALL=C (`sh test/test_truncate.sh`). Where POSIX and GNU differ, the text below says which one we follow.

## Supported options

- `-s, --size=SIZE`: New size; prefixes `+ - < > / %` and suffixes K, M, G, T, P, E, Z, Y, R, Q (1024) or KB, MB, ... (1000); a plain `b` is not a valid suffix.
- `-r, --reference=RFILE`: Use RFILE's size (alone), or as the base of a relative SIZE.
- `-c`: Do not create files.
- `-o`: SIZE counts I/O blocks.
- `--help, --version`: Print help or version and exit.

## Supported behaviour

- Files are created unless `-c`; extending leaves a sparse hole.

## Known deviations and gaps

- None known.

## Tests

test/test_truncate.sh (148 cases) — differential tests using run_tree (two fresh directories, GNU in one and ours in the other; stdout, stderr with the directory name masked, exit status and the resulting tree including symlink targets are compared).

## Not yet done

- Not run under multicall dispatch.
- Not run on Windows or macOS.
